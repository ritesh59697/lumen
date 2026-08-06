import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'player_controller.dart';

/// How playback proceeds at the end of an item.
enum PlaylistRepeat {
  /// Stop after the last item.
  off,

  /// Restart the list from the beginning.
  all,

  /// Replay the current item indefinitely.
  one,
}

/// An ordered list of media files with the usual navigation behaviour.
///
/// Holds paths rather than opened media, so building a playlist stays cheap
/// and the player owns all decoding.
class Playlist extends ChangeNotifier {
  Playlist({List<String> paths = const []}) : _paths = List.of(paths);

  List<String> _paths;
  List<String> get paths => List.unmodifiable(_paths);

  int _currentIndex = -1;

  /// Index of the playing item, or -1 when nothing is selected.
  int get currentIndex => _currentIndex;

  String? get currentPath =>
      _currentIndex >= 0 && _currentIndex < _paths.length
          ? _paths[_currentIndex]
          : null;

  bool get isEmpty => _paths.isEmpty;
  int get length => _paths.length;

  PlaylistRepeat _repeat = PlaylistRepeat.off;
  PlaylistRepeat get repeat => _repeat;

  set repeat(PlaylistRepeat mode) {
    if (_repeat == mode) return;
    _repeat = mode;
    notifyListeners();
  }

  bool _shuffle = false;
  bool get shuffle => _shuffle;

  /// Playback order used while shuffling, as indices into [_paths].
  ///
  /// A precomputed permutation rather than a random pick per track, so
  /// shuffling plays everything once before repeating — the behaviour
  /// people actually expect.
  List<int> _shuffleOrder = [];

  set shuffle(bool value) {
    if (_shuffle == value) return;
    _shuffle = value;
    if (value) {
      _rebuildShuffleOrder();
    } else {
      _shuffleOrder = [];
    }
    notifyListeners();
  }

  /// Appends [paths], ignoring anything that is not a recognised media file.
  void addAll(Iterable<String> paths) {
    final accepted = paths.where(isSupportedMedia).toList();
    if (accepted.isEmpty) return;

    _paths.addAll(accepted);
    if (_shuffle) _rebuildShuffleOrder();
    notifyListeners();
  }

  void add(String path) => addAll([path]);

  /// Adds every supported file directly inside [directoryPath].
  ///
  /// Sorted by name so a numbered series plays in order.
  Future<int> addDirectory(String directoryPath) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) return 0;

    final found = <String>[];
    await for (final entity in dir.list()) {
      if (entity is File && isSupportedMedia(entity.path)) {
        found.add(entity.path);
      }
    }

    found.sort(_naturalCompare);
    addAll(found);
    return found.length;
  }

  /// Removes the item at [index], keeping [currentIndex] pointing at the
  /// same item where possible.
  void removeAt(int index) {
    if (index < 0 || index >= _paths.length) return;

    _paths.removeAt(index);

    if (index < _currentIndex) {
      _currentIndex--;
    } else if (index == _currentIndex) {
      // The playing item is gone; clamp into the new bounds.
      if (_paths.isEmpty) {
        _currentIndex = -1;
      } else if (_currentIndex >= _paths.length) {
        _currentIndex = _paths.length - 1;
      }
    }

    if (_shuffle) _rebuildShuffleOrder();
    notifyListeners();
  }

  void clear() {
    _paths = [];
    _shuffleOrder = [];
    _currentIndex = -1;
    notifyListeners();
  }

  /// Moves the item at [from] to [to], for drag-to-reorder.
  void move(int from, int to) {
    if (from < 0 || from >= _paths.length) return;
    if (to < 0 || to >= _paths.length || from == to) return;

    final path = _paths.removeAt(from);
    _paths.insert(to, path);

    // Keep following whatever was playing.
    if (_currentIndex == from) {
      _currentIndex = to;
    } else if (from < _currentIndex && to >= _currentIndex) {
      _currentIndex--;
    } else if (from > _currentIndex && to <= _currentIndex) {
      _currentIndex++;
    }

    notifyListeners();
  }

  /// Selects [index] and returns its path, or null if out of range.
  String? jumpTo(int index) {
    if (index < 0 || index >= _paths.length) return null;

    _currentIndex = index;
    notifyListeners();
    return _paths[index];
  }

  /// The next item to play, honouring shuffle and repeat.
  ///
  /// Returns null when the list is finished. [PlaylistRepeat.one] is handled by
  /// the caller on natural completion, so an explicit "next" press still
  /// advances rather than replaying.
  String? next() {
    if (_paths.isEmpty) return null;

    final nextIndex = _nextIndex();
    if (nextIndex == null) return null;

    _currentIndex = nextIndex;
    notifyListeners();
    return _paths[_currentIndex];
  }

  /// The previous item, wrapping only when repeating the whole list.
  String? previous() {
    if (_paths.isEmpty) return null;

    if (_shuffle) {
      final position = _shuffleOrder.indexOf(_currentIndex);
      if (position > 0) {
        _currentIndex = _shuffleOrder[position - 1];
        notifyListeners();
        return _paths[_currentIndex];
      }
      if (_repeat != PlaylistRepeat.all) return null;
      _currentIndex = _shuffleOrder.last;
      notifyListeners();
      return _paths[_currentIndex];
    }

    if (_currentIndex > 0) {
      _currentIndex--;
    } else if (_repeat == PlaylistRepeat.all) {
      _currentIndex = _paths.length - 1;
    } else {
      return null;
    }

    notifyListeners();
    return _paths[_currentIndex];
  }

  /// What to play when the current item ends on its own.
  ///
  /// Distinct from [next] so [PlaylistRepeat.one] can replay the same file.
  String? onCompleted() {
    if (_repeat == PlaylistRepeat.one) return currentPath;
    return next();
  }

  int? _nextIndex() {
    if (_shuffle) {
      final position = _shuffleOrder.indexOf(_currentIndex);
      if (position >= 0 && position + 1 < _shuffleOrder.length) {
        return _shuffleOrder[position + 1];
      }
      if (_repeat == PlaylistRepeat.all) {
        _rebuildShuffleOrder();
        return _shuffleOrder.first;
      }
      return null;
    }

    if (_currentIndex + 1 < _paths.length) return _currentIndex + 1;
    if (_repeat == PlaylistRepeat.all) return 0;
    return null;
  }

  void _rebuildShuffleOrder() {
    _shuffleOrder = List.generate(_paths.length, (i) => i)..shuffle(Random());

    // Keep the playing item first so enabling shuffle never cuts it off.
    if (_currentIndex >= 0) {
      _shuffleOrder
        ..remove(_currentIndex)
        ..insert(0, _currentIndex);
    }
  }

  /// Whether [path] has a container extension the player can open.
  static bool isSupportedMedia(String path) {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    return PlayerController.videoExtensions.contains(ext);
  }

  /// Compares filenames so `ep2` sorts before `ep10`.
  ///
  /// Plain string sort puts `10` before `2`, which scrambles numbered
  /// series — the most common thing anyone puts in a playlist.
  static int _naturalCompare(String a, String b) {
    final ax = p.basename(a).toLowerCase();
    final bx = p.basename(b).toLowerCase();

    final chunk = RegExp(r'(\d+|\D+)');
    final aParts = chunk.allMatches(ax).map((m) => m.group(0)!).toList();
    final bParts = chunk.allMatches(bx).map((m) => m.group(0)!).toList();

    for (var i = 0; i < min(aParts.length, bParts.length); i++) {
      final an = int.tryParse(aParts[i]);
      final bn = int.tryParse(bParts[i]);

      final cmp = (an != null && bn != null)
          ? an.compareTo(bn)
          : aParts[i].compareTo(bParts[i]);

      if (cmp != 0) return cmp;
    }

    return aParts.length.compareTo(bParts.length);
  }
}
