import 'dart:async';

import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

/// Shows one field of an item.
///
/// A secret value is masked until tapped, and hides itself again after
/// [rehideAfter] or when tapped a second time. Put it in a [CardGroup]; the
/// card draws the dividers.
class SecretValueTile extends StatefulWidget {
  const SecretValueTile({
    super.key,
    required this.label,
    required this.value,
    this.secret = true,
    this.onCopy,
    this.rehideAfter = const Duration(seconds: 20),
    this.footer,
  });

  final String label;
  final String value;
  final bool secret;
  final VoidCallback? onCopy;
  final Duration rehideAfter;

  /// Shown under the value, for instance a strength bar.
  final Widget? footer;

  @override
  State<SecretValueTile> createState() => _SecretValueTileState();
}

class _SecretValueTileState extends State<SecretValueTile> {
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
    return InkWell(
      onTap: widget.secret ? _toggle : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.label,
                        style: const TextStyle(
                          fontSize: 12,
                          color: LeopardColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        visible ? widget.value : _mask,
                        style: widget.secret
                            ? leopardSecretTextStyle.copyWith(
                                fontSize: 17,
                                letterSpacing: _revealed ? 0.4 : 2,
                              )
                            : const TextStyle(fontSize: 16, height: 1.35),
                      ),
                    ],
                  ),
                ),
                if (widget.secret)
                  IconButton(
                    tooltip: _revealed ? 'Hide' : 'Reveal',
                    icon: LeopardIcon(
                      LeopardIcons.eye,
                      color: _revealed
                          ? LeopardColors.primary
                          : LeopardColors.textMuted,
                    ),
                    onPressed: _toggle,
                  ),
                if (widget.onCopy != null)
                  IconButton(
                    tooltip: 'Copy',
                    style: widget.secret
                        ? IconButton.styleFrom(
                            backgroundColor: LeopardColors.primaryContainer,
                          )
                        : null,
                    icon: LeopardIcon(
                      LeopardIcons.copy,
                      color: widget.secret
                          ? LeopardColors.primary
                          : LeopardColors.textMuted,
                    ),
                    onPressed: widget.onCopy,
                  ),
              ],
            ),
            if (widget.footer != null)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 10),
                child: widget.footer,
              ),
          ],
        ),
      ),
    );
  }
}
