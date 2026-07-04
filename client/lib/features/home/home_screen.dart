import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../crypto/fingerprint.dart';
import '../auth/auth_providers.dart';
import '../auth/auth_repository.dart';
import 'fingerprint_qr_sheet.dart';

/// `Signed in as` line. Both fields are optional in [AuthSession]:
///   - email + handle → `alice@example.com (@alice)`
///   - email only     → `alice@example.com`
///   - handle only    → `@alice`
///   - neither        → placeholder (legacy session that predates M2.x
///                      or a broken `/me` — user should sign back in)
String _identityLine(AuthSession s) {
  final email = s.email;
  final handle = s.handle;
  if (email != null && email.isNotEmpty && handle != null) {
    return '$email (@$handle)';
  }
  if (email != null && email.isNotEmpty) return email;
  if (handle != null) return '@$handle';
  return '(identity not on this device)';
}

/// Placeholder landing surface for the signed-in user. Real send / inbox
/// screens land in M2. For M1 we surface the fingerprint (so the user can
/// cross-check with a counterparty out-of-band per spec §6) and the
/// sign-out path.
///
/// Fingerprint UX (M2.5):
///   - The stored form is [Fingerprint.canonical] (25 decimal digits, no
///     spaces) — the exact string the server-side `key_fingerprint` also
///     produces, so OOB comparisons work whichever direction the value
///     travelled.
///   - We render [Fingerprint.display] (5 groups of 5) for humans and
///     offer three OOB share paths: read it, copy to clipboard, or show
///     as QR.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(authSessionProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpaqueShare'),
        actions: [
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await ref.read(authSessionProvider.notifier).clear();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: session.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Text('Session error: $err'),
          data: (data) {
            if (data == null) {
              return const Text('Not signed in.');
            }
            final fingerprint = data.fingerprint.isEmpty
                ? null
                : Fingerprint(data.fingerprint);
            return ListView(
              children: [
                Text(
                  'Signed in as',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 2),
                SelectableText(
                  _identityLine(data),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                _FingerprintCard(fingerprint: fingerprint),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => context.push('/send'),
                        icon: const Icon(Icons.upload_file),
                        label: const Text('Send a file'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: () => context.push('/inbox'),
                        icon: const Icon(Icons.inbox),
                        label: const Text('Inbox'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: () => context.push('/verify-contact'),
                  icon: const Icon(Icons.verified_user_outlined),
                  label: const Text("Verify a contact's fingerprint"),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => context.push('/history'),
                  icon: const Icon(Icons.history),
                  label: const Text('Transfer history'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => context.push('/paywall'),
                  icon: const Icon(Icons.wallet),
                  label: const Text('Storage & credits'),
                ),
                if (!data.mfaEnabled) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/mfa/enroll'),
                    icon: const Icon(Icons.shield),
                    label: const Text('Enable two-factor authentication'),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Icon(
                        Icons.shield,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      const Text('Two-factor authentication is on'),
                    ],
                  ),
                ],
                const SizedBox(height: 32),
                const Divider(),
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await ref.read(authSessionProvider.notifier).clear();
                    if (context.mounted) context.go('/login');
                  },
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign out'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Signing out clears your session on this device. Your '
                  'private keys stay on-device so you can sign back in '
                  'and keep decrypting past transfers.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FingerprintCard extends StatelessWidget {
  const _FingerprintCard({required this.fingerprint});
  final Fingerprint? fingerprint;

  @override
  Widget build(BuildContext context) {
    final fp = fingerprint;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your fingerprint',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (fp == null)
              const Text(
                '(not available on this device — sign in on the device '
                'where you registered to view it)',
                style: TextStyle(fontStyle: FontStyle.italic),
              )
            else ...[
              SelectableText(
                fp.display,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Share this out-of-band with the people you transfer with. '
                'If it changes, someone may be intercepting your keys.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(
                        ClipboardData(text: fp.display),
                      );
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Fingerprint copied.')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => FingerprintQrSheet(fingerprint: fp),
                    ),
                    icon: const Icon(Icons.qr_code),
                    label: const Text('Show QR'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
