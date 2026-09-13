import 'package:flutter/widgets.dart';

import '../core/tokens.dart';
import '../input/focus_debug.dart';
import '../input/mira_focusable.dart';
import '../overseerr/discover_source.dart';
import '../overseerr/overseerr_client.dart';
import 'discover_search_screen.dart';
import 'discover_title_screen.dart';
import 'widgets/chrome.dart';
import 'widgets/mira_button.dart';
import 'widgets/poster.dart';

/// The Discover tab: what to request next, from Seerr.
///
/// Follows design/Overseerr.dc.html with two deliberate departures. The list
/// chips sit on the left above the grid's first column, where Up from the grid
/// lands - at the far right the directional policy skipped them, as it did on
/// Films. And OK opens the title rather than requesting it: a request spends
/// the household's disk and bandwidth, so it should never be one stray press.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key, required this.source, this.onTab});

  final DiscoverSource source;
  final ValueChanged<String>? onTab;

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

  double get _ringRoom => MiraFocusRing.reach + 2;

  @override
  void initState() {
    super.initState();
    _loadFirst();
    debugAssertReachableAfterFrame(context, screen: 'DiscoverScreen');
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
      final DiscoverPage page = await widget.source.list(_list);
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
      final DiscoverPage page = await widget.source.list(_list, page: _page + 1);
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

  void _setList(DiscoverList list) {
    if (list == _list) return;
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
                MiraTopBar(activeTab: 'Discover', onTab: widget.onTab, networkLabel: widget.source.label),
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
          if (current != null && _error == null)
            Positioned(left: 0, right: 0, bottom: 0, child: _InfoBar(title: current)),
        ],
      ),
    );
  }

  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('SEERR', style: MiraType.sectionLabel),
        const SizedBox(height: 10),
        Text('Discover', style: MiraType.screenTitle),
        const SizedBox(height: 20),
        Row(
          children: <Widget>[
            for (final DiscoverList list in DiscoverList.values) ...<Widget>[
              _Chip(label: _labels[list]!, active: list == _list, onSelect: () => _setList(list)),
              const SizedBox(width: 16),
            ],
            const SizedBox(width: 16),
            _Chip(label: 'Search', active: false, onSelect: _openSearch),
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
    if (!_loaded) return const SizedBox.shrink();
    if (_titles.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Text('Nothing here right now.', style: MiraType.body.copyWith(color: MiraColors.textTertiary)),
      );
    }
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      final double width = (c.maxWidth - _ringRoom * 2 - _gap * (_columns - 1)) / _columns;
      final double height = PosterTile.heightFor(width);
      return GridView.builder(
        padding: EdgeInsets.fromLTRB(_ringRoom, _ringRoom, _ringRoom, _ringRoom),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _columns,
          mainAxisSpacing: 28,
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
              imageUrl: widget.source.posterFor(title),
              onSelect: () => _open(i),
            ),
          );
        },
      );
    });
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
  });

  final DiscoverTitle title;
  final double width;
  final Uri? imageUrl;
  final VoidCallback onSelect;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final double height = width / MiraMetrics.posterAspect;
    final double dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    return MiraFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
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
  const _InfoBar({required this.title});

  static const double height = 172;

  final DiscoverTitle title;

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
                Text(describeTitle(title), style: MiraType.meta.copyWith(fontSize: 20, color: MiraColors.textTertiary)),
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
