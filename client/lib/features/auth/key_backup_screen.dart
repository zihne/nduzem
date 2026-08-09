import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../crypto/recovery_key.dart';
import '../../widgets/max_width_content.dart';
import '../../widgets/password_form_field.dart';
import 'auth_providers.dart';

/// Create an encrypted backup of this device's identity keypair
/// (ADR-0017).
///
/// The screen has exactly one irreversible moment: the recovery key is
/// generated here, shown once, and then gone. Nothing else on it
/// matters as much as making sure the user actually wrote it down
/// before that screen is dismissed — which is why leaving is gated on
/// an explicit acknowledgement rather than a "Done" button they can tap
/// past.
class KeyBackupScreen extends ConsumerStatefulWidget {
  const KeyBackupScreen({super.key});

  @override
  ConsumerState<KeyBackupScreen> createState() => _KeyBackupScreenState();
}

class _KeyBackupScreenState extends ConsumerState<KeyBackupScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  RecoveryKey? _created;
  bool _savedIt = false;

  @override
  void dispose() {
    _password.dispose();
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
      final key = await repo.createKeyBackup(password: _password.text);
      // The home screen decides between "not backed up" and "backed up"
      // from this provider; leaving it stale would show the prompt
      // again immediately after the user acted on it.
      ref.invalidate(keyBackupStatusProvider);
      if (mounted) setState(() => _created = key);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } on StateError catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Back up your key')),
      body: MaxWidthContent(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: _created == null ? _explainAndConfirm() : _showKeyOnce(),
        ),
      ),
    );
  }

  Widget _explainAndConfirm() {
    final theme = Theme.of(context);
    // A backup already exists when the user came here from "Create a
    // new backup…", which is the lost-recovery-key path. Saying so
    // matters: the old key stops working, and someone who still had it
    // filed away would otherwise keep a key that silently no longer
    // opens anything.
    final replacing =
        ref.watch(keyBackupStatusProvider).valueOrNull?.exists ?? false;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            replacing ? 'Replacing your backup' : 'Why this matters',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          if (replacing) ...[
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'You already have a backup. Creating a new one gives you '
                  'a new recovery key and stops the old one from working. '
                  'Do this if you have lost the old key — not if you still '
                  'have it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            'Your encryption key lives only on your devices. If you lose '
            'them all — a phone replaced, a browser cleared — files sent '
            'to you can never be opened again, by anyone.\n\n'
            'A backup fixes that. We store an encrypted copy that we '
            'cannot read: it is locked with a recovery key created on '
            'this device and shown to you once. Keep that key somewhere '
            'safe and you can always get back in.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.lock_outline, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    // Said plainly and up front. A user who discovers
                    // this only after losing the key will reasonably
                    // feel misled, and "we cannot help you" is much
                    // harder to hear when it was never mentioned.
                    child: Text(
                      'We never see your recovery key, so we cannot reset '
                      'it or recover your account without it. Losing both '
                      'your devices and the recovery key is permanent.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          PasswordFormField(
            controller: _password,
            labelText: 'Your password',
            autofillHints: const [AutofillHints.password],
            validator: (v) =>
                (v == null || v.isEmpty) ? 'Enter your password.' : null,
          ),
          const SizedBox(height: 4),
          Text(
            // Explaining the ask pre-empts the obvious worry: that the
            // password is what protects the backup. It is not.
            'Confirms it is you. Your password does not unlock the backup '
            '— only the recovery key does.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(replacing ? 'Replace backup' : 'Create backup'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _showKeyOnce() {
    final theme = Theme.of(context);
    final key = _created!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Your recovery key', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'This is shown once and cannot be shown again. Write it down or '
          'save it in a password manager before continuing.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              key.display,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 20,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            await Clipboard.setData(ClipboardData(text: key.display));
            messenger.showSnackBar(
              const SnackBar(content: Text('Recovery key copied.')),
            );
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy'),
        ),
        const SizedBox(height: 20),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _savedIt,
          onChanged: (v) => setState(() => _savedIt = v ?? false),
          title: const Text('I have saved my recovery key'),
          subtitle: const Text(
            'Nobody can show it to you again, including us.',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          // Gated on the acknowledgement rather than free to tap past.
          // The whole value of the backup evaporates if the user leaves
          // this screen without the key, and that is an easy thing to do
          // by reflex.
          onPressed: _savedIt ? () => context.go('/') : null,
          child: const Text('Done'),
        ),
      ],
    );
  }
}
