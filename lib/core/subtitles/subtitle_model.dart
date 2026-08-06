/// A single subtitle cue: a span of time and the text shown during it.
///
/// This is the app's own representation, deliberately independent of
/// whisper_ggml_plus's segment type. Keeping our own model means the
/// transcription engine can be swapped without touching the editor,
/// the SRT writer, or the player wiring.
class SubtitleCue {
  const SubtitleCue({
    required this.start,
    required this.end,
    required this.text,
  });

  final Duration start;
  final Duration end;
  final String text;

  Duration get duration => end - start;

  SubtitleCue copyWith({Duration? start, Duration? end, String? text}) {
    return SubtitleCue(
      start: start ?? this.start,
      end: end ?? this.end,
      text: text ?? this.text,
    );
  }

  @override
  String toString() => 'SubtitleCue($start -> $end: $text)';
}

/// Formats a [Duration] as an SRT timestamp: `HH:MM:SS,mmm`.
///
/// SRT uses a comma before milliseconds; WebVTT uses a period. Using the
/// wrong separator makes players silently reject the file, so the two
/// formats are kept as separate functions rather than a flag.
String formatSrtTimestamp(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);
  final millis = d.inMilliseconds.remainder(1000);

  final h = hours.toString().padLeft(2, '0');
  final m = minutes.toString().padLeft(2, '0');
  final s = seconds.toString().padLeft(2, '0');
  final ms = millis.toString().padLeft(3, '0');

  return '$h:$m:$s,$ms';
}

/// Formats a [Duration] as a WebVTT timestamp: `HH:MM:SS.mmm`.
String formatVttTimestamp(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60);
  final seconds = d.inSeconds.remainder(60);
  final millis = d.inMilliseconds.remainder(1000);

  final h = hours.toString().padLeft(2, '0');
  final m = minutes.toString().padLeft(2, '0');
  final s = seconds.toString().padLeft(2, '0');
  final ms = millis.toString().padLeft(3, '0');

  return '$h:$m:$s.$ms';
}

/// Serializes [cues] to SRT format.
///
/// Cues are renumbered from 1 in the order given, so an edited or
/// reordered list always produces a valid file.
String cuesToSrt(List<SubtitleCue> cues) {
  final buffer = StringBuffer();

  for (var i = 0; i < cues.length; i++) {
    final cue = cues[i];
    buffer
      ..writeln(i + 1)
      ..writeln(
        '${formatSrtTimestamp(cue.start)} --> ${formatSrtTimestamp(cue.end)}',
      )
      ..writeln(cue.text)
      ..writeln();
  }

  return buffer.toString();
}

/// Serializes [cues] to WebVTT format.
String cuesToVtt(List<SubtitleCue> cues) {
  final buffer = StringBuffer()..writeln('WEBVTT')..writeln();

  for (final cue in cues) {
    buffer
      ..writeln(
        '${formatVttTimestamp(cue.start)} --> ${formatVttTimestamp(cue.end)}',
      )
      ..writeln(cue.text)
      ..writeln();
  }

  return buffer.toString();
}
