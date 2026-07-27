import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../widgets/password_form_field.dart';
import 'auth_providers.dart';
import '../../widgets/max_width_content.dart';

/// Phase 2 of the M1.7 password-reset flow: the user tapped the reset
/// link from their email; the router routed us here with `user_id` and
/// `token` in the query. We prompt for a new password (twice) and
/// consume the token.
///
/// The server side revokes every prior refresh token as a side effect,
/// so on success we bounce back to `/login` for a fresh sign-in.
class PasswordResetConfirmScreen extends ConsumerStatefulWidget {
  const PasswordResetConfirmScreen({
    super.key,
    required this.userId,
    required this.token,
  });

  final String userId;
  final String token;

  @override
  ConsumerState<PasswordResetConfirmScreen> createState() =>
      _PasswordResetConfirmScreenState();
}

class _PasswordResetConfirmScreenState
    extends ConsumerState<PasswordResetConfirmScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (_password.text != _confirm.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.confirmPasswordReset(
        userId: widget.userId,
        token: widget.token,
        newPassword: _password.text,
      );
      if (!mounted) return;
      // Server revoked every session; force the user to sign in fresh.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password updated. Please sign in with the new one.'),
        ),
      );
      context.go('/login');
    } on ApiException catch (exc) {
      // Wrong / expired / already-consumed tokens all surface here as
      // the server's single generic 400.
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Choose a new password')),
      body: MaxWidthContent(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Pick a new password. Any other devices you were signed in '
                'on will be signed out.',
              ),
              const SizedBox(height: 24),
              PasswordFormField(
                controller: _password,
                labelText: 'New password',
                autofillHints: const [AutofillHints.newPassword],
                validator: (v) => (v == null || v.length < 10)
                    ? 'Use at least 10 characters.'
                    : null,
              ),
              const SizedBox(height: 12),
              PasswordFormField(
                controller: _confirm,
                labelText: 'Confirm new password',
                autofillHints: const [AutofillHints.newPassword],
                validator: (v) => (v == null || v.isEmpty)
                    ? 'Retype the new password.'
                    : null,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Update password'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              const SizedBox(height: 24),
              TextButton(
                onPressed: _busy ? null : () => context.go('/login'),
                child: const Text('Back to sign in'),
              ),
            ],
          ),
        ),
      ),),
    );
  }
}
