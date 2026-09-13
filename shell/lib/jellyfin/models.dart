/// Jellyfin measures time in 100-nanosecond ticks.
Duration durationFromTicks(Object? ticks) {
  if (ticks is! num) return Duration.zero;
  return Duration(microseconds: (ticks / 10).round());
}

int ticksFromDuration(Duration d) => d.inMicroseconds * 10;

enum TrackKind { audio, subtitle }

/// An audio or subtitle track inside a file, as the server describes it.
class MediaTrack {
  const MediaTrack({
    required this.index,
    required this.kind,
    this.language,
    this.codec,
    this.title,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
  });

  /// The server's stream index - what PlaybackInfo and subtitle URLs take.
  final int index;
  final TrackKind kind;
  final String? language;
  final String? codec;
  final String? title;
  final bool isDefault;
  final bool isForced;
  final bool isExternal;

  static const Set<String> _textCodecs = <String>{
    'subrip', 'srt', 'ass', 'ssa', 'webvtt', 'vtt', 'mov_text', 'text',
  };

  /// Text subtitles the shell can draw itself. Everything else - DVD and
  /// Blu-ray bitmaps - has to be burned into the picture by the server, which
  /// turns a direct play into a transcode. The UI says so rather than hiding it.
  bool get isTextBased => _textCodecs.contains(codec?.toLowerCase());

  static MediaTrack? fromJson(Map<String, Object?> json) {
    final Object? type = json['Type'];
    final TrackKind? kind = type == 'Audio'
        ? TrackKind.audio
        : (type == 'Subtitle' ? TrackKind.subtitle : null);
    if (kind == null) return null;
    return MediaTrack(
      index: (json['Index'] as int?) ?? -1,
      kind: kind,
      language: json['Language'] as String?,
      codec: json['Codec'] as String?,
      title: json['DisplayTitle'] as String?,
      isDefault: json['IsDefault'] == true,
      isForced: json['IsForced'] == true,
      isExternal: json['IsExternal'] == true,
    );
  }
}

/// One thing that can be watched.
class MediaItem {
  const MediaItem({
    required this.id,
    required this.name,
    this.overview,
    this.productionYear,
    this.runtime = Duration.zero,
    this.resumePosition = Duration.zero,
    this.primaryImageTag,
    this.backdropImageTag,
    this.officialRating,
    this.genres = const <String>[],
    this.videoCodec,
    this.width,
    this.height,
    this.mediaSourceId,
    this.providerIds = const <String, String>{},
    this.tracks = const <MediaTrack>[],
  });

  final String id;
  final String name;
  final String? overview;
  final int? productionYear;
  final Duration runtime;

  /// Where the user stopped. Zero means "not started".
  final Duration resumePosition;

  final String? primaryImageTag;
  final String? backdropImageTag;
  final String? officialRating;
  final List<String> genres;

  final String? videoCodec;
  final int? width;
  final int? height;

  /// The file to play when an item has several versions.
  final String? mediaSourceId;
  final Map<String, String> providerIds;
  final List<MediaTrack> tracks;

  bool get canResume => resumePosition > Duration.zero;

  List<MediaTrack> get audioTracks => tracks
      .where((MediaTrack t) => t.kind == TrackKind.audio)
      .toList(growable: false);

  List<MediaTrack> get subtitleTracks => tracks
      .where((MediaTrack t) => t.kind == TrackKind.subtitle)
      .toList(growable: false);

  /// Whether this will direct-play on a Pi 4, from the same envelope the
  /// DeviceProfile declares. Used only to *label* an item in the UI - the
  /// server makes the actual decision.
  bool get likelyDirectPlay {
    final String? codec = videoCodec?.toLowerCase();
    final int w = width ?? 0;
    final int h = height ?? 0;
    if (codec == 'hevc' || codec == 'h265') return w <= 3840 && h <= 2160;
    if (codec == 'h264' || codec == 'avc') return w <= 1920 && h <= 1080;
    return false;
  }

  static MediaItem fromJson(Map<String, Object?> json) {
    final Map<String, Object?>? userData = json['UserData'] is Map
        ? (json['UserData']! as Map<Object?, Object?>).cast<String, Object?>()
        : null;

    String? codec;
    int? width;
    int? height;
    final List<MediaTrack> tracks = <MediaTrack>[];
    final Object? streams = json['MediaStreams'];
    if (streams is List) {
      for (final Object? s in streams) {
        if (s is! Map) continue;
        final Map<String, Object?> v = s.cast<String, Object?>();
        if (v['Type'] == 'Video' && codec == null) {
          codec = v['Codec'] as String?;
          width = v['Width'] as int?;
          height = v['Height'] as int?;
        }
        final MediaTrack? track = MediaTrack.fromJson(v);
        if (track != null) tracks.add(track);
      }
    }

    String? sourceId;
    final Object? sources = json['MediaSources'];
    if (sources is List && sources.isNotEmpty && sources.first is Map) {
      sourceId = (sources.first! as Map<Object?, Object?>)['Id'] as String?;
    }

    final Map<String, String> providers = <String, String>{};
    final Object? ids = json['ProviderIds'];
    if (ids is Map) {
      ids.forEach((Object? k, Object? v) {
        if (k is String && v is String) providers[k] = v;
      });
    }

    return MediaItem(
      id: json['Id']! as String,
      name: (json['Name'] as String?) ?? 'Untitled',
      overview: json['Overview'] as String?,
      productionYear: json['ProductionYear'] as int?,
      runtime: durationFromTicks(json['RunTimeTicks']),
      resumePosition: durationFromTicks(userData?['PlaybackPositionTicks']),
      primaryImageTag: _imageTag(json, 'Primary'),
      backdropImageTag: _backdropTag(json),
      officialRating: json['OfficialRating'] as String?,
      genres: (json['Genres'] as List<Object?>? ?? const <Object?>[])
          .whereType<String>()
          .toList(growable: false),
      videoCodec: codec,
      width: width,
      height: height,
      mediaSourceId: sourceId,
      providerIds: providers,
      tracks: tracks,
    );
  }

  static String? _imageTag(Map<String, Object?> json, String kind) {
    final Object? tags = json['ImageTags'];
    if (tags is Map) return tags[kind] as String?;
    return null;
  }

  static String? _backdropTag(Map<String, Object?> json) {
    final Object? tags = json['BackdropImageTags'];
    if (tags is List && tags.isNotEmpty) return tags.first as String?;
    return null;
  }
}

/// A subtitle the server found on OpenSubtitles through its plugin.
class RemoteSubtitle {
  const RemoteSubtitle({
    required this.id,
    required this.name,
    this.language,
    this.format,
    this.downloads = 0,
    this.isHashMatch = false,
    this.isForced = false,
    this.isHearingImpaired = false,
    this.provider,
  });

  final String id;
  final String name;
  final String? language;
  final String? format;
  final int downloads;

  /// Matched on the file's hash rather than its name - timed for this exact
  /// release, so it should not drift.
  final bool isHashMatch;
  final bool isForced;
  final bool isHearingImpaired;
  final String? provider;

  static RemoteSubtitle fromJson(Map<String, Object?> json) {
    return RemoteSubtitle(
      id: json['Id']! as String,
      name: (json['Name'] as String?) ?? '',
      language: json['ThreeLetterISOLanguageName'] as String?,
      format: json['Format'] as String?,
      downloads: (json['DownloadCount'] as int?) ?? 0,
      isHashMatch: json['IsHashMatch'] == true,
      isForced: json['Forced'] == true,
      isHearingImpaired: json['HearingImpaired'] == true,
      provider: json['ProviderName'] as String?,
    );
  }
}

class GenreCount {
  const GenreCount(this.name, this.count);

  final String name;
  final int count;
}

/// What the server decided to do with a request to play something.
class PlaybackPlan {
  const PlaybackPlan({
    required this.streamUrl,
    required this.isDirectPlay,
    this.mediaSourceId,
    this.playSessionId,
    this.transcodeReasons = const <String>[],
  });

  final Uri streamUrl;

  /// True when the Pi decodes the original file untouched. False means the
  /// server is re-encoding or remuxing, which is not an error - it is the
  /// DeviceProfile doing its job - but it is worth surfacing, because a title
  /// that transcodes unexpectedly usually means the profile is wrong.
  final bool isDirectPlay;

  final String? mediaSourceId;
  final String? playSessionId;
  final List<String> transcodeReasons;
}
