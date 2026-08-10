import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../api/users_api.dart';
import '../../widgets/max_width_content.dart';
import '../../widgets/password_form_field.dart';
import '../auth/auth_providers.dart';

/// Self-serve account erasure — GDPR Article 17.
///
/// The two gates (a typed phrase and a password) are the ones our
/// public deletion policy already describes, so they are implemented
/// exactly as written there rather than approximated. The phrase is
/// checked locally before the request goes out, purely so a typo comes
/// back instantly instead of as a 400.
///
/// The success state deliberately shows a receipt rather than dropping
/// the user straight at the login screen. Erasure is not total — some
/// records survive for audit and referential integrity — and the moment
/// a user has just deleted their account is precisely when they are
/// owed a straight account of what was kept.
class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() =>
      _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _phrase = TextEditingController();
  bool _busy = false;
  String? _error;
  ErasureReceipt? _done;

  @override
  void dispose() {
    _password.dispose();
    _phrase.dispose();
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
      final receipt = await repo.eraseAccount(password: _password.text);
      if (mounted) setState(() => _done = receipt);
    } on ApiException catch (exc) {
      // The server's own text is used verbatim. It distinguishes a wrong
      // password from an account under moderation review, and the second
      // of those tells the user something they need to act on — a
      // generic "could not delete" would strand them.
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delete my account')),
      body: MaxWidthContent(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: _done != null ? _receipt(context, _done!) : _formBody(context),
        ),
      ),
    );
  }

  Widget _formBody(BuildContext context) {
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
                    'This cannot be undone.',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your account is erased, every signed-in session is '
                    'ended, and any transfers still waiting for you are '
                    'destroyed unread. Your encryption keys are removed '
                    'from this device — anything already sent to you '
                    'becomes permanently unreadable, including by us.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Type $erasureConfirmPhrase to confirm',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          TextFormField(
            controller: _phrase,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: erasureConfirmPhrase,
            ),
            // Checked here as well as on the server so a mistyped phrase
            // is caught before the password is sent anywhere.
            validator: (value) => value == erasureConfirmPhrase
                ? null
                : 'Type the phrase exactly: $erasureConfirmPhrase',
          ),
          const SizedBox(height: 16),
          PasswordFormField(
            controller: _password,
            labelText: 'Your password',
            autofillHints: const [AutofillHints.password],
            validator: (value) =>
                (value == null || value.isEmpty) ? 'Required' : null,
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.delete_forever),
            label: const Text('Delete my account'),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy ? null : () => context.pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget _receipt(BuildContext context, ErasureReceipt receipt) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 48,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            'Account deleted',
            style: theme.textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 16),
        if (receipt.pendingTransfersBurned > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              '${receipt.pendingTransfersBurned} transfer(s) that were '
              'waiting for you were destroyed unread.',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        if (receipt.retainedNotice.isNotEmpty) ...[
          Text('What we keep', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(receipt.retainedNotice, style: theme.textTheme.bodySmall),
          const SizedBox(height: 20),
        ],
        FilledButton(
          onPressed: () async {
            // Local key material and tokens are already gone — the
            // repository purged them when the server confirmed. This
            // only drops the in-memory session so the router stops
            // treating the user as signed in.
            await ref.read(authSessionProvider.notifier).clear();
            if (context.mounted) context.go('/login');
          },
          child: const Text('Done'),
        ),
      ],
    );
  }
}
