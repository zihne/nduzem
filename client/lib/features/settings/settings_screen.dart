import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../widgets/max_width_content.dart';
import '../auth/auth_providers.dart';

/// Account settings.
///
/// This screen exists because we published a deletion policy page that
/// told users to find it — "account menu → Settings → Delete my
/// account" — and for a while there was no such menu. The server has
/// had `POST /v1/users/me/erasure` since M9.5; only the way in was
/// missing, which is the worst version of that gap: the capability
/// exists, the promise is public, and the user cannot reach it.
///
/// Key management is linked rather than moved. The home screen still
/// surfaces restore/rotate contextually when the identity key is
/// missing, which is where someone actually hits that problem; Settings
/// is where someone goes when they are looking for it deliberately.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final session = ref.watch(authSessionProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: MaxWidthContent(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            if (session != null) ...[
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(session.email ?? 'Signed in'),
                subtitle: session.handle == null
                    ? null
                    : Text('@${session.handle}'),
              ),
              const Divider(),
            ],
            _sectionLabel(theme, 'Encryption key'),
            ListTile(
              leading: const Icon(Icons.backup_outlined),
              title: const Text('Back up your key'),
              subtitle: const Text(
                'Save a recovery key so you can restore access on another '
                'device.',
              ),
              onTap: () => context.push('/key-backup'),
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Restore from recovery key'),
              subtitle: const Text(
                'Bring your original key back onto this device.',
              ),
              onTap: () => context.push('/restore-key'),
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Replace encryption key'),
              subtitle: const Text(
                'Start over with a new key. Files already sent to you stay '
                'unreadable.',
              ),
              onTap: () => context.push('/rotate-key'),
            ),
            const Divider(),
            _sectionLabel(theme, 'Danger zone', color: theme.colorScheme.error),
            ListTile(
              leading: Icon(
                Icons.delete_forever_outlined,
                color: theme.colorScheme.error,
              ),
              title: Text(
                'Delete my account',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text(
                'Permanently erase your account and everything in it.',
              ),
              onTap: () => context.push('/settings/delete-account'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(ThemeData theme, String text, {Color? color}) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          text.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: color ?? theme.colorScheme.primary,
            letterSpacing: 0.8,
          ),
        ),
      );
}
