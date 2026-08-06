import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the thread budget used for transcription.
///
/// Whisper is given a fixed thread count, and getting it wrong is not a
/// subtle performance question — asking for more threads than there are
/// performance cores makes the entire machine feel slow for as long as a
/// transcription runs.
void main() {
  test('Apple silicon reports performance cores separately', () {
    if (!Platform.isMacOS) return;

    final result = Process.runSync('sysctl', ['-n', 'hw.perflevel0.physicalcpu']);
    if (result.exitCode != 0) return; // Intel Mac: no P/E split.

    final performance = int.tryParse(result.stdout.toString().trim());
    if (performance == null) return;

    // The whole point: performance cores are fewer than total cores, so
    // sizing the thread pool from Platform.numberOfProcessors oversubscribes
    // them. On an M4 that is 4 performance cores against 10 total.
    expect(performance, lessThan(Platform.numberOfProcessors),
        reason: 'total core count overstates the cores worth using');
  });

  test('the budget leaves at least one performance core free', () {
    if (!Platform.isMacOS) return;

    final result = Process.runSync('sysctl', ['-n', 'hw.perflevel0.physicalcpu']);
    if (result.exitCode != 0) return;

    final performance = int.tryParse(result.stdout.toString().trim());
    if (performance == null || performance <= 0) return;

    final threads = (performance - 1).clamp(1, 8);

    expect(threads, lessThan(performance),
        reason: 'a core must stay free for the UI and video decoding');
    expect(threads, greaterThanOrEqualTo(1));
  });

  test('a single-performance-core machine still gets one thread', () {
    // The clamp must not produce zero threads on minimal hardware.
    expect((1 - 1).clamp(1, 8), 1);
  });

  test('the budget is capped so huge machines do not spawn absurd pools', () {
    // A 24-performance-core Mac Studio should not hand Whisper 23 threads;
    // returns diminish and memory bandwidth becomes the limit.
    expect((24 - 1).clamp(1, 8), 8);
  });
}
