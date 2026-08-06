import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/core/subtitles/cue_sanitizer.dart';
import 'package:lumen/core/subtitles/subtitle_model.dart';

/// End-to-end check of the segment -> cue -> SRT path using output shaped
/// like real whisper.cpp results (padded text, annotations, tight timings).
///
/// This is the part of the pipeline that runs identically on every platform,
/// so proving it here covers the logic that native builds only exercise
/// later.
void main() {
  test('raw whisper-style segments become a valid SRT file', () {
    // Mirrors real whisper.cpp output: leading spaces on every segment,
    // a [BLANK_AUDIO] marker during silence, and a zero-length segment.
    final raw = <SubtitleCue>[
      SubtitleCue(
        start: Duration.zero,
        end: const Duration(milliseconds: 2400),
        text: ' Good morning, everyone.',
      ),
      SubtitleCue(
        start: const Duration(milliseconds: 2400),
        end: const Duration(milliseconds: 4000),
        text: ' [BLANK_AUDIO]',
      ),
      SubtitleCue(
        start: const Duration(milliseconds: 4000),
        end: const Duration(milliseconds: 4000),
        text: ' Right.',
      ),
      SubtitleCue(
        start: const Duration(milliseconds: 4200),
        end: const Duration(milliseconds: 9000),
        text: '  Today we are going to talk about how offline speech '
            'recognition actually works in practice. ',
      ),
    ];

    final cues = const CueSanitizer().sanitize(raw);
    final srt = cuesToSrt(cues);

    // The silence marker must not reach the screen.
    expect(srt, isNot(contains('BLANK_AUDIO')));

    // Padding is gone.
    expect(srt, contains('Good morning, everyone.'));
    expect(srt, isNot(contains(' Good morning')));

    // Cues are numbered from 1 and strictly increasing.
    final indexLines = RegExp(r'^\d+$', multiLine: true)
        .allMatches(srt)
        .map((m) => int.parse(m.group(0)!))
        .toList();
    expect(indexLines, List.generate(cues.length, (i) => i + 1));

    // Every cue has a positive, non-overlapping span.
    for (var i = 0; i < cues.length; i++) {
      expect(cues[i].end, greaterThan(cues[i].start));
      if (i > 0) {
        expect(cues[i].start, greaterThanOrEqualTo(cues[i - 1].end));
      }
    }

    // Structure check: index, timing line, text, blank line.
    expect(
      RegExp(r'\d+\n\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3}\n')
          .allMatches(srt)
          .length,
      cues.length,
    );
  });

  test('a transcript of only music yields no cues', () {
    final raw = [
      SubtitleCue(
        start: Duration.zero,
        end: const Duration(seconds: 3),
        text: ' (gentle piano music)',
      ),
      SubtitleCue(
        start: const Duration(seconds: 3),
        end: const Duration(seconds: 6),
        text: ' [BLANK_AUDIO]',
      ),
    ];

    expect(const CueSanitizer().sanitize(raw), isEmpty);
  });
}
