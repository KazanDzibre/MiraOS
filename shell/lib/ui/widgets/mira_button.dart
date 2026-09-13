import 'package:flutter/widgets.dart';

import '../../core/tokens.dart';
import '../../input/mira_focusable.dart';

enum MiraButtonKind { primary, secondary }

/// A button. At least 68 logical pixels tall, always, because the gyro pointer
/// drifts and the remote is imprecise - small adjacent controls are a design
/// bug, not a density choice.
class MiraButton extends StatelessWidget {
  const MiraButton({
    super.key,
    required this.label,
    this.onSelect,
    this.kind = MiraButtonKind.secondary,
    this.icon,
    this.autofocus = false,
    this.focusNode,
  });

  final String label;
  final VoidCallback? onSelect;
  final MiraButtonKind kind;
  final Widget? icon;
  final bool autofocus;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final bool primary = kind == MiraButtonKind.primary;

    return MiraFocusable(
      onSelect: onSelect,
      autofocus: autofocus,
      focusNode: focusNode,
      debugLabel: 'button:$label',
      builder: (BuildContext context, bool focused) {
        return Container(
          height: MiraMetrics.minControl,
          padding: EdgeInsets.symmetric(horizontal: primary ? 34 : 30),
          decoration: BoxDecoration(
            color: primary ? MiraColors.textPrimary : null,
            borderRadius: MiraMetrics.borderRadius,
            border: primary
                ? null
                : Border.all(color: MiraColors.outline, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                IconTheme(
                  data: IconThemeData(
                    color: primary
                        ? MiraColors.background
                        : MiraColors.textPrimary,
                    size: 20,
                  ),
                  child: icon!,
                ),
                const SizedBox(width: 14),
              ],
              Text(
                label,
                style: MiraType.control.copyWith(
                  color: primary
                      ? MiraColors.background
                      : MiraColors.textPrimary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
