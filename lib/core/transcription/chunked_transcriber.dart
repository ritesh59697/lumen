import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

import '../subtitles/subtitle_model.dart';
import 'audio_extractor.dart';

/// Progress through a chunked transcription.
class TranscriptionProgress {
  const TranscriptionProgress({
    required this.processed,
    required this.total,
    required this.elapsed,
  });

  /// Audio transcribed so far.
  final Duration processed;

  /// Total audio to transcribe.
  final Duration total;

  /// Wall-clock time spent so far.
  final Duration elapsed;

  double get fraction => total.inMilliseconds == 0
      ? 0
      : (processed.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);

  /// Estimated time remaining, or null before there is enough data to say.
  ///
  /// Extrapolates from average throughput across the whole run so far.
  /// Averaging matters: the first chunk carries model-load cost and later
  /// ones vary with how dense the speech is, so an estimate taken from any
  /// single chunk swings alarmingly. A cumulative average settles quickly
  /// and moves smoothly.
  ///
  /// Withheld entirely until a meaningful amount is done — an estimate drawn
  /// from the first seconds of an eight-hour file is noise, and a wrong
  /// number is worse than no number.
  Duration? get remaining {
    if (processed.inMilliseconds < 5000) return null;
    if (elapsed.inMilliseconds == 0) return null;

    final rate = processed.inMilliseconds / elapsed.inMilliseconds;
    if (rate <= 0) return null;

    final left = total.inMilliseconds - processed.inMilliseconds;
    if (left <= 0) return Duration.zero;

    return Duration(milliseconds: (left / rate).round());
  }
}

/// Transcribes long audio in chunks so progress can be reported.
///
/// whisper_ggml_plus exposes no progress callback — `transcribe` is a single
/// blocking FFI call that returns everything at once, and the
/// `realtimeStream` field on its request model is declared but never used.
/// For a three-hour video that means an indeterminate spinner for the entire
/// run, which is unusable.
///
/// Splitting the audio and transcribing piece by piece makes each completed
/// chunk a real progress event, and lets partial results reach the screen
/// while the rest is still running.
class ChunkedTranscriber {
  const ChunkedTranscriber({
    this.chunkDuration = const Duration(seconds: 90),
    this.overlap = const Duration(seconds: 2),
  });

  /// How much audio to transcribe per pass.
  ///
  /// Whisper works in 30-second windows internally, so chunks should be a
  /// comfortable multiple of that. 90 seconds keeps progress updates
  /// frequent enough to feel live without paying the model-warmup cost too
  /// often.
  final Duration chunkDuration;

  /// Audio replayed at the start of each chunk.
  ///
  /// A hard cut can land mid-word and lose it. Overlapping slightly and then
  /// dropping cues that fall in the replayed region keeps boundary words
  /// intact.
  final Duration overlap;

  /// Whether [audioDuration] is worth chunking at all.
  ///
  /// Short files transcribe fast enough that the extra ffmpeg calls and
  /// repeated model warmup cost more than the progress reporting is worth.
  bool shouldChunk(Duration audioDuration) =>
      audioDuration > chunkDuration * 2;

  /// Transcribes [wavPath] in chunks, reporting progress as each completes.
  ///
  /// [onProgress] fires after every chunk; [onPartialCues] receives the cues
  /// found so far, so the UI can show subtitles building up.
  Future<List<SubtitleCue>> transcribe({
    required String wavPath,
    required Duration audioDuration,
    required WhisperModel model,
    required WhisperController controller,
    required int threads,
    String language = 'en',
    bool translateToEnglish = false,
    void Function(TranscriptionProgress)? onProgress,
    void Function(List<SubtitleCue>)? onPartialCues,
    bool Function()? isCancelled,
  }) async {
    final cues = <SubtitleCue>[];
    final started = DateTime.now();
    final tempDir = Directory(p.dirname(wavPath));

    var offset = Duration.zero;

    while (offset < audioDuration) {
      if (isCancelled?.call() ?? false) break;

      // Replay a little of the previous chunk so a word split across the
      // boundary still has its full context.
      final readFrom = offset > overlap ? offset - overlap : Duration.zero;
      final readLength = chunkDuration + (offset - readFrom);

      final chunkPath = p.join(
        tempDir.path,
        'lumen_chunk_${offset.inMilliseconds}.wav',
      );

      try {
        await _sliceWav(
          source: wavPath,
          destination: chunkPath,
          start: readFrom,
          length: readLength,
        );

        final result = await controller.transcribe(
          model: model,
          audioPath: chunkPath,
          lang: language,
          isTranslate: translateToEnglish,
          withTimestamps: true,
          convert: false,
          threads: threads,
        );

        for (final segment in result?.transcription.segments ?? const []) {
          // Segment times are relative to the chunk; shift them back onto
          // the real timeline.
          final start = readFrom + segment.fromTs;
          final end = readFrom + segment.toTs;

          // Drop anything that lands in the replayed overlap — it was
          // already transcribed as part of the previous chunk.
          if (start < offset && offset > Duration.zero) continue;

          cues.add(SubtitleCue(start: start, end: end, text: segment.text));
        }
      } finally {
        final chunk = File(chunkPath);
        if (await chunk.exists()) {
          try {
            await chunk.delete();
          } catch (_) {
            // A stray temp file is not worth failing the run over.
          }
        }
      }

      offset += chunkDuration;

      final processed = offset < audioDuration ? offset : audioDuration;
      onProgress?.call(TranscriptionProgress(
        processed: processed,
        total: audioDuration,
        elapsed: DateTime.now().difference(started),
      ));
      onPartialCues?.call(List.unmodifiable(cues));
    }

    return cues;
  }

  /// Cuts [length] of audio starting at [start] into [destination].
  ///
  /// Uses stream copy — the source is already the 16 kHz mono PCM Whisper
  /// needs, so re-encoding would only risk changing it. Seeking before `-i`
  /// makes the cut effectively instant.
  Future<void> _sliceWav({
    required String source,
    required String destination,
    required Duration start,
    required Duration length,
  }) async {
    String seconds(Duration d) => (d.inMilliseconds / 1000).toStringAsFixed(3);

    final session = await FFmpegKit.execute(
      '-hide_banner -nostdin -y '
      '-ss ${seconds(start)} -t ${seconds(length)} '
      "-i '${source.replaceAll("'", r"'\''")}' "
      '-c copy '
      "'${destination.replaceAll("'", r"'\''")}'",
    );

    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      final logs = await session.getAllLogsAsString();
      throw AudioExtractionException(
        'Could not split audio for transcription.',
        details: logs,
      );
    }
  }
}
