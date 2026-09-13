import 'dart:convert';
import 'dart:io';

import 'device_profile.dart';
import 'models.dart';

/// A failure with a sentence fit for a television.
///
/// Everything thrown out of this client carries text a person can read from
/// three metres. The UI turns these into designed screens; it never prints an
/// exception.
class JellyfinException implements Exception {
  const JellyfinException(this.message, {this.isReachabilityProblem = false});

  final String message;

  /// True when we could not reach the server at all, as opposed to the server
  /// answering with a refusal. The distinction matters: one is the tunnel or
  /// the box being off, the other is credentials or configuration, and they are
  /// different screens with different advice.
  final bool isReachabilityProblem;

  @override
  String toString() => message;
}

class JellyfinClient {
  JellyfinClient({
    required this.baseUrl,
    required this.deviceId,
    this.deviceName = 'Mira',
    this.clientVersion = '0.1.0',
    Duration timeout = const Duration(seconds: 8),
  }) : _http = HttpClient()
          ..connectionTimeout = timeout
          ..userAgent = 'Mira/0.1.0';

  final Uri baseUrl;
  final String deviceId;
  final String deviceName;
  final String clientVersion;
  final HttpClient _http;

  String? _token;
  String? _userId;

  bool get isAuthenticated => _token != null && _userId != null;
  String? get userId => _userId;

  String get _authHeader {
    final StringBuffer b = StringBuffer()
      ..write('MediaBrowser Client="Mira"')
      ..write(', Device="$deviceName"')
      ..write(', DeviceId="$deviceId"')
      ..write(', Version="$clientVersion"');
    if (_token != null) b.write(', Token="$_token"');
    return b.toString();
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      baseUrl.replace(path: path, queryParameters: query);

  Future<Object?> _send(
    String method,
    Uri uri, {
    Object? body,
    bool expectJson = true,
    bool isSignIn = false,
    bool raw = false,
  }) async {
    HttpClientRequest request;
    try {
      request = await _http.openUrl(method, uri);
    } on SocketException {
      throw const JellyfinException(
        'Could not reach your server.',
        isReachabilityProblem: true,
      );
    } on HttpException {
      throw const JellyfinException(
        'Could not reach your server.',
        isReachabilityProblem: true,
      );
    }

    request.headers.set(HttpHeaders.authorizationHeader, _authHeader);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }

    final HttpClientResponse response;
    try {
      response = await request.close();
    } on SocketException {
      throw const JellyfinException(
        'Lost contact with your server.',
        isReachabilityProblem: true,
      );
    }

    final String text = await response.transform(utf8.decoder).join();

    if (response.statusCode == 401) {
      // The same status means two very different things, and telling a person
      // their session expired when they simply mistyped a password sends them
      // looking in the wrong place.
      throw JellyfinException(
        isSignIn
            ? 'That username or password was not accepted.'
            : 'Your sign-in is no longer valid.',
      );
    }
    if (response.statusCode >= 400) {
      throw JellyfinException(
        'Your server refused the request (${response.statusCode}).',
      );
    }
    if (raw) return text;
    if (!expectJson || text.isEmpty) return null;

    try {
      return jsonDecode(text) as Object?;
    } on FormatException {
      throw const JellyfinException('Your server sent something unreadable.');
    }
  }

  Map<String, Object?> _asMap(Object? value) =>
      value is Map ? value.cast<String, Object?>() : <String, Object?>{};

  List<MediaItem> _itemsFrom(Object? payload) {
    final Object? items = _asMap(payload)['Items'];
    if (items is! List) return const <MediaItem>[];
    return items
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) => MediaItem.fromJson(m.cast<String, Object?>()))
        .toList(growable: false);
  }

  static const String _fields =
      'Overview,Genres,MediaStreams,MediaSources,ProductionYear,OfficialRating,ProviderIds';

  Future<void> authenticate({
    required String username,
    required String password,
  }) async {
    final Object? payload = await _send(
      'POST',
      _uri('/Users/AuthenticateByName'),
      body: <String, Object?>{'Username': username, 'Pw': password},
      isSignIn: true,
    );
    final Map<String, Object?> data = _asMap(payload);
    _token = data['AccessToken'] as String?;
    _userId = _asMap(data['User'])['Id'] as String?;
    if (!isAuthenticated) {
      throw const JellyfinException('That username or password was not accepted.');
    }
  }

  void restoreSession({required String token, required String userId}) {
    _token = token;
    _userId = userId;
  }

  void _requireSession() {
    if (!isAuthenticated) {
      throw const JellyfinException('Not signed in to your server.');
    }
  }

  /// What the user was part-way through.
  Future<List<MediaItem>> resume({int limit = 12}) async {
    _requireSession();
    return _itemsFrom(await _send(
      'GET',
      _uri('/Users/$_userId/Items/Resume', <String, String>{
        'Limit': '$limit',
        'MediaTypes': 'Video',
        'Fields': _fields,
        'EnableImageTypes': 'Primary,Backdrop',
      }),
    ));
  }

  Future<List<MediaItem>> latest({String? parentId, int limit = 24}) async {
    _requireSession();
    return _itemsFrom(await _send(
      'GET',
      _uri('/Users/$_userId/Items', <String, String>{
        if (parentId != null) 'ParentId': parentId,
        'Limit': '$limit',
        'Recursive': 'true',
        'IncludeItemTypes': 'Movie',
        'SortBy': 'DateCreated',
        'SortOrder': 'Descending',
        'Fields': _fields,
        'EnableImageTypes': 'Primary,Backdrop',
      }),
    ));
  }

  /// All films, a page at a time, optionally narrowed to one genre.
  Future<List<MediaItem>> movies({
    int startIndex = 0,
    int limit = 60,
    String? genre,
  }) async {
    _requireSession();
    return _itemsFrom(await _send(
      'GET',
      _uri('/Users/$_userId/Items', <String, String>{
        'IncludeItemTypes': 'Movie',
        'Recursive': 'true',
        'SortBy': 'SortName',
        'SortOrder': 'Ascending',
        'StartIndex': '$startIndex',
        'Limit': '$limit',
        'Fields': _fields,
        'EnableImageTypes': 'Primary,Backdrop',
        if (genre != null) 'Genres': genre,
      }),
    ));
  }

  Future<int> movieCount({String? genre}) async {
    _requireSession();
    final Map<String, Object?> data = _asMap(await _send(
      'GET',
      _uri('/Users/$_userId/Items', <String, String>{
        'IncludeItemTypes': 'Movie',
        'Recursive': 'true',
        'Limit': '0',
        if (genre != null) 'Genres': genre,
      }),
    ));
    return (data['TotalRecordCount'] as int?) ?? 0;
  }

  /// Genres counted from the films themselves, most common first.
  ///
  /// Jellyfin's `/Genres` endpoint can come back empty even when every film
  /// carries genres - it does on the server this was built against - so the
  /// count is taken from the films rather than trusted to that endpoint.
  Future<List<GenreCount>> movieGenres() async {
    _requireSession();
    const int page = 200;
    final Map<String, int> counts = <String, int>{};
    for (int start = 0;; start += page) {
      final Map<String, Object?> data = _asMap(await _send(
        'GET',
        _uri('/Users/$_userId/Items', <String, String>{
          'IncludeItemTypes': 'Movie',
          'Recursive': 'true',
          'Fields': 'Genres',
          'EnableImages': 'false',
          'StartIndex': '$start',
          'Limit': '$page',
        }),
      ));
      final Object? items = data['Items'];
      if (items is! List || items.isEmpty) break;
      for (final Object? item in items) {
        if (item is! Map) continue;
        final Object? genres = item['Genres'];
        if (genres is! List) continue;
        for (final Object? g in genres) {
          if (g is String) counts[g] = (counts[g] ?? 0) + 1;
        }
      }
      final int total = (data['TotalRecordCount'] as int?) ?? 0;
      if (start + page >= total) break;
    }
    return counts.entries
        .map((MapEntry<String, int> e) => GenreCount(e.key, e.value))
        .toList()
      ..sort((GenreCount a, GenreCount b) => b.count != a.count
          ? b.count.compareTo(a.count)
          : a.name.compareTo(b.name));
  }

  /// One item with its full track list.
  Future<MediaItem> item(String id) async {
    _requireSession();
    return MediaItem.fromJson(_asMap(await _send(
      'GET',
      _uri('/Users/$_userId/Items/$id', <String, String>{'Fields': _fields}),
    )));
  }

  /// Subtitles the server can fetch from OpenSubtitles for [item], in a
  /// three-letter ISO language ('srp', 'hrv', 'eng'). The server's Open
  /// Subtitles plugin holds the credentials, so none live on the TV.
  ///
  /// Best first: hash matches (timed for this exact file), then popularity.
  Future<List<RemoteSubtitle>> searchSubtitles(
    MediaItem item,
    String language,
  ) async {
    _requireSession();
    final Object? payload = await _send(
      'GET',
      _uri('/Items/${item.id}/RemoteSearch/Subtitles/$language'),
    );
    if (payload is! List) return const <RemoteSubtitle>[];
    return payload
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> m) =>
            RemoteSubtitle.fromJson(m.cast<String, Object?>()))
        .toList()
      ..sort((RemoteSubtitle a, RemoteSubtitle b) {
        if (a.isHashMatch != b.isHashMatch) return a.isHashMatch ? -1 : 1;
        return b.downloads.compareTo(a.downloads);
      });
  }

  /// Has the server download [subtitle] and attach it to [item]. It then shows
  /// up as an external track - for every client, not just this box. Costs one
  /// of the OpenSubtitles account's daily downloads, so only call on intent.
  Future<void> downloadSubtitle(MediaItem item, RemoteSubtitle subtitle) async {
    _requireSession();
    await _send(
      'POST',
      _uri('/Items/${item.id}/RemoteSearch/Subtitles/${Uri.encodeComponent(subtitle.id)}'),
      expectJson: false,
    );
  }

  /// A text subtitle track as WebVTT. The server converts SRT and ASS on the
  /// way out, so the shell only ever has to understand one format.
  Future<String> subtitleText(MediaItem item, MediaTrack track) async {
    _requireSession();
    final String source = item.mediaSourceId ?? item.id;
    final Object? text = await _send(
      'GET',
      _uri('/Videos/${item.id}/$source/Subtitles/${track.index}/Stream.vtt'),
      raw: true,
    );
    return text is String ? text : '';
  }

  Uri imageUrl(
    MediaItem item, {
    String kind = 'Primary',
    int? maxHeight,
  }) {
    final String? tag =
        kind == 'Primary' ? item.primaryImageTag : item.backdropImageTag;
    return _uri('/Items/${item.id}/Images/$kind', <String, String>{
      if (tag != null) 'tag': tag,
      // Ask for what is actually displayed. Decoding a full-size poster costs
      // more than the whole UI does.
      if (maxHeight != null) 'maxHeight': '$maxHeight',
      'quality': '90',
    });
  }

  /// Ask the server how to play [item], handing it our decode envelope.
  ///
  /// This is where the DeviceProfile earns its keep: the server answers with
  /// either the original file or a transcode, and it decides using what we
  /// declare here.
  ///
  /// [audioStreamIndex] picks a non-default audio track. A file cannot be
  /// direct-played with a different audio track, so choosing one asks for a
  /// direct *stream* instead: the server remuxes, copying the video untouched.
  ///
  /// [subtitleStreamIndex] is only for bitmap subtitles the server must burn
  /// in. Text subtitles are drawn by the shell and never passed here - passing
  /// one would needlessly cost a transcode.
  Future<PlaybackPlan> planPlayback(
    MediaItem item, {
    Duration startAt = Duration.zero,
    int maxStreamingBitrate = 120000000,
    int? audioStreamIndex,
    int? subtitleStreamIndex,
  }) async {
    _requireSession();
    final bool remux = audioStreamIndex != null || subtitleStreamIndex != null;
    final Object? payload = await _send(
      'POST',
      _uri('/Items/${item.id}/PlaybackInfo', <String, String>{
        'UserId': _userId!,
        if (audioStreamIndex != null) 'audioStreamIndex': '$audioStreamIndex',
        if (subtitleStreamIndex != null)
          'subtitleStreamIndex': '$subtitleStreamIndex',
      }),
      body: <String, Object?>{
        'DeviceProfile':
            JellyfinDeviceProfile.build(maxStreamingBitrate: maxStreamingBitrate),
        'StartTimeTicks': ticksFromDuration(startAt),
        'MaxStreamingBitrate': maxStreamingBitrate,
        'AutoOpenLiveStream': true,
        if (item.mediaSourceId != null) 'MediaSourceId': item.mediaSourceId,
        if (audioStreamIndex != null) 'AudioStreamIndex': audioStreamIndex,
        if (subtitleStreamIndex != null) 'SubtitleStreamIndex': subtitleStreamIndex,
        if (remux) 'EnableDirectPlay': false,
        if (remux) 'EnableDirectStream': true,
        if (remux) 'AllowVideoStreamCopy': true,
        if (remux) 'AllowAudioStreamCopy': true,
      },
    );

    final Map<String, Object?> data = _asMap(payload);
    final Object? sources = data['MediaSources'];
    if (sources is! List || sources.isEmpty) {
      throw const JellyfinException('Your server has no playable copy of this.');
    }
    final Map<String, Object?> source =
        (sources.first! as Map<Object?, Object?>).cast<String, Object?>();

    final bool supportsDirect = (source['SupportsDirectPlay'] as bool? ?? false) ||
        (source['SupportsDirectStream'] as bool? ?? false);
    final String? transcodingUrl = source['TranscodingUrl'] as String?;

    final Uri url;
    if (supportsDirect && transcodingUrl == null) {
      url = _uri('/Videos/${item.id}/stream', <String, String>{
        'static': 'true',
        'mediaSourceId': (source['Id'] as String?) ?? item.id,
        if (_token != null) 'api_key': _token!,
      });
    } else if (transcodingUrl != null) {
      url = baseUrl.resolve(transcodingUrl);
    } else {
      throw const JellyfinException('Your server could not prepare this title.');
    }

    return PlaybackPlan(
      streamUrl: url,
      isDirectPlay: supportsDirect && transcodingUrl == null,
      mediaSourceId: source['Id'] as String?,
      playSessionId: data['PlaySessionId'] as String?,
      transcodeReasons: (source['TranscodeReasons'] as List<Object?>? ??
              const <Object?>[])
          .whereType<String>()
          .toList(growable: false),
    );
  }

  /// Tell the server where we are, so resume works from any device.
  /// Mark a film watched. It leaves Continue Watching because the server
  /// clears the resume point of anything played.
  Future<void> markPlayed(MediaItem item) async {
    _requireSession();
    await _send(
      'POST',
      _uri('/UserPlayedItems/${item.id}', <String, String>{'userId': _userId!}),
      expectJson: false,
    );
  }

  /// Drop a film from Continue Watching without claiming it was watched: the
  /// resume point goes to zero, and played state and play count are untouched.
  Future<void> clearResume(MediaItem item) async {
    _requireSession();
    await _send(
      'POST',
      _uri('/UserItems/${item.id}/UserData', <String, String>{'userId': _userId!}),
      body: <String, Object?>{'PlaybackPositionTicks': 0},
      expectJson: false,
    );
  }

  /// Tell the server playback began. Without this the server records positions
  /// but never a last-played date, and the film does not appear in
  /// Items/Resume at all - verified against 10.11.11: a film with a 50-minute
  /// position and LastPlayedDate null was missing from Continue Watching.
  Future<void> reportStart({
    required MediaItem item,
    required Duration position,
    required PlaybackPlan plan,
  }) async {
    if (!isAuthenticated) return;
    try {
      await _send(
        'POST',
        _uri('/Sessions/Playing'),
        body: <String, Object?>{
          'ItemId': item.id,
          'PositionTicks': ticksFromDuration(position),
          'IsPaused': false,
          'CanSeek': true,
          'PlayMethod': plan.isDirectPlay ? 'DirectPlay' : 'Transcode',
          if (plan.mediaSourceId != null) 'MediaSourceId': plan.mediaSourceId,
          if (plan.playSessionId != null) 'PlaySessionId': plan.playSessionId,
        },
        expectJson: false,
      );
    } on JellyfinException catch (e) {
      // Best-effort, like progress: never stop a film that is playing. But say
      // so on the console - a silent failure here is why Continue Watching
      // stayed stale for a whole afternoon.
      stderr.writeln('mira jellyfin: playback start report failed: ${e.message}');
    }
  }

  Future<void> reportProgress({
    required MediaItem item,
    required Duration position,
    required bool isPaused,
    String? playSessionId,
  }) async {
    if (!isAuthenticated) return;
    try {
      await _send(
        'POST',
        _uri('/Sessions/Playing/Progress'),
        body: <String, Object?>{
          'ItemId': item.id,
          'PositionTicks': ticksFromDuration(position),
          'IsPaused': isPaused,
          if (playSessionId != null) 'PlaySessionId': playSessionId,
        },
        expectJson: false,
      );
    } on JellyfinException catch (e) {
      // Progress reporting is best-effort. Losing a position update must never
      // interrupt playback that is otherwise working.
      stderr.writeln('mira jellyfin: progress report failed: ${e.message}');
    }
  }

  /// Tell the server playback ended here, so the resume point is exact rather
  /// than up to one progress interval stale.
  Future<void> reportStopped({
    required MediaItem item,
    required Duration position,
    String? playSessionId,
  }) async {
    if (!isAuthenticated) return;
    try {
      await _send(
        'POST',
        _uri('/Sessions/Playing/Stopped'),
        body: <String, Object?>{
          'ItemId': item.id,
          'PositionTicks': ticksFromDuration(position),
          if (item.mediaSourceId != null) 'MediaSourceId': item.mediaSourceId,
          if (playSessionId != null) 'PlaySessionId': playSessionId,
        },
        expectJson: false,
      );
    } on JellyfinException catch (e) {
      // Best-effort, like progress: never block leaving the player on it.
      stderr.writeln('mira jellyfin: playback stop report failed: ${e.message}');
    }
  }

  void close() => _http.close(force: true);
}
