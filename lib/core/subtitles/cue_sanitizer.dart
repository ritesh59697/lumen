import 'subtitle_model.dart';

/// Cleans raw Whisper segments into cues that are actually watchable.
///
/// Whisper's raw output is not directly usable as subtitles. Four problems
/// show up on essentially every real video, and each is handled here:
///
///  1. Leading/trailing spaces on every segment (whisper.cpp emits them).
///  2. Non-speech annotations like `[BLANK_AUDIO]`, `(music)`, `*sighs*`,
///     which are noise on screen and appear during silence.
///  3. Zero-length or overlapping timings, which make players flicker
///     or drop cues entirely.
///  4. Cues too brief to read, or single cues holding a whole paragraph.
///
/// Fixing these at the boundary keeps every downstream consumer — the SRT
/// writer, the editor, the player — working with clean data.
class CueSanitizer {
  const CueSanitizer({
    this.minDuration = const Duration(milliseconds: 500),
    this.maxCharsPerLine = 42,
    this.maxLines = 2,
  });

  /// Shortest a cue may stay on screen. Anything briefer is extended,
  /// since a sub that flashes for 100ms is unreadable.
  final Duration minDuration;

  /// Line-wrap width. 42 characters is the broadcast-caption convention
  /// (BBC/Netflix guidelines land in the 37-42 range) and reads well
  /// on both a phone and a desktop.
  final int maxCharsPerLine;

  /// Maximum lines per cue, so subtitles never swallow the picture.
  final int maxLines;

  /// Matches non-speech annotations Whisper emits for music, silence and
  /// sound effects: `[BLANK_AUDIO]`, `(upbeat music)`, `*door slams*`.
  static final _annotationOnly = RegExp(
    r'^\s*[\[\(\*][^\]\)\*]*[\]\)\*]\s*$',
  );

  /// Converts raw (start, end, text) triples into display-ready cues.
  List<SubtitleCue> sanitize(List<SubtitleCue> raw) {
    final cleaned = <SubtitleCue>[];

    for (final cue in raw) {
      final text = _normalizeText(cue.text);
      if (text.isEmpty) continue;

      cleaned.add(cue.copyWith(text: _wrap(text)));
    }

    return _fixTimings(cleaned);
  }

  /// Trims whitespace and drops pure non-speech annotations.
  String _normalizeText(String input) {
    // Collapse newlines and runs of whitespace introduced by the model.
    final collapsed = input.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (collapsed.isEmpty) return '';
    if (_annotationOnly.hasMatch(collapsed)) return '';

    return collapsed;
  }

  /// Greedy word wrap to [maxCharsPerLine], capped at [maxLines].
  ///
  /// If the text exceeds the line budget it is kept on the last line rather
  /// than truncated — losing dialogue is worse than an over-long line.
  String _wrap(String text) {
    if (text.length <= maxCharsPerLine) return text;

    final words = text.split(' ');
    final lines = <String>[];
    var current = StringBuffer();

    for (final word in words) {
      final candidate = current.isEmpty ? word : '${current.toString()} $word';

      if (candidate.length <= maxCharsPerLine) {
        current = StringBuffer(candidate);
      } else {
        if (current.isNotEmpty) lines.add(current.toString());
        current = StringBuffer(word);

        // Out of line budget: dump the rest onto the final line.
        if (lines.length == maxLines - 1) {
          final remaining = words.sublist(words.indexOf(word) + 1);
          if (remaining.isNotEmpty) {
            current.write(' ${remaining.join(' ')}');
          }
          break;
        }
      }
    }

    if (current.isNotEmpty) lines.add(current.toString());
    return lines.join('\n');
  }

  /// Enforces monotonic, non-overlapping, readable timings.
  ///
  /// Runs after text cleanup so that cues dropped as annotations don't
  /// leave gaps that push neighbouring cues around.
  List<SubtitleCue> _fixTimings(List<SubtitleCue> cues) {
    if (cues.isEmpty) return cues;

    final result = <SubtitleCue>[];

    for (var i = 0; i < cues.length; i++) {
      var start = cues[i].start;
      var end = cues[i].end;

      // Never start before the previous cue ended.
      if (result.isNotEmpty) {
        final prevEnd = result.last.end;
        if (start < prevEnd) start = prevEnd;
      }

      // Guarantee a readable minimum, but don't run into the next cue.
      if (end - start < minDuration) {
        final desired = start + minDuration;
        final nextStart = i + 1 < cues.length ? cues[i + 1].start : null;
        end = (nextStart != null && desired > nextStart) ? nextStart : desired;
      }

      // A cue that still has no positive duration cannot be displayed.
      if (end <= start) continue;

      result.add(cues[i].copyWith(start: start, end: end));
    }

    return result;
  }
}
