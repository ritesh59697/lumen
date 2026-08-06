import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/player/playlist.dart';

Playlist listOf(int n) => Playlist(
      paths: [for (var i = 1; i <= n; i++) '/videos/clip$i.mp4'],
    );

void main() {
  group('adding', () {
    test('accepts supported media and rejects everything else', () {
      final pl = Playlist()
        ..addAll([
          '/videos/a.mp4',
          '/videos/b.mkv',
          '/videos/notes.txt',
          '/videos/cover.jpg',
        ]);

      expect(pl.length, 2);
    });

    test('ignores an add of only unsupported files', () {
      final pl = Playlist()..addAll(['/videos/readme.md']);
      expect(pl.isEmpty, isTrue);
    });
  });

  group('navigation', () {
    test('next advances and stops at the end by default', () {
      final pl = listOf(3)..jumpTo(0);

      expect(pl.next(), '/videos/clip2.mp4');
      expect(pl.next(), '/videos/clip3.mp4');
      expect(pl.next(), isNull);
      expect(pl.currentIndex, 2);
    });

    test('next wraps when repeating all', () {
      final pl = listOf(3)
        ..jumpTo(2)
        ..repeat = PlaylistRepeat.all;

      expect(pl.next(), '/videos/clip1.mp4');
    });

    test('previous stops at the start by default', () {
      final pl = listOf(3)..jumpTo(0);
      expect(pl.previous(), isNull);
    });

    test('previous wraps to the end when repeating all', () {
      final pl = listOf(3)
        ..jumpTo(0)
        ..repeat = PlaylistRepeat.all;

      expect(pl.previous(), '/videos/clip3.mp4');
    });

    test('jumpTo rejects an out-of-range index', () {
      final pl = listOf(3)..jumpTo(1);
      expect(pl.jumpTo(99), isNull);
      expect(pl.currentIndex, 1);
    });
  });

  group('repeat one', () {
    test('onCompleted replays the same item', () {
      final pl = listOf(3)
        ..jumpTo(1)
        ..repeat = PlaylistRepeat.one;

      expect(pl.onCompleted(), '/videos/clip2.mp4');
      expect(pl.currentIndex, 1);
    });

    test('an explicit next still advances past a repeating item', () {
      final pl = listOf(3)
        ..jumpTo(1)
        ..repeat = PlaylistRepeat.one;

      expect(pl.next(), '/videos/clip3.mp4');
    });
  });

  group('removal keeps the current item stable', () {
    test('removing an earlier item shifts the index down', () {
      final pl = listOf(4)..jumpTo(2);
      pl.removeAt(0);

      expect(pl.currentIndex, 1);
      expect(pl.currentPath, '/videos/clip3.mp4');
    });

    test('removing a later item leaves the index alone', () {
      final pl = listOf(4)..jumpTo(1);
      pl.removeAt(3);

      expect(pl.currentIndex, 1);
      expect(pl.currentPath, '/videos/clip2.mp4');
    });

    test('removing the last item while it plays clamps the index', () {
      final pl = listOf(3)..jumpTo(2);
      pl.removeAt(2);

      expect(pl.currentIndex, 1);
    });

    test('emptying the list resets the index', () {
      final pl = listOf(1)..jumpTo(0);
      pl.removeAt(0);

      expect(pl.currentIndex, -1);
      expect(pl.currentPath, isNull);
    });
  });

  group('reordering follows the playing item', () {
    test('moving the current item updates the index', () {
      final pl = listOf(4)..jumpTo(0);
      pl.move(0, 2);

      expect(pl.currentIndex, 2);
      expect(pl.currentPath, '/videos/clip1.mp4');
    });

    test('moving an item from before to after decrements the index', () {
      final pl = listOf(4)..jumpTo(2);
      pl.move(0, 3);

      expect(pl.currentPath, '/videos/clip3.mp4');
    });

    test('moving an item from after to before increments the index', () {
      final pl = listOf(4)..jumpTo(1);
      pl.move(3, 0);

      expect(pl.currentPath, '/videos/clip2.mp4');
    });
  });

  group('shuffle', () {
    test('keeps the playing item first so it is not cut off', () {
      final pl = listOf(5)..jumpTo(3);
      pl.shuffle = true;

      expect(pl.currentIndex, 3);
      expect(pl.currentPath, '/videos/clip4.mp4');
    });

    test('plays every item exactly once before stopping', () {
      final pl = listOf(5)..jumpTo(0);
      pl.shuffle = true;

      final seen = <String>{pl.currentPath!};
      String? item;
      while ((item = pl.next()) != null) {
        seen.add(item!);
      }

      expect(seen.length, 5);
    });

    test('disabling shuffle restores sequential order', () {
      final pl = listOf(4)..jumpTo(0);
      pl
        ..shuffle = true
        ..shuffle = false
        ..jumpTo(0);

      expect(pl.next(), '/videos/clip2.mp4');
    });
  });

  group('directory loading', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('lumen_playlist_test');
    });

    tearDown(() async {
      if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    });

    test('adds only media files, sorted naturally', () async {
      for (final name in [
        'ep10.mp4',
        'ep2.mp4',
        'ep1.mp4',
        'notes.txt',
      ]) {
        await File('${tempDir.path}/$name').writeAsString('x');
      }

      final pl = Playlist();
      final added = await pl.addDirectory(tempDir.path);

      expect(added, 3);
      // ep2 must come before ep10 — plain string sort gets this wrong.
      expect(
        pl.paths.map((p) => p.split('/').last).toList(),
        ['ep1.mp4', 'ep2.mp4', 'ep10.mp4'],
      );
    });

    test('returns zero for a directory that does not exist', () async {
      final pl = Playlist();
      expect(await pl.addDirectory('${tempDir.path}/nope'), 0);
    });
  });
}
