import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/subtitles/cue_sanitizer.dart';
import 'package:lumen/core/subtitles/srt_parser.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

/// Partial subtitles are handed to the player mid-transcription, so every
/// intermediate payload has to be valid on its own — not just the final one.
/// A malformed batch would be rejected by libmpv and the captions would
/// simply vanish from the video with no error.
void main() {
  List<SubtitleCue> cuesUpTo(int count) => [
        for (var i = 0; i < count; i++)
          SubtitleCue(
            start: Duration(seconds: i * 5),
            end: Duration(seconds: i * 5 + 4),
            // Raw whisper output, padding included.
            text: ' Segment number ${i + 1} of the transcript.',
          ),
      ];

  test('every intermediate batch is valid SRT', () {
    const sanitizer = CueSanitizer();
    const parser = SubtitleParser();

    // Simulate chunks landing one after another.
    for (var chunk = 1; chunk <= 10; chunk++) {
      final srt = cuesToSrt(sanitizer.sanitize(cuesUpTo(chunk)));

      final reparsed = parser.parse(srt);
      expect(reparsed.length, chunk,
          reason: 'batch of $chunk cues did not round-trip');

      for (final cue in reparsed) {
        expect(cue.end, greaterThan(cue.start));
        expect(cue.text.trim(), isNotEmpty);
      }
    }
  });

  test('cues stay in order as batches grow', () {
    const sanitizer = CueSanitizer();

    final srt = cuesToSrt(sanitizer.sanitize(cuesUpTo(8)));
    final cues = const SubtitleParser().parse(srt);

    for (var i = 1; i < cues.length; i++) {
      expect(cues[i].start, greaterThanOrEqualTo(cues[i - 1].end),
          reason: 'cue $i overlaps its predecessor');
    }
  });

  test('a later batch is a superset of the one before it', () {
    // The player replaces the whole track each time, so earlier subtitles
    // must survive into later payloads or they would disappear from the
    // part of the video already watched.
    const sanitizer = CueSanitizer();

    final earlier = sanitizer.sanitize(cuesUpTo(3));
    final later = sanitizer.sanitize(cuesUpTo(6));

    expect(later.length, greaterThan(earlier.length));
    for (var i = 0; i < earlier.length; i++) {
      expect(later[i].start, earlier[i].start);
      expect(later[i].text, earlier[i].text);
    }
  });

  test('an empty batch produces no payload to push', () {
    // Silence at the start of a video yields no cues; the service must not
    // hand the player an empty track.
    const sanitizer = CueSanitizer();

    final onlySilence = [
      const SubtitleCue(
        start: Duration.zero,
        end: Duration(seconds: 4),
        text: ' [BLANK_AUDIO]',
      ),
    ];

    expect(sanitizer.sanitize(onlySilence), isEmpty);
  });

  test('whisper padding is gone from partial output', () {
    const sanitizer = CueSanitizer();
    final srt = cuesToSrt(sanitizer.sanitize(cuesUpTo(2)));

    expect(srt, isNot(contains('\n Segment')));
    expect(srt, contains('Segment number 1'));
  });
}
