import '../jellyfin/models.dart';

/// Which audio and subtitle track to use for one film.
class TrackChoice {
  const TrackChoice({this.audio, this.subtitle});

  /// Null means the file's default audio track.
  final MediaTrack? audio;

  /// Null means subtitles off.
  final MediaTrack? subtitle;

  /// A bitmap subtitle the server must burn into the picture.
  bool get burnsInSubtitle => subtitle != null && !subtitle!.isTextBased;

  /// Anything other than the file as-is. The server cannot direct-play a file
  /// with a different audio track, or with a subtitle painted into it.
  bool get needsServerWork =>
      (audio != null && !audio!.isDefault) || burnsInSubtitle;

  TrackChoice withAudio(MediaTrack? audio) =>
      TrackChoice(audio: audio, subtitle: subtitle);

  TrackChoice withSubtitle(MediaTrack? subtitle) =>
      TrackChoice(audio: audio, subtitle: subtitle);

  /// The stored form, as the server keeps it for one film.
  Map<String, String> toPrefs() => <String, String>{
        'audio': audio == null ? 'default' : _encode(audio!),
        'subtitle': subtitle == null ? 'off' : _encode(subtitle!),
      };

  /// The choice stored for [item], matched against its current tracks. A track
  /// that no longer matches falls back to the default rather than guessing.
  static TrackChoice fromPrefs(Map<String, String> prefs, MediaItem item) => TrackChoice(
        audio: _decode(prefs['audio'], item.audioTracks),
        subtitle: _decode(prefs['subtitle'], item.subtitleTracks),
      );

  // Index plus language and codec: an index alone can name a different track
  // after the server rescans the file or a subtitle is deleted.
  static String _encode(MediaTrack t) => '${t.index}|${t.language ?? ''}|${t.codec ?? ''}';

  static MediaTrack? _decode(String? stored, List<MediaTrack> tracks) {
    final List<String> parts = (stored ?? '').split('|');
    if (parts.length != 3) return null;
    final int? index = int.tryParse(parts[0]);
    for (final MediaTrack t in tracks) {
      if (t.index == index && (t.language ?? '') == parts[1] && (t.codec ?? '') == parts[2]) return t;
    }
    // The same language and format at another index: a show's choice applied
    // to one of its other episodes, whose files number their tracks alike but
    // not always identically.
    for (final MediaTrack t in tracks) {
      if ((t.language ?? '') == parts[1] && (t.codec ?? '') == parts[2]) return t;
    }
    return null;
  }
}

const Map<String, String> _languages = <String, String>{
  'eng': 'English', 'srp': 'Serbian', 'hrv': 'Croatian', 'bos': 'Bosnian',
  'slv': 'Slovenian', 'mkd': 'Macedonian', 'deu': 'German', 'ger': 'German',
  'fra': 'French', 'fre': 'French', 'spa': 'Spanish', 'ita': 'Italian',
  'por': 'Portuguese', 'nld': 'Dutch', 'dut': 'Dutch', 'ell': 'Greek',
  'gre': 'Greek', 'hun': 'Hungarian', 'ron': 'Romanian', 'rum': 'Romanian',
  'pol': 'Polish', 'ces': 'Czech', 'cze': 'Czech', 'rus': 'Russian',
  'ukr': 'Ukrainian', 'tur': 'Turkish', 'jpn': 'Japanese', 'kor': 'Korean',
  'zho': 'Chinese', 'chi': 'Chinese', 'swe': 'Swedish', 'nor': 'Norwegian',
  'dan': 'Danish', 'fin': 'Finnish', 'ara': 'Arabic', 'heb': 'Hebrew',
};

/// A three-letter ISO 639-2 code as a word a person would say.
String languageName(String? iso3) {
  // `und` is ISO 639-2 for "undetermined" - what an untagged track reports.
  if (iso3 == null || iso3.isEmpty || iso3.toLowerCase() == 'und') return 'Unknown language';
  return _languages[iso3.toLowerCase()] ?? iso3.toUpperCase();
}

/// The first line of a track row: what it is, in plain words.
String trackName(MediaTrack t) {
  final String title = t.title ?? '';
  if (title.startsWith('Commentary')) {
    final String who = title.split(' - ').length > 1 ? title.split(' - ')[1] : '';
    return who.isEmpty ? 'Commentary' : 'Commentary - $who';
  }
  final String lang = languageName(t.language);
  return t.isForced ? '$lang - forced' : lang;
}

/// The second line: format, and the consequence if there is one.
String trackDetail(MediaTrack t) {
  if (t.kind == TrackKind.audio) {
    final List<String> parts = (t.title ?? '').split(' - ');
    final String codec = (t.codec ?? '').toUpperCase();
    final String channels = parts.firstWhere(
      (String p) => RegExp(r'^\d\.\d$|Stereo|Mono').hasMatch(p.trim()),
      orElse: () => '',
    );
    return <String>[codec, channels, if (t.isDefault) 'default']
        .where((String s) => s.isNotEmpty)
        .join(' · ');
  }
  if (!t.isTextBased) return 'DVD bitmap · the server burns it into the picture';
  final String format = (t.codec ?? 'text').toUpperCase().replaceAll('SUBRIP', 'SRT');
  return t.isExternal ? '$format · external file' : '$format · in the file';
}
