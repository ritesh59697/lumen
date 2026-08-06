import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import '../subtitles/cue_sanitizer.dart';
import '../subtitles/subtitle_model.dart';
import 'audio_extractor.dart';
import 'chunked_transcriber.dart';
import 'model_manager.dart';

/// Phases a transcription job moves through, in order.
enum TranscriptionStage {
  idle,
  downloadingModel,
  extractingAudio,
  transcribing,
  writingSubtitles,
  complete,
  failed,
  cancelled,
}

/// A snapshot of a transcription job, suitable for driving UI.
class TranscriptionState {
  const TranscriptionState({
    this.stage = TranscriptionStage.idle,
    this.progress,
    this.message,
    this.subtitlePath,
    this.partialSrt,
    this.error,
  });

  final TranscriptionStage stage;

  /// Fraction complete for the current stage, when it is measurable.
  ///
  /// Null means indeterminate — the UI should show a spinner rather than a
  /// bar. Whisper does not report progress during inference, so honesty
  /// here beats a fake animated bar.
  final double? progress;

  final String? message;

  /// Path of the written .srt, set once [stage] is [TranscriptionStage.complete].
  final String? subtitlePath;

  /// Subtitles for the part of the video transcribed so far, as SRT.
  ///
  /// Updated after each chunk while a long transcription is still running,
  /// so the player can show captions for the beginning of the video without
  /// waiting for the end of it.
  final String? partialSrt;

  final String? error;

  bool get isRunning =>
      stage != TranscriptionStage.idle &&
      stage != TranscriptionStage.complete &&
      stage != TranscriptionStage.failed &&
      stage != TranscriptionStage.cancelled;

  TranscriptionState copyWith({
    TranscriptionStage? stage,
    double? progress,
    bool clearProgress = false,
    String? message,
    String? subtitlePath,
    String? partialSrt,
    String? error,
  }) {
    return TranscriptionState(
      stage: stage ?? this.stage,
      progress: clearProgress ? null : (progress ?? this.progress),
      message: message ?? this.message,
      subtitlePath: subtitlePath ?? this.subtitlePath,
      partialSrt: partialSrt ?? this.partialSrt,
      error: error ?? this.error,
    );
  }
}

/// Runs the video -> audio -> Whisper -> .srt pipeline.
///
/// The service owns no player state. It takes a video path and produces a
/// subtitle file path; wiring that file into playback is the caller's job.
/// That separation keeps a failed or cancelled transcription from ever
/// disturbing playback.
class TranscriptionService {
  TranscriptionService({
    ModelManager? modelManager,
    AudioExtractor? extractor,
    this.sanitizer = const CueSanitizer(),
    WhisperController? controller,
  })  : _models = modelManager ?? ModelManager(),
        _extractor = extractor ?? const AudioExtractor(),
        _controller = controller ?? WhisperController() {
    // Let whisper_ggml_plus convert non-WAV input via our FFmpeg extractor.
    WhisperController.registerAudioConverter(_extractor);
  }

  final ModelManager _models;
  final AudioExtractor _extractor;
  final WhisperController _controller;
  final ChunkedTranscriber _chunker = const ChunkedTranscriber();

  /// Cleans raw Whisper segments into watchable cues.
  final CueSanitizer sanitizer;

  final _stateController = StreamController<TranscriptionState>.broadcast();

  /// Live job state. Broadcast, so several widgets may listen.
  Stream<TranscriptionState> get states => _stateController.stream;

  TranscriptionState _state = const TranscriptionState();
  TranscriptionState get state => _state;

  CancellationToken? _cancellation;

  void _emit(TranscriptionState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  /// Cancels the running job.
  ///
  /// Cancellation is cooperative and only takes effect between stages: the
  /// whisper.cpp call itself is a blocking FFI call that cannot be
  /// interrupted partway, so a cancel during inference lands when that
  /// call returns.
  void cancel() => _cancellation?.cancel();

  /// Transcribes [videoPath] and writes an .srt beside it.
  ///
  /// Returns the subtitle path, or null if the job failed or was cancelled —
  /// in which case [state] carries the reason.
  Future<String?> generate({
    required String videoPath,
    WhisperModel model = WhisperModel.base,
    String language = 'en',
    bool translateToEnglish = false,
    String? outputPath,
  }) async {
    final cancellation = CancellationToken();
    _cancellation = cancellation;

    File? extractedAudio;

    // Clear any previous result before the first await. Otherwise a stale
    // "failed" banner stays on screen through the opening stages — and when
    // the model is already downloaded, that first stage is skipped entirely,
    // so the old error can outlive the job that replaced it.
    _emit(const TranscriptionState(
      stage: TranscriptionStage.extractingAudio,
      message: 'Starting...',
    ));

    try {
      // ---- 1. Model ----------------------------------------------------
      if (!await _models.isInstalled(model)) {
        _emit(TranscriptionState(
          stage: TranscriptionStage.downloadingModel,
          progress: 0,
          message: 'Downloading ${model.modelName} model...',
        ));

        await _models.ensureDownloaded(
          model,
          cancellationToken: cancellation,
          onProgress: (p) => _emit(_state.copyWith(
            progress: p.fraction,
            message: 'Downloading ${model.modelName} model...',
          )),
        );
      }

      _throwIfCancelled(cancellation);

      // ---- 2. Audio ----------------------------------------------------
      _emit(const TranscriptionState(
        stage: TranscriptionStage.extractingAudio,
        message: 'Extracting audio...',
      ));

      if (!await _extractor.hasAudioTrack(videoPath)) {
        throw const TranscriptionException(
          'This file has no audio track, so there is nothing to transcribe.',
        );
      }

      extractedAudio = await _extractor.extract(videoPath);
      _throwIfCancelled(cancellation);

      // ---- 3. Transcribe -----------------------------------------------
      final audioSeconds =
          await _extractor.probeDurationSeconds(extractedAudio.path);
      final audioDuration = audioSeconds == null
          ? null
          : Duration(milliseconds: (audioSeconds * 1000).round());

      final rawCues = <SubtitleCue>[];

      if (audioDuration != null && _chunker.shouldChunk(audioDuration)) {
        // Long file: transcribe in chunks so there is real progress to show.
        _emit(TranscriptionState(
          stage: TranscriptionStage.transcribing,
          progress: 0,
          message: 'Transcribing ${_describe(audioDuration)} of audio...',
        ));

        rawCues.addAll(await _chunker.transcribe(
          wavPath: extractedAudio.path,
          audioDuration: audioDuration,
          model: model,
          controller: _controller,
          threads: _recommendedThreads(),
          language: language,
          translateToEnglish: translateToEnglish,
          isCancelled: () => cancellation.isCancelled,
          onProgress: (p) => _emit(_state.copyWith(
            progress: p.fraction,
            message: _progressMessage(p),
          )),
          onPartialCues: (partial) {
            // Chunks are transcribed in order, so a run that is half done
            // has subtitles for the first half of the video — which is the
            // part someone watching along is actually up to. Publishing them
            // as they arrive means playback can start immediately instead of
            // waiting for a multi-hour job to finish.
            final ready = sanitizer.sanitize(partial);
            if (ready.isEmpty) return;

            _emit(_state.copyWith(partialSrt: cuesToSrt(ready)));
          },
        ));
      } else {
        // Short file: one pass is quicker than the chunking overhead.
        _emit(const TranscriptionState(
          stage: TranscriptionStage.transcribing,
          message: 'Transcribing audio...',
        ));

        final result = await _controller.transcribe(
          model: model,
          audioPath: extractedAudio.path,
          lang: language,
          isTranslate: translateToEnglish,
          withTimestamps: true,
          // Already 16 kHz mono WAV, so skip the package's own conversion.
          convert: false,
          threads: _recommendedThreads(),
        );

        for (final s in result?.transcription.segments ?? const []) {
          rawCues.add(
            SubtitleCue(start: s.fromTs, end: s.toTs, text: s.text),
          );
        }
      }

      // A cancelled run keeps whatever was transcribed rather than discarding
      // it. On a multi-hour file, throwing away an hour of finished work
      // because the user stopped at 90% would be indefensible.
      final wasCancelled = cancellation.isCancelled;

      if (rawCues.isEmpty) {
        if (wasCancelled) throw const _CancelledSignal();
        throw const TranscriptionException(
          'No speech was detected in this file.',
        );
      }

      // ---- 4. Subtitles ------------------------------------------------
      _emit(const TranscriptionState(
        stage: TranscriptionStage.writingSubtitles,
        message: 'Writing subtitles...',
      ));

      final cues = sanitizer.sanitize(rawCues);

      if (cues.isEmpty) {
        throw const TranscriptionException(
          'Only non-speech audio (music or silence) was detected.',
        );
      }

      final destination =
          outputPath ?? await _subtitlePathFor(videoPath, language);
      await File(destination).writeAsString(cuesToSrt(cues));

      _emit(TranscriptionState(
        stage: TranscriptionStage.complete,
        progress: 1,
        message: wasCancelled
            // Say plainly that this covers only part of the video, so the
            // subtitles running out partway is expected rather than a bug.
            ? 'Stopped early — kept ${cues.length} subtitles '
                'up to ${_describe(cues.last.end)}.'
            : 'Generated ${cues.length} subtitles.',
        subtitlePath: destination,
      ));

      return destination;
    } on ModelDownloadCancelled {
      _emit(const TranscriptionState(
        stage: TranscriptionStage.cancelled,
        message: 'Cancelled.',
      ));
      return null;
    } on _CancelledSignal {
      _emit(const TranscriptionState(
        stage: TranscriptionStage.cancelled,
        message: 'Cancelled.',
      ));
      return null;
    } catch (e) {
      _emit(TranscriptionState(
        stage: TranscriptionStage.failed,
        message: 'Transcription failed.',
        error: _readableError(e),
      ));
      return null;
    } finally {
      // The extracted WAV is a large temp artifact; always clean it up.
      if (extractedAudio != null && await extractedAudio.exists()) {
        try {
          await extractedAudio.delete();
        } catch (_) {
          // A leftover temp file is not worth failing the job over.
        }
      }
      _cancellation = null;
    }
  }

  /// Writes `<video basename>.<lang>.srt` next to the video.
  ///
  /// The language tag matches the convention players use to label tracks,
  /// and keeps transcriptions in different languages from overwriting
  /// each other. Falls back to a temp dir if the video's folder is
  /// read-only (external drives, SD cards).
  Future<String> _subtitlePathFor(String videoPath, String language) async {
    final base = p.basenameWithoutExtension(videoPath);
    final beside = p.join(p.dirname(videoPath), '$base.$language.srt');

    // Probe rather than assume: under the macOS sandbox the user grants
    // access to the picked file, not its folder, so writing alongside it
    // often fails even though the video opened fine.
    try {
      final probe = File('$beside.tmp');
      await probe.writeAsString('', flush: true);
      await probe.delete();
      return beside;
    } on FileSystemException {
      // Fall back to app storage so the transcription is never lost.
      final dir = await getApplicationSupportDirectory();
      final subtitles = Directory(p.join(dir.path, 'subtitles'));
      await subtitles.create(recursive: true);
      return p.join(subtitles.path, '$base.$language.srt');
    }
  }

  /// Builds the progress line, e.g. "3:20 of 1:45:00 · about 12 min left".
  ///
  /// The remaining estimate is omitted until throughput is measurable —
  /// a wrong number is worse than no number.
  String _progressMessage(TranscriptionProgress p) {
    final done = _describe(p.processed);
    final total = _describe(p.total);
    final left = p.remaining;

    if (left == null) return 'Transcribing $done of $total...';
    return 'Transcribing $done of $total · ${_describeRough(left)} left';
  }

  /// Exact-ish duration for positions: "3:20", "1:45:00".
  String _describe(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);

    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// Rounded duration for estimates, which should not look precise.
  String _describeRough(Duration d) {
    if (d.inMinutes < 1) return 'under a minute';
    if (d.inMinutes < 60) return 'about ${d.inMinutes} min';

    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (m == 0) return 'about $h hr';
    return 'about $h hr $m min';
  }

  /// Leaves headroom so the UI and video decoding stay responsive during
  /// a long transcription.
  int _recommendedThreads() {
    // Apple silicon reports performance and efficiency cores separately, and
    // only the performance cores are worth giving to Whisper. Counting all
    // ten cores on an M4 and asking for eight threads oversubscribes the
    // four performance cores 2:1 — the surplus threads fight each other and
    // the rest of the system, which is what makes the whole Mac feel slow
    // during a long transcription.
    final performanceCores = _performanceCoreCount();

    if (performanceCores != null) {
      // Leave one performance core for the UI, video decoding, and whatever
      // else the user is doing. Finishing slightly later is a far better
      // trade than making the machine unpleasant to use for an hour.
      return (performanceCores - 1).clamp(1, 8);
    }

    // Intel and other platforms: no P/E split, so fall back to core count.
    final cores = Platform.numberOfProcessors;
    if (cores <= 2) return 1;
    return (cores - 2).clamp(1, 8);
  }

  /// Performance-core count on Apple silicon, or null elsewhere.
  int? _performanceCoreCount() {
    if (!Platform.isMacOS) return null;

    try {
      final result = Process.runSync(
        'sysctl',
        ['-n', 'hw.perflevel0.physicalcpu'],
      );
      if (result.exitCode != 0) return null;

      final value = int.tryParse(result.stdout.toString().trim());
      // Intel Macs have no perflevel0 key, so a missing or absurd value
      // means this is not a P/E machine.
      return (value != null && value > 0) ? value : null;
    } catch (_) {
      return null;
    }
  }

  void _throwIfCancelled(CancellationToken token) {
    if (token.isCancelled) throw const _CancelledSignal();
  }

  String _readableError(Object e) {
    if (e is TranscriptionException) return e.message;
    if (e is AudioExtractionException) return e.message;
    if (e is ModelDownloadException) return e.message;
    return e.toString();
  }

  Future<void> dispose() async {
    _cancellation?.cancel();
    await _stateController.close();
  }
}

class TranscriptionException implements Exception {
  const TranscriptionException(this.message);
  final String message;

  @override
  String toString() => 'TranscriptionException: $message';
}

class _CancelledSignal implements Exception {
  const _CancelledSignal();
}
