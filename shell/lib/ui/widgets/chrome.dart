import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/tokens.dart';
import '../../input/mira_focusable.dart';

/// The layered backdrop that gives the Cinema direction its depth: artwork (or
/// a tinted field standing in for it), then scrims that guarantee text contrast
/// no matter what the artwork happens to be.
class MiraBackdrop extends StatelessWidget {
  const MiraBackdrop({
    super.key,
    required this.child,
    this.tint = const Color(0xFF35696B),
    this.horizontalScrim = true,
    this.art,
  });

  final Widget child;
  final Color tint;
  final bool horizontalScrim;

  /// Real artwork, drawn over the tint and *under* the scrims - so text stays
  /// readable whatever the image happens to be.
  final Widget? art;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: MiraColors.background,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.45, -0.45),
                radius: 1.2,
                colors: <Color>[
                  tint,
                  Color.lerp(tint, MiraColors.background, 0.62)!,
                  MiraColors.background,
                ],
                stops: const <double>[0.0, 0.38, 1.0],
              ),
            ),
          ),
          if (art != null) art!,
          if (horizontalScrim)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: <Color>[
                    Color(0xF5060608),
                    Color(0xDB060608),
                    Color(0x3D060608),
                    Color(0x1A060608),
                  ],
                  stops: <double>[0.0, 0.38, 0.74, 1.0],
                ),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: <Color>[Color(0xF7060608), Color(0xB8060608), Color(0x00060608)],
                stops: <double>[0.0, 0.22, 0.56],
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// Everything inside the overscan safe area. The TV will crop the edges.
class SafeAreaPadding extends StatelessWidget {
  const SafeAreaPadding({super.key, required this.child, this.bottom = true});

  final Widget child;
  final bool bottom;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        MiraMetrics.safeH,
        MiraMetrics.safeV,
        MiraMetrics.safeH,
        bottom ? MiraMetrics.safeV : 0,
      ),
      child: child,
    );
  }
}

/// The current time, overridable so goldens are not at the mercy of the wall
/// clock - a clock in a golden makes the test fail whenever the minute ticks.
DateTime Function() miraNow = DateTime.now;

/// The Mira star, drawn rather than shipped as an asset.
class MiraStar extends StatelessWidget {
  const MiraStar({super.key, this.size = 22, this.color = MiraColors.accent});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _StarPainter(color));
  }
}

class _StarPainter extends CustomPainter {
  const _StarPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 24;
    final Path path = Path()
      ..moveTo(12 * s, 3.2 * s)
      ..lineTo(13.9 * s, 9.4 * s)
      ..lineTo(20.2 * s, 9.6 * s)
      ..lineTo(15.2 * s, 13.4 * s)
      ..lineTo(17 * s, 19.7 * s)
      ..lineTo(12 * s, 15.8 * s)
      ..lineTo(7 * s, 19.7 * s)
      ..lineTo(8.8 * s, 13.4 * s)
      ..lineTo(3.8 * s, 9.6 * s)
      ..lineTo(10.1 * s, 9.4 * s)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * s
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_StarPainter oldDelegate) => oldDelegate.color != color;
}

/// Wordmark, navigation and status. Nav entries are plain labels for now: with
/// one app in v1 there is nothing to pick between, and this is where a second
/// one lands when there is.
class MiraTopBar extends StatelessWidget {
  const MiraTopBar({
    super.key,
    this.activeTab = 'Home',
    this.tabs = const <String>['Home', 'Discover', 'Films'],
    this.networkUp = true,
    this.networkLabel = 'homelab',
    this.onTab,
  });

  final String activeTab;

  /// Only tabs that do something. Shows and Settings are in the design and
  /// not built yet - a tab that goes nowhere is worse than no tab.
  final List<String> tabs;

  /// When set, tabs are focusable and switch screens. Up from the content
  /// reaches them through ordinary directional traversal.
  final ValueChanged<String>? onTab;
  final bool networkUp;
  final String networkLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        const MiraStar(),
        const SizedBox(width: 14),
        Text(
          'MIRA',
          style: const TextStyle(
            fontFamily: 'ArchivoBlack',
            fontSize: 22,
            letterSpacing: 7.5,
            color: MiraColors.textPrimary,
          ),
        ),
        const SizedBox(width: 48),
        for (final String tab in tabs) ...<Widget>[
          if (onTab == null)
            _Tab(label: tab, active: tab == activeTab)
          else
            MiraFocusable(
              onSelect: () => onTab!(tab),
              debugLabel: 'tab:$tab',
              borderRadius: const BorderRadius.all(Radius.circular(4)),
              builder: (BuildContext context, bool focused) => Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                child: _Tab(label: tab, active: tab == activeTab),
              ),
            ),
          const SizedBox(width: 26),
        ],
        const Spacer(),
        _NetworkBadge(up: networkUp, label: networkLabel),
        const SizedBox(width: 26),
        const _Clock(),
      ],
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: active
              ? MiraType.nav.copyWith(color: MiraColors.textPrimary)
              : MiraType.nav,
        ),
        const SizedBox(height: 9),
        Container(
          height: 3,
          width: label.length * 11.0,
          color: active ? MiraColors.accent : const Color(0x00000000),
        ),
      ],
    );
  }
}

class _NetworkBadge extends StatelessWidget {
  const _NetworkBadge({required this.up, required this.label});

  final bool up;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: up ? MiraColors.positive : MiraColors.danger,
          ),
        ),
        const SizedBox(width: 10),
        Text(label, style: MiraType.status.copyWith(letterSpacing: 1.1)),
      ],
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  late Timer _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = miraNow();
    // Once every 20 s is plenty for a minute-resolution clock and costs the
    // compositor nothing.
    _timer = Timer.periodic(const Duration(seconds: 20), (Timer _) {
      if (mounted) setState(() => _now = miraNow());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String hh = _now.hour.toString().padLeft(2, '0');
    final String mm = _now.minute.toString().padLeft(2, '0');
    return Text('$hh:$mm', style: MiraType.status);
  }
}
