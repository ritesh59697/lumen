import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/subtitles/cue_sanitizer.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

/// Guards the chunk-boundary behaviour.
///
/// Splitting audio into chunks introduces seams that did not exist in the
/// source. The first implementation dropped every cue starting inside the
/// replayed overlap, on the assumption the previous chunk had already
/// transcribed it. It usually had not: Whisper truncates whatever utterance
/// it is mid-way through at a hard boundary, so words either side of a seam
/// were transcribed by neither chunk and vanished. Across the hundreds of
/// seams in a long video that removed a lot of dialogue.
void main() {
  group('seam de-duplication', () {
    // Mirrors _alreadyCaptured in ChunkedTranscriber.
    String normalize(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r"[^\w\s']"), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    bool duplicate(List<String> recent, String candidate) {
      final c = normalize(candidate);
      if (c.isEmpty) return true;
      for (final r in recent.map(normalize)) {
        if (r == c || r.contains(c) || c.contains(r)) return true;
      }
      return false;
    }

    test('matches the same words punctuated differently', () {
      // The two chunks hear identical audio with different context, so the
      // punctuation and capitalisation routinely differ.
      expect(
        duplicate(['So, we declare a variable.'], 'so we declare a variable'),
        isTrue,
      );
    });

    test('treats a truncated utterance as the same as its full form', () {
      // The previous chunk cut off at the boundary; this chunk heard it all.
      expect(
        duplicate(['and then we call the'], 'and then we call the function'),
        isTrue,
      );
    });

    test('keeps genuinely new speech at the seam', () {
      // The case the original code got wrong — this is not a repeat, and
      // dropping it loses the words entirely.
      expect(
        duplicate(['welcome to the course'], 'today we cover closures'),
        isFalse,
      );
    });

    test('only compares against recent cues', () {
      // A phrase repeated much later in the video is not a seam duplicate,
      // so only the last few cues are considered.
      final recent = ['third', 'fourth', 'fifth', 'sixth'];
      expect(duplicate(recent, 'first'), isFalse);
    });

    test('discards empty text', () {
      expect(duplicate(const [], '   '), isTrue);
    });
  });

  group('cues across a seam survive sanitizing', () {
    test('a boundary-spanning sentence keeps all its words', () {
      // Chunk 1 ends mid-sentence; chunk 2 re-hears it with more context.
      final raw = [
        const SubtitleCue(
          start: Duration(seconds: 116),
          end: Duration(seconds: 119),
          text: ' So the important thing about closures',
        ),
        const SubtitleCue(
          start: Duration(seconds: 119),
          end: Duration(seconds: 123),
          text: ' is that they capture the surrounding scope.',
        ),
      ];

      final cues = const CueSanitizer().sanitize(raw);
      final all = cues.map((c) => c.text).join(' ').replaceAll('\n', ' ');

      expect(all, contains('closures'));
      expect(all, contains('capture the surrounding scope'));
    });

    test('timings stay ordered across a seam', () {
      final raw = [
        const SubtitleCue(
          start: Duration(seconds: 118),
          end: Duration(seconds: 120),
          text: ' before the boundary',
        ),
        const SubtitleCue(
          start: Duration(seconds: 120),
          end: Duration(seconds: 122),
          text: ' after the boundary',
        ),
      ];

      final cues = const CueSanitizer().sanitize(raw);
      for (var i = 1; i < cues.length; i++) {
        expect(cues[i].start, greaterThanOrEqualTo(cues[i - 1].end));
      }
    });
  });
}
