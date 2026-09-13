import 'package:flutter/widgets.dart';

/// Asserts, after the first frame, that this screen has something the d-pad can
/// reach.
///
/// "Everything works with the cursor off" is the kind of rule that holds the day
/// it is written and quietly rots afterwards. This makes the rot loud - in debug
/// builds only, so it costs nothing on the box.
///
/// It must run *after* layout: during build the screen's own children do not
/// exist yet, so the focus tree is legitimately empty and checking then only
/// ever produces a false alarm.
void debugAssertReachableAfterFrame(BuildContext context, {String? screen}) {
  assert(() {
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!context.mounted) return;
      final FocusScopeNode scope = FocusScope.of(context);
      final bool any = scope.traversalDescendants
          .any((FocusNode n) => n.canRequestFocus);
      if (!any) {
        throw FlutterError(
          'The screen ${screen ?? context.widget.runtimeType} has no focusable '
          'control, so the d-pad cannot reach anything on it. Every screen '
          'needs at least one MiraFocusable - including failure screens, '
          'otherwise the remote is stuck with no way out.',
        );
      }
    });
    return true;
  }());
}
