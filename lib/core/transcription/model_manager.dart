import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

/// Download progress for a Whisper model file.
class ModelDownloadProgress {
  const ModelDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
  });

  final int receivedBytes;

  /// Total size, or null when the server sends no Content-Length.
  final int? totalBytes;

  /// Fraction complete in `0.0..1.0`, or null if the total is unknown.
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// Downloads and tracks the on-device Whisper model files.
///
/// This deliberately replaces `WhisperController.downloadModel`, which reads
/// the entire response into memory before writing. A `small` model is roughly
/// 500 MB, so that approach spikes RAM and gives the user no progress. Here
/// the response is streamed to disk instead.
///
/// Downloads land on a `.part` file and are renamed only on success, so an
/// interrupted download can never be mistaken for a usable model — a
/// truncated .bin fails deep inside whisper.cpp with an opaque error.
class ModelManager {
  ModelManager({WhisperController? controller})
      : _controller = controller ?? WhisperController();

  final WhisperController _controller;

  /// Approximate on-disk sizes, for warning the user before a large download.
  static const Map<WhisperModel, int> approximateSizesMb = {
    WhisperModel.tiny: 75,
    WhisperModel.tinyEn: 75,
    WhisperModel.base: 142,
    WhisperModel.baseEn: 142,
    WhisperModel.small: 466,
    WhisperModel.smallEn: 466,
    WhisperModel.medium: 1500,
    WhisperModel.mediumEn: 1500,
    WhisperModel.large: 3100,
    WhisperModel.largeV3Turbo: 1600,
  };

  Future<String> pathFor(WhisperModel model) => _controller.getPath(model);

  /// Whether [model] is already downloaded and non-empty.
  Future<bool> isInstalled(WhisperModel model) async {
    final file = File(await pathFor(model));
    if (!await file.exists()) return false;
    return await file.length() > 0;
  }

  /// Every model currently present on disk.
  Future<List<WhisperModel>> installedModels() async {
    final found = <WhisperModel>[];
    for (final model in WhisperModel.values) {
      if (await isInstalled(model)) found.add(model);
    }
    return found;
  }

  /// Downloads [model] unless already present, reporting progress.
  ///
  /// Returns the path to the model file.
  Future<String> ensureDownloaded(
    WhisperModel model, {
    void Function(ModelDownloadProgress)? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    final destination = await pathFor(model);
    if (await isInstalled(model)) return destination;

    // Same sandbox trap as the audio temp dir: the directory the model
    // path points into may not exist yet, and openWrite will not create it.
    await Directory(p.dirname(destination)).create(recursive: true);

    final partFile = File('$destination.part');
    if (await partFile.exists()) await partFile.delete();

    final client = HttpClient();
    IOSink? sink;

    try {
      final request = await client.getUrl(model.modelUri);
      final response = await request.close();

      if (response.statusCode != HttpStatus.ok) {
        throw ModelDownloadException(
          'Download failed for ${model.modelName} '
          '(HTTP ${response.statusCode}).',
        );
      }

      final total =
          response.contentLength == -1 ? null : response.contentLength;
      var received = 0;

      sink = partFile.openWrite();

      await for (final chunk in response) {
        if (cancellationToken?.isCancelled ?? false) {
          throw const ModelDownloadCancelled();
        }

        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(
          ModelDownloadProgress(receivedBytes: received, totalBytes: total),
        );
      }

      await sink.flush();
      await sink.close();
      sink = null;

      // Guard against a silently truncated transfer.
      if (total != null && await partFile.length() != total) {
        throw ModelDownloadException(
          'Download for ${model.modelName} was incomplete.',
        );
      }

      await partFile.rename(destination);
      return destination;
    } on ModelDownloadCancelled {
      await sink?.close();
      if (await partFile.exists()) await partFile.delete();
      rethrow;
    } catch (e) {
      await sink?.close();
      if (await partFile.exists()) await partFile.delete();
      if (e is ModelDownloadException) rethrow;
      throw ModelDownloadException('Could not download ${model.modelName}: $e');
    } finally {
      client.close(force: true);
    }
  }

  /// Deletes [model] from disk to reclaim space.
  Future<void> delete(WhisperModel model) async {
    final file = File(await pathFor(model));
    if (await file.exists()) await file.delete();
  }
}

/// Cooperative cancellation flag for long-running downloads.
class CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class ModelDownloadException implements Exception {
  const ModelDownloadException(this.message);
  final String message;

  @override
  String toString() => 'ModelDownloadException: $message';
}

class ModelDownloadCancelled implements Exception {
  const ModelDownloadCancelled();

  @override
  String toString() => 'Model download cancelled';
}
