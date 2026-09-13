import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';

/// Where the shell gets things to watch.
///
/// An interface rather than a direct Jellyfin dependency, so the UI can be
/// built, tested and rendered as goldens without a server - and so Overseerr,
/// which is a second REST client rather than a second graphical app, slots in
/// beside it without touching the screens.
abstract interface class LibrarySource {
  String get label;

  /// True for sample content. Screens never behave differently because of it;
  /// it exists so a technical line can say so.
  bool get isDemo;

  Future<List<MediaItem>> continueWatching();

  /// Newest films first - what arrived since you last looked.
  Future<List<MediaItem>> recentlyAdded({int limit = 16});
  Future<int> movieCount({String? genre});
  Future<List<MediaItem>> movies({int startIndex = 0, int limit = 60, String? genre});
  Future<List<GenreCount>> genres();

  /// One item with its full track list.
  Future<MediaItem> item(String id);

  Uri? posterFor(MediaItem item, {int? maxHeight});
  Uri? backdropFor(MediaItem item, {int? maxHeight});

  Future<PlaybackPlan> planPlayback(
    MediaItem item, {
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  });

  Future<String> subtitleText(MediaItem item, MediaTrack track);
  Future<List<RemoteSubtitle>> searchSubtitles(MediaItem item, String language);
  Future<void> downloadSubtitle(MediaItem item, RemoteSubtitle subtitle);

  Future<void> reportProgress(
    MediaItem item, {
    required Duration position,
    required bool isPaused,
    String? playSessionId,
  });

  /// Playback began. This is what puts a film into Continue Watching.
  Future<void> reportStart(MediaItem item, {required Duration position, required PlaybackPlan plan});

  /// Mark watched; the film leaves Continue Watching.
  Future<void> markWatched(MediaItem item);

  /// Leave Continue Watching without marking watched.
  Future<void> removeFromContinueWatching(MediaItem item);

  Future<void> reportStopped(
    MediaItem item, {
    required Duration position,
    String? playSessionId,
  });
}

const List<MediaTrack> _demoTracks = <MediaTrack>[
  MediaTrack(index: 1, kind: TrackKind.audio, language: 'eng', codec: 'eac3', title: 'English - Dolby Digital+ - 5.1 - Default', isDefault: true),
  MediaTrack(index: 2, kind: TrackKind.audio, language: 'eng', codec: 'aac', title: 'Commentary - English - AAC - Stereo'),
  MediaTrack(index: 3, kind: TrackKind.subtitle, language: 'eng', codec: 'subrip', title: 'English - SUBRIP - External', isExternal: true),
  MediaTrack(index: 4, kind: TrackKind.subtitle, language: 'deu', codec: 'dvdsub', title: 'German - DVDSUB'),
];

/// Sample titles, for laying out the UI without a server.
///
/// Clearly invented on purpose: if this ever appears on a real box, it should
/// be obvious at a glance that nothing is actually connected.
class DemoLibrarySource implements LibrarySource {
  const DemoLibrarySource();

  static const List<MediaItem> _films = <MediaItem>[
    MediaItem(
      id: 'demo-ashfall',
      name: 'Ashfall',
      productionYear: 2021,
      runtime: Duration(hours: 1, minutes: 44),
      resumePosition: Duration(hours: 1),
      overview: 'A volcanologist returns to the valley she grew up in, three '
          'weeks before it is due to be evacuated.',
      videoCodec: 'hevc',
      width: 3840,
      height: 2160,
      genres: <String>['Drama'],
      tracks: _demoTracks,
    ),
    MediaItem(
      id: 'demo-salt-road',
      name: 'The Salt Road',
      productionYear: 2024,
      runtime: Duration(hours: 1, minutes: 58),
      resumePosition: Duration(hours: 1, minutes: 12, seconds: 40),
      overview: 'A salt caravan crossing the interior loses its guide on the '
          'fourth day, and the youngest driver has to read a route he has '
          'only ever been told about.',
      videoCodec: 'hevc',
      width: 3840,
      height: 2160,
      genres: <String>['Drama', 'Adventure'],
      tracks: _demoTracks,
    ),
    MediaItem(
      id: 'demo-nightjar',
      name: 'Nightjar',
      productionYear: 2019,
      runtime: Duration(hours: 2, minutes: 6),
      resumePosition: Duration(minutes: 18),
      overview: 'Two ornithologists share a hide for a season and disagree '
          'about almost everything.',
      videoCodec: 'h264',
      width: 1920,
      height: 1080,
      genres: <String>['Thriller'],
      tracks: _demoTracks,
    ),
    MediaItem(
      id: 'demo-quiet-coast',
      name: 'Quiet Coast',
      productionYear: 2023,
      runtime: Duration(hours: 1, minutes: 37),
      resumePosition: Duration(hours: 1, minutes: 16),
      overview: 'A harbourmaster counts the boats back in every night, and '
          'one night the number is wrong.',
      videoCodec: 'h264',
      width: 1920,
      height: 1080,
      genres: <String>['Mystery', 'Drama'],
      tracks: _demoTracks,
    ),
    MediaItem(
      id: 'demo-meridian',
      name: 'Meridian',
      productionYear: 2018,
      runtime: Duration(hours: 2, minutes: 4),
      overview: 'A surveyor walks a line across a country that is about to '
          'stop existing.',
      videoCodec: 'hevc',
      width: 1920,
      height: 1080,
      genres: <String>['Drama', 'History'],
      tracks: _demoTracks,
    ),
    MediaItem(
      id: 'demo-low-tide',
      name: 'Low Tide',
      productionYear: 2022,
      runtime: Duration(hours: 1, minutes: 47),
      overview: 'Three siblings have one afternoon to clear out a house none '
          'of them wants.',
      videoCodec: 'h264',
      width: 1920,
      height: 1080,
      genres: <String>['Drama', 'Comedy'],
      tracks: _demoTracks,
    ),
    MediaItem(
      id: 'demo-ferrous',
      name: 'Ferrous',
      productionYear: 2020,
      runtime: Duration(hours: 1, minutes: 52),
      overview: 'The last shift at a rolling mill, filmed in one take.',
      videoCodec: 'hevc',
      width: 3840,
      height: 2160,
      genres: <String>['Documentary'],
      tracks: _demoTracks,
    ),
  ];

  @override
  String get label => 'demo';

  @override
  bool get isDemo => true;

  static Future<T> _soon<T>(T value) =>
      Future<T>.delayed(const Duration(milliseconds: 120), () => value);

  List<MediaItem> _filtered(String? genre) => genre == null
      ? _films
      : _films.where((MediaItem m) => m.genres.contains(genre)).toList(growable: false);

  @override
  Future<List<MediaItem>> continueWatching() =>
      _soon(_films.where((MediaItem m) => m.canResume).toList(growable: false));

  @override
  Future<List<MediaItem>> recentlyAdded({int limit = 16}) =>
      _soon(_films.reversed.take(limit).toList(growable: false));

  @override
  Future<int> movieCount({String? genre}) => _soon(_filtered(genre).length);

  @override
  Future<List<MediaItem>> movies({int startIndex = 0, int limit = 60, String? genre}) {
    final List<MediaItem> all = _filtered(genre);
    final int start = startIndex.clamp(0, all.length);
    final int end = (start + limit).clamp(0, all.length);
    return _soon(all.sublist(start, end));
  }

  @override
  Future<List<GenreCount>> genres() {
    final Map<String, int> counts = <String, int>{};
    for (final MediaItem m in _films) {
      for (final String g in m.genres) {
        counts[g] = (counts[g] ?? 0) + 1;
      }
    }
    return _soon(counts.entries
        .map((MapEntry<String, int> e) => GenreCount(e.key, e.value))
        .toList()
      ..sort((GenreCount a, GenreCount b) => b.count != a.count
          ? b.count.compareTo(a.count)
          : a.name.compareTo(b.name)));
  }

  @override
  Future<MediaItem> item(String id) =>
      _soon(_films.firstWhere((MediaItem m) => m.id == id, orElse: () => _films.first));

  @override
  Uri? posterFor(MediaItem item, {int? maxHeight}) => null;

  @override
  Uri? backdropFor(MediaItem item, {int? maxHeight}) => null;

  @override
  Future<PlaybackPlan> planPlayback(MediaItem item, {int? audioStreamIndex, int? subtitleStreamIndex}) {
    return _soon(PlaybackPlan(
      streamUrl: Uri(scheme: 'demo', path: item.id),
      isDirectPlay: item.likelyDirectPlay && audioStreamIndex == null && subtitleStreamIndex == null,
    ));
  }

  @override
  Future<String> subtitleText(MediaItem item, MediaTrack track) => _soon(
        'WEBVTT\n\n00:00:02.000 --> 00:00:06.000\nSample subtitles - nothing is connected.\n\n'
        '01:00:00.000 --> 01:00:08.000\nSample subtitles - nothing is connected.\n',
      );

  @override
  Future<List<RemoteSubtitle>> searchSubtitles(MediaItem item, String language) => _soon(<RemoteSubtitle>[
        RemoteSubtitle(id: 'demo-1-$language', name: '${item.name}.1080p.BluRay (sample)', language: language, format: 'srt', downloads: 4210, isHashMatch: true),
        RemoteSubtitle(id: 'demo-2-$language', name: '${item.name}.720p.WEB (sample)', language: language, format: 'srt', downloads: 1880),
        RemoteSubtitle(id: 'demo-3-$language', name: '${item.name} - forced only (sample)', language: language, format: 'srt', downloads: 312, isForced: true),
      ]);

  @override
  Future<void> downloadSubtitle(MediaItem item, RemoteSubtitle subtitle) => _soon(null);

  @override
  Future<void> reportProgress(MediaItem item, {required Duration position, required bool isPaused, String? playSessionId}) async {}

  @override
  Future<void> reportStopped(MediaItem item, {required Duration position, String? playSessionId}) async {}

  @override
  Future<void> reportStart(MediaItem item, {required Duration position, required PlaybackPlan plan}) async {}

  // The sample films are constant, so these succeed without changing them.
  @override
  Future<void> markWatched(MediaItem item) => _soon(null);

  @override
  Future<void> removeFromContinueWatching(MediaItem item) => _soon(null);
}

/// The real thing.
class JellyfinLibrarySource implements LibrarySource {
  JellyfinLibrarySource(this.client, {this.username, this.password});

  final JellyfinClient client;
  final String? username;
  final String? password;

  @override
  String get label => client.baseUrl.host;

  @override
  bool get isDemo => false;

  Future<void>? _signingIn;

  /// Signs in on first use rather than at startup, so a server that is down
  /// surfaces as a failure *screen* instead of an exception during boot.
  ///
  /// Single-flight: callers arriving while a sign-in is under way wait for it.
  /// Home loads its two rails in parallel, and two concurrent sign-ins with
  /// one DeviceId make Jellyfin replace the first session - revoking the token
  /// the other rail was already using, so the box booted into "Your sign-in is
  /// no longer valid" (found in the VM, 2026-09-13).
  Future<void> _signIn() {
    if (client.isAuthenticated) return Future<void>.value();
    if (username == null || password == null) {
      return Future<void>.error(const JellyfinException('Mira is not signed in to your server.'));
    }
    return _signingIn ??= client
        .authenticate(username: username!, password: password!)
        .whenComplete(() => _signingIn = null);
  }

  @override
  Future<List<MediaItem>> continueWatching() async {
    await _signIn();
    return client.resume();
  }

  @override
  Future<List<MediaItem>> recentlyAdded({int limit = 16}) async {
    await _signIn();
    return client.latest(limit: limit);
  }

  @override
  Future<int> movieCount({String? genre}) async {
    await _signIn();
    return client.movieCount(genre: genre);
  }

  @override
  Future<List<MediaItem>> movies({int startIndex = 0, int limit = 60, String? genre}) async {
    await _signIn();
    return client.movies(startIndex: startIndex, limit: limit, genre: genre);
  }

  @override
  Future<List<GenreCount>> genres() async {
    await _signIn();
    return client.movieGenres();
  }

  @override
  Future<MediaItem> item(String id) async {
    await _signIn();
    return client.item(id);
  }

  @override
  Uri? posterFor(MediaItem item, {int? maxHeight}) =>
      item.primaryImageTag == null ? null : client.imageUrl(item, maxHeight: maxHeight);

  @override
  Uri? backdropFor(MediaItem item, {int? maxHeight}) => item.backdropImageTag == null
      ? null
      : client.imageUrl(item, kind: 'Backdrop', maxHeight: maxHeight);

  @override
  Future<PlaybackPlan> planPlayback(MediaItem item, {int? audioStreamIndex, int? subtitleStreamIndex}) async {
    await _signIn();
    return client.planPlayback(item, audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex);
  }

  @override
  Future<String> subtitleText(MediaItem item, MediaTrack track) async {
    await _signIn();
    return client.subtitleText(item, track);
  }

  @override
  Future<List<RemoteSubtitle>> searchSubtitles(MediaItem item, String language) async {
    await _signIn();
    return client.searchSubtitles(item, language);
  }

  @override
  Future<void> downloadSubtitle(MediaItem item, RemoteSubtitle subtitle) async {
    await _signIn();
    return client.downloadSubtitle(item, subtitle);
  }

  @override
  Future<void> reportProgress(MediaItem item, {required Duration position, required bool isPaused, String? playSessionId}) =>
      client.reportProgress(item: item, position: position, isPaused: isPaused, playSessionId: playSessionId);

  @override
  Future<void> reportStopped(MediaItem item, {required Duration position, String? playSessionId}) =>
      client.reportStopped(item: item, position: position, playSessionId: playSessionId);

  @override
  Future<void> reportStart(MediaItem item, {required Duration position, required PlaybackPlan plan}) =>
      client.reportStart(item: item, position: position, plan: plan);

  @override
  Future<void> markWatched(MediaItem item) async {
    await _signIn();
    return client.markPlayed(item);
  }

  @override
  Future<void> removeFromContinueWatching(MediaItem item) async {
    await _signIn();
    return client.clearResume(item);
  }
}
