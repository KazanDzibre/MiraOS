import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../core/tokens.dart';
import 'pointer_mode.dart';

/// Builds a control, told whether it currently holds focus.
typedef FocusedWidgetBuilder = Widget Function(BuildContext context, bool focused);

/// The single focusable primitive in Mira Shell. Every control is one of these.
///
/// Two rules live here, and nowhere else, which is why widgets must not roll
/// their own focus handling:
///
/// 1. **The d-pad is primary.** Focus is a real [FocusNode] in Flutter's
///    traversal graph, so up/down/left/right reach it through the framework's
///    directional policy. That policy also keeps a history stack, which is what
///    makes focus remember its column when it crosses between rows.
///
/// 2. **The pointer moves focus; it does not draw its own state.** When the
///    gyro cursor is on, hovering requests focus, so hover and focus can never
///    disagree about what is selected. When it is off, pointer events are
///    ignored completely - not merely unstyled.
class MiraFocusable extends StatefulWidget {
  const MiraFocusable({
    super.key,
    required this.builder,
    this.onSelect,
    this.focusNode,
    this.autofocus = false,
    this.borderRadius = MiraMetrics.borderRadius,
    this.showRing = true,
    this.debugLabel,
    this.onKey,
    this.revealMargin,
  });

  final FocusedWidgetBuilder builder;

  /// When set, gaining focus scrolls every enclosing scrollable far enough to
  /// show this control plus the margin. Flutter's traversal only scrolls until
  /// the control's own edge meets the viewport's, which clips the focus ring -
  /// it paints outside the bounds - and hides what comes next in a rail.
  final EdgeInsets? revealMargin;

  /// Raw keys while focused, before they become traversal or intents. Only for
  /// controls whose arrows mean something other than "move focus" - the scrub
  /// bar, where left/right seek. Return ignored for anything not consumed.
  final KeyEventResult Function(KeyEvent event)? onKey;

  /// Invoked by OK on the remote, and by a click when the cursor is on.
  final VoidCallback? onSelect;

  final FocusNode? focusNode;
  final bool autofocus;
  final BorderRadius borderRadius;

  /// Set false only when the control paints its own focus treatment (the
  /// reticle on a poster, say). It must still paint *something*.
  final bool showRing;

  final String? debugLabel;

  @override
  State<MiraFocusable> createState() => _MiraFocusableState();
}

class _MiraFocusableState extends State<MiraFocusable> {
  FocusNode? _internalNode;
  bool _focused = false;

  FocusNode get _node =>
      widget.focusNode ?? (_internalNode ??= FocusNode(debugLabel: widget.debugLabel));

  @override
  void dispose() {
    _internalNode?.dispose();
    super.dispose();
  }

  void _handleFocusChange(bool focused) {
    if (focused != _focused) setState(() => _focused = focused);
    final EdgeInsets? margin = widget.revealMargin;
    if (focused && margin != null) {
      // After the frame: the traversal's own scroll has been applied by then,
      // and this only adds the margin on top of it.
      WidgetsBinding.instance.addPostFrameCallback((Duration _) {
        if (!mounted || !_node.hasFocus) return;
        final RenderObject? box = context.findRenderObject();
        if (box is! RenderBox || !box.hasSize) return;
        box.showOnScreen(
          rect: margin.inflateRect(Offset.zero & box.size),
          duration: MiraMotion.focus,
          curve: Curves.easeOut,
        );
      });
    }
  }

  void _select() {
    // Selecting always moves focus first: on a pointer click the focused item
    // and the acted-on item must be the same one.
    if (!_node.hasFocus) _node.requestFocus();
    widget.onSelect?.call();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = Builder(
      builder: (BuildContext context) => widget.builder(context, _focused),
    );

    if (widget.showRing) {
      child = MiraFocusRingBox(
        focused: _focused,
        borderRadius: widget.borderRadius,
        child: child,
      );
    }

    child = Focus(
      focusNode: _node,
      autofocus: widget.autofocus,
      onFocusChange: _handleFocusChange,
      onKeyEvent: widget.onKey == null
          ? null
          : (FocusNode _, KeyEvent event) => widget.onKey!(event),
      child: child,
    );

    // Actions must sit above Focus: the framework resolves an intent by walking
    // up from the focused context.
    child = Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            _select();
            return null;
          },
        ),
      },
      child: child,
    );

    if (PointerMode.enabledOf(context)) {
      child = MouseRegion(
        opaque: false,
        onEnter: (PointerEnterEvent _) {
          if (!_node.hasFocus) _node.requestFocus();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect == null ? null : _select,
          child: child,
        ),
      );
    }

    return child;
  }
}


/// Draws the focus ring around [child] as a stroke.
///
/// It is deliberately not a BoxShadow. A shadow paints the whole box shape,
/// including the area under the child, so anything with a transparent interior
/// - an outlined button, a poster tile whose caption sits below the artwork -
/// comes out as a solid gold slab instead of a ring. Stroking the outline
/// avoids that entirely, and because it paints outside the bounds it still
/// never reflows the layout.
class MiraFocusRingBox extends StatelessWidget {
  const MiraFocusRingBox({
    super.key,
    required this.focused,
    required this.child,
    this.borderRadius = MiraMetrics.borderRadius,
  });

  final bool focused;
  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: focused ? 1 : 0,
              duration: MiraMotion.focus,
              curve: Curves.easeOut,
              child: CustomPaint(painter: _RingPainter(borderRadius)),
            ),
          ),
        ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter(this.borderRadius);

  final BorderRadius borderRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;

    // Halo sits just beyond the solid ring; both are centred on their band, so
    // together they reach exactly MiraFocusRing.reach past the edge.
    _stroke(
      canvas,
      rect,
      inflate: MiraFocusRing.width + MiraFocusRing.haloWidth / 2,
      width: MiraFocusRing.haloWidth,
      color: MiraColors.accent.withValues(alpha: MiraFocusRing.haloOpacity),
    );
    _stroke(
      canvas,
      rect,
      inflate: MiraFocusRing.width / 2,
      width: MiraFocusRing.width,
      color: MiraColors.accent,
    );
  }

  void _stroke(
    Canvas canvas,
    Rect rect, {
    required double inflate,
    required double width,
    required Color color,
  }) {
    final RRect rr = RRect.fromRectAndCorners(
      rect.inflate(inflate),
      topLeft: _grow(borderRadius.topLeft, inflate),
      topRight: _grow(borderRadius.topRight, inflate),
      bottomLeft: _grow(borderRadius.bottomLeft, inflate),
      bottomRight: _grow(borderRadius.bottomRight, inflate),
    );
    canvas.drawRRect(
      rr,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  static Radius _grow(Radius r, double by) =>
      Radius.elliptical(r.x <= 0 ? 0 : r.x + by, r.y <= 0 ? 0 : r.y + by);

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.borderRadius != borderRadius;
}
