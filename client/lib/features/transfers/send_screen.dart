import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mime/mime.dart' show lookupMimeType;

import '../../api/api_client.dart';
import '../../api/users_api.dart';
import '../../crypto/fingerprint.dart';
import '../auth/auth_providers.dart';
import '../verify_contact/verified_contacts_repo.dart';

/// M2 send flow (spec §5.2). Three visible stages inside one screen:
///
///   1. **Pick file + recipient** — file_picker returns bytes or a path
///      (both handled); recipient input accepts email or handle and
///      calls `/v1/users/lookup`.
///   2. **Fingerprint acknowledgement** — TOFU. If the recipient was
///      previously verified via `/verify-contact`, we show a subtle
///      "already verified" confirmation. If a prior verification's
///      fingerprint DIFFERS from what we just fetched, we hard-block
///      (M2.5 key-change alert). Otherwise a soft warning nudges the
///      user to verify OOB — but the send proceeds if they proceed.
///   3. **Confirm + send** — runs the encrypt/upload/commit pipeline
///      via [TransferService.send], shows progress + result.
class SendScreen extends ConsumerStatefulWidget {
  const SendScreen({super.key});

  @override
  ConsumerState<SendScreen> createState() => _SendScreenState();
}

class _SendScreenState extends ConsumerState<SendScreen> {
  final _lookup = TextEditingController();
  _PickedFile? _file;
  UserLookup? _recipient;
  Fingerprint? _recipientFp;
  VerifiedContact? _priorVerification;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _lookup.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(withData: true);
    if (res == null || res.files.isEmpty) return;
    final f = res.files.single;
    Uint8List? bytes = f.bytes;
    // On some platforms `withData: true` isn't honoured for big files;
    // fall back to reading the path.
    if (bytes == null && f.path != null) {
      bytes = await File(f.path!).readAsBytes();
    }
    if (bytes == null) {
      setState(() => _error = 'Could not read that file.');
      return;
    }
    setState(() {
      _file = _PickedFile(
        name: f.name,
        mime: lookupMimeType(f.name),
        bytes: bytes!,
      );
      _error = null;
    });
  }

  Future<void> _lookupRecipient() async {
    final input = _lookup.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Enter the recipient email or @handle.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _recipient = null;
      _recipientFp = null;
      _priorVerification = null;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final res = input.contains('@')
          ? await svc.lookupRecipient(email: input)
          : await svc.lookupRecipient(handle: input);

      final localFp = fingerprintOf(
        identityPublic: res.identityPublic,
        signingPublic: res.signingPublic,
      );
      if (!localFp.matches(res.serverKeyFingerprint)) {
        setState(
          () => _error =
              'Server-computed fingerprint does not match what we compute '
              'from the returned keys. Refusing to seal — this is the '
              'exact case OOB verification catches.',
        );
        return;
      }

      final verifiedRepo = ref.read(verifiedContactsRepoProvider);
      final prior = await verifiedRepo.read(res.userId);
      if (prior != null && !localFp.matches(prior.canonical)) {
        setState(
          () => _error =
              "This contact's fingerprint has changed since you verified "
              'them on ${prior.at.toLocal().toString().split('.').first}. '
              'Re-verify at "Verify a contact" before sending.',
        );
        return;
      }

      setState(() {
        _recipient = res;
        _recipientFp = localFp;
        _priorVerification = prior;
      });
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final file = _file;
    final recipient = _recipient;
    if (file == null || recipient == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final result = await svc.send(
        recipient: recipient,
        plaintext: file.bytes,
        filename: file.name,
        mime: file.mime,
      );
      setState(
        () => _info =
            'Sent ${result.byteCountOnServer} bytes. Transfer '
            '${result.transferId} is now in the recipient\'s inbox.',
      );
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } on Object catch (exc) {
      setState(() => _error = 'Send failed: $exc');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send a file')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            // Stage 1a: file pick
            const Text(
              'Choose a file',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pickFile,
              icon: const Icon(Icons.attach_file),
              label: Text(_file == null ? 'Pick a file' : _file!.name),
            ),
            if (_file != null) ...[
              const SizedBox(height: 4),
              Text(
                '${_file!.bytes.length} bytes'
                '${_file!.mime == null ? '' : ' · ${_file!.mime}'}',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ],

            const SizedBox(height: 24),

            // Stage 1b: recipient lookup
            const Text(
              'To',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _lookup,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email or @handle'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _lookupRecipient,
              icon: const Icon(Icons.search),
              label: const Text('Look up recipient'),
            ),

            // Stage 2: fingerprint state
            if (_recipient != null && _recipientFp != null) ...[
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              Text(
                "Recipient's fingerprint",
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(
                _recipientFp!.display,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 16,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              _FingerprintBanner(
                fingerprint: _recipientFp!,
                prior: _priorVerification,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy || _file == null ? null : _send,
                icon: const Icon(Icons.send),
                label: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Encrypt and send'),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_info != null) ...[
              const SizedBox(height: 16),
              Text(
                _info!,
                style: TextStyle(color: Theme.of(context).colorScheme.primary),
              ),
            ],

          ],
        ),
      ),
    );
  }
}

class _PickedFile {
  const _PickedFile({
    required this.name,
    required this.mime,
    required this.bytes,
  });
  final String name;
  final String? mime;
  final Uint8List bytes;
}

/// One of three states depending on prior-verification history:
///   - already verified, matches      → subtle "verified on `date`"
///   - never verified                 → TOFU nudge, non-blocking
///   - previously verified, mismatch  handled upstream (send is
///     hard-blocked before we get here), so no case in this widget.
class _FingerprintBanner extends StatelessWidget {
  const _FingerprintBanner({required this.fingerprint, required this.prior});
  final Fingerprint fingerprint;
  final VerifiedContact? prior;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final prior = this.prior;
    if (prior != null && fingerprint.matches(prior.canonical)) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'You verified this contact on '
          '${prior.at.toLocal().toString().split('.').first}. Safe to send.',
          style: TextStyle(color: scheme.onSecondaryContainer),
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        "You haven't verified this contact yet. For stronger safety, ask "
        'them to read their fingerprint to you out-of-band before you '
        'send anything sensitive. Otherwise send at your own risk.',
        style: TextStyle(color: scheme.onSurfaceVariant),
      ),
    );
  }
}
