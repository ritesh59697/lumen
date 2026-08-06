import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/subtitles/srt_parser.dart';
import 'package:lumen/core/subtitles/subtitle_document.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

SubtitleCue cue(int startMs, int endMs, String text) => SubtitleCue(
      start: Duration(milliseconds: startMs),
      end: Duration(milliseconds: endMs),
      text: text,
    );

SubtitleDocument doc() => SubtitleDocument(cues: [
      cue(1000, 2000, 'First'),
      cue(3000, 4000, 'Second'),
      cue(5000, 6000, 'Third'),
    ]);

void main() {
  group('editing', () {
    test('editText replaces text and marks the document dirty', () {
      final d = doc();
      expect(d.isDirty, isFalse);

      d.editText(0, 'Changed');

      expect(d.cues[0].text, 'Changed');
      expect(d.isDirty, isTrue);
    });

    test('editText ignores a no-op change', () {
      final d = doc()..editText(0, 'First');
      expect(d.canUndo, isFalse);
      expect(d.isDirty, isFalse);
    });

    test('editText ignores an out-of-range index', () {
      final d = doc()..editText(99, 'Nope');
      expect(d.isDirty, isFalse);
    });

    test('editTiming rejects an inverted span', () {
      final d = doc()
        ..editTiming(0, end: const Duration(milliseconds: 500));

      expect(d.cues[0].end, const Duration(milliseconds: 2000));
      expect(d.isDirty, isFalse);
    });

    test('removeAt drops the cue', () {
      final d = doc()..removeAt(1);

      expect(d.length, 2);
      expect(d.cues[1].text, 'Third');
    });

    test('insert keeps the list ordered by start time', () {
      final d = doc()..insert(cue(2500, 2800, 'Inserted'));

      expect(d.cues.map((c) => c.text).toList(),
          ['First', 'Inserted', 'Second', 'Third']);
    });

    test('insert appends a cue that starts after all others', () {
      final d = doc()..insert(cue(9000, 9500, 'Last'));
      expect(d.cues.last.text, 'Last');
    });

    test('mergeWithNext joins text and spans both timings', () {
      final d = doc()..mergeWithNext(0);

      expect(d.length, 2);
      expect(d.cues[0].text, 'First Second');
      expect(d.cues[0].start, const Duration(milliseconds: 1000));
      expect(d.cues[0].end, const Duration(milliseconds: 4000));
    });

    test('mergeWithNext does nothing on the final cue', () {
      final d = doc()..mergeWithNext(2);
      expect(d.length, 3);
      expect(d.isDirty, isFalse);
    });
  });

  group('shiftAll', () {
    test('moves every cue by the offset', () {
      final d = doc()..shiftAll(const Duration(milliseconds: 500));

      expect(d.cues[0].start, const Duration(milliseconds: 1500));
      expect(d.cues[2].end, const Duration(milliseconds: 6500));
    });

    test('clamps at zero rather than going negative', () {
      final d = doc()..shiftAll(const Duration(seconds: -10));

      for (final c in d.cues) {
        expect(c.start, greaterThanOrEqualTo(Duration.zero));
        expect(c.end, greaterThanOrEqualTo(Duration.zero));
      }
    });

    test('ignores a zero shift', () {
      final d = doc()..shiftAll(Duration.zero);
      expect(d.isDirty, isFalse);
    });
  });

  group('undo and redo', () {
    test('undo restores the previous state', () {
      final d = doc()..editText(0, 'Changed');
      d.undo();

      expect(d.cues[0].text, 'First');
    });

    test('redo reapplies an undone edit', () {
      final d = doc()..editText(0, 'Changed');
      d..undo()..redo();

      expect(d.cues[0].text, 'Changed');
    });

    test('undo walks back through several edits in order', () {
      final d = doc()
        ..editText(0, 'A')
        ..editText(1, 'B')
        ..removeAt(2);

      expect(d.length, 2);

      d.undo();
      expect(d.length, 3);
      expect(d.cues[1].text, 'B');

      d.undo();
      expect(d.cues[1].text, 'Second');
      expect(d.cues[0].text, 'A');

      d.undo();
      expect(d.cues[0].text, 'First');
      expect(d.canUndo, isFalse);
    });

    test('a new edit clears the redo branch', () {
      final d = doc()..editText(0, 'Changed');
      d.undo();
      expect(d.canRedo, isTrue);

      d.editText(1, 'Different');
      expect(d.canRedo, isFalse);
    });

    test('undo does not alias the live list', () {
      // Guards the classic bug: pushing the list by reference means a later
      // edit silently rewrites history.
      final d = doc()..editText(0, 'Changed');
      d.undo();
      d.editText(1, 'Other');
      d.undo();

      expect(d.cues[0].text, 'First');
      expect(d.cues[1].text, 'Second');
    });

    test('undo on a fresh document is a no-op', () {
      final d = doc()..undo();
      expect(d.cues[0].text, 'First');
    });

    test('history is bounded to maxUndoDepth', () {
      final d = doc();
      for (var i = 0; i < SubtitleDocument.maxUndoDepth + 20; i++) {
        d.editText(0, 'Edit $i');
      }

      var steps = 0;
      while (d.canUndo) {
        d.undo();
        steps++;
      }

      expect(steps, SubtitleDocument.maxUndoDepth);
    });
  });

  group('indexAt', () {
    test('finds the cue covering a position', () {
      final d = doc();
      expect(d.indexAt(const Duration(milliseconds: 1500)), 0);
      expect(d.indexAt(const Duration(milliseconds: 3500)), 1);
    });

    test('returns -1 in a gap between cues', () {
      expect(doc().indexAt(const Duration(milliseconds: 2500)), -1);
    });
  });

  group('persistence', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lumen_doc_test');
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('save writes valid SRT and clears the dirty flag', () async {
      final path = '${tempDir.path}/out.srt';
      final d = doc()..editText(0, 'Saved text');

      await d.save(path: path);

      expect(d.isDirty, isFalse);
      final written = await File(path).readAsString();
      expect(written, contains('Saved text'));

      final reparsed = const SubtitleParser().parse(written);
      expect(reparsed.length, 3);
      expect(reparsed[0].text, 'Saved text');
    });

    test('save leaves no temp file behind', () async {
      final path = '${tempDir.path}/out.srt';
      await doc().save(path: path);

      expect(File('$path.tmp').existsSync(), isFalse);
    });

    test('load round-trips a saved document', () async {
      final path = '${tempDir.path}/round.srt';
      await (doc()..editText(1, 'Edited')).save(path: path);

      final loaded = await SubtitleDocument.load(path);

      expect(loaded.length, 3);
      expect(loaded.cues[1].text, 'Edited');
      expect(loaded.isDirty, isFalse);
      expect(loaded.filePath, path);
    });

    test('save without any path throws', () {
      expect(doc().save(), throwsStateError);
    });

    test('markSavedAs records the path and clears the dirty flag', () {
      // The macOS save dialog writes the bytes itself, so the document is
      // told after the fact rather than performing the write.
      final d = doc()..editText(0, 'Edited');
      expect(d.isDirty, isTrue);

      d.markSavedAs('/somewhere/else/out.srt');

      expect(d.filePath, '/somewhere/else/out.srt');
      expect(d.isDirty, isFalse);
    });

    test('a later plain save targets the newly recorded path', () async {
      final path = '${tempDir.path}/exported.srt';
      final d = doc()..markSavedAs(path);

      d.editText(0, 'After export');
      await d.save();

      expect(File(path).readAsStringSync(), contains('After export'));
    });
  });
}
