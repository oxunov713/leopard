import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// Shows one field of an item.
///
/// A secret value is masked until tapped, and hides itself again after
/// [rehideAfter] or when tapped a second time.
class SecretValueTile extends StatefulWidget {
  const SecretValueTile({
    super.key,
    required this.label,
    required this.value,
    this.secret = true,
    this.onCopy,
    this.rehideAfter = const Duration(seconds: 20),
  });

  final String label;
  final String value;
  final bool secret;
  final VoidCallback? onCopy;
  final Duration rehideAfter;

  @override
  State<SecretValueTile> createState() => _SecretValueTileState();
}

class _SecretValueTileState extends State<SecretValueTile> {
  static const String _mask = '••••••••';

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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.label.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      color: LeopardColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    visible ? widget.value : _mask,
                    style: widget.secret
                        ? secretTextStyle
                        : const TextStyle(fontSize: 15, height: 1.35),
                  ),
                ],
              ),
            ),
            if (widget.secret)
              IconButton(
                tooltip: _revealed ? 'Hide' : 'Reveal',
                icon: Icon(
                  _revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
                onPressed: _toggle,
              ),
            if (widget.onCopy != null)
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy_outlined),
                onPressed: widget.onCopy,
              ),
          ],
        ),
      ),
    );
  }
}
