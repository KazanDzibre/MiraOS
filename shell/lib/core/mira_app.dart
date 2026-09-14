import 'package:flutter/widgets.dart';

import '../input/pointer_mode.dart';
import '../overseerr/discover_source.dart';
import '../ui/discover_screen.dart';
import '../input/remote.dart';
import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';
import '../ui/detail_screen.dart';
import '../ui/films_screen.dart';
import '../ui/home_screen.dart';
import '../ui/player_screen.dart';
import '../ui/state_screen.dart';
import '../ui/widgets/chrome.dart';
import 'library_source.dart';
import 'tokens.dart';
import 'track_choice.dart';

/// The root of Mira Shell.
///
/// WidgetsApp rather than MaterialApp: nothing here is Material, and its
/// default shortcuts are what map the d-pad's arrow keys onto directional
/// focus traversal - which is the entire navigation model.
///
/// Back is one rule everywhere: on a pushed screen it pops; on a tab other
/// than Home it returns Home; on Home it does nothing.
class MiraApp extends StatefulWidget {
  const MiraApp({super.key, required this.source, this.discover});

  final LibrarySource source;

  /// Seerr, when configured. Without it Discover explains what is missing.
  final DiscoverSource? discover;

  @override
  State<MiraApp> createState() => _MiraAppState();
}

class _MiraAppState extends State<MiraApp> {
  final PointerModeController _pointer = PointerModeController();
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();

  /// Bumped whenever a pushed screen closes. Watching, marking watched or
  /// clearing progress all change Continue Watching, and Home must show that
  /// the moment you are back - not after a tab switch.
  final ValueNotifier<int> _libraryChanged = ValueNotifier<int>(0);

  @override
  void dispose() {
    _pointer.dispose();
    _libraryChanged.dispose();
    super.dispose();
  }

  Route<void> _route(WidgetBuilder builder) {
    return PageRouteBuilder<void>(
      transitionDuration: MiraMotion.screen,
      reverseTransitionDuration: MiraMotion.screen,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => builder(c),
      transitionsBuilder: (BuildContext c, Animation<double> a, Animation<double> b, Widget child) =>
          FadeTransition(opacity: a, child: child),
    );
  }

  Future<void> _openDetail(MediaItem item) async {
    await _navigator.currentState?.push(_route((BuildContext _) => DetailScreen(
          source: widget.source,
          item: item,
          onPlay: _openPlayer,
        )));
    _libraryChanged.value++;
  }

  Future<void> _openPlayer(
    MediaItem item, {
    required bool fromStart,
    TrackChoice? choice,
  }) async {
    await _navigator.currentState?.push(_route((BuildContext _) => PlayerScreen(
          source: widget.source,
          item: item,
          fromStart: fromStart,
          choice: choice,
        )));
    _libraryChanged.value++;
  }

  @override
  Widget build(BuildContext context) {
    return WidgetsApp(
      navigatorKey: _navigator,
      title: 'Mira',
      color: MiraColors.background,
      debugShowCheckedModeBanner: false,
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) => PageRouteBuilder<T>(
        settings: settings,
        pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => builder(c),
      ),
      home: _Root(
        source: widget.source,
        discover: widget.discover,
        onOpen: _openDetail,
        onPlay: _openPlayer,
        libraryChanged: _libraryChanged,
      ),
      builder: (BuildContext context, Widget? child) {
        return PointerMode(
          controller: _pointer,
          child: RemoteShortcuts(
            child: Actions(
              actions: <Type, Action<Intent>>{
                BackIntent: CallbackAction<BackIntent>(onInvoke: (BackIntent _) {
                  _navigator.currentState?.maybePop();
                  return null;
                }),
              },
              child: DefaultTextStyle(
                style: MiraType.body,
                child: ColoredBox(
                  color: MiraColors.background,
                  child: child ?? const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

enum _Phase { loading, ready, empty, unreachable, refused }

class _Root extends StatefulWidget {
  const _Root({
    required this.source,
    required this.onOpen,
    required this.onPlay,
    required this.libraryChanged,
    this.discover,
  });

  final LibrarySource source;
  final DiscoverSource? discover;
  final Listenable libraryChanged;
  final ValueChanged<MediaItem> onOpen;
  final void Function(MediaItem item, {required bool fromStart, TrackChoice? choice}) onPlay;

  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> {
  String _tab = 'Home';
  _Phase _phase = _Phase.loading;
  List<MediaItem> _items = const <MediaItem>[];
  List<MediaItem> _recent = const <MediaItem>[];
  String? _technical;

  @override
  void initState() {
    super.initState();
    widget.libraryChanged.addListener(_onLibraryChanged);
    _load();
  }

  @override
  void dispose() {
    widget.libraryChanged.removeListener(_onLibraryChanged);
    super.dispose();
  }

  // Other tabs reload Home when you switch back to it anyway.
  void _onLibraryChanged() {
    if (_tab == 'Home') _load(quiet: true);
  }

  /// [quiet] keeps what is on screen while refreshing. Coming back from a film
  /// should update the row in place, not flash the loading star and drop focus.
  Future<void> _load({bool quiet = false}) async {
    if (!quiet || _phase != _Phase.ready) {
      setState(() {
        _phase = _Phase.loading;
        _technical = null;
      });
    }
    try {
      // Both rows at once: two round trips over the tunnel, not one after the
      // other.
      final Future<List<MediaItem>> resume = widget.source.continueWatching();
      final Future<List<MediaItem>> recent = widget.source.recentlyAdded();
      final List<MediaItem> items = await resume;
      final List<MediaItem> latest = await recent;
      if (!mounted) return;
      setState(() {
        _items = items;
        _recent = latest;
        // "Nothing to continue" only when there is also nothing new to show.
        _phase = items.isEmpty && latest.isEmpty ? _Phase.empty : _Phase.ready;
      });
    } on JellyfinException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = e.isReachabilityProblem ? _Phase.unreachable : _Phase.refused;
        _technical = e.message;
      });
    }
  }

  void _setTab(String tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    // Resume positions change while you watch; refresh when coming home.
    if (tab == 'Home') _load();
  }

  Widget _home() {
    return switch (_phase) {
      _Phase.loading => const _Loading(),
      _Phase.ready => HomeScreen(
          source: widget.source,
          items: _items,
          recent: _recent,
          onTab: _setTab,
          onOpen: widget.onOpen,
          onPlay: (MediaItem item, {required bool fromStart}) =>
              widget.onPlay(item, fromStart: fromStart),
        ),
      _Phase.empty => MiraStateScreen(
          glyph: MiraGlyph.emptyLibrary,
          title: 'Nothing to continue yet',
          body: 'Mira reached your server and signed in, but there is nothing '
              'part-watched. Start something and it will show up here.',
          primaryAction: 'Browse films',
          onPrimary: () => _setTab('Films'),
          secondaryAction: 'Refresh',
          onSecondary: _load,
          technical: 'jellyfin · ${widget.source.label} · 0 in progress',
        ),
      _Phase.unreachable => MiraStateScreen(
          glyph: MiraGlyph.serverDown,
          title: 'Your server is not answering',
          body: 'The tunnel may be up while Jellyfin itself is off, restarting, '
              'or listening somewhere else.',
          rows: const <StatusRow>[
            StatusRow(label: 'NetBird', value: 'connected', tone: StatusTone.good),
            StatusRow(label: 'Jellyfin', value: 'no response', tone: StatusTone.bad),
          ],
          primaryAction: 'Retry now',
          onPrimary: _load,
          technical: _technical,
        ),
      _Phase.refused => MiraStateScreen(
          glyph: MiraGlyph.networkDown,
          title: 'Mira could not sign in',
          body: 'Your server answered but would not accept this box. The '
              'sign-in may have been revoked.',
          primaryAction: 'Try again',
          onPrimary: _load,
          technical: _technical,
        ),
    };
  }

  Widget _discover() {
    final DiscoverSource? discover = widget.discover;
    if (discover != null) return DiscoverScreen(source: discover, onTab: _setTab);
    return MiraStateScreen(
      glyph: MiraGlyph.emptyLibrary,
      title: 'Discover is not connected yet',
      body: 'Mira needs an Overseerr API key before it can show what to '
          'request. Add it to the server config and restart the shell.',
      primaryAction: 'Back to home',
      onPrimary: () => _setTab('Home'),
      secondaryAction: 'Browse films',
      onSecondary: () => _setTab('Films'),
      technical: 'overseerr · no API key in config',
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget content = switch (_tab) {
      'Films' => FilmsScreen(source: widget.source, onOpen: widget.onOpen, onTab: _setTab),
      'Discover' => _discover(),
      _ => _home(),
    };
    return Actions(
      actions: <Type, Action<Intent>>{
        BackIntent: CallbackAction<BackIntent>(onInvoke: (BackIntent _) {
          if (_tab != 'Home') _setTab('Home');
          return null;
        }),
      },
      child: KeyedSubtree(key: ValueKey<String>(_tab), child: content),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    // Deliberately almost nothing. A spinner that appears for 200 ms and
    // vanishes is worse than a quiet moment.
    return const ColoredBox(
      color: MiraColors.background,
      child: Center(child: MiraStar(size: 44)),
    );
  }
}
