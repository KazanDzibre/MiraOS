import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/tokens.dart';
import '../../input/mira_focusable.dart';

/// The on-screen keyboard and query field shared by every search screen.
///
/// Extracted from Discover's search when the Films grid grew one too: two
/// copies of a d-pad keyboard would drift, and the whole point is that the
/// couch behaves identically wherever you are searching from.
///
/// Every key is a [MiraFocusable], so OK types it. A physical keyboard types
/// too, through [MiraTypeAhead] - the VM and a Bluetooth keyboard on the couch
/// both have one, and nobody wants to spell a title with a d-pad if they have
/// letters to hand.
class MiraKeyboard extends StatelessWidget {
  const MiraKeyboard({
    super.key,
    required this.onType,
    required this.onDelete,
    required this.onClear,
    this.autofocus = true,
  });

  static const int columns = 6;
  static const String _characters = 'abcdefghijklmnopqrstuvwxyz1234567890';

  final ValueChanged<String> onType;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  /// The first key takes focus when the screen opens.
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final List<Widget> rows = <Widget>[];
    for (int start = 0; start < _characters.length; start += columns) {
      final String row =
          _characters.substring(start, (start + columns).clamp(0, _characters.length));
      rows.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < row.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: _Key.gap),
            _Key(
              label: row[i].toUpperCase(),
              autofocus: autofocus && start == 0 && i == 0,
              onSelect: () => onType(row[i]),
            ),
          ],
        ],
      ));
    }
    rows.add(Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _Key(label: 'Space', span: 2, onSelect: () => onType(' ')),
        const SizedBox(width: _Key.gap),
        _Key(label: 'Delete', span: 2, onSelect: onDelete),
        const SizedBox(width: _Key.gap),
        _Key(label: 'Clear', span: 2, onSelect: onClear),
      ],
    ));

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < rows.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: _Key.gap),
          rows[i],
        ],
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.label, required this.onSelect, this.span = 1, this.autofocus = false});

  /// Never smaller than a control: the remote is imprecise and so is the
  /// gyro pointer.
  static const double size = MiraMetrics.minControl;
  static const double gap = 10;

  final String label;
  final VoidCallback onSelect;
  final int span;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return MiraFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
      debugLabel: 'key:$label',
      builder: (BuildContext context, bool focused) => Container(
        width: size * span + gap * (span - 1),
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused ? MiraColors.textPrimary : MiraColors.surface,
          borderRadius: MiraMetrics.borderRadius,
          border: Border.all(color: MiraColors.surfaceBorder),
        ),
        child: Text(
          label,
          style: MiraType.control.copyWith(
            fontSize: span == 1 ? 24 : 19,
            color: focused ? MiraColors.background : MiraColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// The query as typed, large enough to read from the couch, with a caret.
class MiraQueryField extends StatelessWidget {
  const MiraQueryField({super.key, required this.query, this.placeholder = 'Type a title'});

  final String query;
  final String placeholder;

  @override
  Widget build(BuildContext context) {
    final bool empty = query.isEmpty;
    return Container(
      height: 84,
      alignment: Alignment.centerLeft,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: MiraColors.outline, width: 2)),
      ),
      child: Row(
        children: <Widget>[
          Flexible(
            child: Text(
              empty ? placeholder : query,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MiraType.screenTitle.copyWith(
                fontSize: 48,
                color: empty ? MiraColors.textFaint : MiraColors.textPrimary,
              ),
            ),
          ),
          if (!empty) ...<Widget>[
            const SizedBox(width: 6),
            Container(width: 4, height: 52, color: MiraColors.textPrimary),
          ],
        ],
      ),
    );
  }
}

/// Wraps a search screen so a physical keyboard types into it from anywhere,
/// whatever holds focus.
///
/// Space is deliberately not typeable from the physical keyboard: it is OK on
/// the bench keyboard, and would activate the focused key instead of typing.
/// The on-screen Space key covers it.
class MiraTypeAhead extends StatelessWidget {
  const MiraTypeAhead({
    super.key,
    required this.onType,
    required this.onDelete,
    required this.child,
  });

  static final RegExp _typeable = RegExp(r"[A-Za-z0-9'\-:&.,!?]");

  final ValueChanged<String> onType;
  final VoidCallback onDelete;
  final Widget child;

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      onDelete();
      return KeyEventResult.handled;
    }
    final String? ch = event.character;
    if (ch != null && ch.length == 1 && _typeable.hasMatch(ch)) {
      onType(ch.toLowerCase());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: child,
    );
  }
}
