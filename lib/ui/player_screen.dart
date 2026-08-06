import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../core/player/player_controller.dart';
import '../core/player/playlist.dart';
import '../core/player/shortcuts.dart';
import '../core/subtitles/subtitle_document.dart';
import '../core/transcription/transcription_service.dart';
import 'caption_sheet.dart';
import 'playlist_panel.dart';
import 'shortcuts_help.dart';
import 'subtitle_editor.dart';
import 'transcription_banner.dart';

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  final _controller = PlayerController();
  final _transcription = TranscriptionService();
  final _playlist = Playlist();

  TranscriptionState _jobState = const TranscriptionState();
  SubtitleDocument? _document;

  /// Last partial subtitle payload sent to the player, so an unchanged
  /// chunk does not cause a needless track reload mid-playback.
  String? _lastPartialSrt;

  /// Newest partial payload waiting for a safe moment to be applied.
  String? _pendingPartialSrt;
  Timer? _partialApplyTimer;

  Duration _position = Duration.zero;

  bool _showPlaylist = false;
  bool _showEditor = false;

  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();

    _subs.add(_transcription.states.listen(_onTranscriptionState));
    _subs.add(_controller.player.stream.position.listen((pos) {
      // Only rebuild while the editor is visible; otherwise this fires
      // several times a second for no visible benefit.
      if (_showEditor && mounted) setState(() => _position = pos);
    }));
    _subs.add(_controller.player.stream.completed.listen((done) {
      if (done) _onPlaybackCompleted();
    }));

    _playlist.addListener(_onPlaylistChanged);
  }

  @override
  void dispose() {
    _partialApplyTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _playlist.removeListener(_onPlaylistChanged);
    _transcription.dispose();
    _controller.dispose();
    _document?.dispose();
    super.dispose();
  }

  void _onPlaylistChanged() {
    if (mounted) setState(() {});
  }

  void _onTranscriptionState(TranscriptionState state) {
    if (!mounted) return;

    // Push subtitles onto the video as each chunk lands, so you can start
    // watching a long video immediately instead of waiting for the whole
    // transcription. Chunks run in order, so what arrives first covers the
    // beginning — the part you are watching.
    final partial = state.partialSrt;
    if (partial != null && partial != _lastPartialSrt) {
      _lastPartialSrt = partial;
      _schedulePartialSubtitles(partial);
    }

    setState(() => _jobState = state);

    if (state.stage == TranscriptionStage.complete &&
        state.subtitlePath != null) {
      _controller.setSubtitleFile(state.subtitlePath!);
      _loadDocument(state.subtitlePath!);
    }
  }

  /// Applies newly transcribed subtitles without interrupting the one on
  /// screen.
  ///
  /// Attaching a subtitle track makes libmpv re-parse it, which clears the
  /// cue currently displayed. Doing that every time a chunk lands — roughly
  /// every two seconds — makes captions visibly blink out and back.
  ///
  /// Two things avoid it. Updates are only applied when playback is in a
  /// gap between cues, so nothing is on screen to lose; and they are rate
  /// limited, because the viewer is watching the beginning of the video
  /// while transcription races ahead, so freshly transcribed cues are
  /// minutes away from being needed.
  void _schedulePartialSubtitles(String srt) {
    _pendingPartialSrt = srt;

    // Already waiting to apply one — the newest payload supersedes it.
    if (_partialApplyTimer?.isActive ?? false) return;

    _partialApplyTimer = Timer.periodic(
      const Duration(seconds: 3),
      (timer) {
        final pending = _pendingPartialSrt;
        if (pending == null) {
          timer.cancel();
          return;
        }

        // Wait for a gap between cues so nothing visible is interrupted.
        if (_isCueOnScreen()) return;

        timer.cancel();
        _pendingPartialSrt = null;
        _controller.setSubtitleData(pending, title: 'Generating…');
      },
    );
  }

  /// Whether a subtitle is being displayed at the current playhead.
  bool _isCueOnScreen() {
    final doc = _document;
    if (doc != null && doc.length > 0) {
      return doc.indexAt(_controller.player.state.position) >= 0;
    }
    // No parsed document yet: fall back to what the player is rendering.
    return _controller.player.state.subtitle
        .any((line) => line.trim().isNotEmpty);
  }

  Future<void> _onPlaybackCompleted() async {
    final next = _playlist.onCompleted();
    if (next == null) return;

    // Repeat-one returns the same path; restart rather than reopen so
    // playback resumes instantly.
    if (next == _controller.currentPath) {
      await _controller.seek(Duration.zero);
      await _controller.player.play();
      return;
    }

    await _openPath(next);
  }

  Future<void> _loadDocument(String subtitlePath) async {
    try {
      final doc = await SubtitleDocument.load(subtitlePath);
      if (!mounted) return;

      _document?.dispose();
      setState(() => _document = doc);
    } catch (_) {
      // A subtitle file we cannot parse simply leaves the editor empty;
      // playback is unaffected.
    }
  }

  Future<void> _openPath(String path) async {
    await _controller.open(path);
    if (!mounted) return;

    setState(() => _document = null);

    // Pick up any sidecar the player attached, so the editor matches
    // what is on screen.
    final sidecar = _controller.findSidecarSubtitle(path);
    if (sidecar != null) await _loadDocument(sidecar);

    if (mounted) setState(() {});
  }

  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: PlayerController.videoExtensions,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    final paths = result.files
        .map((f) => f.path)
        .whereType<String>()
        .toList();
    if (paths.isEmpty) return;

    final wasEmpty = _playlist.isEmpty;
    _playlist.addAll(paths);

    // Start playing immediately when this is the first thing queued.
    if (wasEmpty && !_playlist.isEmpty) {
      final first = _playlist.jumpTo(0);
      if (first != null) await _openPath(first);
    }
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;

    final wasEmpty = _playlist.isEmpty;
    final added = await _playlist.addDirectory(dir);

    if (!mounted) return;

    if (added == 0) {
      _showMessage('No supported video files in that folder');
      return;
    }

    if (wasEmpty) {
      final first = _playlist.jumpTo(0);
      if (first != null) await _openPath(first);
    }
  }

  Future<void> _pickSubtitle() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'vtt', 'ass', 'ssa'],
    );

    final path = result?.files.single.path;
    if (path == null) return;

    await _controller.setSubtitleFile(path);
    await _loadDocument(path);

    if (mounted) _showMessage('Loaded ${p.basename(path)}');
  }

  Future<void> _playFromPlaylist(int index) async {
    final path = _playlist.jumpTo(index);
    if (path != null) await _openPath(path);
  }

  Future<void> _openCaptionSheet() async {
    final videoPath = _controller.currentPath;
    if (videoPath == null) return;

    final options = await showModalBottomSheet<CaptionOptions>(
      context: context,
      isScrollControlled: true,
      builder: (_) => CaptionSheet(
        videoPath: videoPath,
        alreadyHasSubtitles: _controller.hasSubtitles,
      ),
    );

    if (options == null) return;

    // Fresh job: forget the previous run's partial payload so its first
    // update is not mistaken for a repeat, and drop anything still queued.
    _lastPartialSrt = null;
    _pendingPartialSrt = null;
    _partialApplyTimer?.cancel();

    unawaited(_transcription.generate(
      videoPath: videoPath,
      model: options.model,
      language: options.language,
      translateToEnglish: options.translateToEnglish,
    ));
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Routes a key press to a player action.
  ///
  /// Returns [KeyEventResult.ignored] whenever a text field holds focus, so
  /// typing a subtitle line never triggers playback shortcuts — otherwise
  /// every space in the text would pause the video.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final focused = FocusManager.instance.primaryFocus;
    if (focused?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }
    // A focused text field parents an EditableText; check ancestors too.
    if (focused != null && _isTextFieldFocused(focused)) {
      return KeyEventResult.ignored;
    }

    final action = const PlayerShortcuts().resolve(event);
    if (action == null) return KeyEventResult.ignored;

    _runAction(action);
    return KeyEventResult.handled;
  }

  bool _isTextFieldFocused(FocusNode node) {
    var found = false;
    node.context?.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  Future<void> _runAction(PlayerAction action) async {
    final player = _controller.player;

    switch (action) {
      case PlayerAction.playPause:
        await _controller.playOrPause();

      case PlayerAction.seekBack:
        await _controller.seekBy(-ShortcutSteps.shortSeek);
      case PlayerAction.seekForward:
        await _controller.seekBy(ShortcutSteps.shortSeek);
      case PlayerAction.seekBackLong:
        await _controller.seekBy(-ShortcutSteps.longSeek);
      case PlayerAction.seekForwardLong:
        await _controller.seekBy(ShortcutSteps.longSeek);

      case PlayerAction.frameBack:
        await _controller.seekBy(-ShortcutSteps.frame);
      case PlayerAction.frameForward:
        await _controller.seekBy(ShortcutSteps.frame);

      case PlayerAction.volumeUp:
        await _controller
            .setVolume((player.state.volume + ShortcutSteps.volume).clamp(0, 100));
      case PlayerAction.volumeDown:
        await _controller
            .setVolume((player.state.volume - ShortcutSteps.volume).clamp(0, 100));
      case PlayerAction.toggleMute:
        await _controller.toggleMute();

      case PlayerAction.speedUp:
        await _controller.stepRate(1);
      case PlayerAction.speedDown:
        await _controller.stepRate(-1);
      case PlayerAction.speedReset:
        await _controller.setRate(1.0);

      case PlayerAction.toggleSubtitles:
        await _controller.toggleSubtitles();
        if (mounted) setState(() {});

      case PlayerAction.toggleFullscreen:
        // media_kit owns the fullscreen window state on desktop.
        await _controller.toggleFullscreen(context);

      case PlayerAction.nextItem:
        final next = _playlist.next();
        if (next != null) await _openPath(next);
      case PlayerAction.previousItem:
        final prev = _playlist.previous();
        if (prev != null) await _openPath(prev);

      case PlayerAction.togglePlaylist:
        setState(() => _showPlaylist = !_showPlaylist);
      case PlayerAction.toggleEditor:
        if (_document != null) setState(() => _showEditor = !_showEditor);

      case PlayerAction.openFile:
        await _pickVideo();

      case PlayerAction.nudgeSubtitleEarlier:
        _shiftSubtitles(-ShortcutSteps.subtitleNudge);
      case PlayerAction.nudgeSubtitleLater:
        _shiftSubtitles(ShortcutSteps.subtitleNudge);
    }
  }

  /// Exports the current subtitles to a location the user picks.
  ///
  /// Offered from the main toolbar because the usual flow is generate then
  /// export — the sandbox means generated files land in app storage rather
  /// than beside the video, so there has to be a way to get them out.
  Future<void> _exportSubtitles() async {
    final doc = _document;
    if (doc == null || doc.length == 0) return;

    final videoPath = _controller.currentPath;
    final suggested = videoPath != null
        ? '${p.basenameWithoutExtension(videoPath)}.srt'
        : 'subtitles.srt';

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Save subtitles',
      fileName: suggested,
      type: FileType.custom,
      allowedExtensions: const ['srt'],
      bytes: utf8.encode(doc.toSrt()),
    );

    if (path == null || !mounted) return;

    doc.markSavedAs(path);
    _showMessage('Saved to ${p.basename(path)}');
  }

  /// Re-attaches the edited subtitles so changes show on the video at once.
  ///
  /// Passed as data rather than reloading from disk, so unsaved edits are
  /// visible without forcing a save first.
  void _pushSubtitlesToPlayer() {
    final doc = _document;
    if (doc == null || doc.length == 0) return;
    _controller.setSubtitleData(doc.toSrt(), title: 'Edited');
  }

  /// Shifts the loaded subtitle document and re-attaches it to the player,
  /// so a sync correction is visible immediately rather than on next load.
  void _shiftSubtitles(Duration offset) {
    final doc = _document;
    if (doc == null || doc.length == 0) {
      _showMessage('No editable subtitles loaded');
      return;
    }

    doc.shiftAll(offset);
    _controller.setSubtitleData(doc.toSrt(), title: 'Edited');

    final ms = offset.inMilliseconds;
    _showMessage('Subtitles ${ms > 0 ? '+' : ''}${ms}ms');
  }

  @override
  Widget build(BuildContext context) {
    final hasVideo = _controller.currentPath != null;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          hasVideo ? p.basename(_controller.currentPath!) : 'Lumen',
          style: const TextStyle(fontSize: 16),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            onPressed: _pickVideo,
            icon: const Icon(Icons.folder_open),
            tooltip: 'Open video',
          ),
          if (hasVideo)
            IconButton(
              onPressed: _pickSubtitle,
              icon: const Icon(Icons.subtitles_outlined),
              tooltip: 'Load subtitle file',
            ),
          if (hasVideo)
            IconButton(
              onPressed: _jobState.isRunning ? null : _openCaptionSheet,
              icon: const Icon(Icons.auto_awesome),
              tooltip: 'Generate captions',
            ),
          if (_document != null)
            IconButton(
              onPressed: _exportSubtitles,
              icon: const Icon(Icons.save_alt),
              tooltip: 'Save subtitles to…',
            ),
          if (_document != null)
            IconButton(
              onPressed: () => setState(() => _showEditor = !_showEditor),
              icon: const Icon(Icons.edit_note),
              color: _showEditor ? Colors.blueAccent : null,
              tooltip: 'Edit subtitles',
            ),
          IconButton(
            onPressed: () => setState(() => _showPlaylist = !_showPlaylist),
            icon: const Icon(Icons.queue_music),
            color: _showPlaylist ? Colors.blueAccent : null,
            tooltip: 'Playlist',
          ),
          IconButton(
            onPressed: () => ShortcutsHelp.show(context),
            icon: const Icon(Icons.keyboard_outlined),
            tooltip: 'Keyboard shortcuts',
          ),
        ],
      ),
      body: Row(
        children: [
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: hasVideo
                      ? Video(
                          controller: _controller.videoController,
                          controls: AdaptiveVideoControls,
                        )
                      : _EmptyState(onOpen: _pickVideo),
                ),
                if (_jobState.stage != TranscriptionStage.idle)
                  TranscriptionBanner(
                    state: _jobState,
                    onCancel: _transcription.cancel,
                    onDismiss: () =>
                        setState(() => _jobState = const TranscriptionState()),
                  ),
              ],
            ),
          ),
          if (_showEditor && _document != null)
            SubtitleEditor(
              document: _document!,
              position: _position,
              onSeek: _controller.seek,
              onClose: () => setState(() => _showEditor = false),
              onSubtitlesChanged: _pushSubtitlesToPlayer,
            ),
          if (_showPlaylist)
            PlaylistPanel(
              playlist: _playlist,
              onPlay: _playFromPlaylist,
              onAddFiles: _pickVideo,
              onAddFolder: _pickFolder,
              onClose: () => setState(() => _showPlaylist = false),
            ),
        ],
      ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.movie_outlined, size: 64, color: Colors.white24),
          const SizedBox(height: 16),
          const Text(
            'Open a video to get started',
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 8),
          const Text(
            'Subtitles can be generated offline for any file',
            style: TextStyle(color: Colors.white38, fontSize: 13),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onOpen,
            icon: const Icon(Icons.folder_open),
            label: const Text('Open video'),
          ),
        ],
      ),
    );
  }
}
