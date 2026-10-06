import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/tokens.dart';
import '../input/focus_debug.dart';
import '../input/mira_focusable.dart';
import '../overseerr/discover_source.dart';
import '../overseerr/overseerr_client.dart';
import 'discover_screen.dart' show DiscoverScreen, DiscoverTile;
import 'discover_title_screen.dart';
import 'widgets/chrome.dart';
import 'widgets/grid_focus.dart';
import 'widgets/search_keyboard.dart';
import 'widgets/poster.dart';

/// Search Seerr for a specific title, with an on-screen keyboard.
///
/// The keyboard is the d-pad path: every key is a MiraFocusable, OK types it.
/// A physical keyboard types too, from anywhere on the screen - the VM and a
/// Bluetooth keyboard on the couch both have one. Results update as the query
/// changes, after a pause, so holding a key does not fire a request per letter.
class DiscoverSearchScreen extends StatefulWidget {
  const DiscoverSearchScreen({super.key, required this.source, this.onChanged});

  final DiscoverSource source;

  /// Told when a title is requested or cancelled from a result, so Discover's
  /// own grid is right on return.
  final ValueChanged<DiscoverTitle>? onChanged;

  @override
  State<DiscoverSearchScreen> createState() => _DiscoverSearchScreenState();
}

class _DiscoverSearchScreenState extends State<DiscoverSearchScreen> {
  static const Duration _debounce = Duration(milliseconds: 450);
  static const int _minLength = 2;
  static const int _columns = 4;
  static const double _gap = 28;

  String _query = '';
  List<DiscoverTitle> _results = const <DiscoverTitle>[];
  List<DiscoverPerson> _people = const <DiscoverPerson>[];
  bool _searching = false;
  bool _searched = false;
  String? _error;
  Timer? _timer;

  /// Bumped per query, so a slow answer for "odys" never replaces "odyssey".
  int _generation = 0;

  double get _ringRoom => MiraFocusRing.reach + 2;

  /// Left from the first column goes back to the keyboard, so no left wrap.
  final GridFocus _grid = GridFocus(columns: _columns, debugName: 'result', wrapLeft: false);

  @override
  void initState() {
    super.initState();
    debugAssertReachableAfterFrame(context, screen: 'DiscoverSearchScreen');
  }

  @override
  void dispose() {
    _timer?.cancel();
    _grid.dispose();
    super.dispose();
  }

  void _type(String s) {
    setState(() => _query += s);
    _schedule();
  }

  void _backspace() {
    if (_query.isEmpty) return;
    setState(() => _query = _query.substring(0, _query.length - 1));
    _schedule();
  }

  void _clear() {
    if (_query.isEmpty) return;
    setState(() => _query = '');
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    final String q = _query.trim();
    if (q.length < _minLength) {
      _generation++;
      setState(() {
        _results = const <DiscoverTitle>[];
        _people = const <DiscoverPerson>[];
        _searching = false;
        _searched = false;
        _error = null;
      });
      return;
    }
    _timer = Timer(_debounce, () => _search(q));
  }

  Future<void> _search(String q) async {
    final int generation = ++_generation;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      // One request, both halves: Seerr returns films, series and people
      // together and charges the same round trip either way.
      final ({DiscoverPage titles, List<DiscoverPerson> people}) found =
          await widget.source.searchAll(q);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = found.titles.results;
        _people = found.people;
        _searching = false;
        _searched = true;
      });
    } on OverseerrException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e.message;
        _searching = false;
      });
    }
  }

  void _openPerson(DiscoverPerson person) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) =>
          DiscoverScreen(source: widget.source, person: person),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  void _open(DiscoverTitle title) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => DiscoverTitleScreen(
        source: widget.source,
        title: title,
        onChanged: (DiscoverTitle updated) {
          if (mounted) {
            setState(() {
              _results = <DiscoverTitle>[
                for (final DiscoverTitle t in _results)
                  t.tmdbId == updated.tmdbId && t.mediaType == updated.mediaType ? updated : t,
              ];
            });
          }
          widget.onChanged?.call(updated);
        },
      ),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return MiraTypeAhead(
      onType: _type,
      onDelete: _backspace,
      child: MiraBackdrop(
        tint: const Color(0xFF2A4A5E),
        horizontalScrim: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(MiraMetrics.safeH, MiraMetrics.safeV, MiraMetrics.safeH, MiraMetrics.safeV),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Discover', style: MiraType.nav.copyWith(color: MiraColors.textSecondary)),
              const SizedBox(height: 28),
              const Text('SEARCH SEERR', style: MiraType.sectionLabel),
              const SizedBox(height: 12),
              MiraQueryField(query: _query),
              const SizedBox(height: 12),
              Text(
                'OK types the focused key   ·   people and titles both match   ·   BACK returns to Discover',
                style: MiraType.meta.copyWith(fontSize: 17, color: MiraColors.textTertiary),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    MiraKeyboard(onType: _type, onDelete: _backspace, onClear: _clear),
                    const SizedBox(width: 64),
                    Expanded(child: _resultsArea()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _message(String text) => Align(
        alignment: Alignment.topLeft,
        child: Text(text, style: MiraType.body.copyWith(color: MiraColors.textTertiary)),
      );

  Widget _resultsArea() {
    if (_query.trim().length < _minLength) {
      return _message('Type at least two letters. Results appear as you type.');
    }
    if (_error != null) return _message(_error!);
    if (_results.isEmpty && _people.isEmpty) {
      return _message(_searching || !_searched ? 'Searching…' : 'Nothing on Seerr matches "${_query.trim()}".');
    }
    if (_people.isEmpty) return _titleGrid();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Text('PEOPLE', style: MiraType.sectionLabel),
        const SizedBox(height: 12),
        _PeopleRow(people: _people, onSelect: _openPerson),
        const SizedBox(height: 26),
        if (_results.isNotEmpty) ...<Widget>[
          const Text('TITLES', style: MiraType.sectionLabel),
          const SizedBox(height: 12),
          Expanded(child: _titleGrid()),
        ],
      ],
    );
  }

  Widget _titleGrid() {
    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      const double spacing = 24;
      final double width = (c.maxWidth - _ringRoom * 2 - _gap * (_columns - 1)) / _columns;
      final double height = PosterTile.heightFor(width);
      _grid
        ..rowExtent = height + spacing
        ..mainAxisSpacing = spacing
        ..itemCount = _results.length;
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
        itemCount: _results.length,
        itemBuilder: (BuildContext context, int i) => DiscoverTile(
          title: _results[i],
          width: width,
          focusNode: _grid.nodeFor(i),
          onKey: (KeyEvent event) => _grid.handleKey(i, event),
          imageUrl: widget.source.posterFor(_results[i]),
          onSelect: () => _open(_results[i]),
        ),
      );
    });
  }
}

/// The people a query matched, as a scrolling row of cards.
///
/// Above the titles rather than mixed in with them: a person is a different
/// kind of answer - OK on one opens everything they made, not a request.
class _PeopleRow extends StatelessWidget {
  const _PeopleRow({required this.people, required this.onSelect});

  static const double height = 104;

  final List<DiscoverPerson> people;
  final ValueChanged<DiscoverPerson> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        itemCount: people.length,
        separatorBuilder: (BuildContext context, int i) => const SizedBox(width: 16),
        itemBuilder: (BuildContext context, int i) {
          final DiscoverPerson person = people[i];
          return MiraFocusable(
            onSelect: () => onSelect(person),
            debugLabel: 'person:${person.name}',
            revealMargin: const EdgeInsets.symmetric(horizontal: 40),
            builder: (BuildContext context, bool focused) => Container(
              width: 320,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                color: MiraColors.textPrimary.withValues(alpha: focused ? 0.09 : 0.05),
                borderRadius: MiraMetrics.borderRadius,
                border: focused ? null : Border.all(color: MiraColors.surfaceBorder),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MiraType.tileTitle.copyWith(fontSize: 26),
                  ),
                  if (person.knownForLabel.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      person.knownForLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MiraType.meta.copyWith(fontSize: 17, color: MiraColors.textTertiary),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
