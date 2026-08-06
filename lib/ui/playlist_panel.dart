import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/player/playlist.dart';

/// A side panel listing queued media, with reorder and playback controls.
class PlaylistPanel extends StatelessWidget {
  const PlaylistPanel({
    super.key,
    required this.playlist,
    required this.onPlay,
    required this.onAddFiles,
    required this.onAddFolder,
    required this.onClose,
  });

  final Playlist playlist;
  final void Function(int index) onPlay;
  final VoidCallback onAddFiles;
  final VoidCallback onAddFolder;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 320,
      color: const Color(0xFF141414),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                Text(
                  'Playlist',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(width: 6),
                Text(
                  '${playlist.length}',
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onAddFiles,
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: 'Add files',
                ),
                IconButton(
                  onPressed: onAddFolder,
                  icon: const Icon(Icons.folder_outlined, size: 18),
                  tooltip: 'Add folder',
                ),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Close playlist',
                ),
              ],
            ),
          ),
          _ModeBar(playlist: playlist),
          const Divider(height: 1),
          Expanded(
            child: playlist.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Add videos to build a queue',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: playlist.length,
                    // onReorderItem already accounts for the dragged item
                    // being removed, so the index needs no adjustment.
                    onReorderItem: playlist.move,
                    itemBuilder: (context, index) {
                      final path = playlist.paths[index];
                      final isCurrent = index == playlist.currentIndex;

                      return ListTile(
                        key: ValueKey('$path#$index'),
                        dense: true,
                        selected: isCurrent,
                        selectedTileColor: Colors.blue.withValues(alpha: 0.14),
                        leading: Icon(
                          isCurrent
                              ? Icons.play_arrow
                              : Icons.video_file_outlined,
                          size: 18,
                          color: isCurrent ? Colors.blueAccent : Colors.white38,
                        ),
                        title: Text(
                          p.basename(path),
                          style: const TextStyle(fontSize: 13),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          onPressed: () => playlist.removeAt(index),
                          icon: const Icon(Icons.close, size: 15),
                          color: Colors.white24,
                          tooltip: 'Remove',
                        ),
                        onTap: () => onPlay(index),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _ModeBar extends StatelessWidget {
  const _ModeBar({required this.playlist});

  final Playlist playlist;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            onPressed: () => playlist.shuffle = !playlist.shuffle,
            icon: const Icon(Icons.shuffle, size: 18),
            color: playlist.shuffle ? Colors.blueAccent : Colors.white38,
            tooltip: playlist.shuffle ? 'Shuffle on' : 'Shuffle off',
          ),
          IconButton(
            onPressed: () => playlist.repeat = _nextRepeat(playlist.repeat),
            icon: Icon(
              playlist.repeat == PlaylistRepeat.one
                  ? Icons.repeat_one
                  : Icons.repeat,
              size: 18,
            ),
            color: playlist.repeat == PlaylistRepeat.off
                ? Colors.white38
                : Colors.blueAccent,
            tooltip: switch (playlist.repeat) {
              PlaylistRepeat.off => 'Repeat off',
              PlaylistRepeat.all => 'Repeat all',
              PlaylistRepeat.one => 'Repeat one',
            },
          ),
          const Spacer(),
          if (playlist.length > 1)
            TextButton(
              onPressed: playlist.clear,
              style: TextButton.styleFrom(
                foregroundColor: Colors.white38,
                textStyle: const TextStyle(fontSize: 12),
              ),
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }

  PlaylistRepeat _nextRepeat(PlaylistRepeat current) => switch (current) {
        PlaylistRepeat.off => PlaylistRepeat.all,
        PlaylistRepeat.all => PlaylistRepeat.one,
        PlaylistRepeat.one => PlaylistRepeat.off,
      };
}
