import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../api/api_client.dart';
import '../../api/auth_api.dart';
import '../../core/external_launcher.dart';
import 'auth_providers.dart';

/// Three-stage flow, matching the server contract (M1.6):
///
///   1. `mfa/enroll/begin` — fetch `{secret, otpauth_url}`. Show three
///      ways to get it into an authenticator app:
///         a. Tap **Open in authenticator** — deep-links the
///            `otpauth://` URL to whatever app the OS has registered
///            (works when the authenticator lives on the same device).
///         b. Scan the **QR code** — works when the authenticator lives
///            on a separate device.
///         c. Type the secret + copy — belt-and-braces manual entry.
///   2. User enters a working TOTP. Client calls `mfa/enroll/confirm`,
///      server returns `{mfa_enabled: true, recovery_codes: [...]}`.
///   3. Client surfaces the recovery codes. User acknowledges having
///      saved them, THEN we navigate away — the codes are shown once
///      and cannot be retrieved later (server stores only hashes).
///
/// The zero-knowledge caveat ("if you lose the device AND lose the
/// recovery codes, we can restore account access but not device-local
/// keys") is on the begin screen so the user sees it before enrolling.
class TotpEnrollScreen extends ConsumerStatefulWidget {
  const TotpEnrollScreen({super.key});

  @override
  ConsumerState<TotpEnrollScreen> createState() => _TotpEnrollScreenState();
}

class _TotpEnrollScreenState extends ConsumerState<TotpEnrollScreen> {
  TotpEnrollment? _enrollment;
  MfaEnrollConfirmResult? _confirmed;
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _begin());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final enrolment = await repo.mfaEnrollBegin();
      setState(() => _enrollment = enrolment);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    if (_code.text.trim().length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your app.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final result = await repo.mfaEnrollConfirm(code: _code.text.trim());
      // Persist + broadcast so the home screen hides the "Enable 2FA"
      // button when the user comes back.
      await ref.read(authSessionProvider.notifier).markMfaEnabled(true);
      if (!mounted) return;
      setState(() => _confirmed = result);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openInAuthenticator(String otpauthUrl) async {
    final messenger = ScaffoldMessenger.of(context);
    // Goes through [launchExternalUri] so on Android the authenticator
    // gets its own task and can be closed without dragging OpaqueShare
    // with it.
    final result = await launchExternalUri(Uri.parse(otpauthUrl));
    if (result == ExternalLaunchResult.noHandler) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "Couldn't find an app to handle otpauth:// links. "
            'Install an authenticator app (Google Authenticator, '
            'Authy, 1Password, iCloud Passwords, …) and try again, '
            'or enter the secret manually.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Stage 3: recovery codes shown, waiting for the user to acknowledge.
    final confirmed = _confirmed;
    if (confirmed != null) {
      return _RecoveryCodesView(codes: confirmed.recoveryCodes);
    }

    final enrolment = _enrollment;
    return Scaffold(
      appBar: AppBar(title: const Text('Enable 2FA')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: enrolment == null
            ? Center(
                child: _busy
                    ? const CircularProgressIndicator()
                    : Text(_error ?? 'Preparing…'),
              )
            : ListView(
                children: [
                  const Text(
                    'Add this account to your authenticator app.',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 16),

                  // --- Path 1: same-device deep link ---
                  FilledButton.icon(
                    onPressed: () => _openInAuthenticator(enrolment.otpauthUrl),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open in authenticator app'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Best when your authenticator app is on this same '
                    'device. Your OS picks the app.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 24),

                  // --- Path 2: separate-device QR ---
                  const Text(
                    'Or scan from another device',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      color: Colors.white,
                      child: QrImageView(
                        data: enrolment.otpauthUrl,
                        version: QrVersions.auto,
                        size: 220,
                        gapless: false,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // --- Path 3: manual entry ---
                  const Text(
                    'Or type the secret',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    enrolment.secret,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 4),
                  TextButton.icon(
                    onPressed: () async {
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(
                        ClipboardData(text: enrolment.secret),
                      );
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Secret copied.')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy secret'),
                  ),
                  const SizedBox(height: 24),

                  // --- Zero-knowledge caveat ---
                  const Text(
                    'Heads-up: if you lose your device AND your recovery '
                    "codes, we can restore account access — but we can't "
                    'restore keys that live only on the device. Past '
                    'transfers stay encrypted.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 24),

                  // --- Confirm ---
                  TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(
                      labelText: 'Enter the 6-digit code',
                    ),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _confirm,
                    child: const Text('Confirm'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}

/// Stage 3 rendering. Blocks navigation until the user taps "I've saved
/// these" — the recovery codes are shown exactly once by design (the
/// server stores hashes only), and losing them before writing them down
/// is exactly the situation MFA recovery is meant to prevent.
class _RecoveryCodesView extends StatelessWidget {
  const _RecoveryCodesView({required this.codes});
  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Save your recovery codes'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            const Text(
              'Two-factor authentication is now enabled. Save these '
              'single-use recovery codes somewhere safe (password manager, '
              'printed copy). They are shown exactly once — the server '
              'only keeps hashes.',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 16),
            ...codes.map(
              (c) => SelectableText(
                c,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                await Clipboard.setData(
                  ClipboardData(text: codes.join('\n')),
                );
                messenger.showSnackBar(
                  const SnackBar(content: Text('Codes copied.')),
                );
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy all'),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/'),
              child: const Text("I've saved these"),
            ),
          ],
        ),
      ),
    );
  }
}
