import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/users_api.dart';
import '../../core/recipient_query.dart';
import '../../crypto/fingerprint.dart';
import '../auth/auth_providers.dart';
import 'verified_contacts_repo.dart';
import '../../widgets/max_width_content.dart';

/// Two-stage screen (M2.5, spec §6):
///
///   1. **Lookup**  — enter an email or handle, hit "Look up". Client
///      calls `/v1/users/lookup`, receives the raw pubkeys, computes
///      the fingerprint locally, and cross-checks against the
///      `key_fingerprint` the server returned. A mismatch here means
///      the server is bugged or being tampered with — we surface it
///      as a hard error, not a silent acceptance.
///
///   2. **Compare** — screen shows the computed fingerprint plus an
///      input for the fingerprint the user got OOB (paste-and-match).
///      "Mark verified" persists the record via
///      [VerifiedContactsRepo]. Any prior verification for the same
///      counterparty is overwritten; the next M2 send flow will
///      compare against the newest record and alert on divergence.
class VerifyContactScreen extends ConsumerStatefulWidget {
  const VerifyContactScreen({super.key});

  @override
  ConsumerState<VerifyContactScreen> createState() =>
      _VerifyContactScreenState();
}

class _VerifyContactScreenState extends ConsumerState<VerifyContactScreen> {
  final _lookup = TextEditingController();
  final _expected = TextEditingController();

  UserLookup? _found;
  Fingerprint? _foundFingerprint;
  VerifiedContact? _priorVerification;
  bool _busy = false;
  String? _error;
  bool _saved = false;

  @override
  void dispose() {
    _lookup.dispose();
    _expected.dispose();
    super.dispose();
  }

  Future<void> _lookupContact() async {
    final query = RecipientQuery.parse(_lookup.text);
    if (query == null) {
      setState(() => _error = 'Enter an email address or handle.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _found = null;
      _foundFingerprint = null;
      _priorVerification = null;
      _saved = false;
    });
    try {
      final usersApi = await ref.read(usersApiProvider.future);
      final result = query.isEmail
          ? await usersApi.lookup(email: query.value)
          : await usersApi.lookup(handle: query.value);

      // Recompute the fingerprint locally and cross-check against the
      // server's echo. Silent mismatch = trust destroyed.
      final localFp = fingerprintOf(
        identityPublic: result.identityPublic,
        signingPublic: result.signingPublic,
      );
      if (!localFp.matches(result.serverKeyFingerprint)) {
        setState(
          () => _error =
              'Server-computed fingerprint does not match what we compute '
                  'from the returned keys. Refusing to proceed.',
        );
        return;
      }

      final verifiedRepo = ref.read(verifiedContactsRepoProvider);
      final prior = await verifiedRepo.read(result.userId);
      setState(() {
        _found = result;
        _foundFingerprint = localFp;
        _priorVerification = prior;
      });
    } on ApiException catch (exc) {
      // 404 (unknown user), 401 (unauth) — surface the server message.
      setState(() => _error = exc.message);
    } on Object catch (exc) {
      // Local failure, not the API — typically secure_storage throwing
      // out of VerifiedContactsRepo.read(). Without this the exception
      // escaped the try and the screen just stopped, showing neither a
      // contact nor a reason. See the matching catch in send_screen.
      setState(
        () => _error = "Couldn't read your saved verifications, so this "
            "contact can't be checked against a previous one. Restart "
            'the app: local secure storage is unreadable, and the next '
            'launch clears it and signs you out so you can start clean. '
            '($exc)',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _markVerified() async {
    final found = _found;
    final fp = _foundFingerprint;
    if (found == null || fp == null) return;
    final expected = tryParseFingerprint(_expected.text);
    if (expected == null || !fp.matches(expected.canonical)) {
      setState(
        () => _error =
            "The fingerprint you entered doesn't match what we computed "
                'for this account. Compare again with the other person.',
      );
      return;
    }
    final repo = ref.read(verifiedContactsRepoProvider);
    await repo.markVerified(
      userId: found.userId,
      canonical: fp.canonical,
      at: DateTime.now(),
    );
    if (!mounted) return;
    setState(() {
      _saved = true;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verify a contact')),
      body: MaxWidthContent(
          child: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            // --- Stage 1: lookup input --------------------------------
            const Text(
              'Enter the email or handle of the person you want to verify.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lookup,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'Email or @handle'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _lookupContact,
              icon: const Icon(Icons.search),
              label: _busy
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Look up'),
            ),

            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],

            // --- Stage 2: compare + confirm ---------------------------
            if (_found != null && _foundFingerprint != null) ...[
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                'Fingerprint for ${_lookup.text.trim()}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(
                _foundFingerprint!.display,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              _PriorBanner(
                  prior: _priorVerification, current: _foundFingerprint!,),
              const SizedBox(height: 16),
              const Text(
                'Ask the other person to read theirs to you (or paste it '
                'below). If both sides see the same digits, the keys are '
                'the ones you exchanged.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _expected,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Paste the fingerprint they gave you',
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _saved ? null : _markVerified,
                icon: Icon(_saved ? Icons.check_circle : Icons.verified_user),
                label: Text(_saved ? 'Verified' : 'Mark verified'),
              ),
              if (_saved) ...[
                const SizedBox(height: 12),
                Text(
                  "You're all set. If this counterparty's fingerprint ever "
                  'changes, the app will warn you before the next send.',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.primary),
                ),
              ],
            ],
          ],
        ),
      ),),
    );
  }
}

/// Banner shown above the compare input when we already have a prior
/// verification for this counterparty. Three states:
///   - never verified   → nothing shown
///   - verified, match  → subtle "already verified" confirmation
///   - verified, drift  → LOUD alert; the fingerprint changed
class _PriorBanner extends StatelessWidget {
  const _PriorBanner({required this.prior, required this.current});
  final VerifiedContact? prior;
  final Fingerprint current;

  @override
  Widget build(BuildContext context) {
    final p = prior;
    if (p == null) return const SizedBox.shrink();
    final match = current.matches(p.canonical);
    final scheme = Theme.of(context).colorScheme;
    if (match) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'You verified this contact on '
          '${p.at.toLocal().toString().split('.').first} — fingerprint '
          'matches.',
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '⚠️  This fingerprint DIFFERS from what you verified on '
        '${p.at.toLocal().toString().split('.').first}. Someone may have '
        'replaced their device (or something worse). Re-verify out of '
        'band before continuing.',
        style: TextStyle(
          color: scheme.onErrorContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
