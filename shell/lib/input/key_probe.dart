import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/tokens.dart';

/// Shows what the box actually receives from the remote, on the screen.
///
/// A bring-up tool, off unless `MIRA_DEBUG_KEYS=1` is set for mira-shell. On a
/// TV with no serial adapter and no ssh, putting the key on screen is the only
/// way to find out what a remote's OK button really sends - and remotes differ.
/// The first one tried on the Pi (a Rii i25) moved focus with its arrows and
/// did nothing at all on OK.
///
/// It reports pointer events too: a remote in air-mouse mode sends clicks, not
/// keys, and that looks identical from the sofa.
class KeyProbe extends StatefulWidget {
  const KeyProbe({super.key, required this.child});

  final Widget child;

  @override
  State<KeyProbe> createState() => _KeyProbeState();
}

class _KeyProbeState extends State<KeyProbe> {
  final List<String> _lines = <String>[];

  void _record(String line) {
    if (!mounted) return;
    setState(() {
      _lines.insert(0, line);
      if (_lines.length > 6) _lines.removeLast();
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final String kind = event is KeyDownEvent
        ? 'down'
        : event is KeyUpEvent
            ? 'up'
            : event is KeyRepeatEvent
                ? 'repeat'
                : 'other';
    _record('$kind  ${event.logicalKey.debugName ?? "?"}  '
        'id 0x${event.logicalKey.keyId.toRadixString(16)}  '
        'phys ${event.physicalKey.debugName ?? "?"}'
        '${event.character == null ? "" : "  char ${event.character}"}');
    // Never consume: the point is to watch what the app does with it.
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (PointerDownEvent e) =>
                _record('pointer down  ${e.kind.name}  buttons ${e.buttons}'),
            child: widget.child,
          ),
        ),
        Positioned(
          left: 28,
          bottom: 28,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: MiraColors.scrim,
              borderRadius: MiraMetrics.borderRadius,
              border: Border.all(color: MiraColors.accent),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('REMOTE', style: MiraType.sectionLabel.copyWith(fontSize: 13)),
                const SizedBox(height: 8),
                if (_lines.isEmpty)
                  Text('press a button', style: MiraType.status.copyWith(fontSize: 16))
                else
                  for (final String line in _lines)
                    Text(line, style: MiraType.status.copyWith(fontSize: 16, color: MiraColors.textPrimary)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
