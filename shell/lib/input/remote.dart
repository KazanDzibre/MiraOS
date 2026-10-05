import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Go back one level - the remote's Back button.
class BackIntent extends Intent {
  const BackIntent();
}

/// Open the contextual menu for whatever is focused - the remote's Menu button.
class MenuIntent extends Intent {
  const MenuIntent();
}

/// Maps remote buttons onto intents.
///
/// Arrow keys already reach [DirectionalFocusIntent] through WidgetsApp's
/// defaults, which is what makes d-pad traversal work without a bespoke
/// navigation model. This adds the buttons a TV remote has and a keyboard does
/// not, plus the keyboard equivalents that make the VM target usable.
class RemoteShortcuts extends StatelessWidget {
  const RemoteShortcuts({super.key, required this.child});

  final Widget child;

  // OK, Back and Menu fire once per press: includeRepeats is off. It defaults
  // to on, so holding Back a moment too long - or a release arriving late, as
  // QEMU's injected keys do - popped the film page as well as the player
  // (found in the VM). Arrow keys still repeat, through WidgetsApp's defaults,
  // because holding them to scroll or scrub is the point.
  static const Map<ShortcutActivator, Intent> _bindings =
      <ShortcutActivator, Intent>{
    // OK / centre of the d-pad. `select` is what an HID remote sends; enter and
    // space are for the VM and for a keyboard on the bench.
    SingleActivator(LogicalKeyboardKey.select, includeRepeats: false): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space, includeRepeats: false): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA, includeRepeats: false): ActivateIntent(),
    // Remotes disagree about which key OK is, and a TV box cannot ask. These
    // are the rest of the plausible ones; numpadEnter and accept are what HID
    // remotes with a keypad tend to send.
    SingleActivator(LogicalKeyboardKey.numpadEnter, includeRepeats: false): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.accept, includeRepeats: false): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.execute, includeRepeats: false): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonStart, includeRepeats: false): ActivateIntent(),

    // Back.
    SingleActivator(LogicalKeyboardKey.escape, includeRepeats: false): BackIntent(),
    SingleActivator(LogicalKeyboardKey.browserBack, includeRepeats: false): BackIntent(),
    SingleActivator(LogicalKeyboardKey.goBack, includeRepeats: false): BackIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonB, includeRepeats: false): BackIntent(),

    // Menu.
    SingleActivator(LogicalKeyboardKey.contextMenu, includeRepeats: false): MenuIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonMode, includeRepeats: false): MenuIntent(),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts(shortcuts: _bindings, child: child);
  }
}
