import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../auth/auth_providers.dart';
import 'transfer_service.dart';

/// Four-stage flow (spec §5.3), post-M4 streaming (ADR-0006):
///
///   1. **Ready**     — explain what the tap will do.
///   2. **Downloading + decrypting** — two-phase streaming progress
///      into two temp files (ciphertext then plaintext). Peak memory
///      ≈ one 64 KiB chunk.
///   3. **Decrypted** — the plaintext lives at a temp path; the user
///      picks where to save it via the native SAF / document picker.
///      The bytes are read into memory ONLY at save-time (peak =
///      plaintext size, once).
///   4. **Saved**     — show the destination the user chose, plus the
///      explicit "burn the sender's copy" button.
///   5. **Acked**     — server-side burn queued.
///
/// The plaintext temp file is deleted on ack, on user-cancel, on
/// error, or on widget dispose — best-effort per path.
class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key, required this.transferId});
  final String transferId;

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveScreenState();
}

/// Above this size, saveFile(bytes:) is at real risk of OOM on
/// mid-range Android devices. The screen shows a warning banner and
/// still attempts the save. True streaming save into a SAF URI is a
/// follow-up (ADR-0006 "Open follow-ups").
const int _saveBytesWarnThreshold = 200 * 1024 * 1024; // 200 MiB

class _ReceiveScreenState extends ConsumerState<ReceiveScreen> {
  DecryptedTransfer? _decrypted;
  String? _savedPath;
  bool _acked = false;
  bool _busy = false;
  String? _error;

  // Streaming progress (ADR-0006). Non-null while `receive()` is in
  // flight; cleared on completion or error.
  ReceivePhase? _phase;
  int? _phaseDone;
  int? _phaseTotal;
  CancelToken? _cancel;

  @override
  void dispose() {
    // Best-effort cleanup of the plaintext temp file if the user
    // backed out of the screen without acking. The OS temp dir is
    // the backstop for a process-kill leak.
    final path = _decrypted?.plaintextPath;
    if (path != null) {
      unawaited(_deleteIfExists(path));
    }
    super.dispose();
  }

  Future<void> _download() async {
    final cancel = CancelToken();
    setState(() {
      _busy = true;
      _error = null;
      _phase = null;
      _phaseDone = null;
      _phaseTotal = null;
      _cancel = cancel;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final res = await svc.receive(
        transferId: widget.transferId,
        cancel: cancel,
        onProgress: (phase, done, total) {
          if (!mounted) return;
          setState(() {
            _phase = phase;
            _phaseDone = done;
            _phaseTotal = total;
          });
        },
      );
      if (!mounted) return;
      setState(() => _decrypted = res);
    } on SendCancelledException {
      if (mounted) setState(() => _error = 'Download cancelled.');
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } on Object catch (exc) {
      setState(() => _error = 'Download failed: $exc');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _phase = null;
          _phaseDone = null;
          _phaseTotal = null;
          _cancel = null;
        });
      }
    }
  }

  void _cancelDownload() {
    _cancel?.cancel();
  }

  Future<void> _saveAs() async {
    final decrypted = _decrypted;
    if (decrypted == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Read plaintext from the temp file only at save time.
      // `file_picker` 8.x still requires `bytes:` on Android — the
      // path-based streaming save is a follow-up (ADR-0006).
      final bytes = await File(decrypted.plaintextPath).readAsBytes();
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save decrypted file',
        fileName: decrypted.filename,
        bytes: bytes,
      );
      if (result == null) {
        // User cancelled the dialog — leave the plaintext on disk
        // so they can retry.
        return;
      }
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
      // Success: drop the plaintext temp file. Nothing else will
      // consume it — the user has already saved via SAF above.
      final path = _decrypted?.plaintextPath;
      if (path != null) {
        await _deleteIfExists(path);
      }
      if (!mounted) return;
      setState(() => _acked = true);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } on Object {
      // ignore
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
              if (_busy && _cancel != null) ...[
                _ReceiveProgress(
                  phase: _phase,
                  done: _phaseDone,
                  total: _phaseTotal,
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _cancelDownload,
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel'),
                ),
              ] else
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
              if (_decrypted!.plaintextLength > _saveBytesWarnThreshold &&
                  _savedPath == null) ...[
                const SizedBox(height: 12),
                _LargeFileWarning(
                  size: _decrypted!.plaintextLength,
                ),
              ],
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

// --- widgets ---------------------------------------------------------------

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
              '${decrypted.plaintextLength} bytes'
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

/// Two-phase progress (ADR-0006). Mirrors the send screen's widget.
class _ReceiveProgress extends StatelessWidget {
  const _ReceiveProgress({
    required this.phase,
    required this.done,
    required this.total,
  });
  final ReceivePhase? phase;
  final int? done;
  final int? total;

  @override
  Widget build(BuildContext context) {
    final t = total;
    final d = done;
    double? value;
    if (t != null && t > 0 && d != null) {
      value = (d / t).clamp(0.0, 1.0);
    }
    final phaseLabel = switch (phase) {
      ReceivePhase.downloading => 'Downloading',
      ReceivePhase.decrypting => 'Decrypting',
      null => 'Starting',
    };
    String label;
    if (value != null && d != null && t != null) {
      label = '$phaseLabel · ${_mib(d)} / ${_mib(t)}'
          ' (${(value * 100).toStringAsFixed(0)}%)';
    } else {
      label = '$phaseLabel…';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: value),
        const SizedBox(height: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  static String _mib(int bytes) {
    final gib = bytes / (1024 * 1024 * 1024);
    if (gib >= 1) return '${gib.toStringAsFixed(2)} GiB';
    final mib = bytes / (1024 * 1024);
    if (mib >= 100) return '${mib.toStringAsFixed(0)} MiB';
    if (mib >= 1) return '${mib.toStringAsFixed(1)} MiB';
    return '${(bytes / 1024).toStringAsFixed(0)} KiB';
  }
}

/// Banner shown before the SAF save button when the plaintext is
/// large enough that the save step might OOM on mid-range Android
/// devices. Documented in ADR-0006 as the residual gap; true
/// streaming save into a SAF URI is a follow-up.
class _LargeFileWarning extends StatelessWidget {
  const _LargeFileWarning({required this.size});
  final int size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 8),
              Text(
                'Large file',
                style: TextStyle(
                  color: scheme.onErrorContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'The decrypted file is bigger than 200 MiB. Saving very '
            "large files can fail on mid-range phones if there isn't "
            'enough free memory at the save step. If the save button '
            'errors, close some apps and try again.',
            style: TextStyle(
              color: scheme.onErrorContainer,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// Fire-and-forget helper used by dispose (no async keyword allowed).
void unawaited(Future<void> f) {
  f.ignore();
}
