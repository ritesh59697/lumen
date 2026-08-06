import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/media_kit_video.dart' as mkv;
import 'package:path/path.dart' as p;

/// Wraps media_kit's [Player] with the behaviour this app needs.
///
/// Kept deliberately thin: media_kit already exposes good streams and
/// controls, so this adds only what is missing — sidecar subtitle
/// discovery, a curated speed list, and safe subtitle attachment.
class PlayerController {
  PlayerController() {
    _player = Player(
      configuration: const PlayerConfiguration(
        // Shows the filename in OS media controls instead of "mpv".
        title: 'Lumen',
        // Large enough to seek smoothly in high-bitrate local files.
        bufferSize: 32 * 1024 * 1024,
      ),
    );

    _videoController = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        // libmpv picks the best available backend (VideoToolbox on macOS,
        // MediaCodec on Android). Leaving this on is what makes 4K playback
        // viable on modest hardware.
        enableHardwareAcceleration: true,
      ),
    );
  }

  late final Player _player;
  late final VideoController _videoController;

  Player get player => _player;
  VideoController get videoController => _videoController;

  /// Playback speeds offered in the UI, matching what viewers expect.
  static const List<double> speedOptions = [
    0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0,
  ];

  /// Subtitle file extensions recognised as sidecars.
  static const Set<String> subtitleExtensions = {'.srt', '.vtt', '.ass', '.ssa'};

  /// Media container extensions offered in the file picker.
  static const List<String> videoExtensions = [
    'mp4', 'mkv', 'avi', 'webm', 'mov', 'flv', 'wmv',
    'm4v', 'mpg', 'mpeg', 'ts', 'm2ts', '3gp', 'ogv',
  ];

  String? _currentPath;

  /// Path of the media file currently open, if any.
  String? get currentPath => _currentPath;

  /// Opens [path] and begins playback unless [autoPlay] is false.
  ///
  /// Any sidecar subtitle sitting next to the file is attached automatically,
  /// matching the behaviour people expect from desktop players.
  Future<void> open(String path, {bool autoPlay = true}) async {
    _currentPath = path;
    await _player.open(Media(path), play: autoPlay);

    final sidecar = findSidecarSubtitle(path);
    if (sidecar != null) {
      await setSubtitleFile(sidecar);
    }
  }

  /// Attaches an external subtitle file to the current media.
  ///
  /// The file is read and passed as data rather than by URI: libmpv's URI
  /// handling stumbles on paths containing spaces or non-ASCII characters,
  /// which are common in downloaded media.
  Future<void> setSubtitleFile(String subtitlePath) async {
    final file = File(subtitlePath);
    if (!await file.exists()) return;

    final content = await file.readAsString();
    await _player.setSubtitleTrack(
      SubtitleTrack.data(content, title: p.basename(subtitlePath)),
    );
  }

  /// Looks for a subtitle file matching [videoPath] in the same directory.
  ///
  /// Matches both `movie.srt` and language-tagged `movie.en.srt`. Returns
  /// the shortest match so a plain `.srt` wins over a tagged variant.
  /// Returns null when the directory cannot be listed.
  ///
  /// Under the macOS sandbox the user grants access to the *file* they
  /// picked, not its folder, so listing Desktop or Documents throws
  /// `PathAccessException`. Sidecar discovery is a convenience, so a denial
  /// must degrade quietly rather than take down playback.
  String? findSidecarSubtitle(String videoPath) {
    final dir = Directory(p.dirname(videoPath));

    final List<FileSystemEntity> entries;
    try {
      if (!dir.existsSync()) return null;
      entries = dir.listSync();
    } on FileSystemException {
      return null;
    }

    final base = p.basenameWithoutExtension(videoPath).toLowerCase();
    final matches = <String>[];

    for (final entity in entries) {
      if (entity is! File) continue;

      final ext = p.extension(entity.path).toLowerCase();
      if (!subtitleExtensions.contains(ext)) continue;

      final candidate = p.basenameWithoutExtension(entity.path).toLowerCase();
      // `movie` matches, and so does `movie.en`.
      if (candidate == base || candidate.startsWith('$base.')) {
        matches.add(entity.path);
      }
    }

    if (matches.isEmpty) return null;
    matches.sort((a, b) => a.length.compareTo(b.length));
    return matches.first;
  }

  /// Whether the open media already carries subtitles, embedded or sidecar.
  ///
  /// Drives whether "Generate Captions" is offered. libmpv always reports a
  /// synthetic "no subtitles" track, so that one is filtered out.
  bool get hasSubtitles {
    final tracks = _player.state.tracks.subtitle;
    return tracks.any((t) => t.id != 'no' && t.id != 'auto');
  }

  Future<void> playOrPause() => _player.playOrPause();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> setVolume(double volume) => _player.setVolume(volume);
  Future<void> setRate(double rate) => _player.setRate(rate);

  /// Seeks by [offset], clamped to the media bounds.
  Future<void> seekBy(Duration offset) async {
    final target = _player.state.position + offset;
    final duration = _player.state.duration;

    if (target < Duration.zero) return seek(Duration.zero);
    if (duration > Duration.zero && target > duration) return seek(duration);
    return seek(target);
  }

  /// Volume to restore when unmuting.
  double _volumeBeforeMute = 100;

  bool get isMuted => _player.state.volume == 0;

  /// Mutes, or restores the previous level.
  Future<void> toggleMute() async {
    if (isMuted) {
      // Guard against restoring to silence if muted from zero.
      await setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 100);
    } else {
      _volumeBeforeMute = _player.state.volume;
      await setVolume(0);
    }
  }

  /// Moves [direction] steps through [speedOptions] from the current rate.
  ///
  /// Stepping a fixed list keeps speeds on familiar values rather than
  /// drifting to arbitrary multipliers.
  Future<void> stepRate(int direction) async {
    final current = _player.state.rate;

    // Nearest listed speed, so an off-list rate still steps predictably.
    var nearest = 0;
    for (var i = 1; i < speedOptions.length; i++) {
      if ((speedOptions[i] - current).abs() <
          (speedOptions[nearest] - current).abs()) {
        nearest = i;
      }
    }

    final next = (nearest + direction).clamp(0, speedOptions.length - 1);
    await setRate(speedOptions[next]);
  }

  /// Attaches subtitles from an in-memory string.
  ///
  /// Used after an edit, so corrections appear without a disk round-trip.
  Future<void> setSubtitleData(String srt, {String title = 'Subtitles'}) {
    return _player.setSubtitleTrack(SubtitleTrack.data(srt, title: title));
  }

  /// Last subtitle track shown, so it can be restored after hiding.
  SubtitleTrack? _lastSubtitleTrack;

  bool get subtitlesVisible => _player.state.track.subtitle.id != 'no';

  /// Hides subtitles, or restores the last shown track.
  Future<void> toggleSubtitles() async {
    if (subtitlesVisible) {
      _lastSubtitleTrack = _player.state.track.subtitle;
      await _player.setSubtitleTrack(SubtitleTrack.no());
    } else if (_lastSubtitleTrack != null) {
      await _player.setSubtitleTrack(_lastSubtitleTrack!);
    } else {
      await _player.setSubtitleTrack(SubtitleTrack.auto());
    }
  }

  /// Enters or leaves fullscreen.
  ///
  /// Delegates to media_kit_video, which owns the platform window state and
  /// restores the correct layout on exit. Aliased on import because the
  /// package's top-level function shares this name.
  Future<void> toggleFullscreen(BuildContext context) =>
      mkv.toggleFullscreen(context);

  Future<void> dispose() async {
    await _player.dispose();
  }
}
