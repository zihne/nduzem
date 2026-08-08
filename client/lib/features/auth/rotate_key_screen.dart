import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../api/users_api.dart';
import '../../widgets/max_width_content.dart';
import '../../widgets/password_form_field.dart';
import 'auth_providers.dart';

/// Replace this account's identity keypair (ADR-0017).
///
/// This screen exists for one situation: the private key is gone and is
/// not coming back. A wiped phone, cleared browser storage, or WebKit
/// deleting all script-writable storage after seven days of Safari use
/// without interacting with the site. Before rotation there was no way
/// out of that — the account stayed live, and could never decrypt again.
///
/// It recovers nothing, and the copy says so plainly rather than letting
/// "recover" imply otherwise. Anything already sealed to the old key
/// stays sealed to the old key forever.
class RotateKeyScreen extends ConsumerStatefulWidget {
  const RotateKeyScreen({super.key});

  @override
  ConsumerState<RotateKeyScreen> createState() => _RotateKeyScreenState();
}

class _RotateKeyScreenState extends ConsumerState<RotateKeyScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _mfaCode = TextEditingController();
  bool _isRecoveryCode = false;
  bool _understood = false;
  bool _busy = false;
  String? _error;
  IdentityKeyRotation? _done;

  @override
  void dispose() {
    _password.dispose();
    _mfaCode.dispose();
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
      final result = await repo.rotateIdentityKey(
        password: _password.text,
        mfaCode: _mfaCode.text.trim().isEmpty ? null : _mfaCode.text.trim(),
        mfaIsRecoveryCode: _isRecoveryCode,
      );
      // Pull the session's cached fingerprint back in line so the home
      // screen shows the new value rather than the old one.
      await ref.read(authSessionProvider.notifier).refreshMe();
      if (mounted) setState(() => _done = result);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } on StateError catch (exc) {
      // Raised when the server's fingerprint disagrees with ours — the
      // one case where the user must NOT be handed a number to share.
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(authSessionProvider).valueOrNull;
    final mfaEnabled = session?.mfaEnabled ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Replace encryption key')),
      body: MaxWidthContent(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: _done != null ? _result(context) : _formBody(context, mfaEnabled),
        ),
      ),
    );
  }

  Widget _formBody(BuildContext context, bool mfaEnabled) {
    final theme = Theme.of(context);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This does not recover anything',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  // Deliberately blunt. A screen labelled "recover" that
                  // silently fails to recover the files someone came
                  // here for is worse than the dead end it replaced.
                  Text(
                    'Replacing your key lets people send you files again. '
                    'It cannot open files that were already sent to you — '
                    'those are locked to your old key, and nobody, '
                    'including us, can unlock them without it.\n\n'
                    'Only do this if your old key is genuinely gone. If it '
                    'still exists on another device or browser, sign in '
                    'there instead and keep it.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Your contacts will be warned that your fingerprint changed, and '
            'will need to verify the new one with you before they can send. '
            'That warning is working as intended — from the outside, an '
            'honest replacement looks exactly like someone impersonating you.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          PasswordFormField(
            controller: _password,
            labelText: 'Your password',
            autofillHints: const [AutofillHints.password],
            validator: (v) =>
                (v == null || v.isEmpty) ? 'Enter your password.' : null,
          ),
          if (mfaEnabled) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _mfaCode,
              decoration: InputDecoration(
                labelText: _isRecoveryCode
                    ? 'Recovery code'
                    : 'Code from your authenticator',
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Enter a code.'
                  : null,
            ),
            // The lost-device case is the ordinary reason to be on this
            // screen, and a lost device takes the authenticator with it.
            // Without this option the second factor would block the
            // recovery it exists to protect.
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _isRecoveryCode,
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _isRecoveryCode = v ?? false),
              title: const Text('Use a recovery code instead'),
              subtitle: const Text(
                "If you've lost the device with your authenticator on it.",
              ),
            ),
          ],
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _understood,
            onChanged:
                _busy ? null : (v) => setState(() => _understood = v ?? false),
            title: const Text(
              'I understand files already sent to me will stay unreadable',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: (_busy || !_understood) ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Replace my key'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _result(BuildContext context) {
    final theme = Theme.of(context);
    final done = _done!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your new fingerprint', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(
          done.keyFingerprint,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 18,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Share this with the people you exchange files with, the same way '
          'you shared the old one. We also emailed it to you — if that email '
          'arrives and you did not do this, change your password immediately.',
          style: theme.textTheme.bodySmall,
        ),
        if (done.pendingTransfersUnreadable > 0) ...[
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                // Named rather than hidden. The count is the honest cost
                // of the operation, and the user chose to pay it.
                '${done.pendingTransfersUnreadable} '
                '${done.pendingTransfersUnreadable == 1 ? "file was" : "files were"} '
                'waiting for you and can no longer be opened. Ask the sender '
                'to send again.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => context.go('/'),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
