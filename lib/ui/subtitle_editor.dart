import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/subtitles/subtitle_document.dart';
import '../core/subtitles/subtitle_model.dart';

/// How far one nudge moves a cue boundary.
const _nudgeStep = Duration(milliseconds: 100);

/// A side panel for reviewing and correcting subtitles while the video plays.
///
/// Built around the workflow that actually matters after auto-generation:
/// scan for mistakes, fix a line, nudge timing that drifted. The cue under
/// the playhead is highlighted, and tapping a cue seeks to it, so errors can
/// be found by watching rather than by reading timestamps.
class SubtitleEditor extends StatefulWidget {
  const SubtitleEditor({
    super.key,
    required this.document,
    required this.position,
    required this.onSeek,
    required this.onClose,
    this.onSubtitlesChanged,
  });

  /// Called after any timing edit, so the parent can push the revised
  /// subtitles into the player and make the change visible immediately.
  final VoidCallback? onSubtitlesChanged;

  final SubtitleDocument document;

  /// Current playback position, used to highlight the active cue.
  final Duration position;

  final void Function(Duration) onSeek;
  final VoidCallback onClose;

  /// Height of a normal row. Fixed so scroll offsets can be computed
  /// directly rather than needing a keyed measurement pass.
  static const double rowHeight = 78;

  /// Height of the selected row, which also shows timing controls.
  static const double expandedRowHeight = 108;

  @override
  State<SubtitleEditor> createState() => _SubtitleEditorState();
}

class _SubtitleEditorState extends State<SubtitleEditor> {
  final _scrollController = ScrollController();

  /// Index being edited, or -1 when the list is read-only.
  int _editingIndex = -1;
  TextEditingController? _textController;

  /// Suppresses auto-scroll while the user is reading or editing, so the
  /// list does not yank away under them.
  bool _followPlayback = true;
  int _lastFollowedIndex = -1;

  /// Row showing timing controls, or -1 when none is selected.
  int _selectedIndex = -1;

  @override
  void initState() {
    super.initState();
    widget.document.addListener(_onDocumentChanged);
  }

  @override
  void didUpdateWidget(SubtitleEditor old) {
    super.didUpdateWidget(old);
    if (old.document != widget.document) {
      old.document.removeListener(_onDocumentChanged);
      widget.document.addListener(_onDocumentChanged);
    }
    if (_followPlayback && _editingIndex == -1) _scrollToActive();
  }

  @override
  void dispose() {
    widget.document.removeListener(_onDocumentChanged);
    _textController?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onDocumentChanged() {
    if (mounted) setState(() {});
  }

  void _scrollToActive() {
    final index = widget.document.indexAt(widget.position);
    if (index < 0 || index == _lastFollowedIndex) return;
    if (!_scrollController.hasClients) return;

    _lastFollowedIndex = index;

    // Rows are fixed-height, but the selected row is taller, so account for
    // it when it sits above the target. Ignoring this would leave the
    // active cue offset by the difference.
    var target = index * SubtitleEditor.rowHeight;
    if (_selectedIndex >= 0 && _selectedIndex < index) {
      target += SubtitleEditor.expandedRowHeight - SubtitleEditor.rowHeight;
    }
    target -= 120;

    _scrollController.animateTo(
      target.clamp(0.0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _beginEdit(int index) {
    _textController?.dispose();
    setState(() {
      _editingIndex = index;
      _textController =
          TextEditingController(text: widget.document.cues[index].text);
    });
  }

  void _commitEdit() {
    if (_editingIndex >= 0 && _textController != null) {
      widget.document.editText(_editingIndex, _textController!.text.trim());
    }
    setState(() => _editingIndex = -1);
  }

  void _nudge(int index, CueEdge edge, Duration delta) {
    widget.document.nudge(index, edge, delta);
    widget.onSubtitlesChanged?.call();
  }

  /// Moves the cue to the current playhead, keeping its length.
  void _retimeToPlayhead(int index) {
    widget.document.retimeToPlayhead(index, widget.position);
    widget.onSubtitlesChanged?.call();
  }

  /// Splits the cue at the playhead.
  ///
  /// Only meaningful while the playhead sits inside the cue, so it reports
  /// rather than silently doing nothing.
  void _split(int index) {
    final cue = widget.document.cues[index];
    final at = widget.position;

    if (at <= cue.start || at >= cue.end) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Move the playhead inside the cue to split it'),
        ),
      );
      return;
    }

    widget.document.splitAt(index, at);
    widget.onSubtitlesChanged?.call();
  }

  Future<void> _promptShift() async {
    final controller = TextEditingController(text: '0.0');

    final seconds = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Shift all subtitles'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Positive values delay subtitles, negative move them earlier.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(signed: true, decimal: true),
              decoration: const InputDecoration(
                labelText: 'Seconds',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              double.tryParse(controller.text),
            ),
            child: const Text('Shift'),
          ),
        ],
      ),
    );

    controller.dispose();
    if (seconds == null || seconds == 0) return;

    widget.document.shiftAll(
      Duration(milliseconds: (seconds * 1000).round()),
    );
    widget.onSubtitlesChanged?.call();
  }

  /// Writes the subtitles wherever the user chooses.
  ///
  /// Uses the save dialog rather than writing directly: under the macOS
  /// sandbox the app can only write where the user has explicitly pointed
  /// it, and passing bytes lets the plugin do the write inside that grant.
  Future<void> _saveAs() async {
    final doc = widget.document;

    final suggested = doc.filePath != null
        ? p.basename(doc.filePath!)
        : 'subtitles.srt';

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save subtitles',
      fileName: suggested,
      type: FileType.custom,
      allowedExtensions: const ['srt'],
      bytes: utf8.encode(doc.toSrt()),
    );

    if (path == null) return; // Cancelled.

    // The plugin already wrote the file; record where it went and clear
    // the unsaved marker so the dirty dot disappears.
    doc.markSavedAs(path);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Saved to ${p.basename(path)}')),
    );
  }

  Future<void> _save() async {
    // No known-writable location yet, so ask where it should go.
    if (widget.document.filePath == null) return _saveAs();

    try {
      await widget.document.save();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Subtitles saved')),
      );
    } on FileSystemException {
      // The original location is no longer writable (sandbox grant expired,
      // volume unmounted). Fall back to asking rather than losing the edit.
      if (!mounted) return;
      await _saveAs();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.document;
    final activeIndex = doc.indexAt(widget.position);

    if (_followPlayback && _editingIndex == -1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToActive();
      });
    }

    return Container(
      width: 380,
      color: const Color(0xFF141414),
      child: Column(
        children: [
          _Toolbar(
            document: doc,
            followPlayback: _followPlayback,
            onToggleFollow: () =>
                setState(() => _followPlayback = !_followPlayback),
            onShift: _promptShift,
            onSave: _save,
            onSaveAs: _saveAs,
            onClose: widget.onClose,
          ),
          const Divider(height: 1),
          Expanded(
            child: doc.length == 0
                ? const Center(
                    child: Text(
                      'No subtitles loaded',
                      style: TextStyle(color: Colors.white38),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: doc.length,
                    itemBuilder: (context, index) {
                      final cue = doc.cues[index];
                      return _CueRow(
                        cue: cue,
                        index: index,
                        isActive: index == activeIndex,
                        isEditing: index == _editingIndex,
                        // Fall back to the playing cue so the timing
                        // controls are discoverable without a click —
                        // otherwise nothing hints that they exist.
                        isSelected: _selectedIndex >= 0
                            ? index == _selectedIndex
                            : index == activeIndex,
                        textController: _textController,
                        onTap: () {
                          // Selecting reveals the timing controls; seeking
                          // there too keeps the video in step with the cue
                          // being adjusted.
                          setState(() => _selectedIndex = index);
                          widget.onSeek(cue.start);
                        },
                        onEdit: () => _beginEdit(index),
                        onCommit: _commitEdit,
                        onDelete: () => doc.removeAt(index),
                        onMerge: index < doc.length - 1
                            ? () => doc.mergeWithNext(index)
                            : null,
                        onNudge: (edge, delta) => _nudge(index, edge, delta),
                        onNudgeEnd: doc.endNudge,
                        onRetimeToPlayhead: () =>
                            _retimeToPlayhead(index),
                        onSplit: () => _split(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.document,
    required this.followPlayback,
    required this.onToggleFollow,
    required this.onShift,
    required this.onSave,
    required this.onSaveAs,
    required this.onClose,
  });

  final SubtitleDocument document;
  final bool followPlayback;
  final VoidCallback onToggleFollow;
  final VoidCallback onShift;
  final VoidCallback onSave;
  final VoidCallback onSaveAs;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        children: [
          Text(
            'Subtitles',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (document.isDirty)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Text(
                '•',
                style: TextStyle(color: Colors.amber, fontSize: 18),
              ),
            ),
          const Spacer(),
          IconButton(
            onPressed: document.canUndo ? document.undo : null,
            icon: const Icon(Icons.undo, size: 18),
            tooltip: 'Undo',
          ),
          IconButton(
            onPressed: document.canRedo ? document.redo : null,
            icon: const Icon(Icons.redo, size: 18),
            tooltip: 'Redo',
          ),
          IconButton(
            onPressed: onToggleFollow,
            icon: Icon(
              followPlayback ? Icons.my_location : Icons.location_disabled,
              size: 18,
            ),
            tooltip: followPlayback ? 'Following playback' : 'Not following',
          ),
          IconButton(
            onPressed: onShift,
            icon: const Icon(Icons.schedule, size: 18),
            tooltip: 'Shift all timings',
          ),
          IconButton(
            onPressed: document.isDirty ? onSave : null,
            icon: const Icon(Icons.save_outlined, size: 18),
            tooltip: 'Save',
          ),
          IconButton(
            // Always enabled: exporting a clean transcription to a chosen
            // folder is the common case, and it is not an unsaved-changes
            // action.
            onPressed: onSaveAs,
            icon: const Icon(Icons.save_as_outlined, size: 18),
            tooltip: 'Save subtitles to…',
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Close editor',
          ),
        ],
      ),
    );
  }
}

class _CueRow extends StatelessWidget {
  const _CueRow({
    required this.cue,
    required this.index,
    required this.isActive,
    required this.isEditing,
    required this.isSelected,
    required this.textController,
    required this.onTap,
    required this.onEdit,
    required this.onCommit,
    required this.onDelete,
    required this.onMerge,
    required this.onNudge,
    required this.onNudgeEnd,
    required this.onRetimeToPlayhead,
    required this.onSplit,
  });

  final SubtitleCue cue;
  final int index;
  final bool isActive;
  final bool isEditing;

  /// Whether this row is the one under inspection; only the selected row
  /// shows timing controls, keeping the rest of the list scannable.
  final bool isSelected;

  final TextEditingController? textController;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onCommit;
  final VoidCallback onDelete;
  final VoidCallback? onMerge;
  final void Function(CueEdge edge, Duration delta) onNudge;
  final VoidCallback onNudgeEnd;
  final VoidCallback onRetimeToPlayhead;
  final VoidCallback onSplit;

  @override
  Widget build(BuildContext context) {
    final showControls = isSelected && !isEditing;

    return InkWell(
      onTap: isEditing ? null : onTap,
      onDoubleTap: isEditing ? null : onEdit,
      child: Container(
        height: showControls
            ? SubtitleEditor.expandedRowHeight
            : SubtitleEditor.rowHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.blue.withValues(alpha: 0.14) : null,
          border: Border(
            left: BorderSide(
              color: isActive ? Colors.blueAccent : Colors.transparent,
              width: 3,
            ),
            bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '${index + 1}',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
                const SizedBox(width: 8),
                Text(
                  '${formatSrtTimestamp(cue.start)} → '
                  '${formatSrtTimestamp(cue.end)}',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '${(cue.duration.inMilliseconds / 1000).toStringAsFixed(1)}s',
                  style: TextStyle(
                    // Flag cues too fast to read comfortably.
                    color: cue.duration < const Duration(milliseconds: 700)
                        ? Colors.orangeAccent
                        : Colors.white24,
                    fontSize: 10,
                  ),
                ),
                const Spacer(),
                if (!isEditing) ...[
                  if (onMerge != null)
                    _MiniButton(
                      icon: Icons.merge,
                      tooltip: 'Merge with next',
                      onPressed: onMerge!,
                    ),
                  _MiniButton(
                    icon: Icons.delete_outline,
                    tooltip: 'Delete',
                    onPressed: onDelete,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: isEditing
                  ? TextField(
                      controller: textController,
                      autofocus: true,
                      maxLines: null,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.all(6),
                      ),
                      onSubmitted: (_) => onCommit(),
                      onTapOutside: (_) => onCommit(),
                    )
                  : Text(
                      cue.text,
                      style: const TextStyle(fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            if (showControls)
              _TimingControls(
                onNudge: onNudge,
                onNudgeEnd: onNudgeEnd,
                onRetimeToPlayhead: onRetimeToPlayhead,
                onSplit: onSplit,
              ),
          ],
        ),
      ),
    );
  }
}

/// Per-cue timing adjustment strip, shown on the selected row.
///
/// Each edge gets its own pair of nudge buttons rather than a single
/// timeline drag: at 100ms granularity, discrete taps are far easier to
/// land than a pixel-accurate drag on a narrow panel.
class _TimingControls extends StatelessWidget {
  const _TimingControls({
    required this.onNudge,
    required this.onNudgeEnd,
    required this.onRetimeToPlayhead,
    required this.onSplit,
  });

  final void Function(CueEdge edge, Duration delta) onNudge;
  final VoidCallback onNudgeEnd;
  final VoidCallback onRetimeToPlayhead;
  final VoidCallback onSplit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          _EdgeNudger(
            label: 'In',
            onEarlier: () => onNudge(CueEdge.start, -_nudgeStep),
            onLater: () => onNudge(CueEdge.start, _nudgeStep),
            onEnd: onNudgeEnd,
          ),
          const SizedBox(width: 8),
          _EdgeNudger(
            label: 'Out',
            onEarlier: () => onNudge(CueEdge.end, -_nudgeStep),
            onLater: () => onNudge(CueEdge.end, _nudgeStep),
            onEnd: onNudgeEnd,
          ),
          const SizedBox(width: 8),
          _EdgeNudger(
            label: 'Both',
            onEarlier: () => onNudge(CueEdge.both, -_nudgeStep),
            onLater: () => onNudge(CueEdge.both, _nudgeStep),
            onEnd: onNudgeEnd,
          ),
          const Spacer(),
          _MiniButton(
            icon: Icons.my_location,
            tooltip: 'Move cue to playhead',
            onPressed: onRetimeToPlayhead,
          ),
          _MiniButton(
            icon: Icons.content_cut,
            tooltip: 'Split at playhead',
            onPressed: onSplit,
          ),
        ],
      ),
    );
  }
}

/// A labelled −/+ pair for one cue edge.
class _EdgeNudger extends StatelessWidget {
  const _EdgeNudger({
    required this.label,
    required this.onEarlier,
    required this.onLater,
    required this.onEnd,
  });

  final String label;
  final VoidCallback onEarlier;
  final VoidCallback onLater;

  /// Closes the undo-coalescing run once the user stops adjusting.
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
        const SizedBox(width: 2),
        _NudgeButton(icon: Icons.remove, onPressed: onEarlier, onEnd: onEnd),
        _NudgeButton(icon: Icons.add, onPressed: onLater, onEnd: onEnd),
      ],
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({
    required this.icon,
    required this.onPressed,
    required this.onEnd,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        onPressed();
        // Coalescing keeps a burst of taps in one undo entry; the run is
        // closed on pointer exit rather than per tap.
      },
      onTapCancel: onEnd,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 1),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Icon(icon, size: 13, color: Colors.white54),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(icon, size: 15, color: Colors.white38),
        ),
      ),
    );
  }
}
