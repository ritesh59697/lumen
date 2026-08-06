import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/player/shortcuts.dart';
import 'package:lumen/core/subtitles/srt_parser.dart';
import 'package:lumen/core/subtitles/subtitle_document.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

/// Covers the keyboard subtitle-sync path end to end: nudge the document,
/// serialize it, and confirm the result is what the player would receive.
void main() {
  SubtitleDocument doc() => SubtitleDocument(cues: [
        const SubtitleCue(
          start: Duration(seconds: 1),
          end: Duration(seconds: 3),
          text: 'First line',
        ),
        const SubtitleCue(
          start: Duration(seconds: 5),
          end: Duration(seconds: 7),
          text: 'Second line',
        ),
      ]);

  test('a subtitle nudge shifts every cue by the step size', () {
    final d = doc()..shiftAll(ShortcutSteps.subtitleNudge);

    expect(d.cues[0].start, const Duration(seconds: 1, milliseconds: 100));
    expect(d.cues[1].end, const Duration(seconds: 7, milliseconds: 100));
  });

  test('repeated nudges accumulate', () {
    final d = doc();
    for (var i = 0; i < 5; i++) {
      d.shiftAll(ShortcutSteps.subtitleNudge);
    }

    expect(d.cues[0].start, const Duration(seconds: 1, milliseconds: 500));
  });

  test('a negative nudge moves subtitles earlier', () {
    final d = doc()..shiftAll(-ShortcutSteps.subtitleNudge);
    expect(d.cues[0].start, const Duration(milliseconds: 900));
  });

  test('toSrt output re-parses to the same cues', () {
    // This is what gets handed to the player, so it must be valid SRT.
    final d = doc()..shiftAll(ShortcutSteps.subtitleNudge);
    final reparsed = const SubtitleParser().parse(d.toSrt());

    expect(reparsed.length, d.length);
    for (var i = 0; i < reparsed.length; i++) {
      expect(reparsed[i].start, d.cues[i].start);
      expect(reparsed[i].end, d.cues[i].end);
      expect(reparsed[i].text, d.cues[i].text);
    }
  });

  test('toSrt reflects an edit without needing a save', () {
    final d = doc()..editText(0, 'Corrected');
    expect(d.toSrt(), contains('Corrected'));
    expect(d.isDirty, isTrue);
  });

  test('toSrt on an empty document is empty', () {
    expect(SubtitleDocument(cues: const []).toSrt(), isEmpty);
  });
}
