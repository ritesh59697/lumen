import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/transcription/chunked_transcriber.dart';

TranscriptionProgress progress({
  required int processedSec,
  required int totalSec,
  required int elapsedSec,
}) =>
    TranscriptionProgress(
      processed: Duration(seconds: processedSec),
      total: Duration(seconds: totalSec),
      elapsed: Duration(seconds: elapsedSec),
    );

void main() {
  group('fraction', () {
    test('reports the share of audio transcribed', () {
      final p = progress(processedSec: 30, totalSec: 120, elapsedSec: 10);
      expect(p.fraction, 0.25);
    });

    test('is zero before anything is processed', () {
      expect(progress(processedSec: 0, totalSec: 600, elapsedSec: 0).fraction, 0);
    });

    test('never exceeds 1 even if the last chunk overshoots', () {
      // The final chunk can run past the end of the audio.
      final p = progress(processedSec: 130, totalSec: 120, elapsedSec: 40);
      expect(p.fraction, 1.0);
    });

    test('does not divide by zero on empty audio', () {
      expect(progress(processedSec: 0, totalSec: 0, elapsedSec: 5).fraction, 0);
    });
  });

  group('remaining', () {
    test('extrapolates from measured throughput', () {
      // 60s of audio in 30s of wall clock — 2x realtime, 60s left to do.
      final p = progress(processedSec: 60, totalSec: 120, elapsedSec: 30);
      expect(p.remaining, const Duration(seconds: 30));
    });

    test('is withheld until enough audio is done to be meaningful', () {
      // An estimate from the first second of a long file is noise.
      final p = progress(processedSec: 1, totalSec: 10800, elapsedSec: 1);
      expect(p.remaining, isNull);
    });

    test('is zero once everything is processed', () {
      final p = progress(processedSec: 120, totalSec: 120, elapsedSec: 60);
      expect(p.remaining, Duration.zero);
    });

    test('does not go negative when the last chunk overshoots', () {
      final p = progress(processedSec: 130, totalSec: 120, elapsedSec: 60);
      expect(p.remaining, Duration.zero);
    });

    test('is null when no time has elapsed', () {
      final p = progress(processedSec: 30, totalSec: 120, elapsedSec: 0);
      expect(p.remaining, isNull);
    });

    test('scales sensibly for a three-hour file', () {
      // 10 min of a 3 hr film done in 1 min of wall clock.
      final p = progress(
        processedSec: 600,
        totalSec: 10800,
        elapsedSec: 60,
      );

      // 170 min of audio left at 10x realtime -> ~17 min.
      expect(p.remaining!.inMinutes, 17);
    });
  });

  group('shouldChunk', () {
    const t = ChunkedTranscriber();

    test('skips chunking for short audio', () {
      // Chunking overhead outweighs the benefit on a short clip.
      expect(t.shouldChunk(const Duration(seconds: 10)), isFalse);
      expect(t.shouldChunk(const Duration(minutes: 2)), isFalse);
    });

    test('chunks anything long enough for progress to matter', () {
      expect(t.shouldChunk(const Duration(minutes: 10)), isTrue);
      expect(t.shouldChunk(const Duration(hours: 3)), isTrue);
    });
  });
}
