import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../crypto/fingerprint.dart';
import '../../crypto/recovery_key.dart';
import '../../widgets/max_width_content.dart';
import 'auth_providers.dart';

/// Restore the identity keypair from an encrypted backup (ADR-0017).
///
/// This is the good outcome for a user with no keys on this device — it
/// gets their old key back, so everything already sent to them opens.
/// Key rotation, the other option from that state, abandons it. Where
/// both are offered, this comes first.
class RestoreKeyScreen extends ConsumerStatefulWidget {
  const RestoreKeyScreen({super.key});

  @override
  ConsumerState<RestoreKeyScreen> createState() => _RestoreKeyScreenState();
}

class _RestoreKeyScreenState extends ConsumerState<RestoreKeyScreen> {
  final _form = GlobalKey<FormState>();
  final _key = TextEditingController();
  bool _busy = false;
  String? _error;
  Fingerprint? _restored;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final parsed = RecoveryKey.tryParse(_key.text);
    if (parsed == null) {
      setState(() => _error = 'That does not look like a recovery key.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final restored = await repo.restoreFromKeyBackup(parsed);
      await ref.read(authSessionProvider.notifier).refreshMe();
      if (mounted) {
        setState(
          () => _restored = Fingerprint(
            restored.fingerprint.replaceAll(' ', ''),
          ),
        );
      }
    } on RecoveryKeyMismatch catch (exc) {
      // "Check what you typed" — distinct from the two below, because
      // the user's next action is different in each case.
      setState(() => _error = exc.toString());
    } on StaleKeyBackup catch (exc) {
      setState(() => _error = exc.toString());
    } on FormatException catch (exc) {
      setState(() => _error = exc.message);
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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Restore your key')),
      body: MaxWidthContent(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: _restored != null
              ? _done(theme)
              : Form(
                  key: _form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Enter the recovery key you saved when you created '
                        'your backup. It restores the key this account was '
                        'using, so files already sent to you will open '
                        'again.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 20),
                      TextFormField(
                        controller: _key,
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.characters,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          letterSpacing: 1.2,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Recovery key',
                          hintText: 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXXX',
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Enter your recovery key.'
                            : null,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        // Say so, so nobody retypes a key three times
                        // over a dash or a lowercase letter.
                        'Dashes, spaces and capitalisation do not matter.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Restore'),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Widget _done(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Key restored', style: theme.textTheme.titleMedium),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text('Your fingerprint', style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        SelectableText(
          _restored!.display,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 18,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          // It is the SAME key, so contacts who verified it before are
          // still fine. Worth saying — a user who has just been through
          // a scare will wonder.
          'This is the same key as before, so anyone who already verified '
          'your fingerprint does not need to do it again. Files sent to '
          'you while you were locked out will now open.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => context.go('/'),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
