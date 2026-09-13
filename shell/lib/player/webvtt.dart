/// Subtitles, read from WebVTT.
///
/// Jellyfin converts every text subtitle format to WebVTT on the way out, so
/// this is the only format the shell has to understand. It is deliberately
/// independent of the playback backend: the shell draws subtitles from the
/// player's reported position, so swapping MiraPlayer's backend leaves them
/// untouched. Pure Dart, so it can be exercised against the real server
/// without building the UI.
class SubtitleCue {
  const SubtitleCue(this.start, this.end, this.text);

  final Duration start;
  final Duration end;
  final String text;
}

class Subtitles {
  Subtitles._(this.cues);

  /// Sorted by start time.
  final List<SubtitleCue> cues;

  static final RegExp _timing = RegExp(
    r'^\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})',
  );
  static final RegExp _tags = RegExp(r'<[^>]*>');
  // Override blocks left behind when ASS is converted, e.g. {\an8}.
  static final RegExp _assOverrides = RegExp(r'\{\\[^}]*\}');

  static Duration _time(String raw) {
    final List<String> parts = raw.replaceAll(',', '.').split(':');
    final List<String> secMs = parts.removeLast().split('.');
    final int seconds = int.parse(secMs[0]);
    final int millis = int.parse(secMs.length > 1 ? secMs[1].padRight(3, '0') : '0');
    final int minutes = int.parse(parts.removeLast());
    final int hours = parts.isEmpty ? 0 : int.parse(parts.last);
    return Duration(hours: hours, minutes: minutes, seconds: seconds, milliseconds: millis);
  }

  static String _clean(String text) {
    return text
        .replaceAll(_assOverrides, '')
        .replaceAll(_tags, '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll(r'\N', '\n')
        .trim();
  }

  static Subtitles parseWebVtt(String source) {
    final String normalized =
        source.replaceFirst('﻿', '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final List<SubtitleCue> cues = <SubtitleCue>[];

    for (final String block in normalized.split(RegExp(r'\n[ \t]*\n'))) {
      final List<String> lines = block.split('\n');
      final int timingLine = lines.indexWhere((String l) => l.contains('-->'));
      // Header, Region, NOTE and STYLE blocks carry no timing line.
      if (timingLine < 0) continue;
      final RegExpMatch? m = _timing.firstMatch(lines[timingLine]);
      if (m == null) continue;

      final String text = _clean(lines.skip(timingLine + 1).join('\n'));
      if (text.isEmpty) continue;

      final Duration start = _time(m.group(1)!);
      final Duration end = _time(m.group(2)!);
      if (end <= start) continue;
      cues.add(SubtitleCue(start, end, text));
    }

    cues.sort((SubtitleCue a, SubtitleCue b) => a.start.compareTo(b.start));
    return Subtitles._(List<SubtitleCue>.unmodifiable(cues));
  }

  /// What should be on screen at [position], or null.
  ///
  /// Called on every position update, so it is a binary search rather than a
  /// scan. Overlapping cues - two speakers at once - are joined.
  String? textAt(Duration position) {
    int lo = 0;
    int hi = cues.length - 1;
    int last = -1;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      if (cues[mid].start <= position) {
        last = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (last < 0) return null;

    final List<String> visible = <String>[];
    // Earlier cues can still be showing; look back a short way for overlaps.
    for (int i = last; i >= 0 && i > last - 8; i--) {
      final SubtitleCue c = cues[i];
      if (c.start <= position && position < c.end) visible.insert(0, c.text);
    }
    return visible.isEmpty ? null : visible.join('\n');
  }
}
