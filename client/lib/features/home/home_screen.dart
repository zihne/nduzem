import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../crypto/fingerprint.dart';
import '../auth/auth_providers.dart';
import '../../api/users_api.dart';
import '../auth/auth_repository.dart';
import 'fingerprint_qr_sheet.dart';
import '../../widgets/max_width_content.dart';

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
      body: MaxWidthContent(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: session.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Text('Session error: $err'),
          data: (data) {
            if (data == null) {
              return const Text('Not signed in.');
            }
            final fingerprint =
                data.fingerprint.isEmpty ? null : Fingerprint(data.fingerprint);
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
                _FingerprintCard(
                  fingerprint: fingerprint,
                  backedUp: ref.watch(keyBackupStatusProvider).valueOrNull,
                ),
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
      ),),
    );
  }
}

class _FingerprintCard extends StatelessWidget {
  const _FingerprintCard({required this.fingerprint, this.backedUp});
  final Fingerprint? fingerprint;

  /// Null means "we could not find out" — distinct from "no backup".
  /// Prompting on an unknown would nag people who are already protected
  /// whenever the network hiccups, which teaches them to dismiss it.
  final KeyBackupStatus? backedUp;

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
              // The advice has to differ by platform, because the same
              // symptom has two different causes and only one of them is
              // recoverable.
              //
              // Native: the keypair is in the Keychain /
              // EncryptedSharedPreferences of whichever device
              // registered. It still exists there. "Go to that device"
              // is correct and actionable.
              //
              // Web: it may also simply be GONE. Browser storage is
              // evictable — WebKit deletes all script-writable storage
              // after seven days of Safari use without interaction, and
              // clearing site data does the same instantly. Telling
              // someone to return to a browser that no longer holds
              // anything sends them looking for something that is not
              // there. Say both, honestly, rather than imply the loss
              // is always recoverable.
              Text(
                kIsWeb
                    ? '(not available in this browser)\n\n'
                        'Your key is stored by the browser or device you '
                        'registered with, and is not shared automatically. '
                        'If you saved a recovery key, restore it below — '
                        'that installs the same key here, and files sent '
                        'to you will open.\n\n'
                        'Without a recovery key, open OpaqueShare where '
                        'the key already is. If that device is gone and '
                        'you have no recovery key, the key cannot be '
                        'brought back and files already sent cannot be '
                        'opened.'
                    : '(not available on this device)\n\n'
                        'If you saved a recovery key, restore it below to '
                        'install the same key on this device. Otherwise '
                        'sign in on the device where you registered.',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            // Prominent when the key is ABSENT — this is the only way
            // forward from that state, and surfacing it here means they
            // find it where they hit the problem.
            //
            // A quieter version appears at the end of the `else` branch
            // below, so rotation can also be INITIATED with a working
            // key. An earlier version omitted that on the reasoning that
            // rotation permanently orphans everything already sent and
            // should not sit one tap from a healthy account. That was
            // wrong: it removed the capability rather than gating it,
            // and removed it exactly where it matters most — suspected
            // key compromise (a stolen laptop, a device someone else
            // used) is a legitimate reason to rotate, and the key still
            // works fine in that case. The guardrails belong on the
            // destination screen, where they are: password, second
            // factor, and an explicit acknowledgement of the loss.
            if (fp == null) ...[
              // Restore comes first, and is the filled button, because
              // it is strictly the better outcome: it brings the
              // ORIGINAL key back, so everything already sent opens.
              // Replacing the key abandons all of it. Offering only the
              // destructive option — as an earlier version did — invites
              // someone to throw away recoverable mail because it was
              // the only button on the screen.
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => context.push('/restore-key'),
                icon: const Icon(Icons.restore),
                label: const Text('Restore from recovery key'),
              ),
              const SizedBox(height: 4),
              Text(
                'Gets your original key back, so files already sent to '
                'you will open. Needs the recovery key you saved.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => context.push('/rotate-key'),
                icon: const Icon(Icons.key_outlined),
                label: const Text('Replace my key'),
              ),
              const SizedBox(height: 4),
              Text(
                "Only if it's gone for good and you have no recovery key. "
                'This lets people send to you again; it cannot open files '
                'already sent.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ]
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
              // Low prominence deliberately: a plain text button, not an
              // outlined one, so it reads as available-if-needed rather
              // than a suggested action.
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => context.push('/rotate-key'),
                  icon: const Icon(Icons.key_outlined, size: 18),
                  label: const Text('Replace my key…'),
                ),
              ),
              Text(
                'If you think someone else has had access to this device. '
                'Files already sent to you will stop opening.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              // Key backup. THREE states, and the entry point exists in
              // all of them.
              //
              // An earlier version gated every branch on `backedUp !=
              // null`, so any failed status request — a blip, an expired
              // token — made the whole feature invisible with no way in.
              // That conflated two separate questions: whether to NAG,
              // which does depend on knowing there is no backup, and
              // whether there is a ROUTE, which must not depend on
              // anything.
              const SizedBox(height: 16),
              if (backedUp == null) ...[
                // Status unknown. Neutral wording — claiming either
                // state would be a guess, and guessing "not backed up"
                // alarms people who are fine.
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => context.push('/key-backup'),
                    icon: const Icon(Icons.backup_outlined, size: 18),
                    label: const Text('Key backup…'),
                  ),
                ),
                Text(
                  'Protects your key if you lose this device.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else if (backedUp!.exists) ...[
                Row(
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('Your key is backed up')),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => context.push('/key-backup'),
                    icon: const Icon(Icons.backup_outlined, size: 18),
                    label: const Text('Create a new backup…'),
                  ),
                ),
                Text(
                  "If you've lost your recovery key, make a new backup to "
                  'get a new one. The old key stops working.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ] else ...[
                // Known to be absent: this is the one that earns a
                // prominent card, because the user is one device failure
                // away from losing everything sent to them.
                Card(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Your key is not backed up',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'If you lose this device, files sent to you can '
                          'never be opened again. A backup takes a minute '
                          'and we still cannot read your files.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.tonalIcon(
                            onPressed: () => context.push('/key-backup'),
                            icon: const Icon(Icons.backup_outlined, size: 18),
                            label: const Text('Back up my key'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
