import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../core/external_launcher.dart';
import '../../widgets/password_form_field.dart';
import 'auth_providers.dart';
import '../../widgets/max_width_content.dart';

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _handle = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _handle.dispose();
    // Gesture recognizers hold a reference to their callback and are
    // not garbage-collected with the TextSpan that used them.
    _termsTap.dispose();
    _privacyTap.dispose();
    super.dispose();
  }

  /// The agreement line under "Create account".
  ///
  /// Built with real tap targets rather than a sentence naming two
  /// documents the reader cannot reach — an agreement you are told
  /// about but cannot read is not one anybody has actually accepted.
  Widget _agreementNotice(BuildContext context) {
    final theme = Theme.of(context);
    final linkStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return Text.rich(
      TextSpan(
        style: theme.textTheme.bodySmall,
        children: [
          const TextSpan(text: 'By creating an account you agree to our '),
          TextSpan(
            text: 'Terms of Service',
            style: linkStyle,
            recognizer: _termsTap,
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'Privacy Policy',
            style: linkStyle,
            recognizer: _privacyTap,
          ),
          const TextSpan(text: '.'),
        ],
      ),
      textAlign: TextAlign.center,
    );
  }

  Future<void> _openLegal(String file) async {
    final uri = ref.read(appConfigProvider).legalPage(file);
    final result = await launchExternalUri(uri);
    if (result == ExternalLaunchResult.noHandler && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Open this in a browser: $uri')),
      );
    }
  }

  late final _termsTap = TapGestureRecognizer()
    ..onTap = () => _openLegal('terms.html');
  late final _privacyTap = TapGestureRecognizer()
    ..onTap = () => _openLegal('privacy.html');

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final session = await repo.register(
        email: _email.text.trim(),
        password: _password.text,
        handle: _handle.text.trim().isEmpty ? null : _handle.text.trim(),
      );
      final notifier = ref.read(authSessionProvider.notifier);
      await notifier.setSession(session);
      // Reconcile against `/v1/users/me` so the home screen has the
      // handle + verified state the server reports (ADR-0032). Soft
      // failure — if /me falls over we still hand off to verify-email.
      await notifier.refreshMe();
      if (mounted) {
        // Thread the registered email through so the verify screen can
        // send the {email, code} payload the server expects.
        final email = Uri.encodeQueryComponent(_email.text.trim());
        context.go('/verify-email?user_id=${session.userId}&email=$email');
      }
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create account')),
      body: MaxWidthContent(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Email'),
                validator: (v) => (v == null || !v.contains('@'))
                    ? 'Enter a valid email address.'
                    : null,
              ),
              const SizedBox(height: 12),
              PasswordFormField(
                controller: _password,
                labelText: 'Password',
                autofillHints: const [AutofillHints.newPassword],
                validator: (v) => (v == null || v.length < 10)
                    ? 'Use at least 10 characters.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _handle,
                decoration: const InputDecoration(
                  labelText: 'Handle (optional)',
                ),
              ),
              // Web only, and shown BEFORE the button rather than after
              // registering. Your identity key is generated here and
              // kept by this browser — it is never sent to the server,
              // which is the property the whole product rests on, and
              // also means nobody can restore it for you. Browsers treat
              // that storage as disposable, so this is a real constraint
              // rather than a disclaimer, and someone choosing a browser
              // to register in deserves to know before they choose.
              if (kIsWeb) ...[
                const SizedBox(height: 20),
                Card(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.key_outlined, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Your encryption key is created in this browser '
                            'and never leaves it. That is what stops us from '
                            'reading your files — and it means we cannot '
                            'restore it for you.\n\n'
                            'Sign in from this same browser to open files '
                            'sent to you. Clearing site data, or not '
                            'visiting for a long time, can erase the key '
                            'permanently. For everyday use, the mobile app '
                            'keeps it in your device keychain instead.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Create account'),
              ),
              const SizedBox(height: 12),
              // Our terms open with "by creating an account you agree to
              // them" — true of the document, and not of the product:
              // this screen neither said so nor offered any way to read
              // them. Stated at the point of agreement, with both
              // documents one tap away.
              _agreementNotice(context),
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
                child: const Text('Already have an account? Sign in'),
              ),
            ],
          ),
        ),
      ),),
    );
  }
}
