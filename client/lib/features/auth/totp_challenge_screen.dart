import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import 'auth_providers.dart';

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
      final session = await repo.loginTotp(
        mfaSession: widget.mfaSession,
        code: _code.text.trim(),
        isRecovery: _useRecovery,
      );
      await ref.read(authSessionProvider.notifier).setSession(session);
      if (mounted) context.go('/');
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
      body: Padding(
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
              keyboardType: _useRecovery
                  ? TextInputType.text
                  : TextInputType.number,
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
      ),
    );
  }
}
