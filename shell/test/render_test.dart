import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/core/library_source.dart';
import 'package:mira_shell/core/mira_app.dart';
import 'package:mira_shell/core/tokens.dart';
import 'package:mira_shell/input/pointer_mode.dart';
import 'package:mira_shell/input/remote.dart';
import 'package:mira_shell/jellyfin/models.dart';
import 'package:mira_shell/network/netbird.dart';
import 'package:mira_shell/ui/network_screen.dart';
import 'package:mira_shell/core/track_choice.dart';
import 'package:mira_shell/input/mira_focusable.dart';
import 'package:mira_shell/overseerr/discover_source.dart';
import 'package:mira_shell/overseerr/overseerr_client.dart';
import 'package:mira_shell/player/fake_player.dart';
import 'package:mira_shell/ui/discover_screen.dart';
import 'package:mira_shell/ui/discover_search_screen.dart';
import 'package:mira_shell/ui/discover_title_screen.dart';
import 'package:mira_shell/ui/detail_screen.dart';
import 'package:mira_shell/ui/films_screen.dart';
import 'package:mira_shell/ui/home_screen.dart';
import 'package:mira_shell/ui/player_screen.dart';
import 'package:mira_shell/ui/series_screen.dart';
import 'package:mira_shell/ui/tracks_sheet.dart';
import 'package:mira_shell/ui/state_screen.dart';
import 'package:mira_shell/ui/widgets/chrome.dart';

/// Renders the real screens at real TV size.
///
/// Widget tests normally draw text as blank boxes because bundled fonts are not
/// registered, which makes a golden useless for judging a ten-foot layout - the
/// whole question is whether the type reads. So load the actual faces first.
Future<void> _loadFonts() async {
  const Map<String, String> faces = <String, String>{
    'Archivo': 'assets/fonts/Archivo-Variable.ttf',
    'ArchivoBlack': 'assets/fonts/ArchivoBlack-Regular.ttf',
  };
  for (final MapEntry<String, String> e in faces.entries) {
    final Uint8List bytes = await File(e.value).readAsBytes();
    await (FontLoader(e.key)
          ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes))))
        .load();
  }
}

Widget _harness(Widget child) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(1920, 1080), devicePixelRatio: 1),
    child: Directionality(
      textDirection: TextDirection.ltr,
      // WidgetsApp's defaults are what map arrows onto focus traversal in the
      // real app; without them a d-pad test only proves the keys go nowhere.
      child: Shortcuts(
        shortcuts: WidgetsApp.defaultShortcuts,
        child: Actions(
          actions: WidgetsApp.defaultActions,
          child: PointerMode(
            controller: PointerModeController(),
            child: DefaultTextStyle(
              style: MiraType.body,
              child: ColoredBox(color: MiraColors.background, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(_loadFonts);

  // Freeze the clock: otherwise the golden fails whenever the minute changes.
  setUp(() => miraNow = () => DateTime(2026, 9, 12, 21, 4));
  tearDown(() => miraNow = DateTime.now);

  /// A 1080p surface: the UI plane always renders at 1080p, even when video
  /// output mode-switches to 4K.
  void sizeToTv(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('home screen renders at 1080p', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(const MiraApp(source: DemoLibrarySource()));
    // The source's simulated latency is a bare Future.delayed, which schedules
    // no frame - pumpAndSettle alone would capture the loading screen.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MiraApp),
      matchesGoldenFile('goldens/home.png'),
    );

    // Dispose the tree so the clock's periodic timer is cancelled; a pending
    // timer fails the test after the body returns.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('server-unreachable screen renders', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(_harness(MiraStateScreen(
      glyph: MiraGlyph.serverDown,
      title: 'Your server is not answering',
      body: 'The tunnel is up, so this is Jellyfin itself - it may be off, '
          'restarting, or listening on a different port.',
      rows: const <StatusRow>[
        StatusRow(
            label: 'NetBird',
            value: 'connected · 100.84.0.6',
            tone: StatusTone.good),
        StatusRow(
            label: 'Jellyfin',
            value: 'no response from jellyfin.homelab:8096',
            tone: StatusTone.bad),
      ],
      primaryAction: 'Retry now',
      onPrimary: () {},
      secondaryAction: 'Change server',
      onSecondary: () {},
      technical: 'connection refused after 5 s · 3 attempts since 20:58',
    )));
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(MiraStateScreen),
      matchesGoldenFile('goldens/state_server.png'),
    );
  });

  testWidgets('home survives a long title and synopsis', (WidgetTester tester) async {
    sizeToTv(tester);
    // Real libraries contain titles that wrap. The demo data is all short, which
    // is why an overflow here went unnoticed until it hit a real server - twice:
    // the second time only with the Recently added rail below, which is why
    // this renders both rails.
    await tester.pumpWidget(_harness(HomeScreen(
      source: const DemoLibrarySource(),
      recent: const <MediaItem>[
        MediaItem(id: 'recent-1', name: 'House of Flying Daggers', productionYear: 2004),
      ],
      items: const <MediaItem>[
        MediaItem(
          id: 'long',
          name: 'The Lord of the Rings: The Fellowship of the Ring Extended',
          productionYear: 2001,
          runtime: Duration(hours: 3, minutes: 48),
          resumePosition: Duration(minutes: 55),
          overview: 'Young hobbit Frodo Baggins, after inheriting a mysterious '
              'ring from his uncle Bilbo, must leave his home in order to keep '
              'it from falling into the hands of its evil creator. Along the '
              'way, a fellowship is formed to protect the ringbearer and make '
              'sure that the ring arrives at its final destination.',
          videoCodec: 'hevc',
          width: 1920,
          height: 804,
          genres: <String>['Adventure'],
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'the hero overflowed its box with a long title');

    await expectLater(
      find.byType(HomeScreen),
      matchesGoldenFile('goldens/home_long_title.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Down from Continue Watching reaches Recently added', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(const MiraApp(source: DemoLibrarySource()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // Built but scrolled just below the one-rail window until focus moves down,
    // so the finder must include offstage widgets here.
    expect(find.text('RECENTLY ADDED', skipOffstage: false), findsOneWidget,
        reason: 'the second rail is missing');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'rail-0-0');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, startsWith('rail-1-'),
        reason: 'Down from Continue Watching did not reach Recently added');
    // The hero names the row the focused poster came from.
    expect(find.text('RECENTLY ADDED'), findsNWidgets(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, startsWith('rail-0-'),
        reason: 'Up did not come back to Continue Watching');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Right at the end of a rail carries on into the next rail', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(const MiraApp(source: DemoLibrarySource()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    // The demo Continue Watching rail has four posters.
    for (int i = 0; i < 3; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'rail-0-3');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'rail-1-0',
        reason: 'Right on the last poster was stuck instead of moving to the next rail');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('every screen is reachable by d-pad alone', (WidgetTester tester) async {
    sizeToTv(tester);
    // The rule that is expensive to retrofit, asserted rather than trusted:
    // with the cursor off, focus must still be able to move.
    await tester.pumpWidget(const MiraApp(source: DemoLibrarySource()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final FocusNode? first = FocusManager.instance.primaryFocus;
    expect(first, isNotNull,
        reason: 'nothing had focus on load, so the remote would be stuck');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, isNot(same(first)),
        reason: 'arrow right did not move focus along the rail');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(first),
        reason: 'arrow left did not come back');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  // The demo source answers through a bare Future.delayed, which fake-async
  // never completes on its own; fetch outside it.
  Future<MediaItem> demoItem(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => const DemoLibrarySource().item(id)))!;

  testWidgets('films grid renders', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(_harness(FilmsScreen(source: const DemoLibrarySource(), onOpen: (_) {})));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(FilmsScreen), matchesGoldenFile('goldens/films.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the shows libraries get tabs of their own, named as on the server', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(const MiraApp(source: DemoLibrarySource()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('Shows'), findsOneWidget);
    expect(find.text('Anime'), findsOneWidget);
    // The movies library is the Films tab, not a second one.
    expect(find.text('Movies'), findsNothing);
    await expectLater(find.byType(MiraApp), matchesGoldenFile('goldens/home.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('shows grid renders', (WidgetTester tester) async {
    sizeToTv(tester);
    const DemoLibrarySource source = DemoLibrarySource();
    await tester.pumpWidget(_harness(FilmsScreen(
      source: source,
      catalog: Catalog.shows(source, DemoLibrarySource.demoShows),
      onOpen: (_) {},
    )));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'shows-0');
    expect(find.text('2 shows'), findsOneWidget);
    expect(find.text('All shows'), findsOneWidget);
    await expectLater(find.byType(FilmsScreen), matchesGoldenFile('goldens/shows.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('series page: play next, pick a season, open an episode, all by d-pad', (WidgetTester tester) async {
    sizeToTv(tester);
    final MediaItem series = await demoItem(tester, 'demo-harbour');
    MediaItem? opened;
    MediaItem? played;
    bool? playedFromStart;
    await tester.pumpWidget(_harness(SeriesScreen(
      source: const DemoLibrarySource(),
      series: series,
      onOpen: (MediaItem e) => opened = e,
      onPlay: (MediaItem e, {required bool fromStart, TrackChoice? choice}) {
        played = e;
        playedFromStart = fromStart;
      },
    )));
    // Seasons and next-up, then the season's episodes: three demo round trips.
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'series:primary');
    expect(find.text('Resume S1 E3'), findsOneWidget, reason: 'the button did not offer the half-watched episode');
    await expectLater(find.byType(SeriesScreen), matchesGoldenFile('goldens/series.png'));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(played?.episodeLabel, 'S1 E3');
    expect(playedFromStart, isFalse, reason: 'a half-watched episode should resume');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'season:Season 1');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'episode-2',
        reason: 'Down from the seasons did not land on the episode to watch next');
    expect(find.text('S1 E3   ·   Salt in the Gears'), findsOneWidget, reason: 'the caption did not follow focus');

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened?.episodeLabel, 'S1 E3');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'season:Season 2');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened?.episodeLabel, 'S2 E1', reason: 'Season 2 did not show its own episodes');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('films grid wraps Right into the next row and puts that row at the top', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(_harness(FilmsScreen(source: const DemoLibrarySource(), onOpen: (_) {})));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'films-0');
    final double firstRowTop = FocusManager.instance.primaryFocus!.rect.top;

    // Six columns: five Rights reach the end of the first row.
    for (int i = 0; i < 5; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'films-5');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'films-6',
        reason: 'Right at the end of a row was stuck instead of moving to the next row');
    expect(FocusManager.instance.primaryFocus!.rect.top, moreOrLessEquals(firstRowTop, epsilon: 1),
        reason: 'the focused row was not scrolled to the top of the grid');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'films-5',
        reason: 'Left at the start of a row did not go back to the previous row');
    expect(FocusManager.instance.primaryFocus!.rect.top, moreOrLessEquals(firstRowTop, epsilon: 1));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('genres view renders', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(_harness(FilmsScreen(source: const DemoLibrarySource(), onOpen: (_) {})));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // Select the chip the way OK would, without needing the pointer.
    tester
        .widget<MiraFocusable>(find
            .ancestor(of: find.text('Genres'), matching: find.byType(MiraFocusable))
            .first)
        .onSelect!();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(FilmsScreen), matchesGoldenFile('goldens/genres.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('detail screen renders', (WidgetTester tester) async {
    sizeToTv(tester);
    final MediaItem item = await demoItem(tester, 'demo-ashfall');
    await tester.pumpWidget(_harness(DetailScreen(
      source: const DemoLibrarySource(),
      item: item,
      onPlay: (MediaItem _, {required bool fromStart, required TrackChoice? choice}) {},
    )));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(DetailScreen), matchesGoldenFile('goldens/detail.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('one Back in the player returns to the film, not further', (WidgetTester tester) async {
    sizeToTv(tester);
    // Found in the VM: a single Escape stopped the film and also closed its
    // detail screen, landing on the Films grid. Walk the real app to pin it.
    await tester.pumpWidget(const MiraApp(source: DemoLibrarySource()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // poster -> detail
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // Resume -> player
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(PlayerScreen), findsOneWidget);

    // The controls are up when a film starts: the first Back only hides them.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(PlayerScreen), findsOneWidget, reason: 'Back with the controls up stopped the film');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(PlayerScreen), findsNothing, reason: 'Back did not stop the film');
    expect(find.byType(DetailScreen), findsOneWidget,
        reason: 'one Back closed the film page too');

    // Held Back: one press, however long. A repeat must not go on to stop the
    // film, let alone pop the film page.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter); // Resume -> player again
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(PlayerScreen), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(PlayerScreen), findsOneWidget,
        reason: 'a held Back repeated past hiding the controls and stopped the film');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(find.byType(PlayerScreen), findsNothing);
    expect(find.byType(DetailScreen), findsOneWidget,
        reason: 'Back from the player closed the film page as well');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('detail offers Continue Watching actions and confirms them', (WidgetTester tester) async {
    sizeToTv(tester);
    final MediaItem item = await demoItem(tester, 'demo-ashfall');
    await tester.pumpWidget(_harness(DetailScreen(
      source: const DemoLibrarySource(),
      item: item,
      onPlay: (MediaItem _, {required bool fromStart, required TrackChoice? choice}) {},
    )));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('Mark watched'), findsOneWidget);
    expect(find.text('Clear progress'), findsOneWidget,
        reason: 'a part-watched film must offer to leave Continue Watching');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'detail:primary');

    // Select it the way OK would, without the pointer. Its two demo calls wait
    // on Future.delayed timers made in the test's fake clock, so advance that
    // clock - real time (runAsync) never fires them.
    tester
        .widget<MiraFocusable>(find
            .ancestor(of: find.text('Clear progress'), matching: find.byType(MiraFocusable))
            .first)
        .onSelect!();
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('left Continue Watching'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('discover grid renders', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(_harness(const DiscoverScreen(source: DemoDiscoverSource())));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('IN LIBRARY'), findsWidgets);
    await expectLater(find.byType(DiscoverScreen), matchesGoldenFile('goldens/discover.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('search queries are encoded the way Seerr accepts', () {
    // Seerr 3.4.1 answers 400 to '+' for a space or a bare apostrophe.
    expect(OverseerrClient.strictEncode("mortal's journey"), 'mortal%27s%20journey');
    expect(OverseerrClient.strictEncode('the odyssey'), 'the%20odyssey');
    expect(OverseerrClient.strictEncode('amélie'), 'am%C3%A9lie');
  });

  testWidgets('search types with the on-screen keyboard and shows results', (WidgetTester tester) async {
    sizeToTv(tester);
    await tester.pumpWidget(_harness(const DiscoverSearchScreen(source: DemoDiscoverSource())));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'key:A',
        reason: 'the keyboard must start focused, or the remote has nothing to type with');

    // OK on A, then right five times along the row isn't needed: select keys
    // the way OK would, S then A.
    for (final String key in <String>['S', 'A']) {
      tester
          .widget<MiraFocusable>(find.ancestor(of: find.text(key), matching: find.byType(MiraFocusable)).first)
          .onSelect!();
      await tester.pump();
    }
    expect(find.text('sa'), findsOneWidget, reason: 'typed letters did not appear in the query');

    // Past the debounce, then the demo source's own delay.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Sable'), findsOneWidget, reason: 'matching result did not appear');
    await expectLater(find.byType(DiscoverSearchScreen), matchesGoldenFile('goldens/discover_search.png'));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('discover title requests on OK and confirms', (WidgetTester tester) async {
    sizeToTv(tester);
    const DiscoverTitle title = DiscoverTitle(
      tmdbId: 2,
      mediaType: 'movie',
      title: 'The Ninth Hour',
      year: 2025,
      runtime: Duration(hours: 2, minutes: 6),
      genres: <String>['Thriller'],
      overview: 'A night-shift dispatcher takes a call from a number that was '
          'disconnected eleven years ago.',
    );
    await tester.pumpWidget(_harness(const DiscoverTitleScreen(source: DemoDiscoverSource(), title: title)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Request'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'discover:primary');
    await expectLater(find.byType(DiscoverTitleScreen), matchesGoldenFile('goldens/discover_title.png'));

    tester
        .widget<MiraFocusable>(find.ancestor(of: find.text('Request'), matching: find.byType(MiraFocusable)).first)
        .onSelect!();
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('REQUEST SENT'), findsOneWidget);
    expect(find.text('Keep browsing'), findsOneWidget);
    expect(find.text('Cancel request'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'discover:primary',
        reason: 'focus was stranded when Request turned into Keep browsing');
    await expectLater(find.byType(DiscoverTitleScreen), matchesGoldenFile('goldens/discover_requested.png'));

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('subtitles sheet renders', (WidgetTester tester) async {
    sizeToTv(tester);
    final MediaItem item = await demoItem(tester, 'demo-ashfall');
    await tester.pumpWidget(_harness(TracksSheet(
      source: const DemoLibrarySource(),
      item: item,
      initial: TrackChoice(subtitle: item.subtitleTracks.first),
      onChanged: (TrackChoice _, MediaItem __) {},
    )));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(TracksSheet), matchesGoldenFile('goldens/tracks.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('OK on a subtitle applies it, closes the sheet and remembers it', (WidgetTester tester) async {
    sizeToTv(tester);
    const DemoLibrarySource source = DemoLibrarySource();
    final MediaItem item = await demoItem(tester, 'demo-ferrous');
    TrackChoice? applied;
    await tester.pumpWidget(_harness(Navigator(
      onGenerateRoute: (RouteSettings _) => PageRouteBuilder<void>(
        pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => const SizedBox.shrink(),
      ),
    )));
    tester.state<NavigatorState>(find.byType(Navigator)).push(PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => TracksSheet(
        source: source,
        item: item,
        initial: const TrackChoice(),
        onChanged: (TrackChoice choice, MediaItem _) => applied = choice,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('OK'), findsNothing, reason: 'there is nothing to confirm any more');

    // Subtitles tab -> Off -> English, then OK once.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'track:English');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(applied?.subtitle?.index, 3);
    expect(find.byType(TracksSheet), findsNothing, reason: 'OK did not close the sheet');
    // Real timers: the demo source answers after a delay, which fake time
    // outside a pump never reaches.
    final TrackChoice saved = (await tester.runAsync(() => source.savedTracks(item)))!;
    expect(saved.subtitle?.index, 3, reason: 'the pick was not remembered for the film');
    expect(saved.audio, isNull);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('signed out of NetBird: sign in by code, then back to a connected tunnel', (WidgetTester tester) async {
    sizeToTv(tester);
    final NetbirdMonitor monitor = NetbirdMonitor(FakeNetbird(signInDelay: const Duration(seconds: 2)));
    await tester.pumpWidget(_harness(Navigator(
      onGenerateRoute: (RouteSettings _) => PageRouteBuilder<void>(
        pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => NetworkScreen(
          monitor: monitor,
          serverLabel: '192.168.100.34',
          checkServer: () async => false,
        ),
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Not signed in to NetBird'), findsOneWidget);
    // The screen's own node, shared by whichever action comes first.
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'network:primary',
        reason: 'the one thing to do was not focused');
    expect(find.text('Sign in to NetBird'), findsOneWidget);
    await expectLater(find.byType(NetworkScreen), matchesGoldenFile('goldens/network_signed_out.png'));

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'button:New code',
        reason: 'nothing on the sign-in screen had focus, so the remote was stranded');
    expect(find.text('KXQM-2PLD'), findsNothing, reason: 'the code is shown as tiles, not one string');
    expect(find.text('Q'), findsOneWidget);
    await expectLater(find.byType(NetbirdSignInScreen), matchesGoldenFile('goldens/netbird_signin.png'));

    // The fake signs in after two seconds; the screen says so, then returns.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Signed in. Bringing the tunnel up…'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();
    expect(find.byType(NetbirdSignInScreen), findsNothing);
    expect(find.text('Connected to your network'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'network:primary',
        reason: 'focus was lost when Sign in turned into Check again');
    expect(find.text('Check again'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    monitor.dispose();
  });

  testWidgets('player overlay renders with subtitles', (WidgetTester tester) async {
    sizeToTv(tester);
    final MediaItem item = await demoItem(tester, 'demo-ashfall');
    await tester.pumpWidget(_harness(PlayerScreen(
      source: const DemoLibrarySource(),
      item: item,
      fromStart: false,
      choice: TrackChoice(subtitle: item.subtitleTracks.first),
      playerFactory: FakeMiraPlayer.new,
    )));
    // Plan, open, then into the demo cue that starts two seconds after resume.
    for (int i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(tester.takeException(), isNull);
    await expectLater(find.byType(PlayerScreen), matchesGoldenFile('goldens/player.png'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden player overlay spends the first key on waking', (WidgetTester tester) async {
    sizeToTv(tester);
    final MediaItem item = await demoItem(tester, 'demo-ashfall');
    await tester.pumpWidget(_harness(PlayerScreen(
      source: const DemoLibrarySource(),
      item: item,
      fromStart: true,
      playerFactory: FakeMiraPlayer.new,
    )));
    for (int i = 0; i < 32; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'player:wake',
        reason: 'the overlay did not hide during playback');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 50));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'player:scrub',
        reason: 'the first key did not bring the overlay back');
    expect(find.textContaining('0:00:1'), findsNothing,
        reason: 'the waking key also seeked');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('0:00:1'), findsOneWidget,
        reason: 'right on the scrub bar did not move the target 10 s on');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Back hides the player controls first, and only then stops the film', (WidgetTester tester) async {
    sizeToTv(tester);
    final MediaItem item = await demoItem(tester, 'demo-ashfall');
    // Back wired the way MiraApp wires it: the remote's Back is the app's
    // maybePop, whatever has focus.
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(_harness(RemoteShortcuts(
      child: Actions(
        actions: <Type, Action<Intent>>{
          BackIntent: CallbackAction<BackIntent>(onInvoke: (BackIntent _) {
            navigator.currentState?.maybePop();
            return null;
          }),
        },
        child: Navigator(
          key: navigator,
          onGenerateRoute: (RouteSettings _) => PageRouteBuilder<void>(
            pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => const SizedBox.shrink(),
          ),
        ),
      ),
    )));
    navigator.currentState!.push(PageRouteBuilder<void>(
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => PlayerScreen(
        source: const DemoLibrarySource(),
        item: item,
        fromStart: true,
        choice: const TrackChoice(),
        playerFactory: FakeMiraPlayer.new,
      ),
    ));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'player:scrub', reason: 'the overlay was not up');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(PlayerScreen), findsOneWidget, reason: 'Back with the controls up stopped the film');
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'player:wake', reason: 'Back did not hide the controls');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(PlayerScreen), findsNothing, reason: 'Back with the controls hidden did not stop the film');

    // Found in the VM: while a stream is still opening, focus need not be
    // inside the player yet, and Back reached the app's maybePop directly.
    navigator.currentState!.push(PageRouteBuilder<void>(
      pageBuilder: (BuildContext c, Animation<double> a, Animation<double> b) => PlayerScreen(
        source: const DemoLibrarySource(),
        item: item,
        fromStart: true,
        choice: const TrackChoice(),
        playerFactory: FakeMiraPlayer.new,
      ),
    ));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(find.byType(PlayerScreen), findsOneWidget,
        reason: 'Back with focus outside the player skipped hiding the controls and stopped the film');

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('player controls are reachable from the scrub bar by d-pad', (WidgetTester tester) async {
    sizeToTv(tester);
    final MediaItem item = await demoItem(tester, 'demo-ashfall');
    await tester.pumpWidget(_harness(PlayerScreen(
      source: const DemoLibrarySource(),
      item: item,
      fromStart: true,
      playerFactory: FakeMiraPlayer.new,
    )));
    for (int i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'player:scrub');

    // Found in the VM: down from the scrub bar did not reach the buttons, so
    // "Subtitles & audio" was unreachable during playback without a pointer.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 50));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'player:play',
        reason: 'down from the scrub bar did not land on Play/Pause');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 50));
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'button:Subtitles & audio');

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
