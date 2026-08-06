import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../core/player/shortcuts.dart';

/// A reference sheet for the keyboard shortcuts.
///
/// Generated from [PlayerShortcuts.helpGroups] rather than hand-written, so
/// the list cannot drift out of sync with the actual bindings.
class ShortcutsHelp extends StatelessWidget {
  const ShortcutsHelp({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const ShortcutsHelp(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMacOS = Platform.isMacOS;

    return AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in PlayerShortcuts.helpGroups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 6),
                  child: Text(
                    entry.key,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Colors.blueAccent,
                        ),
                  ),
                ),
                for (final (action, label) in entry.value)
                  _Row(
                    label: label,
                    keys: PlayerShortcuts.bindingFor(action)
                            ?.describe(isMacOS: isMacOS) ??
                        '',
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.keys});

  final String label;
  final String keys;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(fontSize: 13)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: Text(
              keys,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
