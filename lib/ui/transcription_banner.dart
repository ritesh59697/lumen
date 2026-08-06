import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/transcription/transcription_service.dart';

/// A slim status strip under the video showing transcription progress.
///
/// Deliberately not a modal dialog: transcription can take minutes, and
/// blocking playback during it would defeat the purpose of running the
/// job in the background.
class TranscriptionBanner extends StatelessWidget {
  const TranscriptionBanner({
    super.key,
    required this.state,
    required this.onCancel,
    required this.onDismiss,
  });

  final TranscriptionState state;
  final VoidCallback onCancel;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _appearance();

    return Material(
      color: const Color(0xFF1A1A1A),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.message ?? '',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                        ),
                      ),
                      if (state.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            state.error!,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      if (state.stage == TranscriptionStage.complete &&
                          state.subtitlePath != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            'Saved as ${p.basename(state.subtitlePath!)}',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (state.isRunning)
                  TextButton(
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  )
                else
                  IconButton(
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close, size: 18),
                    color: Colors.white54,
                    tooltip: 'Dismiss',
                  ),
              ],
            ),
            if (state.isRunning) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    // A null value renders an indeterminate bar, which is the
                    // honest signal for stages that cannot be measured.
                    child: LinearProgressIndicator(
                      value: state.progress,
                      minHeight: 3,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                  if (state.progress != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      '${(state.progress! * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        // Stops the percentage jittering as digits change.
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  (IconData, Color) _appearance() {
    switch (state.stage) {
      case TranscriptionStage.complete:
        return (Icons.check_circle, Colors.greenAccent);
      case TranscriptionStage.failed:
        return (Icons.error_outline, Colors.redAccent);
      case TranscriptionStage.cancelled:
        return (Icons.cancel_outlined, Colors.white54);
      default:
        return (Icons.auto_awesome, Colors.blueAccent);
    }
  }
}
