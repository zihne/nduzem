import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import 'auth_providers.dart';
import 'auth_repository.dart';
import '../../widgets/max_width_content.dart';

class TotpChallengeScreen extends ConsumerStatefulWidget {
  const TotpChallengeScreen({super.key, required this.mfaSession});
  final String mfaSession;

  @override
  ConsumerState<TotpChallengeScreen> createState() =>
      _TotpChallengeScreenState();
}

class _TotpChallengeScreenState extends ConsumerState<TotpChallengeScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  bool _useRecovery = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_code.text.trim().isEmpty) {
      setState(() => _error = 'Enter the code.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final outcome = await repo.loginTotp(
        mfaSession: widget.mfaSession,
        code: _code.text.trim(),
        isRecovery: _useRecovery,
      );
      // TOTP is stage 2 of password login, so the outcome is always
      // the tokens branch — the API contract guarantees it.
      if (outcome is! LoginOutcomeTokens) {
        setState(() => _error = 'Unexpected server response.');
        return;
      }
      final notifier = ref.read(authSessionProvider.notifier);
      await notifier.setSession(outcome.session);
      // Reconcile handle + verified state against `/v1/users/me`
      // (ADR-0032). This is a soft-failure step: a hiccup here still
      // lets the user land on `/`.
      await notifier.refreshMe();
      if (!mounted) return;
      if (!outcome.emailVerified) {
        context.go('/verify-email?user_id=${outcome.session.userId}');
      } else {
        context.go('/');
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
      appBar: AppBar(title: const Text('Second step')),
      body: MaxWidthContent(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _useRecovery
                  ? 'Enter one of your single-use recovery codes.'
                  : 'Enter the 6-digit code from your authenticator app.',
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _code,
              keyboardType:
                  _useRecovery ? TextInputType.text : TextInputType.number,
              decoration: InputDecoration(
                labelText: _useRecovery ? 'Recovery code' : 'TOTP code',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Continue'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _useRecovery = !_useRecovery;
                        _code.clear();
                        _error = null;
                      }),
              child: Text(
                _useRecovery
                    ? 'Use authenticator app instead'
                    : "Can't access your app? Use a recovery code",
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),),
    );
  }
}
