import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/core/tokens.dart';
import 'package:mira_shell/input/pointer_mode.dart';
import 'package:mira_shell/network/netbird.dart';
import 'package:mira_shell/ui/network_screen.dart';
import 'package:mira_shell/ui/widgets/chrome.dart';

/// A NetBird that accepts the sign-in and then says nothing at all - which is
/// what it does when it cannot reach its own service, and is how the sign-in
/// page came to show an empty square for ever.
class _SilentNetbird implements NetbirdControl {
  // Never emits, never errors - exactly what `netbird up` does when it cannot
  // reach its management service.
  @override
  Stream<LoginStep> signIn() => StreamController<LoginStep>().stream;

  @override
  Future<NetbirdStatus> status() async => const NetbirdStatus(NetbirdState.signedOut);
}

Widget _harness(Widget child) => MediaQuery(
      data: const MediaQueryData(size: Size(1920, 1080), devicePixelRatio: 1),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: PointerMode(
          controller: PointerModeController(),
          child: DefaultTextStyle(
            style: MiraType.body,
            child: ColoredBox(color: MiraColors.background, child: child),
          ),
        ),
      ),
    );

void _sizeToTv(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  tearDown(() => miraNow = DateTime.now);

  testWidgets('a sign-in that produces no code says why, and names the clock',
      (WidgetTester tester) async {
    _sizeToTv(tester);
    // The Pi has no battery-backed clock, so this is the state it boots into.
    miraNow = () => DateTime(1970);

    await tester.pumpWidget(_harness(NetbirdSignInScreen(control: _SilentNetbird())));
    await tester.pump();
    expect(find.textContaining('Asking NetBird'), findsOneWidget);

    // Past the point where a working sign-in would have answered.
    await tester.pump(const Duration(seconds: 21));
    expect(find.textContaining("clock is wrong"), findsOneWidget,
        reason: 'a 1970 clock breaks TLS, and nothing else on screen says so');
    expect(find.textContaining('1970'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('with a sane clock it blames the network instead',
      (WidgetTester tester) async {
    _sizeToTv(tester);
    miraNow = () => DateTime(2026, 10, 8);

    await tester.pumpWidget(_harness(NetbirdSignInScreen(control: _SilentNetbird())));
    await tester.pump(const Duration(seconds: 21));
    expect(find.textContaining('reach the internet'), findsOneWidget);
    expect(find.textContaining('clock is wrong'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
