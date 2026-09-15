import 'package:flutter/widgets.dart';

import '../core/library_source.dart';
import '../core/tokens.dart';
import '../input/focus_debug.dart';
import '../input/mira_focusable.dart';
import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';
import 'widgets/chrome.dart';
import 'widgets/focus_artwork.dart';
import 'widgets/grid_focus.dart';
import 'widgets/mira_button.dart';
import 'widgets/poster.dart';

enum _Mode { all, genres }

/// What a library grid shows: every film, or the shows of one library.
///
/// The grid, the genres view and paging are the same for both, so a shows
/// library is this screen with a different catalog rather than a copy of it.
class Catalog {
  const Catalog({
    required this.title,
    required this.singular,
    required this.plural,
    required this.debugName,
    required this.count,
    required this.page,
    required this.genres,
  });

  factory Catalog.films(LibrarySource source) => Catalog(
        title: 'Films',
        singular: 'film',
        plural: 'films',
        debugName: 'films',
        count: (String? genre) => source.movieCount(genre: genre),
        page: (int start, int limit, String? genre) =>
            source.movies(startIndex: start, limit: limit, genre: genre),
        genres: source.genres,
      );

  /// One shows library, titled as it is on the server - "Shows", "Anime".
  factory Catalog.shows(LibrarySource source, LibraryView library) => Catalog(
        title: library.name,
        singular: 'show',
        plural: 'shows',
        debugName: 'shows',
        count: (String? genre) => source.showCount(library, genre: genre),
        page: (int start, int limit, String? genre) =>
            source.shows(library, startIndex: start, limit: limit, genre: genre),
        genres: () => source.showGenres(library),
      );

  /// The screen title, and the tab it lives under.
  final String title;
  final String singular;
  final String plural;

  /// Prefix of the grid tiles' focus labels, as tests find them.
  final String debugName;

  final Future<int> Function(String? genre) count;
  final Future<List<MediaItem>> Function(int startIndex, int limit, String? genre) page;
  final Future<List<GenreCount>> Function() genres;

  String countLabel(int n) => '$n ${n == 1 ? singular : plural}';
}

/// A library tab: every film (or show), or the genres view, switched by the
/// chips.
///
/// A single genre's titles open as a pushed screen of this same widget with
/// [genre] set, so Back returns to the genres view through the normal
/// navigator rule instead of a special case here.
class FilmsScreen extends StatefulWidget {
  const FilmsScreen({
    super.key,
    required this.source,
    required this.onOpen,
    this.onTab,
    this.genre,
    this.catalog,
  });

  final LibrarySource source;
  final ValueChanged<MediaItem> onOpen;
  final ValueChanged<String>? onTab;

  /// Set when this screen shows one genre's titles.
  final String? genre;

  /// Films when null.
  final Catalog? catalog;

  @override
  State<FilmsScreen> createState() => _FilmsScreenState();
}

class _FilmsScreenState extends State<FilmsScreen> {
  static const int _page = 60;
  static const int _columns = 6;
  static const int _genreColumns = 4;
  static const double _gap = 32;

  late final Catalog _catalog = widget.catalog ?? Catalog.films(widget.source);

  _Mode _mode = _Mode.all;
  final List<MediaItem> _items = <MediaItem>[];
  int _total = 0;
  bool _loaded = false;
  bool _loadingMore = false;
  String? _error;
  List<GenreCount>? _genres;

  /// The poster with focus, whose backdrop is drawn behind the grid.
  MediaItem? _focused;

  late final GridFocus _filmFocus = GridFocus(columns: _columns, debugName: _catalog.debugName);
  final GridFocus _genreFocus = GridFocus(columns: _genreColumns, debugName: 'genres');

  double get _ringRoom => MiraFocusRing.reach + 2;

  @override
  void initState() {
    super.initState();
    _loadFirst();
    debugAssertReachableAfterFrame(context, screen: 'FilmsScreen');
  }

  @override
  void dispose() {
    _filmFocus.dispose();
    _genreFocus.dispose();
    super.dispose();
  }

  Future<void> _loadFirst() async {
    setState(() {
      _loaded = false;
      _error = null;
      _items.clear();
    });
    try {
      final int total = await _catalog.count(widget.genre);
      final List<MediaItem> first = await _catalog.page(0, _page, widget.genre);
      if (!mounted) return;
      setState(() {
        _total = total;
        _items.addAll(first);
        _loaded = true;
      });
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loaded = true;
      });
    }
  }

  /// Pages in as focus approaches the end, so a large library never loads all
  /// at once and never makes the remote wait at the bottom of a row.
  Future<void> _loadMore() async {
    if (_loadingMore || _items.length >= _total) return;
    _loadingMore = true;
    try {
      final List<MediaItem> more = await _catalog.page(_items.length, _page, widget.genre);
      if (!mounted) return;
      setState(() => _items.addAll(more));
    } on JellyfinException {
      // Keep what is on screen; the next approach to the end retries.
    } finally {
      _loadingMore = false;
    }
  }

  Future<void> _setMode(_Mode mode) async {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    if (mode == _Mode.genres && _genres == null) {
      try {
        final List<GenreCount> genres = await _catalog.genres();
        if (!mounted) return;
        setState(() => _genres = genres);
      } on JellyfinException catch (e) {
        if (!mounted) return;
        setState(() => _error = e.message);
      }
    }
  }

  void _openGenre(GenreCount genre) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => FilmsScreen(
        source: widget.source,
        onOpen: widget.onOpen,
        genre: genre.name,
        catalog: _catalog,
      ),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  String get _title {
    if (widget.genre != null) return widget.genre!;
    return _mode == _Mode.genres ? 'Genres' : _catalog.title;
  }

  String get _count {
    if (_mode == _Mode.genres && widget.genre == null) {
      final int? n = _genres?.length;
      return n == null ? '' : '$n genres';
    }
    if (!_loaded) return '';
    return _catalog.countLabel(_total);
  }

  @override
  Widget build(BuildContext context) {
    final MediaItem? focused = _focused;
    return MiraBackdrop(
      tint: const Color(0xFF22454A),
      horizontalScrim: false,
      // Dimmed: here the posters and grey captions sit on it, not text on a
      // scrim. At 0.45 a bright backdrop (2001's white corridor) washed out
      // the film count and captions in the VM.
      art: FocusArtwork(
        url: _mode == _Mode.all && focused != null
            ? widget.source.backdropFor(focused, maxHeight: 1080)
            : null,
        opacity: 0.3,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(MiraMetrics.safeH, MiraMetrics.safeV, MiraMetrics.safeH, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.genre == null)
              MiraTopBar(activeTab: _catalog.title, onTab: widget.onTab, networkLabel: widget.source.label)
            else
              _Breadcrumb(label: '${_catalog.title} · Genres'),
            const SizedBox(height: 40),
            _header(),
            const SizedBox(height: 28),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final Widget title = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Text(_title, style: MiraType.screenTitle),
        const SizedBox(width: 22),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(_count, style: MiraType.meta.copyWith(fontSize: 20, color: MiraColors.textTertiary)),
        ),
      ],
    );
    if (widget.genre != null) return title;
    // The switch sits on the left, directly above the grid's first column. At
    // the far right, Up from the grid skipped it for the nearer tabs, and on a
    // real remote Genres was unreachable without a detour (found in the VM).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        title,
        const SizedBox(height: 22),
        Row(
          children: <Widget>[
            _Chip(label: 'All ${_catalog.plural}', active: _mode == _Mode.all, onSelect: () => _setMode(_Mode.all)),
            const SizedBox(width: 16),
            _Chip(label: 'Genres', active: _mode == _Mode.genres, onSelect: () => _setMode(_Mode.genres)),
          ],
        ),
      ],
    );
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
    if (_mode == _Mode.genres && widget.genre == null) return _genreGrid();
    if (!_loaded) return const SizedBox.shrink();
    if (_items.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('No ${_catalog.plural} here yet.', style: MiraType.body.copyWith(color: MiraColors.textTertiary)),
      );
    }
    return _filmGrid();
  }

  Widget _filmGrid() {
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      const double spacing = 28;
      final double width = (c.maxWidth - _ringRoom * 2 - _gap * (_columns - 1)) / _columns;
      final double height = PosterTile.heightFor(width);
      _filmFocus
        ..rowExtent = height + spacing
        ..mainAxisSpacing = spacing
        ..itemCount = _items.length;
      return GridView.builder(
        controller: _filmFocus.scroll,
        padding: EdgeInsets.fromLTRB(
          _ringRoom,
          _ringRoom,
          _ringRoom,
          _filmFocus.bottomPadding(c.maxHeight, top: _ringRoom, minimum: MiraMetrics.safeV),
        ),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisSpacing: spacing,
          crossAxisSpacing: _gap,
          childAspectRatio: width / height,
        ),
        itemCount: _items.length,
        itemBuilder: (BuildContext context, int i) {
          if (i >= _items.length - _columns * 2) {
            WidgetsBinding.instance.addPostFrameCallback((Duration _) => _loadMore());
          }
          final MediaItem item = _items[i];
          return Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (bool focused) {
              if (focused && _focused?.id != item.id) setState(() => _focused = item);
            },
            child: PosterTile(
              item: item,
              width: width,
              autofocus: i == 0,
              focusNode: _filmFocus.nodeFor(i),
              onKey: (KeyEvent event) => _filmFocus.handleKey(i, event),
              imageUrl: widget.source.posterFor(item, maxHeight: height.round()),
              onSelect: () => widget.onOpen(item),
            ),
          );
        },
      );
    });
  }

  Widget _genreGrid() {
    final List<GenreCount>? genres = _genres;
    if (genres == null) return const SizedBox.shrink();
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      const double tileHeight = 220;
      final double width = (c.maxWidth - _ringRoom * 2 - _gap * (_genreColumns - 1)) / _genreColumns;
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
          crossAxisCount: _genreColumns,
          mainAxisSpacing: _gap,
          crossAxisSpacing: _gap,
          childAspectRatio: width / tileHeight,
        ),
        itemCount: genres.length,
        itemBuilder: (BuildContext context, int i) => _GenreTile(
          genre: genres[i],
          countLabel: _catalog.countLabel(genres[i].count),
          autofocus: i == 0,
          focusNode: _genreFocus.nodeFor(i),
          onKey: (KeyEvent event) => _genreFocus.handleKey(i, event),
          onSelect: () => _openGenre(genres[i]),
        ),
      );
    });
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

class _GenreTile extends StatelessWidget {
  const _GenreTile({
    required this.genre,
    required this.countLabel,
    required this.onSelect,
    this.autofocus = false,
    this.focusNode,
    this.onKey,
  });

  final GenreCount genre;

  /// "12 films", "3 shows".
  final String countLabel;
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
      debugLabel: 'genre:${genre.name}',
      builder: (BuildContext context, bool focused) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: MiraColors.textPrimary.withValues(alpha: focused ? 0.09 : 0.05),
          borderRadius: MiraMetrics.borderRadius,
          border: focused ? null : Border.all(color: MiraColors.surfaceBorder),
        ),
        child: Stack(
          children: <Widget>[
            // Laid out at its real overlapped width. A translated Row keeps its
            // un-overlapped width, so the fan drifted left into the title.
            Positioned(
              right: 24,
              top: 22,
              child: SizedBox(
                width: 60 + 2 * 36,
                height: 90,
                child: Stack(
                  children: <Widget>[
                    for (int k = 0; k < 3; k++)
                      Positioned(
                        left: k * 36.0,
                        child: Container(
                          width: 60,
                          height: 90,
                          decoration: BoxDecoration(
                            gradient: placeholderArt('${genre.name}$k'),
                            borderRadius: const BorderRadius.all(Radius.circular(4)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 28,
              bottom: 26,
              right: 28,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    genre.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MiraType.screenTitle.copyWith(
                      fontSize: 30,
                      color: focused ? MiraColors.textPrimary : MiraColors.textPrimary.withValues(alpha: 0.86),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    countLabel,
                    style: MiraType.meta.copyWith(fontSize: 18, color: MiraColors.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where Back goes, shown but not a control: the remote's Back button is how
/// you get there, so a focusable arrow here would be a second, worse path.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        CustomPaint(size: const Size.square(26), painter: _ChevronPainter()),
        const SizedBox(width: 14),
        Text(label, style: MiraType.nav.copyWith(color: MiraColors.textSecondary)),
      ],
    );
  }
}

class _ChevronPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 24;
    canvas.drawPath(
      Path()
        ..moveTo(14.6 * s, 5.4 * s)
        ..lineTo(7.8 * s, 12 * s)
        ..lineTo(14.6 * s, 18.6 * s),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * s
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = MiraColors.textSecondary,
    );
  }

  @override
  bool shouldRepaint(_ChevronPainter oldDelegate) => false;
}
