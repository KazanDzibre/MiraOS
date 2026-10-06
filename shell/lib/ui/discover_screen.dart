import 'package:flutter/widgets.dart';

import '../core/tokens.dart';
import '../input/focus_debug.dart';
import '../input/mira_focusable.dart';
import '../overseerr/discover_source.dart';
import '../overseerr/overseerr_client.dart';
import 'discover_search_screen.dart';
import 'discover_title_screen.dart';
import 'widgets/chrome.dart';
import 'widgets/grid_focus.dart';
import 'widgets/mira_button.dart';
import 'widgets/poster.dart';

/// The Discover tab: what to request next, from Seerr.
///
/// Follows design/Overseerr.dc.html with two deliberate departures. The list
enum _Mode { lists, genres }

/// chips sit on the left above the grid's first column, where Up from the grid
/// lands - at the far right the directional policy skipped them, as it did on
/// Films. And OK opens the title rather than requesting it: a request spends
/// the household's disk and bandwidth, so it should never be one stray press.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({
    super.key,
    required this.source,
    this.onTab,
    this.genre,
    this.person,
  });

  final DiscoverSource source;
  final ValueChanged<String>? onTab;

  /// Set when this screen shows one genre's films. Pushed, so Back returns to
  /// the genre list through the normal navigator rule - the same shape Films
  /// uses for its genres.
  final DiscoverGenre? genre;

  /// Set when this screen shows one person's credits.
  final DiscoverPerson? person;

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const int _columns = 6;
  static const double _gap = 32;

  static const Map<DiscoverList, String> _labels = <DiscoverList, String>{
    DiscoverList.trending: 'Trending',
    DiscoverList.popular: 'Popular',
    DiscoverList.upcoming: 'Upcoming',
  };

  DiscoverList _list = DiscoverList.trending;
  _Mode _mode = _Mode.lists;
  List<DiscoverGenre>? _genres;

  /// What the focused person did on each title, by title key - only ever set
  /// on a person's screen.
  final Map<String, String> _roles = <String, String>{};
  final List<DiscoverTitle> _titles = <DiscoverTitle>[];
  int _page = 0;
  int _totalPages = 1;
  bool _loaded = false;
  bool _loadingMore = false;
  String? _error;
  int _focused = 0;

  /// Bumped on every list switch, so a slow answer for the previous list can
  /// never land in the new one.
  int _generation = 0;

  final GridFocus _grid = GridFocus(columns: _columns, debugName: 'discover');
  final GridFocus _genreFocus = GridFocus(columns: 4, debugName: 'discover-genre');

  double get _ringRoom => MiraFocusRing.reach + 2;

  @override
  void initState() {
    super.initState();
    _loadFirst();
    debugAssertReachableAfterFrame(context, screen: 'DiscoverScreen');
  }

  @override
  void dispose() {
    _genreFocus.dispose();
    _grid.dispose();
    super.dispose();
  }

  Future<void> _loadFirst() async {
    final int generation = ++_generation;
    setState(() {
      _loaded = false;
      _error = null;
      _titles.clear();
      _page = 0;
      _totalPages = 1;
      _focused = 0;
    });
    try {
      final DiscoverPage page = await _fetch(1);
      if (!mounted || generation != _generation) return;
      setState(() {
        _titles.addAll(page.results);
        _page = page.page;
        _totalPages = page.totalPages;
        _loaded = true;
      });
    } on OverseerrException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e.message;
        _loaded = true;
      });
    }
  }

  /// Pages in as focus nears the end. Trending pages overlap as rankings move,
  /// so titles already shown are skipped rather than listed twice.
  Future<void> _loadMore() async {
    if (_loadingMore || _page >= _totalPages) return;
    _loadingMore = true;
    final int generation = _generation;
    try {
      final DiscoverPage page = await _fetch(_page + 1);
      if (!mounted || generation != _generation) return;
      final Set<String> seen = _titles.map(_key).toSet();
      setState(() {
        _titles.addAll(page.results.where((DiscoverTitle t) => !seen.contains(_key(t))));
        _page = page.page;
        _totalPages = page.totalPages;
      });
    } on OverseerrException {
      // Keep what is on screen; the next approach to the end retries.
    } finally {
      _loadingMore = false;
    }
  }

  static String _key(DiscoverTitle t) => '${t.mediaType}:${t.tmdbId}';

  /// Where this screen's titles come from: a list, a genre, or a person's
  /// credits. Only the first two page - a person's credits arrive whole.
  Future<DiscoverPage> _fetch(int page) async {
    final DiscoverPerson? person = widget.person;
    if (person != null) {
      if (page > 1) return const DiscoverPage(<DiscoverTitle>[], page: 1, totalPages: 1);
      final List<PersonCredit> credits = await widget.source.personCredits(person);
      _roles
        ..clear()
        ..addEntries(credits.map((PersonCredit c) => MapEntry<String, String>(_key(c.title), c.role)));
      return DiscoverPage(
        credits.map((PersonCredit c) => c.title).toList(growable: false),
        page: 1,
        totalPages: 1,
      );
    }
    final DiscoverGenre? genre = widget.genre;
    if (genre != null) return widget.source.genreTitles(genre, page: page);
    return widget.source.list(_list, page: page);
  }

  Future<void> _loadGenres() async {
    if (_genres != null) return;
    try {
      final List<DiscoverGenre> genres = await widget.source.genres();
      if (!mounted) return;
      setState(() => _genres = genres);
    } on OverseerrException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  void _setMode(_Mode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    if (mode == _Mode.genres) _loadGenres();
  }

  void _openGenre(DiscoverGenre genre) => _push(DiscoverScreen(source: widget.source, genre: genre));

  void _push(Widget screen) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => screen,
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  void _setList(DiscoverList list) {
    if (list == _list) return;
    // A new list starts at its first row, not wherever the last one was left.
    if (_grid.scroll.hasClients) _grid.scroll.jumpTo(0);
    setState(() => _list = list);
    _loadFirst();
  }

  void _open(int index) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => DiscoverTitleScreen(
        source: widget.source,
        title: _titles[index],
        onChanged: _replace,
      ),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  void _openSearch() {
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) =>
          DiscoverSearchScreen(source: widget.source, onChanged: _replace),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  /// A request made on the title screen shows on its poster when you return.
  void _replace(DiscoverTitle updated) {
    if (!mounted) return;
    final int i = _titles.indexWhere((DiscoverTitle t) => _key(t) == _key(updated));
    if (i >= 0) setState(() => _titles[i] = updated);
  }

  @override
  Widget build(BuildContext context) {
    final DiscoverTitle? current =
        _titles.isEmpty ? null : _titles[_focused.clamp(0, _titles.length - 1)];
    return MiraBackdrop(
      tint: const Color(0xFF2A4A5E),
      horizontalScrim: false,
      child: Stack(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(MiraMetrics.safeH, MiraMetrics.safeV, MiraMetrics.safeH, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (widget.genre == null && widget.person == null)
                  MiraTopBar(activeTab: 'Discover', onTab: widget.onTab, networkLabel: widget.source.label)
                else
                  _BackCrumb(
                    label: widget.person != null ? 'Discover · Search' : 'Discover · Genres',
                  ),
                const SizedBox(height: 36),
                _header(),
                const SizedBox(height: 24),
                // The grid's viewport ends above the info bar. With the bar
                // overlapping it, a focused row was scrolled into "view"
                // underneath the bar and its caption hidden (found in the VM).
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: _InfoBar.height - 40),
                    child: _body(),
                  ),
                ),
              ],
            ),
          ),
          // Not over the genre grid: nothing focusable there is a title, so
          // the bar would be naming whatever was focused before the switch.
          if (current != null && _error == null && !_showingGenres)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _InfoBar(title: current, role: _roles[_key(current)]),
            ),
        ],
      ),
    );
  }

  Widget _header() {
    final DiscoverPerson? person = widget.person;
    if (person != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('SEERR · PERSON', style: MiraType.sectionLabel),
          const SizedBox(height: 10),
          Text(person.name, style: MiraType.screenTitle),
          if (person.knownForLabel.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text('Known for ${person.knownForLabel}',
                style: MiraType.meta.copyWith(fontSize: 20, color: MiraColors.textTertiary)),
          ],
        ],
      );
    }
    final DiscoverGenre? genre = widget.genre;
    if (genre != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text('SEERR · GENRES', style: MiraType.sectionLabel),
          const SizedBox(height: 10),
          Text(genre.name, style: MiraType.screenTitle),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('SEERR', style: MiraType.sectionLabel),
        const SizedBox(height: 10),
        Text(_mode == _Mode.genres ? 'Genres' : 'Discover', style: MiraType.screenTitle),
        const SizedBox(height: 20),
        Row(
          children: <Widget>[
            for (final DiscoverList list in DiscoverList.values) ...<Widget>[
              _Chip(
                label: _labels[list]!,
                active: _mode == _Mode.lists && list == _list,
                onSelect: () {
                  _setMode(_Mode.lists);
                  _setList(list);
                },
              ),
              const SizedBox(width: 16),
            ],
            _Chip(label: 'Genres', active: _mode == _Mode.genres, onSelect: () => _setMode(_Mode.genres)),
            const SizedBox(width: 16),
            _Chip(label: 'Search', active: false, onSelect: _openSearch),
          ],
        ),
      ],
    );
  }

  bool get _showingGenres =>
      _mode == _Mode.genres && widget.genre == null && widget.person == null;

  Widget _genreGrid() {
    final List<DiscoverGenre>? genres = _genres;
    if (genres == null) return const SizedBox.shrink();
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      const int columns = 4;
      const double tileHeight = 150;
      final double width = (c.maxWidth - _ringRoom * 2 - _gap * (columns - 1)) / columns;
      _genreFocus
        ..rowExtent = tileHeight + _gap
        ..mainAxisSpacing = _gap
        ..itemCount = genres.length;
      return GridView.builder(
        controller: _genreFocus.scroll,
        padding: EdgeInsets.fromLTRB(
          _ringRoom,
          _ringRoom,
          _ringRoom,
          _genreFocus.bottomPadding(c.maxHeight, top: _ringRoom, minimum: MiraMetrics.safeV),
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisSpacing: _gap,
          crossAxisSpacing: _gap,
          childAspectRatio: width / tileHeight,
        ),
        itemCount: genres.length,
        itemBuilder: (BuildContext context, int i) => DiscoverGenreTile(
          label: genres[i].name,
          autofocus: i == 0,
          focusNode: _genreFocus.nodeFor(i),
          onKey: (KeyEvent event) => _genreFocus.handleKey(i, event),
          onSelect: () => _openGenre(genres[i]),
        ),
      );
    });
  }

  Widget _body() {
    if (_error != null) {
      return Align(
        alignment: Alignment.topLeft,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(_error!, style: MiraType.body),
            const SizedBox(height: 24),
            MiraButton(label: 'Try again', kind: MiraButtonKind.primary, autofocus: true, onSelect: _loadFirst),
          ],
        ),
      );
    }
    if (_showingGenres) return _genreGrid();
    if (!_loaded) return const SizedBox.shrink();
    if (_titles.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text(
          widget.person == null
              ? 'Nothing here right now.'
              : 'Seerr lists no films for ${widget.person!.name}.',
          style: MiraType.body.copyWith(color: MiraColors.textTertiary),
        ),
      );
    }
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      const double spacing = 28;
      final double width = (c.maxWidth - _ringRoom * 2 - _gap * (_columns - 1)) / _columns;
      final double height = PosterTile.heightFor(width);
      _grid
        ..rowExtent = height + spacing
        ..mainAxisSpacing = spacing
        ..itemCount = _titles.length;
      return GridView.builder(
        controller: _grid.scroll,
        padding: EdgeInsets.fromLTRB(
          _ringRoom,
          _ringRoom,
          _ringRoom,
          _grid.bottomPadding(c.maxHeight, top: _ringRoom, minimum: _ringRoom),
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisSpacing: spacing,
          crossAxisSpacing: _gap,
          childAspectRatio: width / height,
        ),
        itemCount: _titles.length,
        itemBuilder: (BuildContext context, int i) {
          if (i >= _titles.length - _columns * 2) {
            WidgetsBinding.instance.addPostFrameCallback((Duration _) => _loadMore());
          }
          final DiscoverTitle title = _titles[i];
          // Observes focus only - the tile itself is a MiraFocusable - so the
          // info bar can name whatever is focused.
          return Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (bool has) {
              if (has && _focused != i) setState(() => _focused = i);
            },
            child: DiscoverTile(
              title: title,
              width: width,
              autofocus: i == 0,
              focusNode: _grid.nodeFor(i),
              onKey: (KeyEvent event) => _grid.handleKey(i, event),
              imageUrl: widget.source.posterFor(title),
              onSelect: () => _open(i),
            ),
          );
        },
      );
    });
  }
}

/// The breadcrumb on a pushed Discover screen, as a control rather than a
/// label.
///
/// Focusable on purpose, and it is the first thing built: a genre or person
/// screen has nothing else to focus until its grid arrives, and a screen whose
/// first frame has no focusable control is one the d-pad cannot touch - the
/// debug guard says so out loud. It doubles as a visible way back, which a
/// label never was.
class _BackCrumb extends StatelessWidget {
  const _BackCrumb({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: MiraFocusable(
        onSelect: () => Navigator.maybeOf(context)?.maybePop(),
        debugLabel: 'back:$label',
        builder: (BuildContext context, bool focused) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            '\u2039  $label',
            style: MiraType.nav.copyWith(
              color: focused ? MiraColors.textPrimary : MiraColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// A genre, as a plain card.
///
/// Deliberately not Films' genre tile: that one fans out three posters from
/// the library behind the name, and Seerr's genre list carries neither posters
/// nor counts - there are a thousand pages of Action. A name is the honest
/// amount of information here.
class DiscoverGenreTile extends StatelessWidget {
  const DiscoverGenreTile({
    super.key,
    required this.label,
    required this.onSelect,
    this.autofocus = false,
    this.focusNode,
    this.onKey,
  });

  final String label;
  final VoidCallback onSelect;
  final bool autofocus;
  final FocusNode? focusNode;
  final KeyEventResult Function(KeyEvent event)? onKey;

  @override
  Widget build(BuildContext context) {
    return MiraFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
      focusNode: focusNode,
      onKey: onKey,
      debugLabel: 'genre:$label',
      builder: (BuildContext context, bool focused) => Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 28),
        decoration: BoxDecoration(
          color: MiraColors.textPrimary.withValues(alpha: focused ? 0.09 : 0.05),
          borderRadius: MiraMetrics.borderRadius,
          border: focused ? null : Border.all(color: MiraColors.surfaceBorder),
        ),
        child: Text(
          label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: MiraType.tileTitle.copyWith(fontSize: 30),
        ),
      ),
    );
  }
}

/// A poster with its request state. Shares PosterTile's geometry so Discover
/// and Films line up exactly.
class DiscoverTile extends StatelessWidget {
  const DiscoverTile({
    required this.title,
    required this.width,
    required this.onSelect,
    this.imageUrl,
    this.autofocus = false,
    this.focusNode,
    this.onKey,
  });

  final DiscoverTitle title;
  final double width;
  final Uri? imageUrl;
  final VoidCallback onSelect;
  final bool autofocus;
  final FocusNode? focusNode;
  final KeyEventResult Function(KeyEvent event)? onKey;

  @override
  Widget build(BuildContext context) {
    final double height = width / MiraMetrics.posterAspect;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return MiraFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
      focusNode: focusNode,
      onKey: onKey,
      showRing: false,
      debugLabel: 'discover:${title.title}',
      builder: (BuildContext context, bool focused) => SizedBox(
        width: width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            MiraFocusRingBox(
              focused: focused,
              child: Container(
                width: width,
                height: height,
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  gradient: placeholderArt('${title.mediaType}${title.tmdbId}'),
                  borderRadius: MiraMetrics.borderRadius,
                  border: focused ? null : Border.all(color: MiraColors.hairline),
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    if (imageUrl != null)
                      Image.network(
                        imageUrl.toString(),
                        fit: BoxFit.cover,
                        cacheHeight: (height * dpr).round(),
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    if (_StatusBadge.labelFor(title) != null)
                      Positioned(top: 12, right: 12, child: _StatusBadge(title: title)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: PosterTile.gap),
            SizedBox(
              height: PosterTile.captionHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    title.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: focused ? MiraType.tileTitle : MiraType.tileTitleIdle,
                  ),
                  if (focused) ...<Widget>[
                    const SizedBox(height: 3),
                    Text(
                      describeTitle(title),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MiraType.tileTitleIdle.copyWith(color: MiraColors.accent, fontSize: 17),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Year, kind and whether it is here - the line under a focused poster and in
/// the info bar.
String describeTitle(DiscoverTitle t) {
  final String state = t.inLibrary
      ? 'in your library'
      : t.requestState == RequestState.pendingApproval
          ? 'waiting for approval'
          : t.isRequested
              ? 'requested'
              : 'not in your library';
  return <String>[
    if (t.year != null) '${t.year}',
    t.isMovie ? 'film' : 'series',
    state,
  ].join(' · ');
}

/// In the library, requested, or waiting for approval. Green for "you can
/// watch it"; plain white for the in-between states - gold is focus only, so
/// the design's gold PENDING badge is deliberately not reproduced.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.title});

  final DiscoverTitle title;

  static String? labelFor(DiscoverTitle t) {
    if (t.inLibrary) return 'IN LIBRARY';
    if (t.requestState == RequestState.pendingApproval) return 'PENDING';
    if (t.isRequested) return 'REQUESTED';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final Color color = title.inLibrary ? MiraColors.positive : MiraColors.textPrimary;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: MiraColors.background.withValues(alpha: 0.80),
        borderRadius: const BorderRadius.all(Radius.circular(17)),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Text(
        labelFor(title)!,
        style: MiraType.status.copyWith(fontSize: 14, letterSpacing: 0.84, color: color),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.active, required this.onSelect});

  final String label;
  final bool active;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return MiraFocusable(
      onSelect: onSelect,
      debugLabel: 'chip:$label',
      builder: (BuildContext context, bool focused) => Container(
        height: MiraMetrics.minControl,
        padding: const EdgeInsets.symmetric(horizontal: 30),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? MiraColors.textPrimary.withValues(alpha: 0.10) : null,
          borderRadius: MiraMetrics.borderRadius,
          border: active ? Border.all(color: MiraColors.textPrimary.withValues(alpha: 0.18)) : null,
        ),
        child: Text(
          label,
          style: MiraType.meta.copyWith(color: active ? MiraColors.textPrimary : MiraColors.textTertiary),
        ),
      ),
    );
  }
}

/// The focused title, and what OK and Back do for it.
class _InfoBar extends StatelessWidget {
  const _InfoBar({required this.title, this.role});

  static const double height = 172;

  final DiscoverTitle title;

  /// On a person's screen, what they did on this title - "Director", or the
  /// character played. The whole point of the screen is that the grid mixes
  /// acting and directing, so each poster has to say which it is.
  final String? role;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.fromLTRB(MiraMetrics.safeH, 0, MiraMetrics.safeH, 46),
      alignment: Alignment.bottomCenter,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: <Color>[
            MiraColors.background.withValues(alpha: 0.98),
            MiraColors.background.withValues(alpha: 0.86),
            MiraColors.background.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.48, 1],
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Flexible(
                  child: Text(
                    title.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MiraType.tileTitle.copyWith(fontSize: 30),
                  ),
                ),
                const SizedBox(width: 18),
                Text(
                  role == null ? describeTitle(title) : '$role  ·  ${describeTitle(title)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MiraType.meta.copyWith(fontSize: 20, color: MiraColors.textTertiary),
                ),
              ],
            ),
          ),
          _hint('OK', 'Details', MiraColors.accent),
          const SizedBox(width: 30),
          _hint('BACK', 'Home', MiraColors.textFaint),
        ],
      ),
    );
  }

  Widget _hint(String key, String label, Color ring) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(21)),
            border: Border.all(color: ring, width: 2),
          ),
          child: Text(key, style: MiraType.status.copyWith(fontSize: 14, letterSpacing: 0.8, color: ring)),
        ),
        const SizedBox(width: 13),
        Text(label, style: MiraType.status.copyWith(fontSize: 20, color: MiraColors.textPrimary)),
      ],
    );
  }
}
