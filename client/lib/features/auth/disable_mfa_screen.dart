// Turn two-factor authentication off.
//
// Until now the app could ENABLE two-factor and never disable it. Someone
// who lost their authenticator could still sign in with a recovery code,
// but had no route back to a working account without contacting support.
//
// The server requires the account password AND a second factor —
// deliberately, and recently: `/v1/auth/mfa/disable` previously accepted
// a code alone with no rate limit, so a stolen session plus roughly 333k
// guesses against a 6-digit TOTP removed the second factor in about an
// hour. Rate limits make guessing expensive; the password makes it
// impossible for someone who holds only session tokens.
//
// This screen therefore asks for both, and says why — a user who has just
// been told to re-enter a password they already typed at login deserves
// the reason.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../widgets/max_width_content.dart';
import 'auth_providers.dart';

class DisableMfaScreen extends ConsumerStatefulWidget {
  const DisableMfaScreen({super.key});

  @override
  ConsumerState<DisableMfaScreen> createState() => _DisableMfaScreenState();
}

class _DisableMfaScreenState extends ConsumerState<DisableMfaScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _useRecoveryCode = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final stillEnabled = await repo.mfaDisable(
        password: _password.text,
        code: _code.text.trim(),
        isRecoveryCode: _useRecoveryCode,
      );
      if (!stillEnabled) {
        await ref.read(authSessionProvider.notifier).markMfaEnabled(false);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Two-factor authentication is off.')),
      );
      context.pop();
    } on ApiException catch (exc) {
      // 401 covers both a wrong password and a wrong code, and the server
      // does not say which — nor should it. Report both possibilities
      // rather than guessing, so the user checks the right field.
      if (!mounted) return;
      setState(() {
        _error = exc.statusCode == 401
            ? 'That password or code was not accepted. Check both and try '
                'again.'
            : exc.message;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Turn off two-factor')),
      body: MaxWidthContent(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Your account will be protected by your password alone. '
                  'Anyone who learns it will be able to sign in.',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  decoration: const InputDecoration(
                    labelText: 'Account password',
                    helperText:
                        'Required so that someone with only your unlocked '
                        'phone cannot remove this protection.',
                    helperMaxLines: 3,
                  ),
                  validator: (v) => (v == null || v.isEmpty)
                      ? 'Enter your password'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _code,
                  keyboardType: _useRecoveryCode
                      ? TextInputType.text
                      : TextInputType.number,
                  decoration: InputDecoration(
                    labelText: _useRecoveryCode
                        ? 'Recovery code'
                        : 'Six-digit code',
                    helperText: _useRecoveryCode
                        ? 'One of the codes you saved when you turned this on.'
                        : 'From your authenticator app.',
                    helperMaxLines: 2,
                  ),
                  validator: (v) {
                    final s = v?.trim() ?? '';
                    if (s.isEmpty) return 'Enter a code';
                    if (!_useRecoveryCode && s.length != 6) {
                      return 'A TOTP code is six digits';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                // The escape hatch. Someone disabling two-factor has
                // often lost the authenticator — offering only a TOTP
                // field would leave exactly those users stuck, which is
                // the gap this screen exists to close.
                CheckboxListTile(
                  value: _useRecoveryCode,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                            _useRecoveryCode = v ?? false;
                            _code.clear();
                          }),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text("I'll use a recovery code instead"),
                  subtitle: const Text(
                    'Use this if you no longer have your authenticator.',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  child: _busy
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Turn off two-factor'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
