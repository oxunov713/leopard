import 'dart:async';

import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

import 'ui_parts.dart';

/// One row of the field table of an item: label, value, and buttons.
///
/// A secret value is masked until revealed, and hides itself again after
/// [rehideAfter]. The value is plain [Text], never selectable: a selection
/// could be copied with Ctrl+C and so bypass the clipboard clear.
class FieldRow extends StatefulWidget {
  const FieldRow({
    super.key,
    required this.label,
    required this.value,
    this.secret = false,
    this.onCopy,
    this.copyHint,
    this.primaryCopy = false,
    this.contentKey,
    this.compact = false,
    this.rehideAfter = const Duration(seconds: 20),
  });

  final String label;
  final String value;
  final bool secret;
  final VoidCallback? onCopy;

  /// Keyboard hint on the copy button, e.g. "Ctrl C".
  final String? copyHint;

  /// Whether the copy button is the accent one (the field Ctrl+C copies).
  final bool primaryCopy;

  /// Key of the row's content, for tests.
  final Key? contentKey;

  /// A narrower label column, for small windows.
  final bool compact;
  final Duration rehideAfter;

  @override
  State<FieldRow> createState() => _FieldRowState();
}

class _FieldRowState extends State<FieldRow> {
  static const String _mask = '••••••••••••••••';

  bool _revealed = false;
  Timer? _timer;

  void _toggle() {
    _timer?.cancel();
    setState(() => _revealed = !_revealed);
    if (_revealed) {
      _timer = Timer(widget.rehideAfter, () {
        if (mounted) {
          setState(() => _revealed = false);
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visible = !widget.secret || _revealed;
    final TextStyle valueStyle;
    if (widget.secret) {
      valueStyle = leopardSecretTextStyle.copyWith(
        letterSpacing: visible ? 0.4 : 2,
      );
    } else {
      valueStyle = const TextStyle(fontSize: 15, height: 1.4);
    }
    return Padding(
      key: widget.contentKey,
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: widget.compact ? 84 : 110,
            child: Text(
              widget.label,
              style: const TextStyle(
                fontSize: 13,
                color: LeopardColors.textMuted,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(visible ? widget.value : _mask, style: valueStyle),
            ),
          ),
          if (widget.secret)
            IconButton(
              tooltip: _revealed ? 'Hide' : 'Reveal',
              visualDensity: VisualDensity.compact,
              style: IconButton.styleFrom(
                minimumSize: const Size(32, 32),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: LeopardIcon(
                LeopardIcons.eye,
                size: 18,
                color: _revealed
                    ? LeopardColors.primary
                    : LeopardColors.textMuted,
              ),
              onPressed: _toggle,
            ),
          if (widget.onCopy != null)
            _CopyButton(
              onPressed: widget.onCopy!,
              hint: widget.compact ? null : widget.copyHint,
              primary: widget.primaryCopy,
            ),
        ],
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({
    required this.onPressed,
    required this.primary,
    this.hint,
  });

  final VoidCallback onPressed;
  final String? hint;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final foreground = primary ? LeopardColors.onPrimary : LeopardColors.text;
    return Tooltip(
      message: 'Copy',
      child: Material(
        color: primary ? LeopardColors.primary : LeopardColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          hoverColor: primary
              ? Colors.white.withValues(alpha: 0.12)
              : LeopardColors.outline,
          mouseCursor: SystemMouseCursors.click,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Copy',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: primary ? FontWeight.w600 : FontWeight.w500,
                    color: foreground,
                  ),
                ),
                if (hint != null) ...[
                  const SizedBox(width: 6),
                  Kbd(
                    hint!,
                    outlined: false,
                    color: primary
                        ? LeopardColors.onPrimary.withValues(alpha: 0.75)
                        : LeopardColors.textMuted,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
