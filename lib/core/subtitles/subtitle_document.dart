import 'dart:io';

import 'package:flutter/foundation.dart';

import 'srt_parser.dart';
import 'subtitle_model.dart';

/// An editable subtitle track backed by a file on disk.
///
/// Owns the cue list, undo history, and unsaved-changes flag. Kept separate
/// from any widget so the editing rules are testable without a UI, and so
/// the same document can back both an editor pane and the player.
///
/// Edits are recorded as whole-list snapshots. Subtitle files are small
/// (a feature-length film is a few thousand cues), so the memory cost is
/// trivial next to the complexity of per-field undo commands.
class SubtitleDocument extends ChangeNotifier {
  SubtitleDocument({
    required List<SubtitleCue> cues,
    this.filePath,
  }) : _cues = List.of(cues);

  /// Loads a document from an .srt or .vtt file.
  static Future<SubtitleDocument> load(String path) async {
    final content = await File(path).readAsString();
    return SubtitleDocument(
      cues: const SubtitleParser().parse(content),
      filePath: path,
    );
  }

  /// Where [save] writes. Null for a document not yet associated with a file.
  String? filePath;

  List<SubtitleCue> _cues;

  /// The current cues. Returned unmodifiable so all mutation goes through
  /// the methods here and is therefore undoable.
  List<SubtitleCue> get cues => List.unmodifiable(_cues);

  int get length => _cues.length;

  /// Snapshots of previous states, oldest first.
  final List<List<SubtitleCue>> _undoStack = [];
  final List<List<SubtitleCue>> _redoStack = [];

  /// Bounded so a long editing session cannot grow memory without limit.
  static const int maxUndoDepth = 100;

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  bool _dirty = false;

  /// Whether there are edits not yet written to disk.
  bool get isDirty => _dirty;

  /// Identifies the in-progress nudge run, so repeated adjustments to the
  /// same edge collapse into one undo entry. Null between runs.
  _NudgeSignature? _lastNudge;

  /// Records the current state, then applies [change].
  ///
  /// Every mutation routes through here so undo coverage cannot be
  /// forgotten when a new edit operation is added.
  void _mutate(void Function() change) {
    _undoStack.add(List.of(_cues));
    if (_undoStack.length > maxUndoDepth) _undoStack.removeAt(0);

    // A new edit invalidates any redo branch.
    _redoStack.clear();

    change();

    _dirty = true;
    notifyListeners();
  }

  /// Replaces the text of the cue at [index].
  void editText(int index, String text) {
    if (index < 0 || index >= _cues.length) return;
    if (_cues[index].text == text) return;

    _lastNudge = null;
    _mutate(() => _cues[index] = _cues[index].copyWith(text: text));
  }

  /// Retimes the cue at [index].
  ///
  /// Rejects a non-positive span outright: a cue that ends before it starts
  /// cannot be displayed and would corrupt the file.
  void editTiming(int index, {Duration? start, Duration? end}) {
    if (index < 0 || index >= _cues.length) return;

    final current = _cues[index];
    final newStart = start ?? current.start;
    final newEnd = end ?? current.end;

    if (newEnd <= newStart) return;
    if (newStart == current.start && newEnd == current.end) return;

    _mutate(
      () => _cues[index] = current.copyWith(start: newStart, end: newEnd),
    );
  }

  /// Nudges one edge of the cue at [index] by [delta].
  ///
  /// [edge] selects which boundary moves; passing [CueEdge.both] slides the
  /// whole cue without changing its length.
  ///
  /// Consecutive nudges of the same edge on the same cue are coalesced into
  /// a single undo entry. Without this, holding a nudge key would bury the
  /// pre-nudge state under dozens of one-frame steps and make undo useless.
  void nudge(int index, CueEdge edge, Duration delta) {
    if (index < 0 || index >= _cues.length) return;
    if (delta == Duration.zero) return;

    final current = _cues[index];

    var start = current.start;
    var end = current.end;

    switch (edge) {
      case CueEdge.start:
        start = _clampNonNegative(start + delta);
      case CueEdge.end:
        end = _clampNonNegative(end + delta);
      case CueEdge.both:
        // Slide as a unit: if the start would clip at zero, hold the
        // length steady rather than silently stretching the cue.
        final shifted = _clampNonNegative(start + delta);
        final applied = shifted - start;
        start = shifted;
        end = end + applied;
    }

    if (end <= start) return;
    if (start == current.start && end == current.end) return;

    final signature = _NudgeSignature(index, edge);

    if (_lastNudge == signature) {
      // Continue the existing undo entry.
      _cues[index] = current.copyWith(start: start, end: end);
      _dirty = true;
      notifyListeners();
      return;
    }

    _mutate(() => _cues[index] = current.copyWith(start: start, end: end));
    _lastNudge = signature;
  }

  /// Ends a run of coalesced nudges, so the next one starts a fresh
  /// undo entry. Call when the user releases the control or moves away.
  void endNudge() => _lastNudge = null;

  /// Sets the start of the cue at [index] to [position], typically the
  /// current playhead. The end moves with it, preserving duration.
  void retimeToPlayhead(int index, Duration position) {
    if (index < 0 || index >= _cues.length) return;

    final current = _cues[index];
    final length = current.duration;
    final start = _clampNonNegative(position);

    if (start == current.start) return;

    _lastNudge = null;
    _mutate(
      () => _cues[index] = current.copyWith(start: start, end: start + length),
    );
  }

  /// Splits the cue at [index] at [position], dividing its text in two.
  ///
  /// The counterpart to [mergeWithNext]: Whisper sometimes packs two
  /// sentences into one long segment. Text is split at the word boundary
  /// nearest the proportional cut point, so neither half is left empty.
  void splitAt(int index, Duration position) {
    if (index < 0 || index >= _cues.length) return;

    final current = _cues[index];
    if (position <= current.start || position >= current.end) return;

    final words = current.text.split(RegExp(r'\s+'))
      ..removeWhere((w) => w.isEmpty);
    if (words.length < 2) return;

    // Cut the text in proportion to where the split falls in time.
    final ratio = (position - current.start).inMilliseconds /
        current.duration.inMilliseconds;
    final cut = (words.length * ratio).round().clamp(1, words.length - 1);

    _lastNudge = null;
    _mutate(() {
      _cues[index] = current.copyWith(
        end: position,
        text: words.sublist(0, cut).join(' '),
      );
      _cues.insert(
        index + 1,
        SubtitleCue(
          start: position,
          end: current.end,
          text: words.sublist(cut).join(' '),
        ),
      );
    });
  }

  /// Shifts every cue by [offset], clamped so nothing goes negative.
  ///
  /// This is the single most useful bulk operation: generated or downloaded
  /// subtitles are often uniformly early or late against the video.
  void shiftAll(Duration offset) {
    if (offset == Duration.zero || _cues.isEmpty) return;

    _mutate(() {
      _cues = [
        for (final cue in _cues)
          cue.copyWith(
            start: _clampNonNegative(cue.start + offset),
            end: _clampNonNegative(cue.end + offset),
          ),
      ];
    });
  }

  /// Removes the cue at [index].
  void removeAt(int index) {
    if (index < 0 || index >= _cues.length) return;
    _mutate(() => _cues.removeAt(index));
  }

  /// Inserts [cue], keeping the list ordered by start time.
  void insert(SubtitleCue cue) {
    _mutate(() {
      final at = _cues.indexWhere((c) => c.start > cue.start);
      if (at == -1) {
        _cues.add(cue);
      } else {
        _cues.insert(at, cue);
      }
    });
  }

  /// Merges the cue at [index] with the one after it.
  ///
  /// Useful when Whisper splits a single sentence across two segments.
  void mergeWithNext(int index) {
    if (index < 0 || index >= _cues.length - 1) return;

    _mutate(() {
      final first = _cues[index];
      final second = _cues[index + 1];

      _cues[index] = SubtitleCue(
        start: first.start,
        end: second.end,
        text: '${first.text} ${second.text}'.replaceAll(RegExp(r'\s+'), ' '),
      );
      _cues.removeAt(index + 1);
    });
  }

  void undo() {
    if (_undoStack.isEmpty) return;

    // End any nudge run: continuing it after an undo would append to a
    // history entry the user has already stepped past.
    _lastNudge = null;

    _redoStack.add(List.of(_cues));
    _cues = _undoStack.removeLast();
    _dirty = true;
    notifyListeners();
  }

  void redo() {
    if (_redoStack.isEmpty) return;

    _lastNudge = null;

    _undoStack.add(List.of(_cues));
    _cues = _redoStack.removeLast();
    _dirty = true;
    notifyListeners();
  }

  /// Writes the document back to disk as SRT.
  ///
  /// Writes to a temp file and renames over the target, so an interrupted
  /// save cannot leave a half-written subtitle file where a good one was.
  Future<void> save({String? path}) async {
    final target = path ?? filePath;
    if (target == null) {
      throw StateError('No file path set for this subtitle document.');
    }

    final temp = File('$target.tmp');
    await temp.writeAsString(cuesToSrt(_cues), flush: true);
    await temp.rename(target);

    filePath = target;
    _dirty = false;
    notifyListeners();
  }

  /// Serializes the current cues to SRT without touching disk.
  ///
  /// Used to push live edits straight into the player.
  String toSrt() => cuesToSrt(_cues);

  /// Records that the document was written to [path] by something other
  /// than [save] — the macOS save dialog writes the bytes itself, so the
  /// document must be told rather than doing the write.
  void markSavedAs(String path) {
    filePath = path;
    _dirty = false;
    notifyListeners();
  }

  /// Index of the cue covering [position], or -1 if none does.
  ///
  /// Used to highlight the active line while the video plays.
  int indexAt(Duration position) {
    for (var i = 0; i < _cues.length; i++) {
      if (position >= _cues[i].start && position <= _cues[i].end) return i;
    }
    return -1;
  }

  Duration _clampNonNegative(Duration d) =>
      d < Duration.zero ? Duration.zero : d;
}

/// Which boundary of a cue a timing adjustment moves.
enum CueEdge {
  /// Move the in-point, changing the cue's length.
  start,

  /// Move the out-point, changing the cue's length.
  end,

  /// Move both, preserving length.
  both,
}

/// Identifies a run of nudges on one edge of one cue, for undo coalescing.
class _NudgeSignature {
  const _NudgeSignature(this.index, this.edge);

  final int index;
  final CueEdge edge;

  @override
  bool operator ==(Object other) =>
      other is _NudgeSignature && other.index == index && other.edge == edge;

  @override
  int get hashCode => Object.hash(index, edge);
}
