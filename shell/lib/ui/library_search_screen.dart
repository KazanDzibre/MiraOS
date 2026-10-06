import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/library_source.dart';
import '../core/tokens.dart';
import '../input/focus_debug.dart';
import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';
import 'films_screen.dart' show Catalog;
import 'widgets/chrome.dart';
import 'widgets/grid_focus.dart';
import 'widgets/poster.dart';
import 'widgets/search_keyboard.dart';

/// Search one library by title, with the same on-screen keyboard Discover
/// uses.
///
/// Scrolling a 359-title grid to reach one film is the thing this replaces, so
/// it searches the *server* rather than filtering the page the grid happens to
/// have loaded - a title forty rows down is found by its second letter.
class LibrarySearchScreen extends StatefulWidget {
  const LibrarySearchScreen({
    super.key,
    required this.source,
    required this.catalog,
    required this.onOpen,
  });

  final LibrarySource source;
  final Catalog catalog;
  final ValueChanged<MediaItem> onOpen;

  @override
  State<LibrarySearchScreen> createState() => _LibrarySearchScreenState();
}

class _LibrarySearchScreenState extends State<LibrarySearchScreen> {
  static const Duration _debounce = Duration(milliseconds: 350);
  static const int _minLength = 2;
  static const int _columns = 5;
  static const double _gap = 28;

  String _query = '';
  List<MediaItem> _results = const <MediaItem>[];
  bool _searching = false;
  bool _searched = false;
  String? _error;
  Timer? _timer;

  /// Bumped per query, so a slow answer for "du" never replaces "dune".
  int _generation = 0;

  double get _ringRoom => MiraFocusRing.reach + 2;

  /// Left from the first column goes back to the keyboard, so no left wrap.
  final GridFocus _grid = GridFocus(columns: _columns, debugName: 'found', wrapLeft: false);

  @override
  void initState() {
    super.initState();
    debugAssertReachableAfterFrame(context, screen: 'LibrarySearchScreen');
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
        _results = const <MediaItem>[];
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
      final List<MediaItem> found = await widget.catalog.search(q);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = found;
        _searching = false;
        _searched = true;
      });
    } on JellyfinException catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = e.message;
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MiraTypeAhead(
      onType: _type,
      onDelete: _backspace,
      child: MiraBackdrop(
        tint: const Color(0xFF22454A),
        horizontalScrim: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              MiraMetrics.safeH, MiraMetrics.safeV, MiraMetrics.safeH, MiraMetrics.safeV),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('${widget.catalog.title} · Search',
                  style: MiraType.nav.copyWith(color: MiraColors.textSecondary)),
              const SizedBox(height: 28),
              Text('SEARCH ${widget.catalog.title.toUpperCase()}', style: MiraType.sectionLabel),
              const SizedBox(height: 12),
              MiraQueryField(query: _query, placeholder: 'Type a ${widget.catalog.singular}'),
              const SizedBox(height: 12),
              Text(
                'OK types the focused key   ·   BACK returns to ${widget.catalog.title}',
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
    if (_results.isEmpty) {
      return _message(_searching || !_searched
          ? 'Searching…'
          : 'No ${widget.catalog.plural} match "${_query.trim()}".');
    }
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
        itemBuilder: (BuildContext context, int i) => PosterTile(
          item: _results[i],
          width: width,
          focusNode: _grid.nodeFor(i),
          onKey: (KeyEvent event) => _grid.handleKey(i, event),
          imageUrl: widget.source.posterFor(_results[i], maxHeight: 480),
          onSelect: () => widget.onOpen(_results[i]),
        ),
      );
    });
  }
}
