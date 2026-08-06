import 'package:flutter/services.dart';

/// Every keyboard action the player supports.
enum PlayerAction {
  playPause,
  seekBack,
  seekForward,
  seekBackLong,
  seekForwardLong,
  volumeUp,
  volumeDown,
  toggleMute,
  speedUp,
  speedDown,
  speedReset,
  toggleFullscreen,
  nextItem,
  previousItem,
  toggleSubtitles,
  togglePlaylist,
  toggleEditor,
  openFile,
  nudgeSubtitleEarlier,
  nudgeSubtitleLater,
  frameBack,
  frameForward,
}

/// A key plus its modifiers, used as a lookup key for bindings.
class KeyBinding {
  const KeyBinding(
    this.key, {
    this.shift = false,
    this.control = false,
    this.alt = false,
    this.meta = false,
  });

  final LogicalKeyboardKey key;
  final bool shift;
  final bool control;
  final bool alt;
  final bool meta;

  /// Builds a binding from a live key event's modifier state.
  factory KeyBinding.fromEvent(KeyEvent event) {
    final pressed = HardwareKeyboard.instance;
    return KeyBinding(
      event.logicalKey,
      shift: pressed.isShiftPressed,
      control: pressed.isControlPressed,
      alt: pressed.isAltPressed,
      meta: pressed.isMetaPressed,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KeyBinding &&
      other.key == key &&
      other.shift == shift &&
      other.control == control &&
      other.alt == alt &&
      other.meta == meta;

  @override
  int get hashCode => Object.hash(key, shift, control, alt, meta);

  /// Human-readable form for help text, e.g. `⌘F` or `Shift+←`.
  String describe({required bool isMacOS}) {
    final parts = <String>[];

    // macOS convention orders modifiers ⌃⌥⇧⌘ and uses symbols.
    if (isMacOS) {
      if (control) parts.add('⌃');
      if (alt) parts.add('⌥');
      if (shift) parts.add('⇧');
      if (meta) parts.add('⌘');
      return '${parts.join()}${_keyLabel()}';
    }

    if (control) parts.add('Ctrl');
    if (alt) parts.add('Alt');
    if (shift) parts.add('Shift');
    if (meta) parts.add('Meta');
    parts.add(_keyLabel());
    return parts.join('+');
  }

  String _keyLabel() {
    // Not const: LogicalKeyboardKey overrides ==, and Dart forbids such
    // types as const map keys.
    final named = {
      LogicalKeyboardKey.space: 'Space',
      LogicalKeyboardKey.arrowLeft: '←',
      LogicalKeyboardKey.arrowRight: '→',
      LogicalKeyboardKey.arrowUp: '↑',
      LogicalKeyboardKey.arrowDown: '↓',
      LogicalKeyboardKey.escape: 'Esc',
      LogicalKeyboardKey.comma: ',',
      LogicalKeyboardKey.period: '.',
      LogicalKeyboardKey.bracketLeft: '[',
      LogicalKeyboardKey.bracketRight: ']',
    };

    return named[key] ?? key.keyLabel.toUpperCase();
  }
}

/// The default key map.
///
/// Modelled on VLC and mpv conventions, since anyone reaching for these
/// shortcuts already has that muscle memory: space to pause, arrows to
/// seek, `[`/`]` for speed, `,`/`.` to step frames.
class PlayerShortcuts {
  const PlayerShortcuts();

  /// Not const for the same reason as [KeyBinding._keyLabel]'s table:
  /// [LogicalKeyboardKey] has a custom `==`, so it cannot key a const map.
  static final Map<KeyBinding, PlayerAction> defaults = {
    // Playback
    KeyBinding(LogicalKeyboardKey.space): PlayerAction.playPause,
    KeyBinding(LogicalKeyboardKey.keyK): PlayerAction.playPause,

    // Seeking. Plain arrows are short hops; Shift makes them long.
    KeyBinding(LogicalKeyboardKey.arrowLeft): PlayerAction.seekBack,
    KeyBinding(LogicalKeyboardKey.arrowRight): PlayerAction.seekForward,
    KeyBinding(LogicalKeyboardKey.arrowLeft, shift: true):
        PlayerAction.seekBackLong,
    KeyBinding(LogicalKeyboardKey.arrowRight, shift: true):
        PlayerAction.seekForwardLong,
    KeyBinding(LogicalKeyboardKey.keyJ): PlayerAction.seekBackLong,
    KeyBinding(LogicalKeyboardKey.keyL): PlayerAction.seekForwardLong,

    // Frame stepping, for placing a subtitle precisely.
    KeyBinding(LogicalKeyboardKey.comma): PlayerAction.frameBack,
    KeyBinding(LogicalKeyboardKey.period): PlayerAction.frameForward,

    // Volume
    KeyBinding(LogicalKeyboardKey.arrowUp): PlayerAction.volumeUp,
    KeyBinding(LogicalKeyboardKey.arrowDown): PlayerAction.volumeDown,
    KeyBinding(LogicalKeyboardKey.keyM): PlayerAction.toggleMute,

    // Speed
    KeyBinding(LogicalKeyboardKey.bracketRight): PlayerAction.speedUp,
    KeyBinding(LogicalKeyboardKey.bracketLeft): PlayerAction.speedDown,
    KeyBinding(LogicalKeyboardKey.backspace): PlayerAction.speedReset,

    // View
    KeyBinding(LogicalKeyboardKey.keyF): PlayerAction.toggleFullscreen,
    KeyBinding(LogicalKeyboardKey.keyV): PlayerAction.toggleSubtitles,
    KeyBinding(LogicalKeyboardKey.keyP): PlayerAction.togglePlaylist,
    KeyBinding(LogicalKeyboardKey.keyE): PlayerAction.toggleEditor,

    // Playlist navigation
    KeyBinding(LogicalKeyboardKey.keyN): PlayerAction.nextItem,
    KeyBinding(LogicalKeyboardKey.keyB): PlayerAction.previousItem,

    // Subtitle sync, matching mpv's g/h pairing.
    KeyBinding(LogicalKeyboardKey.keyG): PlayerAction.nudgeSubtitleEarlier,
    KeyBinding(LogicalKeyboardKey.keyH): PlayerAction.nudgeSubtitleLater,

    // File
    KeyBinding(LogicalKeyboardKey.keyO, meta: true): PlayerAction.openFile,
    KeyBinding(LogicalKeyboardKey.keyO, control: true): PlayerAction.openFile,
  };

  /// Resolves [event] to an action, or null if unbound.
  PlayerAction? resolve(KeyEvent event) =>
      defaults[KeyBinding.fromEvent(event)];

  /// Bindings grouped for a help sheet, in display order.
  static const Map<String, List<(PlayerAction, String)>> helpGroups = {
    'Playback': [
      (PlayerAction.playPause, 'Play / pause'),
      (PlayerAction.seekBack, 'Back 5 seconds'),
      (PlayerAction.seekForward, 'Forward 5 seconds'),
      (PlayerAction.seekBackLong, 'Back 30 seconds'),
      (PlayerAction.seekForwardLong, 'Forward 30 seconds'),
      (PlayerAction.frameBack, 'Previous frame'),
      (PlayerAction.frameForward, 'Next frame'),
    ],
    'Audio': [
      (PlayerAction.volumeUp, 'Volume up'),
      (PlayerAction.volumeDown, 'Volume down'),
      (PlayerAction.toggleMute, 'Mute'),
    ],
    'Speed': [
      (PlayerAction.speedUp, 'Faster'),
      (PlayerAction.speedDown, 'Slower'),
      (PlayerAction.speedReset, 'Normal speed'),
    ],
    'Subtitles': [
      (PlayerAction.toggleSubtitles, 'Show / hide subtitles'),
      (PlayerAction.toggleEditor, 'Subtitle editor'),
      (PlayerAction.nudgeSubtitleEarlier, 'Subtitles 100ms earlier'),
      (PlayerAction.nudgeSubtitleLater, 'Subtitles 100ms later'),
    ],
    'Library': [
      (PlayerAction.openFile, 'Open file'),
      (PlayerAction.togglePlaylist, 'Playlist'),
      (PlayerAction.nextItem, 'Next item'),
      (PlayerAction.previousItem, 'Previous item'),
      (PlayerAction.toggleFullscreen, 'Fullscreen'),
    ],
  };

  /// The first binding mapped to [action], for showing in help.
  static KeyBinding? bindingFor(PlayerAction action) {
    for (final entry in defaults.entries) {
      if (entry.value == action) return entry.key;
    }
    return null;
  }
}

/// Step sizes for keyboard-driven adjustments.
class ShortcutSteps {
  const ShortcutSteps._();

  static const Duration shortSeek = Duration(seconds: 5);
  static const Duration longSeek = Duration(seconds: 30);

  /// One frame at 25fps — close enough for stepping on any common rate.
  static const Duration frame = Duration(milliseconds: 40);

  static const double volume = 5.0;
  static const Duration subtitleNudge = Duration(milliseconds: 100);
}
