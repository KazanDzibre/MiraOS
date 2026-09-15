import 'package:flutter/widgets.dart';

import '../input/pointer_mode.dart';
import '../overseerr/discover_source.dart';
import '../ui/discover_screen.dart';
import '../input/remote.dart';
import '../jellyfin/jellyfin_client.dart';
import '../jellyfin/models.dart';
import '../network/netbird.dart';
import '../ui/detail_screen.dart';
import '../ui/network_screen.dart';
import '../ui/films_screen.dart';
import '../ui/home_screen.dart';
import '../ui/player_screen.dart';
import '../ui/series_screen.dart';
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
  const MiraApp({super.key, required this.source, this.netbird, this.discover});

  final LibrarySource source;

  /// The box's tunnel to the server. Without it the top bar's address is just
  /// a label, as in tests that render screens with no network at all.
  final NetbirdControl? netbird;

  /// Seerr, when configured. Without it Discover explains what is missing.
  final DiscoverSource? discover;

  @override
  State<MiraApp> createState() => _MiraAppState();
}

class _MiraAppState extends State<MiraApp> {
  final PointerModeController _pointer = PointerModeController();
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  late final NetbirdMonitor? _netbird =
      widget.netbird == null ? null : (NetbirdMonitor(widget.netbird!)..start());

  /// Bumped whenever a pushed screen closes. Watching, marking watched or
  /// clearing progress all change Continue Watching, and Home must show that
  /// the moment you are back - not after a tab switch.
  final ValueNotifier<int> _libraryChanged = ValueNotifier<int>(0);

  @override
  void dispose() {
    _pointer.dispose();
    _libraryChanged.dispose();
    _netbird?.dispose();
    super.dispose();
  }

  /// Every hop to the server, and NetBird sign-in when the tunnel needs it.
  /// [signIn] goes straight on to the code, with the connection screen behind
  /// it for Back. Coming back reloads the library: signing in is usually why
  /// you went.
  Future<void> _openNetwork({bool signIn = false}) async {
    final NetbirdMonitor? monitor = _netbird;
    if (monitor == null) return;
    await _navigator.currentState?.push(_route((BuildContext _) => NetworkScreen(
          monitor: monitor,
          signInFirst: signIn,
          serverLabel: widget.source.label,
          checkServer: () => widget.source.movieCount().then((int _) => true),
        )));
    _libraryChanged.value++;
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

  /// A film or episode opens its page; a show opens its seasons and episodes.
  Future<void> _openDetail(MediaItem item) async {
    await _navigator.currentState?.push(_route((BuildContext _) => item.isSeries
        ? SeriesScreen(
            source: widget.source,
            series: item,
            onOpen: _openDetail,
            onPlay: _openPlayer,
            libraryChanged: _libraryChanged,
          )
        : DetailScreen(
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
        final Widget app = PointerMode(
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
        final NetbirdMonitor? monitor = _netbird;
        return monitor == null ? app : NetworkScope(monitor: monitor, onOpen: _openNetwork, child: app);
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

  /// The server's libraries. Each shows library is a tab of its own.
  List<LibraryView> _libraries = const <LibraryView>[];

  static const List<String> _fixedTabs = <String>['Home', 'Discover', 'Films'];

  List<String> get _tabs => <String>[
        ..._fixedTabs,
        for (final LibraryView l in _libraries)
          if (l.isShows && !_fixedTabs.contains(l.name)) l.name,
      ];

  LibraryView? _showsLibrary(String tab) {
    for (final LibraryView l in _libraries) {
      if (l.isShows && l.name == tab && !_fixedTabs.contains(tab)) return l;
    }
    return null;
  }

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
      // A library list that fails costs the extra tabs, never Home itself.
      final Future<List<LibraryView>> libraries =
          widget.source.libraries().catchError((Object _) => const <LibraryView>[]);
      final List<MediaItem> items = await resume;
      final List<MediaItem> latest = await recent;
      final List<LibraryView> views = await libraries;
      if (!mounted) return;
      setState(() {
        _items = items;
        _recent = latest;
        _libraries = views;
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
      _Phase.unreachable => _unreachable(),
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

  /// The server did not answer. When the tunnel is why, say so and offer the
  /// fix - NetBird sign-in - instead of blaming the server.
  Widget _unreachable() {
    final NetworkScope? scope = NetworkScope.maybeOf(context);
    final NetbirdStatus? tunnel = scope?.notifier?.value;
    final NetbirdState? state = tunnel?.state;
    if (scope != null &&
        (state == NetbirdState.signedOut || state == NetbirdState.stopped || state == NetbirdState.connecting)) {
      final bool signedOut = state == NetbirdState.signedOut;
      return MiraStateScreen(
        glyph: MiraGlyph.networkDown,
        title: 'Not on your network',
        body: signedOut
            ? 'This box is signed out of NetBird, so your server cannot be '
                'reached from here. Sign in from your phone and Mira carries on.'
            : 'The NetBird tunnel is down, so your server cannot be reached '
                'from here. Nothing is lost - Mira keeps trying on its own.',
        rows: <StatusRow>[
          StatusRow(
            label: 'NetBird',
            value: switch (state) {
              NetbirdState.signedOut => 'signed out',
              NetbirdState.connecting => 'connecting',
              _ => 'not running',
            },
            tone: state == NetbirdState.connecting ? StatusTone.neutral : StatusTone.bad,
          ),
          const StatusRow(label: 'Jellyfin', value: 'waiting for the tunnel'),
        ],
        primaryAction: signedOut ? 'Sign in to NetBird' : 'Retry now',
        onPrimary: signedOut ? () => scope.onOpen(signIn: true) : _load,
        secondaryAction: 'Network details',
        onSecondary: scope.onOpen,
        technical: tunnel?.detail ?? _technical,
      );
    }
    return MiraStateScreen(
      glyph: MiraGlyph.serverDown,
      title: 'Your server is not answering',
      body: 'The tunnel may be up while Jellyfin itself is off, restarting, '
          'or listening somewhere else.',
      rows: <StatusRow>[
        // Without a NetBird on this machine the tunnel is the host's; the
        // server not answering is the only thing known.
        if (state == null || state == NetbirdState.connected)
          const StatusRow(label: 'NetBird', value: 'connected', tone: StatusTone.good),
        const StatusRow(label: 'Jellyfin', value: 'no response', tone: StatusTone.bad),
      ],
      primaryAction: 'Retry now',
      onPrimary: _load,
      secondaryAction: scope == null ? null : 'Network details',
      onSecondary: scope?.onOpen,
      technical: _technical,
    );
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
    final LibraryView? shows = _showsLibrary(_tab);
    final Widget content = shows != null
        ? FilmsScreen(
            source: widget.source,
            catalog: Catalog.shows(widget.source, shows),
            onOpen: widget.onOpen,
            onTab: _setTab,
          )
        : switch (_tab) {
            'Films' => FilmsScreen(source: widget.source, onOpen: widget.onOpen, onTab: _setTab),
            'Discover' => _discover(),
            _ => _home(),
          };
    return MiraTabs(
      tabs: _tabs,
      child: Actions(
      actions: <Type, Action<Intent>>{
        BackIntent: CallbackAction<BackIntent>(onInvoke: (BackIntent _) {
          if (_tab != 'Home') _setTab('Home');
          return null;
        }),
      },
        child: KeyedSubtree(key: ValueKey<String>(_tab), child: content),
      ),
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
