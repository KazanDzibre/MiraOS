import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/tokens.dart';
import '../input/focus_debug.dart';
import '../input/mira_focusable.dart';
import '../overseerr/discover_source.dart';
import '../overseerr/overseerr_client.dart';
import 'discover_screen.dart' show DiscoverTile;
import 'discover_title_screen.dart';
import 'widgets/chrome.dart';
import 'widgets/grid_focus.dart';
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

  /// Characters a physical keyboard may type. Space is deliberately absent:
  /// it is OK on the bench keyboard, and the on-screen Space key covers it.
  static final RegExp _typeable = RegExp(r"[A-Za-z0-9'\-:&.,!?]");

  String _query = '';
  List<DiscoverTitle> _results = const <DiscoverTitle>[];
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
      final DiscoverPage page = await widget.source.search(q);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = page.results;
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

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    final String? ch = event.character;
    if (ch != null && ch.length == 1 && _typeable.hasMatch(ch)) {
      _type(ch.toLowerCase());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
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
              _QueryField(query: _query),
              const SizedBox(height: 12),
              Text(
                'OK types the focused key   ·   BACK returns to Discover',
                style: MiraType.meta.copyWith(fontSize: 17, color: MiraColors.textTertiary),
              ),
              const SizedBox(height: 32),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _Keyboard(onType: _type, onDelete: _backspace, onClear: _clear),
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
      return _message(_searching || !_searched ? 'Searching…' : 'Nothing on Seerr matches "${_query.trim()}".');
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

/// The query as typed, large enough to read from the couch, with a caret.
class _QueryField extends StatelessWidget {
  const _QueryField({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final bool empty = query.isEmpty;
    return Container(
      height: 84,
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MiraColors.outline, width: 2)),
      ),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              empty ? 'Type a title' : query,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MiraType.screenTitle.copyWith(
                fontSize: 48,
                color: empty ? MiraColors.textFaint : MiraColors.textPrimary,
              ),
            ),
          ),
          if (!empty) ...<Widget>[
            const SizedBox(width: 6),
            Container(width: 4, height: 52, color: MiraColors.textPrimary),
          ],
        ],
      ),
    );
  }
}

/// a-z and 0-9 in remote-sized keys, then Space, Delete and Clear.
class _Keyboard extends StatelessWidget {
  const _Keyboard({required this.onType, required this.onDelete, required this.onClear});

  static const int columns = 6;
  static const String _characters = 'abcdefghijklmnopqrstuvwxyz1234567890';

  final ValueChanged<String> onType;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];
    for (int start = 0; start < _characters.length; start += columns) {
      final String row = _characters.substring(start, (start + columns).clamp(0, _characters.length));
      rows.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < row.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: _Key.gap),
            _Key(
              label: row[i].toUpperCase(),
              autofocus: start == 0 && i == 0,
              onSelect: () => onType(row[i]),
            ),
          ],
        ],
      ));
    }
    rows.add(Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Key(label: 'Space', span: 2, onSelect: () => onType(' ')),
        const SizedBox(width: _Key.gap),
        _Key(label: 'Delete', span: 2, onSelect: onDelete),
        const SizedBox(width: _Key.gap),
        _Key(label: 'Clear', span: 2, onSelect: onClear),
      ],
    ));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: _Key.gap),
          rows[i],
        ],
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onSelect, this.span = 1, this.autofocus = false});

  /// Never smaller than a control: the remote is imprecise and so is the
  /// gyro pointer.
  static const double size = MiraMetrics.minControl;
  static const double gap = 10;

  final String label;
  final VoidCallback onSelect;
  final int span;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return MiraFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
      debugLabel: 'key:$label',
      builder: (BuildContext context, bool focused) => Container(
        width: size * span + gap * (span - 1),
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused ? MiraColors.textPrimary : MiraColors.surface,
          borderRadius: MiraMetrics.borderRadius,
          border: Border.all(color: MiraColors.surfaceBorder),
        ),
        child: Text(
          label,
          style: MiraType.control.copyWith(
            fontSize: span == 1 ? 24 : 19,
            color: focused ? MiraColors.background : MiraColors.textPrimary,
          ),
        ),
      ),
    );
  }
}
