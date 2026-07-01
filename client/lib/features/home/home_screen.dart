import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../auth/auth_providers.dart';

/// Placeholder landing surface for the signed-in user. Real send / inbox
/// screens land in M2. For M1 we surface the fingerprint (so the user can
/// cross-check with a counterparty out-of-band per spec §6) and the sign-out
/// path.
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
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Signed in as ${data.userId}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Text(
                  'Your fingerprint',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _groupForDisplay(data.fingerprintHex),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Share this out-of-band with the people you transfer with. '
                  'If it changes, someone may be intercepting your keys.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  onPressed: () => context.go('/mfa/enroll'),
                  icon: const Icon(Icons.shield),
                  label: const Text('Enable two-factor authentication'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

String _groupForDisplay(String hex) {
  if (hex.isEmpty) return '(unavailable)';
  final head = hex.length >= 60 ? hex.substring(0, 60) : hex;
  final buf = StringBuffer();
  for (var i = 0; i < head.length; i += 5) {
    if (i > 0) buf.write(' ');
    buf.write(head.substring(i, i + 5 > head.length ? head.length : i + 5));
  }
  return buf.toString();
}
