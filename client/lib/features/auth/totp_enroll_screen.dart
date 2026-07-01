import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/api_client.dart';
import '../../api/auth_api.dart';
import 'auth_providers.dart';

/// Two-phase enrolment:
///
///   1. `begin` — fetch a fresh secret + recovery codes (shown once).
///   2. `confirm` — the user types a working TOTP; server flips
///      `mfa_enabled = true`.
///
/// The enrolment screen surfaces the "you'll lose access to past transfers if
/// you also lose your device" caveat inline. This is a property of
/// zero-knowledge, not an MFA bug (see project memory notes on M1.6).
class TotpEnrollScreen extends ConsumerStatefulWidget {
  const TotpEnrollScreen({super.key});

  @override
  ConsumerState<TotpEnrollScreen> createState() => _TotpEnrollScreenState();
}

class _TotpEnrollScreenState extends ConsumerState<TotpEnrollScreen> {
  TotpEnrollment? _enrollment;
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
      await repo.mfaEnrollConfirm(code: _code.text.trim());
      if (mounted) context.go('/');
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    'Scan this in your authenticator app, then enter the '
                    '6-digit code to confirm.',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    enrolment.secretBase32,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () async {
                      // Capture the messenger before the async gap so we
                      // don't reach into context after await — satisfies
                      // the `use_build_context_synchronously` lint.
                      final messenger = ScaffoldMessenger.of(context);
                      await Clipboard.setData(
                        ClipboardData(text: enrolment.otpauthUri),
                      );
                      messenger.showSnackBar(
                        const SnackBar(content: Text('otpauth URI copied.')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Copy otpauth URI'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Recovery codes (single-use, store them somewhere safe):',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  ...enrolment.recoveryCodes.map(
                    (c) => SelectableText(
                      c,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Heads-up: if you lose your device AND your recovery '
                    "codes, we can restore account access — but we can't "
                    'restore keys that live only on the device. Past '
                    'transfers stay encrypted.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration: const InputDecoration(labelText: 'Confirm code'),
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
