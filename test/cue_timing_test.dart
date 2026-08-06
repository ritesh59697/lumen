import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/subtitles/subtitle_document.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

SubtitleCue cue(int startMs, int endMs, String text) => SubtitleCue(
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
      text: text,
    );

SubtitleDocument doc() => SubtitleDocument(cues: [
      cue(1000, 3000, 'First cue here'),
      cue(4000, 6000, 'Second cue here'),
      cue(7000, 9000, 'Third cue here'),
    ]);

const step = Duration(milliseconds: 100);

void main() {
  group('nudge', () {
    test('start edge moves the in-point only', () {
      final d = doc()..nudge(0, CueEdge.start, step);

      expect(d.cues[0].start, const Duration(milliseconds: 1100));
      expect(d.cues[0].end, const Duration(milliseconds: 3000));
    });

    test('end edge moves the out-point only', () {
      final d = doc()..nudge(0, CueEdge.end, step);

      expect(d.cues[0].start, const Duration(milliseconds: 1000));
      expect(d.cues[0].end, const Duration(milliseconds: 3100));
    });

    test('both edges slide the cue without changing its length', () {
      final d = doc();
      final before = d.cues[0].duration;

      d.nudge(0, CueEdge.both, step);

      expect(d.cues[0].start, const Duration(milliseconds: 1100));
      expect(d.cues[0].duration, before);
    });

    test('sliding into negative time holds the length steady', () {
      // Start is 1000ms; a -5s slide must clamp at zero without stretching.
      final d = doc();
      final before = d.cues[0].duration;

      d.nudge(0, CueEdge.both, const Duration(seconds: -5));

      expect(d.cues[0].start, Duration.zero);
      expect(d.cues[0].duration, before);
    });

    test('refuses to invert the cue', () {
      final d = doc()..nudge(0, CueEdge.start, const Duration(seconds: 5));

      expect(d.cues[0].start, const Duration(milliseconds: 1000));
      expect(d.isDirty, isFalse);
    });

    test('ignores a zero delta and out-of-range indices', () {
      final d = doc()
        ..nudge(0, CueEdge.start, Duration.zero)
        ..nudge(99, CueEdge.start, step);

      expect(d.isDirty, isFalse);
    });
  });

  group('nudge undo coalescing', () {
    test('a run of nudges collapses into one undo step', () {
      final d = doc();
      for (var i = 0; i < 10; i++) {
        d.nudge(0, CueEdge.end, step);
      }

      expect(d.cues[0].end, const Duration(milliseconds: 4000));

      d.undo();

      // One undo returns to the pre-run state, not one step back.
      expect(d.cues[0].end, const Duration(milliseconds: 3000));
      expect(d.canUndo, isFalse);
    });

    test('switching edge starts a new undo entry', () {
      final d = doc()
        ..nudge(0, CueEdge.end, step)
        ..nudge(0, CueEdge.start, step);

      d.undo();
      expect(d.cues[0].start, const Duration(milliseconds: 1000));
      expect(d.cues[0].end, const Duration(milliseconds: 3100));

      d.undo();
      expect(d.cues[0].end, const Duration(milliseconds: 3000));
    });

    test('switching cue starts a new undo entry', () {
      final d = doc()
        ..nudge(0, CueEdge.end, step)
        ..nudge(1, CueEdge.end, step);

      d.undo();
      expect(d.cues[1].end, const Duration(milliseconds: 6000));
      expect(d.cues[0].end, const Duration(milliseconds: 3100));
    });

    test('endNudge closes the run so the next nudge is separate', () {
      final d = doc()
        ..nudge(0, CueEdge.end, step)
        ..endNudge()
        ..nudge(0, CueEdge.end, step);

      expect(d.cues[0].end, const Duration(milliseconds: 3200));

      d.undo();
      expect(d.cues[0].end, const Duration(milliseconds: 3100));
    });

    test('a nudge after undo does not rewrite the restored history', () {
      // Guards the leak where the coalescing key survives an undo and the
      // next nudge appends to an entry the user already stepped past.
      final d = doc()..nudge(0, CueEdge.end, step);
      d.undo();
      expect(d.cues[0].end, const Duration(milliseconds: 3000));

      d.nudge(0, CueEdge.end, step);
      expect(d.cues[0].end, const Duration(milliseconds: 3100));

      d.undo();
      expect(d.cues[0].end, const Duration(milliseconds: 3000));
    });

    test('a text edit between nudges breaks the run', () {
      final d = doc()
        ..nudge(0, CueEdge.end, step)
        ..editText(0, 'Changed')
        ..nudge(0, CueEdge.end, step);

      d.undo();
      expect(d.cues[0].end, const Duration(milliseconds: 3100));
      expect(d.cues[0].text, 'Changed');
    });
  });

  group('retimeToPlayhead', () {
    test('moves the cue to the playhead, preserving length', () {
      final d = doc();
      final before = d.cues[1].duration;

      d.retimeToPlayhead(1, const Duration(milliseconds: 4500));

      expect(d.cues[1].start, const Duration(milliseconds: 4500));
      expect(d.cues[1].duration, before);
    });

    test('is undoable as a single step', () {
      final d = doc()
        ..retimeToPlayhead(1, const Duration(milliseconds: 4500))
        ..undo();

      expect(d.cues[1].start, const Duration(milliseconds: 4000));
    });

    test('ignores a retime to the current start', () {
      final d = doc()..retimeToPlayhead(1, const Duration(milliseconds: 4000));
      expect(d.isDirty, isFalse);
    });
  });

  group('splitAt', () {
    test('divides a cue into two at the given position', () {
      final d = doc()..splitAt(0, const Duration(milliseconds: 2000));

      expect(d.length, 4);
      expect(d.cues[0].end, const Duration(milliseconds: 2000));
      expect(d.cues[1].start, const Duration(milliseconds: 2000));
      expect(d.cues[1].end, const Duration(milliseconds: 3000));
    });

    test('splits the text at a word boundary with neither half empty', () {
      final d = doc()..splitAt(0, const Duration(milliseconds: 2000));

      expect(d.cues[0].text.trim(), isNotEmpty);
      expect(d.cues[1].text.trim(), isNotEmpty);
      // No words lost.
      expect(
        '${d.cues[0].text} ${d.cues[1].text}',
        'First cue here',
      );
    });

    test('refuses to split outside the cue span', () {
      final d = doc()
        ..splitAt(0, const Duration(milliseconds: 500))
        ..splitAt(0, const Duration(milliseconds: 5000));

      expect(d.length, 3);
      expect(d.isDirty, isFalse);
    });

    test('refuses to split a single-word cue', () {
      final d = SubtitleDocument(cues: [cue(1000, 3000, 'Hello')])
        ..splitAt(0, const Duration(milliseconds: 2000));

      expect(d.length, 1);
      expect(d.isDirty, isFalse);
    });

    test('is undoable as a single step', () {
      final d = doc()
        ..splitAt(0, const Duration(milliseconds: 2000))
        ..undo();

      expect(d.length, 3);
      expect(d.cues[0].text, 'First cue here');
    });

    test('split then merge restores the original cue', () {
      final d = doc()
        ..splitAt(0, const Duration(milliseconds: 2000))
        ..mergeWithNext(0);

      expect(d.length, 3);
      expect(d.cues[0].text, 'First cue here');
      expect(d.cues[0].start, const Duration(milliseconds: 1000));
      expect(d.cues[0].end, const Duration(milliseconds: 3000));
    });
  });
}
