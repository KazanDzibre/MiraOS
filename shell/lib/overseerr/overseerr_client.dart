import 'dart:convert';
import 'dart:io';

/// Which Discover list to show.
enum DiscoverList { trending, popular, upcoming }

/// Whether a title is on the server, from Seerr's `mediaInfo.status`.
///
/// Seerr is Overseerr's successor and keeps its API: 1 unknown, 2 pending,
/// 3 processing, 4 partially available, 5 available, 6 deleted. A title Seerr
/// has never seen has no mediaInfo at all, which is [none].
enum Availability { none, unknown, pending, processing, partial, available, deleted }

Availability availabilityFrom(Object? status) => switch (status) {
      1 => Availability.unknown,
      2 => Availability.pending,
      3 => Availability.processing,
      4 => Availability.partial,
      5 => Availability.available,
      6 => Availability.deleted,
      _ => Availability.none,
    };

/// A request's own state: 1 pending approval, 2 approved, 3 declined.
enum RequestState { none, pendingApproval, approved, declined }

RequestState requestStateFrom(Object? status) => switch (status) {
      1 => RequestState.pendingApproval,
      2 => RequestState.approved,
      3 => RequestState.declined,
      _ => RequestState.none,
    };

class OverseerrException implements Exception {
  const OverseerrException(this.message, {this.isReachabilityProblem = false});

  /// A sentence a person can read from the couch.
  final String message;
  final bool isReachabilityProblem;

  @override
  String toString() => 'OverseerrException: $message';
}

/// A film or series as Discover shows it.
class DiscoverTitle {
  const DiscoverTitle({
    required this.tmdbId,
    required this.mediaType,
    required this.title,
    this.year,
    this.overview,
    this.posterPath,
    this.backdropPath,
    this.runtime,
    this.genres = const <String>[],
    this.availability = Availability.none,
    this.requestId,
    this.requestState = RequestState.none,
  });

  final int tmdbId;

  /// `movie` or `tv`.
  final String mediaType;
  final String title;
  final int? year;
  final String? overview;
  final String? posterPath;
  final String? backdropPath;
  final Duration? runtime;
  final List<String> genres;
  final Availability availability;

  /// The newest request for this title, when Seerr returned one - needed to
  /// cancel it.
  final int? requestId;
  final RequestState requestState;

  bool get isMovie => mediaType == 'movie';

  bool get inLibrary =>
      availability == Availability.available || availability == Availability.partial;

  /// Asked for and not yet watchable.
  bool get isRequested =>
      !inLibrary &&
      (availability == Availability.pending ||
          availability == Availability.processing ||
          requestState == RequestState.pendingApproval ||
          requestState == RequestState.approved);

  bool get canRequest => !inLibrary && !isRequested;

  static int? _year(Object? date) {
    if (date is! String || date.length < 4) return null;
    return int.tryParse(date.substring(0, 4));
  }

  /// From a Discover/search result or a /movie or /tv details response. List
  /// results for /discover/movies omit mediaType, so the caller supplies it.
  factory DiscoverTitle.fromJson(Map<String, Object?> j, {String? mediaType}) {
    final String type = (j['mediaType'] as String?) ?? mediaType ?? 'movie';
    final Map<String, Object?> info =
        (j['mediaInfo'] as Map<Object?, Object?>?)?.cast<String, Object?>() ??
            const <String, Object?>{};
    final List<Map<String, Object?>> requests = ((info['requests'] as List<Object?>?) ??
            const <Object?>[])
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> r) => r.cast<String, Object?>())
        .toList();
    requests.sort((Map<String, Object?> a, Map<String, Object?> b) =>
        ((b['id'] as num?) ?? 0).compareTo((a['id'] as num?) ?? 0));
    final Map<String, Object?>? latest = requests.isEmpty ? null : requests.first;

    final Object? minutes = j['runtime'];
    return DiscoverTitle(
      tmdbId: (j['id'] as num).toInt(),
      mediaType: type,
      title: ((j['title'] ?? j['name']) as String?) ?? 'Untitled',
      year: _year(j['releaseDate'] ?? j['firstAirDate']),
      overview: (j['overview'] as String?)?.trim().isEmpty ?? true ? null : j['overview'] as String,
      posterPath: j['posterPath'] as String?,
      backdropPath: j['backdropPath'] as String?,
      runtime: minutes is num && minutes > 0 ? Duration(minutes: minutes.toInt()) : null,
      genres: ((j['genres'] as List<Object?>?) ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> g) => g['name'])
          .whereType<String>()
          .toList(),
      availability: availabilityFrom(info['status']),
      requestId: (latest?['id'] as num?)?.toInt(),
      requestState: requestStateFrom(latest?['status']),
    );
  }
}

class DiscoverPage {
  const DiscoverPage(this.results, {required this.page, required this.totalPages});

  final List<DiscoverTitle> results;
  final int page;
  final int totalPages;

  bool get hasMore => page < totalPages;
}

/// Seerr's REST API (Overseerr-compatible), authenticated with an API key.
///
/// Depends only on dart:io, like the Jellyfin client, so a probe can exercise
/// the real server as plain Dart. It never requests anything on its own - a
/// request costs the household disk space and bandwidth, so it only ever
/// follows an explicit OK.
class OverseerrClient {
  OverseerrClient({required this.baseUrl, required String apiKey, HttpClient? http})
      : _apiKey = apiKey,
        _http = http ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 8)
              // Seerr is Node, which drops idle keep-alive connections after
              // 5 s; Dart keeps them 15 s by default and will reuse one the
              // server has just closed. Stay under Node's limit.
              ..idleTimeout = const Duration(seconds: 3));

  final Uri baseUrl;
  final String _apiKey;
  final HttpClient _http;

  Uri _uri(String path, [Map<String, String>? query]) {
    final String base = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(path: '$base/api/v1$path', queryParameters: query);
  }

  /// A GET is retried once when the connection closes under it - the
  /// keep-alive race above can still happen at the boundary. Requests and
  /// cancellations are never retried: repeating them is not harmless.
  Future<Object?> _send(String method, String path,
      {Map<String, String>? query, Object? body, String? rawQuery}) async {
    try {
      return await _sendOnce(method, path, query: query, body: body, rawQuery: rawQuery);
    } on OverseerrException catch (e) {
      if (method != 'GET' || !e.isReachabilityProblem) rethrow;
      return _sendOnce(method, path, query: query, body: body, rawQuery: rawQuery);
    }
  }

  Future<Object?> _sendOnce(String method, String path,
      {Map<String, String>? query, Object? body, String? rawQuery}) async {
    final Uri uri = rawQuery == null ? _uri(path, query) : _uri(path).replace(query: rawQuery);
    final HttpClientRequest request;
    try {
      request = await _http.openUrl(method, uri);
    } on SocketException {
      throw const OverseerrException('Could not reach Seerr.', isReachabilityProblem: true);
    } on HttpException {
      throw const OverseerrException('Could not reach Seerr.', isReachabilityProblem: true);
    }
    request.headers.set('X-Api-Key', _apiKey);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }

    final HttpClientResponse response;
    final String text;
    try {
      response = await request.close();
      text = await response.transform(utf8.decoder).join();
    } on SocketException {
      throw const OverseerrException('Lost contact with Seerr.', isReachabilityProblem: true);
    } on HttpException {
      // "Connection closed before full header was received": the keep-alive
      // race. Reported as reachability so a GET gets its one retry.
      throw const OverseerrException('Lost contact with Seerr.', isReachabilityProblem: true);
    }

    switch (response.statusCode) {
      case >= 200 && < 300:
        return text.isEmpty ? null : jsonDecode(text);
      case 401 || 403:
        throw const OverseerrException('Seerr refused this box. The API key may have been changed.');
      case 404:
        throw const OverseerrException('Seerr could not find that title.');
      case 409:
        throw const OverseerrException('That title has already been requested.');
      default:
        throw OverseerrException('Seerr answered with an error (${response.statusCode}).');
    }
  }

  List<DiscoverTitle> _titles(Object? json, {String? mediaType}) {
    final List<Object?> results =
        ((json as Map<Object?, Object?>?)?['results'] as List<Object?>?) ?? const <Object?>[];
    return results
        .whereType<Map<Object?, Object?>>()
        .map((Map<Object?, Object?> r) => r.cast<String, Object?>())
        // Trending and search mix in people, which cannot be requested.
        .where((Map<String, Object?> r) =>
            (r['mediaType'] ?? mediaType) == 'movie' || (r['mediaType'] ?? mediaType) == 'tv')
        .map((Map<String, Object?> r) => DiscoverTitle.fromJson(r, mediaType: mediaType))
        .toList();
  }

  DiscoverPage _page(Object? json, List<DiscoverTitle> titles) {
    final Map<Object?, Object?> m = (json as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
    return DiscoverPage(
      titles,
      page: (m['page'] as num?)?.toInt() ?? 1,
      totalPages: (m['totalPages'] as num?)?.toInt() ?? 1,
    );
  }

  Future<DiscoverPage> discover(DiscoverList list, {int page = 1}) async {
    final (String path, String? type) = switch (list) {
      DiscoverList.trending => ('/discover/trending', null),
      DiscoverList.popular => ('/discover/movies', 'movie'),
      DiscoverList.upcoming => ('/discover/movies/upcoming', 'movie'),
    };
    final Object? json = await _send('GET', path, query: <String, String>{'page': '$page'});
    return _page(json, _titles(json, mediaType: type));
  }

  /// Seerr rejects a query containing any reserved character with a 400 -
  /// including `+` for a space and a bare apostrophe, both of which Dart's own
  /// query encoding produces. Measured against Seerr 3.4.1: `the+odyssey` is
  /// refused, `the%20odyssey` returns 192 results. So encode strictly.
  static String strictEncode(String value) {
    final StringBuffer out = StringBuffer();
    for (final int byte in utf8.encode(value)) {
      final bool unreserved = (byte >= 0x30 && byte <= 0x39) || // 0-9
          (byte >= 0x41 && byte <= 0x5a) || // A-Z
          (byte >= 0x61 && byte <= 0x7a) || // a-z
          byte == 0x2d || byte == 0x2e || byte == 0x5f || byte == 0x7e; // - . _ ~
      if (unreserved) {
        out.writeCharCode(byte);
      } else {
        out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return out.toString();
  }

  Future<DiscoverPage> search(String query, {int page = 1}) async {
    final Object? json = await _send('GET', '/search',
        rawQuery: 'query=${strictEncode(query.trim())}&page=$page');
    return _page(json, _titles(json));
  }

  /// Full details, including current availability and the latest request.
  Future<DiscoverTitle> details(DiscoverTitle title) async {
    final String path = title.isMovie ? '/movie/${title.tmdbId}' : '/tv/${title.tmdbId}';
    final Object? json = await _send('GET', path);
    return DiscoverTitle.fromJson(
      (json! as Map<Object?, Object?>).cast<String, Object?>(),
      mediaType: title.mediaType,
    );
  }

  /// Ask for a title. Series are requested whole: choosing seasons with a
  /// d-pad is a screen of its own, and v1 does not have it.
  Future<void> request(DiscoverTitle title) async {
    await _send('POST', '/request', body: <String, Object?>{
      'mediaType': title.mediaType,
      'mediaId': title.tmdbId,
      if (!title.isMovie) 'seasons': 'all',
    });
  }

  Future<void> cancelRequest(int requestId) async {
    await _send('DELETE', '/request/$requestId');
  }

  /// TMDB artwork through Seerr's image proxy, not image.tmdb.org directly.
  ///
  /// The proxy is plain http on the LAN, reached over the same tunnel as
  /// everything else, and cached by Seerr - so artwork needs neither internet
  /// access nor HTTPS from the box. Direct TMDB rendered every poster as a
  /// placeholder in the VM, whose image had no CA certificates. Verified: the
  /// proxy returns the same bytes as TMDB and needs no API key.
  Uri? imageUrl(String? path, {String size = 'w342'}) {
    if (path == null) return null;
    final String base = baseUrl.path.endsWith('/')
        ? baseUrl.path.substring(0, baseUrl.path.length - 1)
        : baseUrl.path;
    return baseUrl.replace(path: '$base/imageproxy/tmdb/t/p/$size$path', queryParameters: null);
  }

  void close() => _http.close(force: true);
}
