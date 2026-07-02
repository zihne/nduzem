import 'package:flutter/material.dart';

/// Password form field with an eye-toggle suffix icon.
///
/// Behaviour:
///   - starts obscured (dots)
///   - tapping the eye icon toggles between obscured and cleartext
///   - the icon reflects the current state (`visibility_off` when
///     hidden, `visibility` when shown)
///   - all the usual [TextFormField] knobs are forwarded: controller,
///     validator, hint, autofillHints, labelText, textInputAction,
///     onSubmitted.
///
/// Use this in every screen that asks for a password so the UX is
/// consistent (register, login, password-reset confirm, and — if we
/// ever add a "change password" screen — that too).
class PasswordFormField extends StatefulWidget {
  const PasswordFormField({
    super.key,
    required this.controller,
    required this.labelText,
    this.validator,
    this.autofillHints,
    this.textInputAction,
    this.onFieldSubmitted,
  });

  final TextEditingController controller;
  final String labelText;
  final String? Function(String?)? validator;
  final List<String>? autofillHints;
  final TextInputAction? textInputAction;
  final void Function(String)? onFieldSubmitted;

  @override
  State<PasswordFormField> createState() => _PasswordFormFieldState();
}

class _PasswordFormFieldState extends State<PasswordFormField> {
  bool _obscured = true;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: widget.controller,
      obscureText: _obscured,
      autofillHints: widget.autofillHints,
      textInputAction: widget.textInputAction,
      onFieldSubmitted: widget.onFieldSubmitted,
      validator: widget.validator,
      decoration: InputDecoration(
        labelText: widget.labelText,
        suffixIcon: IconButton(
          tooltip: _obscured ? 'Show password' : 'Hide password',
          icon: Icon(_obscured ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _obscured = !_obscured),
        ),
      ),
    );
  }
}
