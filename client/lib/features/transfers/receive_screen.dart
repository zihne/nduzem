import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../auth/auth_providers.dart';
import 'transfer_service.dart';

/// Four-stage flow (spec §5.3):
///
///   1. **Ready**    — explain what the tap will do.
///   2. **Decrypted** — bytes in memory; show file info; the user picks
///      where to save them via a native SAF / document picker.
///   3. **Saved**    — show the destination the user chose, plus the
///      explicit "burn the sender's copy" button.
///   4. **Acked**    — server-side burn queued.
///
/// The save-location prompt in stage 2 is the whole reason receive was
/// refactored — the previous "app documents dir" was a sandboxed path
/// (`/data/data/…/app_flutter`) invisible to Android's Files app or any
/// third-party file manager without root.
class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key, required this.transferId});
  final String transferId;

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends ConsumerState<ReceiveScreen> {
  DecryptedTransfer? _decrypted;
  String? _savedPath;
  bool _acked = false;
  bool _busy = false;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final res = await svc.receive(transferId: widget.transferId);
      setState(() => _decrypted = res);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } on Object catch (exc) {
      setState(() => _error = 'Download failed: $exc');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAs() async {
    final decrypted = _decrypted;
    if (decrypted == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save decrypted file',
        fileName: decrypted.filename,
        bytes: decrypted.plaintext,
      );
      if (result == null) {
        // User cancelled the dialog — leave the plaintext in memory so
        // they can try again.
        return;
      }
      // On Android with Storage Access Framework, `result` is the path
      // that file_picker wrote to for us; on iOS/desktop it's the path
      // the user picked. In every case, we can verify the file exists
      // and report the location back so the user knows where it landed.
      final saved = File(result);
      if (!saved.existsSync()) {
        // Some Android variants return a content:// URI that isn't a
        // filesystem path — the write still happened via SAF. Just
        // surface the URI as-is.
        setState(() => _savedPath = result);
      } else {
        setState(() => _savedPath = saved.path);
      }
    } on Object catch (exc) {
      setState(() => _error = 'Save failed: $exc');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ack() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      await svc.ack(widget.transferId);
      setState(() => _acked = true);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            if (_decrypted == null) ...[
              const Text(
                'This will download the encrypted bytes, verify the '
                'ciphertext hash, and decrypt locally with your device '
                'key. You choose where to save the file after.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _download,
                icon: const Icon(Icons.download),
                label: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Download and decrypt'),
              ),
            ] else ...[
              _DecryptedCard(
                decrypted: _decrypted!,
                savedPath: _savedPath,
              ),
              const SizedBox(height: 16),
              if (_savedPath == null) ...[
                const Text(
                  'Pick where to save the decrypted file. On Android '
                  'the system file picker opens; on iOS the Files app '
                  'dialog opens.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _saveAs,
                  icon: const Icon(Icons.save),
                  label: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save to...'),
                ),
              ] else if (!_acked) ...[
                const Text(
                  'Now that the file is saved, ack the transfer to burn '
                  "the sender's server-side copy. The object is "
                  'unrecoverable after this.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _ack,
                  icon: const Icon(Icons.local_fire_department),
                  label: const Text("Delete the sender's copy (ack)"),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                ),
              ] else ...[
                Text(
                  'Burn queued. The recipient copy on the server is '
                  'scheduled for deletion.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ],

            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One-liner reassurance under the file info. Explains, in plain
/// English, whether the recipient's client checked the sender's
/// Ed25519 signature over `blob_sha256`. "Not verified" is not an
/// error — it means the sender has since erased themselves (M9.5)
/// and their public keys were withheld by the server (ADR-0031).
class _SignatureBadge extends StatelessWidget {
  const _SignatureBadge({required this.verified});
  final bool verified;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = verified ? Icons.verified : Icons.help_outline;
    final color = verified ? scheme.primary : scheme.outline;
    final text = verified
        ? 'Sender signature verified against their signing key.'
        : 'Sender key not available — signature could not be verified. '
            'The sender may have erased their account.';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

class _DecryptedCard extends StatelessWidget {
  const _DecryptedCard({required this.decrypted, required this.savedPath});
  final DecryptedTransfer decrypted;
  final String? savedPath;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              savedPath == null ? 'Ready to save' : 'Saved',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(decrypted.filename),
            const SizedBox(height: 4),
            Text(
              '${decrypted.byteCount} bytes'
              '${decrypted.mime == null ? '' : ' · ${decrypted.mime}'}',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 8),
            _SignatureBadge(verified: decrypted.senderSignatureVerified),
            if (savedPath != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                savedPath!,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
