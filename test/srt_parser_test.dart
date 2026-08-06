import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/subtitles/srt_parser.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

void main() {
  const parser = SubtitleParser();

  group('well-formed input', () {
    test('parses a standard SRT file', () {
      final cues = parser.parse('''
1
00:00:01,000 --> 00:00:03,500
Hello there.

2
00:00:04,000 --> 00:00:06,000
General Kenobi.
''');

      expect(cues.length, 2);
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 3, milliseconds: 500));
      expect(cues[0].text, 'Hello there.');
      expect(cues[1].text, 'General Kenobi.');
    });

    test('parses WebVTT with a period separator and header', () {
      final cues = parser.parse('''
WEBVTT

00:00:01.000 --> 00:00:03.000
Hello from VTT.
''');

      expect(cues.length, 1);
      expect(cues.single.text, 'Hello from VTT.');
      expect(cues.single.start, const Duration(seconds: 1));
    });

    test('keeps multi-line cue text', () {
      final cues = parser.parse('''
1
00:00:01,000 --> 00:00:03,000
First line
Second line
''');

      expect(cues.single.text, 'First line\nSecond line');
    });

    test('round-trips through cuesToSrt without drift', () {
      final original = [
        const SubtitleCue(
          start: Duration(seconds: 1, milliseconds: 250),
          end: Duration(seconds: 3, milliseconds: 900),
          text: 'Round trip.',
        ),
        const SubtitleCue(
          start: Duration(hours: 1, minutes: 2, seconds: 3),
          end: Duration(hours: 1, minutes: 2, seconds: 5),
          text: 'Past the hour.',
        ),
      ];

      final reparsed = parser.parse(cuesToSrt(original));

      expect(reparsed.length, original.length);
      for (var i = 0; i < original.length; i++) {
        expect(reparsed[i].start, original[i].start);
        expect(reparsed[i].end, original[i].end);
        expect(reparsed[i].text, original[i].text);
      }
    });
  });

  group('malformed input from the wild', () {
    test('handles Windows CRLF line endings', () {
      final cues = parser.parse(
        '1\r\n00:00:01,000 --> 00:00:03,000\r\nCRLF text.\r\n',
      );

      expect(cues.single.text, 'CRLF text.');
    });

    test('strips a UTF-8 BOM before the first cue', () {
      final cues = parser.parse(
        '\u{FEFF}1\n00:00:01,000 --> 00:00:02,000\nBOM text.\n',
      );

      expect(cues.single.text, 'BOM text.');
    });

    test('tolerates missing index lines', () {
      final cues = parser.parse('''
00:00:01,000 --> 00:00:02,000
No index here.
''');

      expect(cues.single.text, 'No index here.');
    });

    test('tolerates wrong or duplicated index numbers', () {
      final cues = parser.parse('''
7
00:00:01,000 --> 00:00:02,000
First.

7
00:00:03,000 --> 00:00:04,000
Second.
''');

      expect(cues.length, 2);
      expect(cues[1].text, 'Second.');
    });

    test('skips unparseable blocks but keeps valid ones', () {
      final cues = parser.parse('''
1
this is not a timing line
Garbage block.

2
00:00:05,000 --> 00:00:07,000
Valid block.
''');

      expect(cues.length, 1);
      expect(cues.single.text, 'Valid block.');
    });

    test('drops cues that have timings but no text', () {
      final cues = parser.parse('''
1
00:00:01,000 --> 00:00:02,000

2
00:00:03,000 --> 00:00:04,000
Has text.
''');

      expect(cues.length, 1);
      expect(cues.single.text, 'Has text.');
    });

    test('reads a short fraction as tenths, not milliseconds', () {
      // ",5" means 500ms. Left-padding here would yield 5ms and desync
      // the whole file.
      final cues = parser.parse(
        '1\n00:00:01,5 --> 00:00:02,25\nFraction.\n',
      );

      expect(cues.single.start, const Duration(seconds: 1, milliseconds: 500));
      expect(cues.single.end, const Duration(seconds: 2, milliseconds: 250));
    });

    test('ignores VTT cue settings after the timing', () {
      final cues = parser.parse('''
WEBVTT

00:00:01.000 --> 00:00:03.000 align:start position:10%
Positioned text.
''');

      expect(cues.single.text, 'Positioned text.');
    });

    test('handles extra blank lines between cues', () {
      final cues = parser.parse('''
1
00:00:01,000 --> 00:00:02,000
First.



2
00:00:03,000 --> 00:00:04,000
Second.
''');

      expect(cues.length, 2);
    });

    test('returns an empty list for empty or junk input', () {
      expect(parser.parse(''), isEmpty);
      expect(parser.parse('   \n\n  '), isEmpty);
      expect(parser.parse('not a subtitle file at all'), isEmpty);
    });
  });
}
