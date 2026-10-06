import 'overseerr_client.dart';

/// Where Discover gets titles to request.
///
/// An interface for the same reason LibrarySource is one: the screens are
/// built, tested and rendered as goldens without a server.
abstract interface class DiscoverSource {
  /// Shown in the top bar's connection label.
  String get label;

  Future<DiscoverPage> list(DiscoverList list, {int page = 1});

  /// Films and series whose title matches [query].
  Future<DiscoverPage> search(String query, {int page = 1});

  /// Titles and people matching [query], from one request.
  Future<({DiscoverPage titles, List<DiscoverPerson> people})> searchAll(String query,
      {int page = 1});

  /// The genres titles can be browsed by.
  Future<List<DiscoverGenre>> genres();

  /// One genre's films, paged.
  Future<DiscoverPage> genreTitles(DiscoverGenre genre, {int page = 1});

  /// Everything a person is credited on, newest first.
  Future<List<PersonCredit>> personCredits(DiscoverPerson person);

  /// Current availability and request state for one title.
  Future<DiscoverTitle> details(DiscoverTitle title);

  /// Request, then return the title as Seerr now sees it.
  Future<DiscoverTitle> request(DiscoverTitle title);

  /// Cancel the title's request, then return it as Seerr now sees it.
  Future<DiscoverTitle> cancelRequest(DiscoverTitle title);

  Uri? posterFor(DiscoverTitle title);
  Uri? backdropFor(DiscoverTitle title);
}

class OverseerrDiscoverSource implements DiscoverSource {
  OverseerrDiscoverSource(this.client);

  final OverseerrClient client;

  @override
  String get label => client.baseUrl.host;

  @override
  Future<DiscoverPage> list(DiscoverList list, {int page = 1}) =>
      client.discover(list, page: page);

  @override
  Future<DiscoverPage> search(String query, {int page = 1}) => client.search(query, page: page);

  @override
  Future<({DiscoverPage titles, List<DiscoverPerson> people})> searchAll(String query,
          {int page = 1}) =>
      client.searchAll(query, page: page);

  @override
  Future<List<DiscoverGenre>> genres() => client.genres();

  @override
  Future<DiscoverPage> genreTitles(DiscoverGenre genre, {int page = 1}) =>
      client.discoverGenre(genre.id, page: page);

  @override
  Future<List<PersonCredit>> personCredits(DiscoverPerson person) =>
      client.personCredits(person.id);

  @override
  Future<DiscoverTitle> details(DiscoverTitle title) => client.details(title);

  @override
  Future<DiscoverTitle> request(DiscoverTitle title) async {
    await client.request(title);
    return client.details(title);
  }

  @override
  Future<DiscoverTitle> cancelRequest(DiscoverTitle title) async {
    final int? id = title.requestId;
    if (id == null) {
      throw const OverseerrException('There is no request to cancel for that title.');
    }
    await client.cancelRequest(id);
    return client.details(title);
  }

  @override
  Uri? posterFor(DiscoverTitle title) => client.imageUrl(title.posterPath);

  @override
  Uri? backdropFor(DiscoverTitle title) =>
      client.imageUrl(title.backdropPath, size: 'w1280');
}

/// Sample titles, for laying out Discover without a server. Requests succeed
/// and change nothing, like the demo library's progress actions.
class DemoDiscoverSource implements DiscoverSource {
  const DemoDiscoverSource();

  static const List<DiscoverTitle> _titles = <DiscoverTitle>[
    DiscoverTitle(tmdbId: 1, mediaType: 'movie', title: 'Vantage', year: 2025, availability: Availability.available, genres: <String>['Drama']),
    DiscoverTitle(
      tmdbId: 2,
      mediaType: 'movie',
      title: 'The Ninth Hour',
      year: 2025,
      runtime: Duration(hours: 2, minutes: 6),
      genres: <String>['Thriller'],
      overview: 'A night-shift dispatcher takes a call from a number that was '
          'disconnected eleven years ago.',
    ),
    DiscoverTitle(tmdbId: 3, mediaType: 'movie', title: 'Coldwater', year: 2026, availability: Availability.processing, requestId: 30, requestState: RequestState.approved),
    DiscoverTitle(tmdbId: 4, mediaType: 'movie', title: 'Marrow', year: 2026),
    DiscoverTitle(tmdbId: 5, mediaType: 'movie', title: 'Signal Fire', year: 2024, availability: Availability.available),
    DiscoverTitle(tmdbId: 6, mediaType: 'tv', title: 'Atlas Bloom', year: 2025),
    DiscoverTitle(tmdbId: 7, mediaType: 'movie', title: 'Understory', year: 2026),
    DiscoverTitle(tmdbId: 8, mediaType: 'movie', title: 'Rivermouth', year: 2025),
    DiscoverTitle(tmdbId: 9, mediaType: 'movie', title: 'Glasshouse', year: 2026, availability: Availability.pending, requestId: 90, requestState: RequestState.pendingApproval),
    DiscoverTitle(tmdbId: 10, mediaType: 'movie', title: 'The Undertow', year: 2024),
    DiscoverTitle(tmdbId: 11, mediaType: 'tv', title: 'Sable', year: 2026),
    DiscoverTitle(tmdbId: 12, mediaType: 'movie', title: 'Northwind', year: 2025),
  ];

  static const List<DiscoverGenre> _genres = <DiscoverGenre>[
    DiscoverGenre(id: 28, name: 'Action'),
    DiscoverGenre(id: 18, name: 'Drama'),
    DiscoverGenre(id: 878, name: 'Science Fiction'),
    DiscoverGenre(id: 53, name: 'Thriller'),
    DiscoverGenre(id: 35, name: 'Comedy'),
    DiscoverGenre(id: 27, name: 'Horror'),
  ];

  static const List<DiscoverPerson> _people = <DiscoverPerson>[
    DiscoverPerson(id: 1, name: 'Ada Vance', knownFor: <String>['Vantage', 'Marrow']),
    DiscoverPerson(id: 2, name: 'Ivo Marek', knownFor: <String>['The Ninth Hour']),
  ];

  static Future<T> _soon<T>(T value) =>
      Future<T>.delayed(const Duration(milliseconds: 120), () => value);

  @override
  String get label => 'demo';

  @override
  Future<DiscoverPage> list(DiscoverList list, {int page = 1}) {
    final List<DiscoverTitle> ordered = switch (list) {
      DiscoverList.trending => _titles,
      DiscoverList.popular => _titles.reversed.toList(),
      DiscoverList.upcoming => _titles.where((DiscoverTitle t) => (t.year ?? 0) >= 2026).toList(),
    };
    return _soon(DiscoverPage(ordered, page: 1, totalPages: 1));
  }

  @override
  Future<DiscoverPage> search(String query, {int page = 1}) {
    final String q = query.trim().toLowerCase();
    final List<DiscoverTitle> matches =
        _titles.where((DiscoverTitle t) => t.title.toLowerCase().contains(q)).toList();
    return _soon(DiscoverPage(matches, page: 1, totalPages: 1));
  }

  @override
  Future<({DiscoverPage titles, List<DiscoverPerson> people})> searchAll(String query,
      {int page = 1}) async {
    final String q = query.trim().toLowerCase();
    return (
      titles: await search(query, page: page),
      people: _people
          .where((DiscoverPerson p) => p.name.toLowerCase().contains(q))
          .toList(growable: false),
    );
  }

  @override
  Future<List<DiscoverGenre>> genres() => _soon(_genres);

  @override
  Future<DiscoverPage> genreTitles(DiscoverGenre genre, {int page = 1}) {
    final List<DiscoverTitle> matches = _titles
        .where((DiscoverTitle t) => t.genres.contains(genre.name))
        .toList(growable: false);
    return _soon(DiscoverPage(
      matches.isEmpty ? _titles.take(4).toList(growable: false) : matches,
      page: 1,
      totalPages: 1,
    ));
  }

  @override
  Future<List<PersonCredit>> personCredits(DiscoverPerson person) => _soon(<PersonCredit>[
        for (int i = 0; i < _titles.length && i < 5; i++)
          PersonCredit(title: _titles[i], role: i == 0 ? 'Director' : 'Actor'),
      ]);

  @override
  Future<DiscoverTitle> details(DiscoverTitle title) =>
      _soon(_titles.firstWhere((DiscoverTitle t) => t.tmdbId == title.tmdbId, orElse: () => title));

  @override
  Future<DiscoverTitle> request(DiscoverTitle title) => _soon(DiscoverTitle(
        tmdbId: title.tmdbId,
        mediaType: title.mediaType,
        title: title.title,
        year: title.year,
        overview: title.overview,
        runtime: title.runtime,
        genres: title.genres,
        availability: Availability.processing,
        requestId: 1000 + title.tmdbId,
        requestState: RequestState.approved,
      ));

  @override
  Future<DiscoverTitle> cancelRequest(DiscoverTitle title) => _soon(DiscoverTitle(
        tmdbId: title.tmdbId,
        mediaType: title.mediaType,
        title: title.title,
        year: title.year,
        overview: title.overview,
        runtime: title.runtime,
        genres: title.genres,
      ));

  @override
  Uri? posterFor(DiscoverTitle title) => null;

  @override
  Uri? backdropFor(DiscoverTitle title) => null;
}
