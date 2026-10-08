import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/core/library_source.dart';
import 'package:mira_shell/core/tokens.dart';
import 'package:mira_shell/input/mira_focusable.dart';
import 'package:mira_shell/input/pointer_mode.dart';
import 'package:mira_shell/jellyfin/models.dart';
import 'package:mira_shell/overseerr/discover_source.dart';
import 'package:mira_shell/overseerr/overseerr_client.dart';
import 'package:mira_shell/player/fake_player.dart';
import 'package:mira_shell/ui/discover_screen.dart';
import 'package:mira_shell/ui/discover_search_screen.dart';
import 'package:mira_shell/ui/films_screen.dart';
import 'package:mira_shell/ui/library_search_screen.dart';
import 'package:mira_shell/core/track_choice.dart';
import 'package:mira_shell/ui/player_screen.dart';
import 'package:mira_shell/ui/tracks_sheet.dart';
import 'package:mira_shell/ui/widgets/chrome.dart';

Future<void> _loadFonts() async {
  const Map<String, String> faces = <String, String>{
    'Archivo': 'assets/fonts/Archivo-Variable.ttf',
    'ArchivoBlack': 'assets/fonts/ArchivoBlack-Regular.ttf',
  };
  for (final MapEntry<String, String> e in faces.entries) {
    final Uint8List bytes = await File(e.value).readAsBytes();
    await (FontLoader(e.key)..addFont(Future<ByteData>.value(ByteData.sublistView(bytes))))
        .load();
  }
}

Widget _harness(Widget child) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(1920, 1080), devicePixelRatio: 1),
    child: Directionality(
      textDirection: TextDirection.ltr,
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

void _sizeToTv(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Presses the focusable whose text is [label], the way OK would.
void _press(WidgetTester tester, String label) {
  tester
      .widget<MiraFocusable>(
          find.ancestor(of: find.text(label), matching: find.byType(MiraFocusable)).first)
      .onSelect!();
}

void main() {
  setUpAll(_loadFonts);
  setUp(() => miraNow = () => DateTime(2026, 10, 6, 21, 4));
  tearDown(() => miraNow = DateTime.now);

  group('searching a library', () {
    testWidgets('types a title and finds it without scrolling the grid',
        (WidgetTester tester) async {
      _sizeToTv(tester);
      await tester.pumpWidget(_harness(LibrarySearchScreen(
        source: const DemoLibrarySource(),
        catalog: Catalog.films(const DemoLibrarySource()),
        onOpen: (MediaItem _) {},
      )));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'key:A',
          reason: 'the keyboard must start focused, or the remote cannot type');

      for (final String key in <String>['T', 'I']) {
        _press(tester, key);
        await tester.pump();
      }
      expect(find.text('ti'), findsOneWidget, reason: 'typed letters did not reach the query');

      await tester.pump(const Duration(milliseconds: 400)); // debounce
      await tester.pump(const Duration(milliseconds: 200)); // demo source delay
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Low Tide'), findsOneWidget,
          reason: 'a film matching "ti" should be found by the server, not by the visible page');
      await expectLater(
          find.byType(LibrarySearchScreen), matchesGoldenFile('goldens/library_search.png'));
      await _settleTimers(tester);
    });

    testWidgets('says so when nothing matches', (WidgetTester tester) async {
      _sizeToTv(tester);
      await tester.pumpWidget(_harness(LibrarySearchScreen(
        source: const DemoLibrarySource(),
        catalog: Catalog.films(const DemoLibrarySource()),
        onOpen: (MediaItem _) {},
      )));
      await tester.pumpAndSettle();
      for (final String key in <String>['Z', 'Z']) {
        _press(tester, key);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.textContaining('No films match'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Films offers Search beside All films and Genres',
        (WidgetTester tester) async {
      _sizeToTv(tester);
      await tester.pumpWidget(_harness(FilmsScreen(
        source: const DemoLibrarySource(),
        onOpen: (MediaItem _) {},
      )));
      await tester.pumpAndSettle();
      expect(find.text('Search'), findsOneWidget);
      await _settleTimers(tester);
    });
  });

  group('Discover by genre and by person', () {
    testWidgets('the Genres chip lists genres to browse', (WidgetTester tester) async {
      _sizeToTv(tester);
      await tester.pumpWidget(_harness(const DiscoverScreen(source: DemoDiscoverSource())));
      await tester.pumpAndSettle();

      _press(tester, 'Genres');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.byType(DiscoverGenreTile), findsWidgets);
      expect(find.text('Science Fiction'), findsOneWidget);
      await expectLater(
          find.byType(DiscoverScreen), matchesGoldenFile('goldens/discover_genres.png'));
      await _settleTimers(tester);
    });

    testWidgets('search offers the people it matched, not just titles',
        (WidgetTester tester) async {
      _sizeToTv(tester);
      await tester.pumpWidget(_harness(const DiscoverSearchScreen(source: DemoDiscoverSource())));
      await tester.pumpAndSettle();

      for (final String key in <String>['A', 'D']) {
        _press(tester, key);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      // A person is a different kind of answer from a title, so it gets its
      // own heading rather than being mixed into the poster grid.
      expect(find.text('PEOPLE'), findsOneWidget);
      expect(find.text('Ada Vance'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets("a person's screen names them and says what they did on each title",
        (WidgetTester tester) async {
      _sizeToTv(tester);
      await tester.pumpWidget(_harness(const DiscoverScreen(
        source: DemoDiscoverSource(),
        person: DiscoverPerson(id: 1, name: 'Ada Vance', knownFor: <String>['Vantage']),
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text('Ada Vance'), findsOneWidget);
      expect(find.textContaining('Known for'), findsOneWidget);
      expect(find.textContaining('Director'), findsOneWidget,
          reason: 'the grid mixes acting and directing, so the bar must say which');
      await expectLater(
          find.byType(DiscoverScreen), matchesGoldenFile('goldens/discover_person.png'));
      await _settleTimers(tester);
    });
  });

  _deleteSubtitleTests();

  group('holding an arrow seeks faster and faster', () {
    // The ramp is pure arithmetic, so it is tested as arithmetic: driving a
    // hundred and fifty key repeats through a widget to measure a curve is
    // slow and proves less.
    test('it starts well past what tapping achieves, and doubles every 0.6 s', () {
      // Tapping a remote that sends eight presses a second already covers
      // 80 s of film a second, so the ramp has to start above that or the
      // acceleration cannot be felt.
      expect(PlayerScreen.rateFor(Duration.zero), 150);
      expect(PlayerScreen.rateFor(const Duration(milliseconds: 600)), closeTo(300, 0.001));
      expect(PlayerScreen.rateFor(const Duration(milliseconds: 1200)), closeTo(600, 0.001));
    });

    test('it caps, so a long hold stays steerable', () {
      // 1200 s of film a second crosses a two-hour film in about six seconds.
      expect(PlayerScreen.rateFor(const Duration(seconds: 10)), 1200);
      expect(PlayerScreen.rateFor(const Duration(minutes: 5)), 1200);
    });

    test('it only ever grows', () {
      double previous = 0;
      for (int ms = 0; ms <= 6000; ms += 100) {
        final double rate = PlayerScreen.rateFor(Duration(milliseconds: ms));
        expect(rate, greaterThanOrEqualTo(previous));
        previous = rate;
      }
    });

    // The Rii air-mouse sends a fresh press and release for each step rather
    // than holding a key down, so an acceleration keyed on KeyRepeatEvent
    // never fired for it and every press was another ten seconds.
    testWidgets('a run of discrete presses accelerates, with no key repeats',
        (WidgetTester tester) async {
      _sizeToTv(tester);
      DateTime now = DateTime(2026, 10, 8, 21, 0);
      miraNow = () => now;

      final MediaItem item =
          (await tester.runAsync(() => const DemoLibrarySource().item('demo-ashfall')))!;
      await tester.pumpWidget(_harness(PlayerScreen(
        source: const DemoLibrarySource(),
        item: item,
        fromStart: true,
        playerFactory: FakeMiraPlayer.new,
      )));
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player:scrub');

      // Press and release, eight times, 120 ms apart - no repeats at all.
      for (int i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        now = now.add(const Duration(milliseconds: 120));
      }
      final Duration reached = _readClock(tester);
      // Eight unaccelerated taps would be 80 s. Anything well past that means
      // the run was recognised.
      expect(reached.inSeconds, greaterThan(120),
          reason: 'discrete presses must accelerate like a held key');

      await _settleTimers(tester);
    });

    testWidgets('a held arrow moves further than a tapped one',
        (WidgetTester tester) async {
      _sizeToTv(tester);
      DateTime now = DateTime(2026, 10, 6, 21, 4);
      miraNow = () => now;

      // runAsync, because a widget test's fake clock never completes the demo
      // source's delays on its own - awaiting one directly just hangs.
      final MediaItem item =
          (await tester.runAsync(() => const DemoLibrarySource().item('demo-ashfall')))!;
      await tester.pumpWidget(_harness(PlayerScreen(
        source: const DemoLibrarySource(),
        item: item,
        fromStart: true,
        playerFactory: FakeMiraPlayer.new,
      )));
      for (int i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'player:scrub');

      // A tap: the 10 s step, unchanged from before.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 20));
      final Duration tapped = _readClock(tester);
      expect(tapped.inSeconds, 10, reason: 'a tap must still be a ten second step');

      // Then a hold: eight repeats, 100 ms of wall clock apart.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      for (int i = 0; i < 8; i++) {
        now = now.add(const Duration(milliseconds: 100));
        await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
      }
      final Duration held = _readClock(tester);
      expect(held - tapped, greaterThan(const Duration(seconds: 30)),
          reason: 'eight repeats of a held arrow should cover far more than another tap');

      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
      await _settleTimers(tester);
    });
  });
}

void _deleteSubtitleTests() {
  // Deleting is server-side: the file goes for every client, so a stray press
  // on a remote must not be enough.
  group('deleting a downloaded subtitle', () {
    testWidgets('asks twice, and only deletes an external track',
        (WidgetTester tester) async {
      _sizeToTv(tester);
      final MediaItem item =
          (await tester.runAsync(() => const DemoLibrarySource().item('demo-ashfall')))!;
      final List<MediaTrack> subs = item.subtitleTracks;
      expect(subs.any((MediaTrack t) => t.isExternal), isTrue,
          reason: 'the demo film needs an external subtitle for this test');

      await tester.pumpWidget(_harness(TracksSheet(
        source: const DemoLibrarySource(),
        item: item,
        initial: const TrackChoice(),
        onChanged: (TrackChoice _, MediaItem __) {},
      )));
      await tester.pumpAndSettle();

      // One Delete control per external subtitle, and none for embedded ones.
      final int external = subs.where((MediaTrack t) => t.isExternal).length;
      expect(find.text('Delete'), findsNWidgets(external));

      _press(tester, 'Delete');
      await tester.pumpAndSettle();
      expect(find.text('Really delete?'), findsOneWidget,
          reason: 'the first press must ask rather than delete');
      expect(find.text('Delete'), findsNWidgets(external - 1));

      await _settleTimers(tester);
    });
  });
}

/// Lets pending timers - the demo source's delays, the backdrop's focus
/// settle - run out before and after the tree goes away, so a test does not
/// fail on a timer belonging to the screen it just closed.
Future<void> _settleTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 400));
}

/// The time the scrub bar is showing, which is where the pending seek has got
/// to. The remaining-time readout is negative, so it never matches.
Duration _readClock(WidgetTester tester) {
  final RegExp clock = RegExp(r'^(\d+):(\d{2}):(\d{2})$');
  for (final Text t in tester.widgetList<Text>(find.byType(Text))) {
    final String? data = t.data;
    if (data == null) continue;
    final RegExpMatch? m = clock.firstMatch(data);
    if (m != null) {
      return Duration(
        hours: int.parse(m.group(1)!),
        minutes: int.parse(m.group(2)!),
        seconds: int.parse(m.group(3)!),
      );
    }
  }
  throw StateError('no clock found on the scrub bar');
}
