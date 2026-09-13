import 'package:flutter/widgets.dart';

import '../core/tokens.dart';
import 'widgets/chrome.dart';
import 'widgets/mira_button.dart';

enum MiraGlyph { networkDown, serverDown, emptyLibrary }

/// One row of a status card: which hop worked and which did not.
class StatusRow {
  const StatusRow({
    required this.label,
    required this.value,
    this.tone = StatusTone.neutral,
  });

  final String label;
  final String value;
  final StatusTone tone;
}

enum StatusTone { good, bad, neutral }

/// A failure is a screen, not an exception.
///
/// Plain-language headline, a status card naming the hop that actually failed,
/// and one small technical line for debugging from the couch. A television must
/// never show a stack trace, and a box that shows nothing is unfixable in a
/// living room.
class MiraStateScreen extends StatelessWidget {
  const MiraStateScreen({
    super.key,
    required this.glyph,
    required this.title,
    required this.body,
    required this.primaryAction,
    required this.onPrimary,
    this.secondaryAction,
    this.onSecondary,
    this.rows = const <StatusRow>[],
    this.technical,
  });

  final MiraGlyph glyph;
  final String title;
  final String body;
  final String primaryAction;
  final VoidCallback onPrimary;
  final String? secondaryAction;
  final VoidCallback? onSecondary;
  final List<StatusRow> rows;
  final String? technical;

  Color get _accent =>
      glyph == MiraGlyph.emptyLibrary ? MiraColors.accent : MiraColors.danger;

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
                center: const Alignment(0, -0.3),
                radius: 0.9,
                colors: <Color>[
                  _accent.withValues(alpha: 0.10),
                  const Color(0x00000000),
                ],
              ),
            ),
          ),
          SafeAreaPadding(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: const <Widget>[
                    MiraStar(),
                    SizedBox(width: 14),
                    Text(
                      'MIRA',
                      style: TextStyle(
                        fontFamily: 'ArchivoBlack',
                        fontSize: 22,
                        letterSpacing: 7.5,
                        color: MiraColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          width: 136,
                          height: 136,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _accent.withValues(alpha: 0.10),
                            border: Border.all(
                              color: _accent.withValues(alpha: 0.42),
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: CustomPaint(
                              size: const Size.square(58),
                              painter: _GlyphPainter(glyph, _accent),
                            ),
                          ),
                        ),
                        const SizedBox(height: 34),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: MiraType.screenTitle.copyWith(fontSize: 62),
                        ),
                        const SizedBox(height: 20),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 780),
                          child: Text(
                            body,
                            textAlign: TextAlign.center,
                            style: MiraType.body.copyWith(fontSize: 24),
                          ),
                        ),
                        if (rows.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 34),
                          _StatusCard(rows: rows),
                        ],
                        const SizedBox(height: 42),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            MiraButton(
                              label: primaryAction,
                              kind: MiraButtonKind.primary,
                              autofocus: true,
                              onSelect: onPrimary,
                            ),
                            if (secondaryAction != null) ...<Widget>[
                              const SizedBox(width: 18),
                              MiraButton(
                                label: secondaryAction!,
                                onSelect: onSecondary,
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (technical != null)
                  Center(
                    child: Text(
                      technical!,
                      style: MiraType.status.copyWith(
                        fontSize: 17,
                        color: MiraColors.textFaint,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.rows});

  final List<StatusRow> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 760,
      decoration: BoxDecoration(
        color: MiraColors.surface,
        borderRadius: const BorderRadius.all(Radius.circular(8)),
        border: Border.all(color: MiraColors.surfaceBorder),
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < rows.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
              decoration: BoxDecoration(
                border: i == rows.length - 1
                    ? null
                    : const Border(
                        bottom: BorderSide(color: MiraColors.hairline),
                      ),
              ),
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 34,
                    child: CustomPaint(
                      size: const Size.square(24),
                      painter: _MarkPainter(rows[i].tone),
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: Text(
                      rows[i].label,
                      style: MiraType.meta
                          .copyWith(fontSize: 21, color: MiraColors.textTertiary),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      rows[i].value,
                      style: MiraType.meta.copyWith(
                        fontSize: 21,
                        color: switch (rows[i].tone) {
                          StatusTone.good => MiraColors.positive,
                          StatusTone.bad => MiraColors.danger,
                          StatusTone.neutral => MiraColors.textSecondary,
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MarkPainter extends CustomPainter {
  const _MarkPainter(this.tone);

  final StatusTone tone;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 24;
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2 * s
      ..strokeCap = StrokeCap.round
      ..color = switch (tone) {
        StatusTone.good => MiraColors.positive,
        StatusTone.bad => MiraColors.danger,
        StatusTone.neutral => MiraColors.textTertiary,
      };

    switch (tone) {
      case StatusTone.good:
        canvas.drawPath(
          Path()
            ..moveTo(5.4 * s, 12.4 * s)
            ..lineTo(9.6 * s, 16.6 * s)
            ..lineTo(18.6 * s, 7.2 * s),
          p,
        );
      case StatusTone.bad:
        canvas
          ..drawLine(Offset(6.4 * s, 6.4 * s), Offset(17.6 * s, 17.6 * s), p)
          ..drawLine(Offset(17.6 * s, 6.4 * s), Offset(6.4 * s, 17.6 * s), p);
      case StatusTone.neutral:
        canvas
          ..drawCircle(Offset(12 * s, 12 * s), 8.4 * s, p)
          ..drawPath(
            Path()
              ..moveTo(12 * s, 7.6 * s)
              ..lineTo(12 * s, 12 * s)
              ..lineTo(15 * s, 14 * s),
            p,
          );
    }
  }

  @override
  bool shouldRepaint(_MarkPainter oldDelegate) => oldDelegate.tone != tone;
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color);

  final MiraGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width / 24;
    final Paint p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    switch (glyph) {
      case MiraGlyph.networkDown:
        canvas
          ..drawPath(
            Path()
              ..moveTo(12 * s, 2.8 * s)
              ..lineTo(20 * s, 6 * s)
              ..lineTo(20 * s, 11.4 * s)
              ..cubicTo(20 * s, 16.4 * s, 16.6 * s, 20 * s, 12 * s, 21.2 * s)
              ..cubicTo(7.4 * s, 20 * s, 4 * s, 16.4 * s, 4 * s, 11.4 * s)
              ..lineTo(4 * s, 6 * s)
              ..close(),
            p,
          )
          ..drawLine(Offset(4.6 * s, 4.2 * s), Offset(19.4 * s, 19.8 * s), p);
      case MiraGlyph.serverDown:
        canvas
          ..drawRRect(
            RRect.fromLTRBR(3.2 * s, 4.2 * s, 20.8 * s, 10.2 * s,
                Radius.circular(1.6 * s)),
            p,
          )
          ..drawRRect(
            RRect.fromLTRBR(3.2 * s, 13.8 * s, 20.8 * s, 19.8 * s,
                Radius.circular(1.6 * s)),
            p,
          )
          ..drawLine(Offset(4.4 * s, 3.2 * s), Offset(19.6 * s, 20.8 * s), p);
      case MiraGlyph.emptyLibrary:
        canvas
          ..drawRRect(
            RRect.fromLTRBR(3.4 * s, 4.6 * s, 20.6 * s, 19.4 * s,
                Radius.circular(2 * s)),
            p,
          )
          ..drawPath(
            Path()
              ..moveTo(3.4 * s, 15.4 * s)
              ..lineTo(7.8 * s, 11.2 * s)
              ..lineTo(11.2 * s, 14.4 * s)
              ..lineTo(14.8 * s, 10.8 * s)
              ..lineTo(20.6 * s, 16.2 * s),
            p,
          );
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
