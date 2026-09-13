import 'package:flutter/widgets.dart';

/// Whether the gyro cursor is switched on.
///
/// The d-pad is the primary input: every control is reachable with
/// up/down/left/right and OK, and the box stays completely usable with this
/// off. It is a user-facing setting, not a debug flag - see [PointerMode].
class PointerModeController extends ValueNotifier<bool> {
  PointerModeController({bool enabled = true}) : super(enabled);

  void toggle() => value = !value;
}

/// Exposes [PointerModeController] to the tree.
///
/// Widgets read this to decide whether pointer events may move focus. When it
/// is off they must ignore the pointer entirely rather than degrade - a control
/// that only half-works without a cursor is the failure this guards against.
class PointerMode extends InheritedNotifier<PointerModeController> {
  const PointerMode({
    super.key,
    required PointerModeController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Whether pointer input should currently move focus. Defaults to true so a
  /// widget used outside a [PointerMode] still behaves sensibly in tests.
  static bool enabledOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PointerMode>()?.notifier?.value ??
      true;

  /// The controller, without subscribing to changes. Use to flip the setting.
  static PointerModeController? maybeControllerOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<PointerMode>()
      ?.notifier;
}
