import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

/// Extracts a Whisper-compatible audio track from any media file.
///
/// Whisper accepts exactly one input format: 16 kHz, mono, 16-bit PCM WAV.
/// Feeding it anything else yields silence or garbage rather than an error,
/// so those parameters are hard-coded here instead of being configurable.
///
/// Implements [WhisperAudioConverter] so it can be registered with
/// [WhisperController.registerAudioConverter] and used automatically.
class AudioExtractor implements WhisperAudioConverter {
  const AudioExtractor();

  /// Whisper's required sample rate. Not configurable by design.
  static const int sampleRate = 16000;

  @override
  Future<File?> convert(File input) async {
    try {
      return await extract(input.path);
    } on AudioExtractionException {
      // The interface contract is to return null on failure; the
      // controller logs and continues.
      return null;
    }
  }

  /// Extracts audio from [sourcePath] to a 16 kHz mono WAV.
  ///
  /// Returns the written file. Throws [AudioExtractionException] if FFmpeg
  /// fails, with the tail of the FFmpeg log attached for diagnosis.
  Future<File> extract(String sourcePath, {String? outputPath}) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw AudioExtractionException('Source file not found: $sourcePath');
    }

    final destination = outputPath ?? await _defaultOutputPath(sourcePath);

    // A stale file from an interrupted run would make FFmpeg prompt to
    // overwrite; -y handles that, but removing it keeps failures honest.
    final existing = File(destination);
    if (await existing.exists()) {
      await existing.delete();
    }

    // -vn        drop video (we only need audio)
    // -sn        drop existing subtitle tracks
    // -ac 1      downmix to mono
    // -ar 16000  resample to 16 kHz
    // -c:a pcm_s16le  16-bit little-endian PCM, the format whisper.cpp reads
    final command = '-hide_banner -nostdin -y '
        '-i ${_quote(sourcePath)} '
        '-vn -sn -ac 1 -ar $sampleRate -c:a pcm_s16le '
        '${_quote(destination)}';

    final FFmpegSession session = await FFmpegKit.execute(command);
    final ReturnCode? returnCode = await session.getReturnCode();

    if (!ReturnCode.isSuccess(returnCode)) {
      final logs = await session.getAllLogsAsString();
      throw AudioExtractionException(
        'FFmpeg failed with code ${returnCode?.getValue()}',
        details: _tail(logs ?? '', 1200),
      );
    }

    final output = File(destination);
    if (!await output.exists() || await output.length() == 0) {
      throw AudioExtractionException(
        'FFmpeg reported success but produced no audio. '
        'The file may have no audio track.',
      );
    }

    return output;
  }

  /// Whether [sourcePath] contains at least one audio stream.
  ///
  /// Worth checking before a long transcription run: a silent screen
  /// recording would otherwise burn minutes of CPU to produce nothing.
  ///
  /// Uses FFprobe's structured stream data rather than scraping FFmpeg's
  /// human-readable log, which changes between builds.
  Future<bool> hasAudioTrack(String sourcePath) async {
    final session = await FFprobeKit.getMediaInformation(sourcePath);
    final information = session.getMediaInformation();
    if (information == null) return false;

    final streams = information.getStreams();
    return streams.any((s) => s.getType() == 'audio');
  }

  /// The media duration in seconds, or null if it cannot be determined.
  ///
  /// Used to turn Whisper's segment timestamps into a progress percentage.
  Future<double?> probeDurationSeconds(String sourcePath) async {
    final session = await FFprobeKit.getMediaInformation(sourcePath);
    final duration = session.getMediaInformation()?.getDuration();
    return duration == null ? null : double.tryParse(duration);
  }

  /// Places extracted audio in a temp dir, keyed to the source filename.
  ///
  /// The directory is created if missing: under the macOS sandbox,
  /// `getTemporaryDirectory()` returns a Caches path that may not exist
  /// yet, and FFmpeg will not create it — it just fails with "No such file
  /// or directory" on the output.
  Future<String> _defaultOutputPath(String sourcePath) async {
    final tempDir = await getTemporaryDirectory();
    await tempDir.create(recursive: true);

    final baseName = p.basenameWithoutExtension(sourcePath);
    final safeName = baseName.replaceAll(RegExp(r'[^\w\-. ]'), '_');
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return p.join(tempDir.path, 'lumen_${safeName}_$stamp.wav');
  }

  /// Wraps a path in single quotes for FFmpegKit's shell-style parser,
  /// escaping any embedded quotes. Media filenames routinely contain
  /// spaces, apostrophes and brackets.
  String _quote(String path) => "'${path.replaceAll("'", r"'\''")}'";

  String _tail(String text, int maxChars) =>
      text.length <= maxChars ? text : text.substring(text.length - maxChars);
}

/// Raised when audio cannot be extracted from a media file.
class AudioExtractionException implements Exception {
  const AudioExtractionException(this.message, {this.details});

  final String message;
  final String? details;

  @override
  String toString() => details == null
      ? 'AudioExtractionException: $message'
      : 'AudioExtractionException: $message\n$details';
}
