import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/subtitles/cue_sanitizer.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

SubtitleCue cue(int startMs, int endMs, String text) => SubtitleCue(
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
      text: text,
    );

void main() {
  group('formatSrtTimestamp', () {
    test('pads all components and uses a comma before millis', () {
      expect(formatSrtTimestamp(Duration.zero), '00:00:00,000');
      expect(
        formatSrtTimestamp(const Duration(seconds: 5, milliseconds: 70)),
        '00:00:05,070',
      );
    });

    test('handles durations past one hour', () {
      expect(
        formatSrtTimestamp(
          const Duration(hours: 2, minutes: 3, seconds: 4, milliseconds: 5),
        ),
        '02:03:04,005',
      );
    });
  });

  test('formatVttTimestamp uses a period before millis', () {
    expect(
      formatVttTimestamp(const Duration(seconds: 5, milliseconds: 70)),
      '00:00:05.070',
    );
  });

  group('CueSanitizer text cleanup', () {
    const s = CueSanitizer();

    test('trims the whitespace whisper.cpp pads segments with', () {
      final out = s.sanitize([cue(0, 2000, '  Hello there.  ')]);
      expect(out.single.text, 'Hello there.');
    });

    test('drops non-speech annotations entirely', () {
      final out = s.sanitize([
        cue(0, 2000, '[BLANK_AUDIO]'),
        cue(2000, 4000, '(upbeat music)'),
        cue(4000, 6000, '*door slams*'),
        cue(6000, 8000, 'Real dialogue.'),
      ]);

      expect(out.length, 1);
      expect(out.single.text, 'Real dialogue.');
    });

    test('keeps text that merely contains brackets', () {
      final out = s.sanitize([cue(0, 2000, 'He said [sic] it was fine.')]);
      expect(out.single.text, 'He said [sic] it was fine.');
    });

    test('collapses internal newlines and repeated spaces', () {
      final out = s.sanitize([cue(0, 2000, 'Hello\n\n  there')]);
      expect(out.single.text, 'Hello there');
    });
  });

  group('CueSanitizer wrapping', () {
    const s = CueSanitizer();

    test('leaves short lines unwrapped', () {
      final out = s.sanitize([cue(0, 3000, 'Short line.')]);
      expect(out.single.text, isNot(contains('\n')));
    });

    test('wraps long text and respects the two-line cap', () {
      final long = 'This is a considerably longer subtitle line that must be '
          'wrapped across multiple lines to stay readable on screen.';
      final out = s.sanitize([cue(0, 6000, long)]);

      final lines = out.single.text.split('\n');
      expect(lines.length, lessThanOrEqualTo(2));
      // No dialogue may be lost to wrapping.
      expect(out.single.text.replaceAll('\n', ' '), long);
    });
  });

  group('CueSanitizer timing repair', () {
    const s = CueSanitizer();

    test('extends cues that are too brief to read', () {
      final out = s.sanitize([cue(0, 100, 'Hi')]);
      expect(
        out.single.duration,
        greaterThanOrEqualTo(const Duration(milliseconds: 500)),
      );
    });

    test('removes overlap by pushing the later cue forward', () {
      final out = s.sanitize([
        cue(0, 3000, 'First'),
        cue(2000, 5000, 'Second'),
      ]);

      expect(out[0].end, lessThanOrEqualTo(out[1].start));
    });

    test('does not extend a short cue into the following one', () {
      final out = s.sanitize([
        cue(0, 100, 'Hi'),
        cue(300, 3000, 'Next'),
      ]);

      expect(out[0].end, lessThanOrEqualTo(out[1].start));
    });

    test('drops cues that cannot be given a positive duration', () {
      final out = s.sanitize([
        cue(1000, 3000, 'First'),
        cue(500, 800, 'Swallowed'),
      ]);

      for (final c in out) {
        expect(c.end, greaterThan(c.start));
      }
    });
  });

  group('cuesToSrt', () {
    test('numbers cues from 1 with the SRT arrow separator', () {
      final srt = cuesToSrt([
        cue(0, 2000, 'First'),
        cue(2000, 4000, 'Second'),
      ]);

      expect(srt, contains('1\n00:00:00,000 --> 00:00:02,000\nFirst'));
      expect(srt, contains('2\n00:00:02,000 --> 00:00:04,000\nSecond'));
    });

    test('produces an empty string for no cues', () {
      expect(cuesToSrt([]), isEmpty);
    });
  });

  test('cuesToVtt emits the WEBVTT header', () {
    final vtt = cuesToVtt([cue(0, 2000, 'Hello')]);
    expect(vtt.startsWith('WEBVTT'), isTrue);
    expect(vtt, contains('00:00:00.000 --> 00:00:02.000'));
  });
}
