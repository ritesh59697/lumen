import 'subtitle_model.dart';

/// Parses SRT and WebVTT files into [SubtitleCue]s.
///
/// Written to be forgiving. Subtitle files in the wild are frequently
/// malformed — downloaded from scrapers, hand-edited, or converted between
/// tools — and a parser that throws on the first bad cue is useless for
/// real media. Unparseable blocks are skipped; whatever is valid is kept.
class SubtitleParser {
  const SubtitleParser();

  /// Matches an SRT or VTT timing line, tolerating either separator.
  ///
  /// SRT uses `00:00:01,500`, VTT uses `00:00:01.500`, and VTT permits a
  /// two-field `MM:SS.mmm` form. Trailing VTT cue settings (`align:start`)
  /// are allowed and ignored.
  static final _timing = RegExp(
    r'(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})'
    r'\s*-->\s*'
    r'(?:(\d+):)?(\d{1,2}):(\d{1,2})[,.](\d{1,3})',
  );

  /// Parses [content] into cues, in file order.
  ///
  /// Handles both SRT and VTT, since they differ only in header, separator
  /// and optional cue settings — all of which are tolerated here.
  List<SubtitleCue> parse(String content) {
    // Normalise Windows and classic-Mac line endings, and strip a BOM.
    final text = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceFirst('﻿', '');

    final cues = <SubtitleCue>[];

    // Blocks are separated by blank lines. Splitting this way keeps the
    // parser robust to missing or misnumbered index lines, which are the
    // most common defect in scraped SRT files.
    for (final block in text.split(RegExp(r'\n\s*\n'))) {
      final cue = _parseBlock(block);
      if (cue != null) cues.add(cue);
    }

    return cues;
  }

  SubtitleCue? _parseBlock(String block) {
    final lines = block.split('\n');

    // Find the timing line; anything before it is an index or VTT
    // identifier, anything after is the subtitle text.
    var timingIndex = -1;
    RegExpMatch? match;

    for (var i = 0; i < lines.length; i++) {
      final m = _timing.firstMatch(lines[i]);
      if (m != null) {
        timingIndex = i;
        match = m;
        break;
      }
    }

    if (match == null) return null;

    final start = _durationFrom(match, 1);
    final end = _durationFrom(match, 5);

    final text = lines
        .sublist(timingIndex + 1)
        .join('\n')
        .trim();

    // A cue with no text is not worth keeping.
    if (text.isEmpty) return null;

    return SubtitleCue(start: start, end: end, text: text);
  }

  /// Builds a [Duration] from four capture groups starting at [offset]:
  /// hours (optional), minutes, seconds, fractional seconds.
  Duration _durationFrom(RegExpMatch m, int offset) {
    final hours = int.tryParse(m.group(offset) ?? '') ?? 0;
    final minutes = int.tryParse(m.group(offset + 1) ?? '') ?? 0;
    final seconds = int.tryParse(m.group(offset + 2) ?? '') ?? 0;

    // `,5` means 500ms, not 5ms — pad right, not left.
    final fraction = m.group(offset + 3) ?? '0';
    final millis = int.tryParse(fraction.padRight(3, '0')) ?? 0;

    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: millis,
    );
  }
}
