import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/subtitles/cue_sanitizer.dart';
import 'package:lumen/core/subtitles/srt_parser.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

/// Verified against genuine whisper.cpp v1.8.x output.
///
/// Captured 2026-08-06 by transcribing a 10s clip with ggml-base on an M4.
/// Kept verbatim — including the leading space on each segment, which is
/// what whisper.cpp actually emits and the single most common reason naive
/// SRT writers produce subtitles with a stray indent.
const _realWhisperSrt = '''
1
00:00:00,000 --> 00:00:05,080
 Hello and welcome to Lumen, this is a test of offline speech recognition, the quick brown

2
00:00:05,080 --> 00:00:10,280
 fox jumps over the lazy dog, subtitle should appear automatically while this video plays.
''';

void main() {
  test('parses real whisper.cpp SRT output', () {
    final cues = const SubtitleParser().parse(_realWhisperSrt);

    expect(cues.length, 2);
    expect(cues[0].start, Duration.zero);
    expect(cues[0].end, const Duration(seconds: 5, milliseconds: 80));
    expect(cues[1].end, const Duration(seconds: 10, milliseconds: 280));

    // The parser trims each block, so whisper.cpp's leading space is
    // already gone by this point — the sanitizer never sees it. Asserted
    // here because it pins down *which* stage owns the fix.
    expect(cues[0].text.startsWith(' '), isFalse);
    expect(cues[0].text.startsWith('Hello and welcome'), isTrue);
  });

  test('the raw file really does contain the padding being handled', () {
    // Guards against the fixture being silently "cleaned up" later and
    // this suite then proving nothing.
    expect(_realWhisperSrt, contains('\n Hello and welcome'));
    expect(_realWhisperSrt, contains('\n fox jumps over'));
  });

  test('no cue survives with surrounding whitespace', () {
    final cues = const CueSanitizer()
        .sanitize(const SubtitleParser().parse(_realWhisperSrt));

    for (final cue in cues) {
      expect(cue.text, cue.text.trim());
    }
  });

  test('sanitizer wraps whisper long lines to a readable width', () {
    final raw = const SubtitleParser().parse(_realWhisperSrt);
    // Real segments arrive well over a comfortable caption width.
    expect(raw[0].text.length, greaterThan(60));

    final cues = const CueSanitizer().sanitize(raw);

    for (final cue in cues) {
      final lines = cue.text.split('\n');
      expect(lines.length, lessThanOrEqualTo(2));
      // Every line fits the caption width, apart from an unavoidable
      // overflow on the final line.
      for (final line in lines.take(lines.length - 1)) {
        expect(line.length, lessThanOrEqualTo(42));
      }
    }
  });

  test('no dialogue is lost between raw output and final SRT', () {
    final raw = const SubtitleParser().parse(_realWhisperSrt);
    final cues = const CueSanitizer().sanitize(raw);

    String words(String s) =>
        s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

    expect(
      words(cues.map((c) => c.text).join(' ')),
      words(raw.map((c) => c.text).join(' ')),
    );
  });

  test('round-trips back to valid, correctly timed SRT', () {
    final cues = const CueSanitizer()
        .sanitize(const SubtitleParser().parse(_realWhisperSrt));
    final srt = cuesToSrt(cues);

    // Timings must survive the round trip unchanged.
    expect(srt, contains('00:00:00,000 --> 00:00:05,080'));
    expect(srt, contains('00:00:05,080 --> 00:00:10,280'));

    final reparsed = const SubtitleParser().parse(srt);
    expect(reparsed.length, cues.length);
    for (var i = 0; i < cues.length; i++) {
      expect(reparsed[i].start, cues[i].start);
      expect(reparsed[i].end, cues[i].end);
    }
  });
}
