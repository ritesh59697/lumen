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
    this.chunkDuration = const Duration(seconds: 120),
    this.overlap = const Duration(seconds: 5),
  });

  /// How much audio to transcribe per pass.
  ///
  /// Whisper works in 30-second windows internally, so chunks should be a
  /// comfortable multiple of that. Two minutes keeps progress updates
  /// frequent enough to feel live while keeping the number of seams down —
  /// every boundary is a chance to mangle a sentence, and an eight-hour
  /// video has hundreds of them.
  final Duration chunkDuration;

  /// Audio replayed at the start of each chunk.
  ///
  /// A hard cut lands mid-sentence and Whisper truncates whatever utterance
  /// it was in the middle of, so words at a seam go missing unless the next
  /// chunk hears them with enough context to transcribe them properly.
  ///
  /// Five seconds comfortably covers a spoken sentence. Two was not enough:
  /// the replayed audio started mid-phrase, so the model had no more context
  /// than the previous chunk did and produced the same truncated result.
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
          final text = segment.text.trim();

          if (text.isEmpty) continue;

          // Cues in the replayed region are kept unless the previous chunk
          // already produced the same words.
          //
          // Dropping them purely by timestamp loses speech: Whisper
          // truncates the final utterance of a chunk at the hard boundary,
          // so the words either side of a seam are frequently transcribed
          // by *neither* chunk. Over the 320 seams in an eight-hour video
          // that silently removes a great deal of dialogue.
          if (start < offset && cues.isNotEmpty) {
            if (_alreadyCaptured(cues, text)) continue;
          }

          cues.add(SubtitleCue(start: start, end: end, text: text));
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

  /// Whether [text] repeats something already transcribed at the seam.
  ///
  /// Only the last few cues are checked — a duplicate can only come from the
  /// immediately preceding chunk, and comparing against the whole transcript
  /// would both cost more and wrongly drop legitimately repeated phrases
  /// later in the video.
  ///
  /// Comparison is on normalized text because the two chunks hear the same
  /// audio with different context, so punctuation and capitalisation often
  /// differ even when the words are identical.
  bool _alreadyCaptured(List<SubtitleCue> cues, String text) {
    final candidate = _normalize(text);
    if (candidate.isEmpty) return true;

    final from = cues.length < 4 ? 0 : cues.length - 4;
    for (var i = from; i < cues.length; i++) {
      final existing = _normalize(cues[i].text);

      // Exact repeat, or one is contained in the other — a truncated
      // utterance from the previous chunk against its complete form here.
      if (existing == candidate ||
          existing.contains(candidate) ||
          candidate.contains(existing)) {
        return true;
      }
    }
    return false;
  }

  /// Lowercases and strips punctuation so the same words compare equal
  /// regardless of how each chunk punctuated them.
  String _normalize(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r"[^\w\s']"), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

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
