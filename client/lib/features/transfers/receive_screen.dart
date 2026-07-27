import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/api_client.dart';
import '../../native/saf_saver.dart';
import '../auth/auth_providers.dart';
import '../history/transfer_history_entry.dart';
import '../history/transfer_history_provider.dart';
import 'transfer_service.dart';
import 'web_saver.dart';

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

  /// Where the large-file save fallback will drop the plaintext.
  /// Resolved once at screen mount so the warning banner can show the
  /// exact destination path BEFORE the user commits to the save.
  String? _externalBaseDir;

  // Streaming progress (ADR-0006). Non-null while `receive()` is in
  // flight; cleared on completion or error.
  ReceivePhase? _phase;
  int? _phaseDone;
  int? _phaseTotal;
  CancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    _resolveExternalBaseDir();
  }

  Future<void> _resolveExternalBaseDir() async {
    // Web has no filesystem — the browser drops downloads into the
    // user's default folder (or wherever FSA sends them). Nothing to
    // resolve.
    if (kIsWeb) return;
    try {
      final base = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(() => _externalBaseDir = base?.path);
    } on Object {
      // Best-effort — the warning banner falls back to a generic
      // "OpaqueShare folder" wording if we couldn't resolve.
    }
  }

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
    String? savedPath;
    try {
      if (kIsWeb) {
        // Web save: File System Access API (Chromium) with an
        // `<a download>` fallback for browsers that don't ship it.
        // Peak memory = plaintextBytes size, already accepted at
        // decrypt time.
        savedPath = await saveBytesWeb(
          bytes: decrypted.plaintextBytes!,
          filename: decrypted.filename,
          mimeType: decrypted.mime,
        );
        if (savedPath == null) return;
      } else if (decrypted.plaintextLength > _saveBytesWarnThreshold) {
        // Big files on Android go through the native SAF stream-save
        // (ADR-0008): user picks a `content://` URI, we stream-copy
        // the plaintext temp into it via ContentResolver on the
        // platform thread — peak heap ≈ 64 KiB. On iOS the plugin
        // declines (pickSaveUri → null), so we route to
        // `_saveToExternalStorage` which drops the file into the
        // app-documents dir.
        savedPath = await _saveLargeFile(decrypted);
      } else {
        // Small-file fast path: `file_picker.saveFile(bytes:)` uses
        // SAF on Android and iOS document picker on iOS. Peak
        // memory = plaintext size (once); fine for < 200 MiB.
        final bytes = await File(decrypted.plaintextPath!).readAsBytes();
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
        // Some Android variants return a content:// URI that isn't a
        // filesystem path — the write still happened via SAF. Just
        // surface the URI as-is.
        savedPath = saved.existsSync() ? saved.path : result;
      }
    } on Object catch (exc) {
      setState(() => _error = 'Save failed: $exc');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (savedPath == null) return;
    setState(() => _savedPath = savedPath);
    // Auto-ack after a successful save. Server's /ack burns
    // immediately for `max_downloads=1` (the default) and defers
    // for multi-download links (per the fix to /v1/links/{id}/ack).
    // If the ack fails, we surface a manual retry button below —
    // don't leave the user unsure whether the server is holding
    // storage.
    await _ack(autoTriggered: true);
  }

  /// Primary large-file save path (ADR-0008). Launches the native
  /// SAF picker via [SafSaver.pickSaveUri], then stream-copies the
  /// plaintext temp file into the chosen `content://` URI via
  /// [SafSaver.writeFileToUri]. Peak heap ≈ one 64 KiB buffer on the
  /// Kotlin side — safe for multi-GB files.
  ///
  /// Falls back to [_saveToExternalStorage] when SAF is unavailable
  /// (iOS today) or when the picker fails to launch. User-cancel from
  /// the picker returns null without an error — the user just backs
  /// out, plaintext temp file stays put for a retry.
  ///
  /// Returns the human-readable display name the picker resolved,
  /// NOT the raw `content://` URI — the URI is noisy
  /// (`content://com.android.providers.downloads.documents/…`) and
  /// confusing for users. The URI stays internal to the write step.
  Future<String?> _saveLargeFile(DecryptedTransfer decrypted) async {
    final saf = ref.read(safSaverProvider);
    SafPickedDestination? destination;
    try {
      destination = await saf.pickSaveUri(
        suggestedFilename: decrypted.filename,
      );
    } on SafSaveWriteException catch (exc) {
      // Picker launch failed. Fall through to the fallback path — the
      // user still gets their file even if the fancy picker didn't
      // come up.
      setState(() => _error = 'Picker failed: ${exc.message}');
      return _saveToExternalStorage(decrypted);
    }
    if (destination == null) {
      // Two cases lead here:
      //  1. Android user cancelled the picker → they're consciously
      //     backing out; leave the plaintext temp for a retry.
      //  2. Non-Android platform (iOS today) → route to the app-docs
      //     fallback so the file still lands somewhere useful.
      if (!Platform.isAndroid) {
        return _saveToExternalStorage(decrypted);
      }
      return null;
    }
    try {
      await saf.writeFileToUri(
        sourcePath: decrypted.plaintextPath!,
        uri: destination.uri,
      );
    } on SafSaveWriteException catch (exc) {
      // The SAF write started but didn't complete. Fall back rather
      // than leaving the user with nothing — losing the file to a
      // provider bug is worse than an unexpected save location.
      setState(() => _error = 'SAF save failed: ${exc.message}');
      return _saveToExternalStorage(decrypted);
    }
    // Success. Drop the plaintext temp file to reclaim cache space —
    // the fallback path does the same after its File.copy.
    await _deleteIfExists(decrypted.plaintextPath!);
    return destination.displayName;
  }

  /// Fallback save path when SAF isn't available (iOS today) or the
  /// SAF write failed for a provider-side reason. Copies the plaintext
  /// temp file (streaming, via `File.copy`) into the app-external
  /// files directory under an `OpaqueShare/` subfolder, then deletes
  /// the source temp. Peak memory ≈ Dart I/O buffers.
  ///
  /// The destination path is user-visible under
  /// `Android/data/<pkg>/files/OpaqueShare/` (Android) or
  /// `On My iPhone > OpaqueShare` (iOS Files app). Not as slick as
  /// SAF but reliable for multi-GB receives.
  Future<String?> _saveToExternalStorage(DecryptedTransfer decrypted) async {
    final Directory? baseDir;
    try {
      // Android: `/storage/emulated/0/Android/data/<pkg>/files`.
      // iOS: throws — fall back to app-documents (visible via Files
      // app under "On My iPhone > OpaqueShare").
      baseDir = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getApplicationDocumentsDirectory();
    } on Object catch (exc) {
      setState(() => _error = 'Could not open save directory: $exc');
      return null;
    }
    if (baseDir == null) {
      setState(
        () => _error = 'Save directory is not available on this device.',
      );
      return null;
    }
    final saveDir = Directory('${baseDir.path}/OpaqueShare');
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }
    final finalPath = await _uniquePath(saveDir.path, decrypted.filename);
    try {
      await File(decrypted.plaintextPath!).copy(finalPath);
      // Copy succeeded — drop the source temp file to reclaim space.
      await _deleteIfExists(decrypted.plaintextPath!);
    } on Object catch (exc) {
      // Best-effort: try to remove a half-written destination if the
      // copy died partway.
      await _deleteIfExists(finalPath);
      setState(() => _error = 'Save failed: $exc');
      return null;
    }
    return finalPath;
  }

  /// Return `<dir>/<name>` unless it already exists; then append -1,
  /// -2, … before the extension until we find a free slot. Prevents
  /// silently clobbering a same-named file the user saved earlier.
  Future<String> _uniquePath(String dir, String name) async {
    var candidate = '$dir/$name';
    if (!await File(candidate).exists()) return candidate;
    final dot = name.lastIndexOf('.');
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    for (var i = 1; i < 1000; i++) {
      candidate = '$dir/$stem-$i$ext';
      if (!await File(candidate).exists()) return candidate;
    }
    // Absurdly unlikely — bail out with the last candidate.
    return candidate;
  }

  Future<void> _ack({bool autoTriggered = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      await svc.ack(widget.transferId);
      // Success: drop the plaintext temp file. Nothing else will
      // consume it — the user has already saved above.
      final path = _decrypted?.plaintextPath;
      if (path != null) {
        await _deleteIfExists(path);
      }
      // Log to local history (ADR-0007). Ack is the point at which
      // the receive is unambiguously "done" — the server-side burn is
      // in flight and the user has already saved locally.
      final decrypted = _decrypted;
      if (decrypted != null) {
        final senderId = decrypted.senderId;
        await ref.read(transferHistoryProvider.notifier).log(
              ReceivedHistoryEntry(
                transferId: decrypted.transferId,
                timestamp: DateTime.now().toUtc(),
                filename: decrypted.filename,
                sizeBytes: decrypted.plaintextLength,
                senderIdShort: senderId != null && senderId.length >= 8
                    ? senderId.substring(0, 8)
                    : senderId,
                senderHandle: decrypted.senderHandle,
                signatureVerified: decrypted.senderSignatureVerified,
                savedPath: _savedPath,
              ),
            );
      }
      if (!mounted) return;
      setState(() => _acked = true);
    } on ApiException catch (exc) {
      // On auto-ack failure we still leave the user with a manual
      // retry — the ack button re-appears below because `_acked`
      // stays false. Server has a 7-day TTL sweeper as the backstop
      // if the user never retries.
      final prefix = autoTriggered
          ? 'Auto-ack failed — tap the button below to retry: '
          : '';
      setState(() => _error = '$prefix${exc.message}');
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
              // Large-file banner only fires on iOS now — Android
              // routes through the native SAF stream-save (ADR-0008)
              // and gets the same "pick where to save" UX regardless
              // of file size.
              if (!Platform.isAndroid &&
                  _decrypted!.plaintextLength > _saveBytesWarnThreshold &&
                  _savedPath == null) ...[
                const SizedBox(height: 12),
                _LargeFileWarning(
                  destinationPath: _externalBaseDir == null
                      ? null
                      : '$_externalBaseDir/OpaqueShare/${_decrypted!.filename}',
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

/// Banner shown before the save button when the plaintext exceeds
/// the SAF-with-bytes ceiling. Explains where the file will actually
/// land — the save step skips SAF and copies to app-external storage
/// (ADR-0006 hotfix). A true native SAF stream-write is the
/// follow-up.
class _LargeFileWarning extends StatelessWidget {
  const _LargeFileWarning({required this.destinationPath});

  /// Where the file will land after Save. Null when
  /// `getExternalStorageDirectory()` couldn't be resolved (rare) —
  /// the widget then falls back to a generic message.
  final String? destinationPath;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = destinationPath;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: scheme.onTertiaryContainer,
              ),
              const SizedBox(width: 8),
              Text(
                'Large file',
                style: TextStyle(
                  color: scheme.onTertiaryContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'The decrypted file is bigger than 200 MiB — the system '
            "file picker isn't reliable at this size. Tapping Save "
            'will copy it straight to:',
            style: TextStyle(
              color: scheme.onTertiaryContainer,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            path ?? '(OpaqueShare folder under this app\'s external storage)',
            style: TextStyle(
              color: scheme.onTertiaryContainer,
              fontSize: 11,
              fontFamily: 'monospace',
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
