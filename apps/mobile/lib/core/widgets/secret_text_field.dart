import 'package:flutter/material.dart';
import 'package:leopard_ui/leopard_ui.dart';

/// A text field for a secret.
///
/// The keyboard is told not to learn from it, suggest for it or correct it,
/// and the field does not take part in autofill. The text is obscured until
/// the user asks to see it.
class SecretTextField extends StatefulWidget {
  const SecretTextField({
    super.key,
    required this.controller,
    required this.label,
    this.helperText,
    this.errorText,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
    this.autofocus = false,
    this.enabled = true,
    this.multiline = false,
    this.keyboardType,
    this.maxLength,
  });

  final TextEditingController controller;
  final String label;
  final String? helperText;
  final String? errorText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final bool enabled;

  /// Multi-line secrets (SSH keys, notes) cannot be obscured by the
  /// platform; they are shown only after the user reveals them.
  final bool multiline;
  final TextInputType? keyboardType;
  final int? maxLength;

  @override
  State<SecretTextField> createState() => _SecretTextFieldState();
}

class _SecretTextFieldState extends State<SecretTextField> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final obscure = !_revealed && !widget.multiline;
    return TextField(
      controller: widget.controller,
      enabled: widget.enabled,
      autofocus: widget.autofocus,
      obscureText: obscure,
      style: leopardSecretTextStyle,
      minLines: widget.multiline ? 3 : 1,
      maxLines: widget.multiline ? 8 : 1,
      maxLength: widget.maxLength,
      keyboardType:
          widget.keyboardType ??
          (widget.multiline
              ? TextInputType.multiline
              : TextInputType.visiblePassword),
      textInputAction: widget.textInputAction,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      autofillHints: null,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      textCapitalization: TextCapitalization.none,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: widget.helperText,
        errorText: widget.errorText,
        counterText: '',
        suffixIcon: widget.multiline
            ? null
            : IconButton(
                tooltip: _revealed ? 'Hide' : 'Show',
                icon: LeopardIcon(
                  LeopardIcons.eye,
                  color: _revealed
                      ? LeopardColors.primary
                      : LeopardColors.textMuted,
                ),
                onPressed: () => setState(() => _revealed = !_revealed),
              ),
      ),
    );
  }
}
