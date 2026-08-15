import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/api_client.dart';
import '../../api/links_api.dart';
import '../../crypto/suite.dart';
import '../../crypto/suite_keys.dart';
import '../../native/saf_saver.dart';
import '../auth/auth_providers.dart';
import '../history/transfer_history_entry.dart';
import '../history/transfer_history_provider.dart';
import 'transfer_service.dart';
import 'web_saver.dart';
import '../../widgets/max_width_content.dart';

/// In-app link-mode receive (ADR-0010) — same conceptual flow as the
/// authed [ReceiveScreen], but auth-less and using the URL fragment
/// as the file key.
///
/// Stages:
///   1. **Loading** — `GET /v1/links/<id>` info; renders a spinner.
///   2. **Not-available** — panels for expired / consumed / missing.
///   3. **Password prompt** — text field + Download button when the
///      link has an out-of-band password.
///   4. **Ready** — filename + size (decoded from `enc_header` with
///      the fragment K_file). Download button.
///   5. **Downloading + decrypting** — two-phase progress.
///   6. **Decrypted → Save** — SAF stream-save (ADR-0008) on Android,
///      app-docs fallback on iOS.
///   7. **Saved + acked** — the plaintext + history are locked in.
class LinkReceiveScreen extends ConsumerStatefulWidget {
  const LinkReceiveScreen({
    super.key,
    required this.transferId,
    required this.fileKeyB64Url,
  });
  final String transferId;

  /// Base64URL-encoded K_file lifted from the URL fragment. May be
  /// empty when the user opened `/r/<id>` without a fragment — we
  /// surface a specific "invalid link" panel in that case.
  final String fileKeyB64Url;

  @override
  ConsumerState<LinkReceiveScreen> createState() => _LinkReceiveScreenState();
}

const int _saveBytesWarnThreshold = 200 * 1024 * 1024;

class _LinkReceiveScreenState extends ConsumerState<LinkReceiveScreen> {
  final _password = TextEditingController();

  AsyncValue<LinkInfo> _linkInfo = const AsyncValue.loading();
  Uint8List? _fileKey;
  String? _fragmentError;

  /// Filename + size decoded from `enc_header` before the user commits
  /// to the download. Lets the receive screen show the user WHAT they'd
  /// be downloading before actually pulling the ciphertext.
  String? _previewFilename;
  int? _previewByteCount;

  DecryptedTransfer? _decrypted;
  String? _savedPath;
  bool _acked = false;
  bool _busy = false;
  String? _error;

  /// Set when the last download attempt failed with 401 because the
  /// server said the link password is wrong (or missing). Distinct
  /// from [_error] so the UI can show an inline "password incorrect"
  /// hint under the field rather than a generic error.
  bool _passwordRejected = false;

  String? _externalBaseDir;

  ReceivePhase? _phase;
  int? _phaseDone;
  int? _phaseTotal;
  CancelToken? _cancel;

  @override
  void initState() {
    super.initState();
    _decodeFragmentKey();
    _resolveExternalBaseDir();
    _loadLinkInfo();
  }

  @override
  void dispose() {
    _password.dispose();
    final path = _decrypted?.plaintextPath;
    if (path != null) {
      // Best-effort cleanup if the user backed out mid-flow.
      unawaited(_deleteIfExists(path));
    }
    super.dispose();
  }

  void _decodeFragmentKey() {
    if (widget.fileKeyB64Url.isEmpty) {
      _fragmentError =
          'This link is missing its decryption key. The URL fragment '
          '(after "#") must be present — check the link you were sent.';
      return;
    }
    try {
      // The sender assembles the fragment as base64url WITHOUT padding
      // (see send_screen `_buildLinkUrl`). Restore padding for
      // base64Url.decode.
      final raw = widget.fileKeyB64Url;
      final padded = raw + '=' * ((4 - raw.length % 4) % 4);
      _fileKey = Uint8List.fromList(base64Url.decode(padded));
    } on Object {
      _fragmentError = 'This link\'s decryption key is malformed. The URL '
          'fragment isn\'t valid base64url — the link may have been '
          'corrupted in transit.';
    }
  }

  Future<void> _resolveExternalBaseDir() async {
    // Web has no filesystem — see [ReceiveScreen] for the same guard.
    if (kIsWeb) return;
    try {
      final base = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getApplicationDocumentsDirectory();
      if (!mounted) return;
      setState(() => _externalBaseDir = base?.path);
    } on Object {
      // ignore
    }
  }

  Future<void> _loadLinkInfo() async {
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final info = await svc.linkInfo(widget.transferId);
      if (!mounted) return;
      setState(() => _linkInfo = AsyncValue.data(info));
      _tryDecodePreview(info);
    } on Object catch (exc, st) {
      if (!mounted) return;
      setState(() => _linkInfo = AsyncValue.error(exc, st));
    }
  }

  /// Local enc_header decrypt to show filename BEFORE downloading. No
  /// server call, no counter increment — pure client-side unwrap of
  /// the envelope shown in `/v1/links/<id>` info.
  void _tryDecodePreview(LinkInfo info) {
    final key = _fileKey;
    final headerB64 = info.encHeaderB64;
    if (key == null || headerB64 == null || !info.downloadable) return;
    try {
      final envelope = ref.read(envelopeProvider);
      final env = envelope.valueOrNull;
      if (env == null) return;
      final sodium = ref.read(sodiumProvider).valueOrNull;
      if (sodium == null) return;
      // The header key depends on the envelope's suite: suite 1 uses
      // K_file directly, suite 2 a derived subkey. Getting this wrong
      // costs no security here — the header simply fails to open — but
      // the catch below swallows that, so the preview would silently go
      // blank rather than showing a filename.
      final wire = info.cryptoSuite;
      if (wire == null) return;
      final suiteKeys =
          SuiteKeys.derive(sodium, key, CryptoSuite.fromWire(wire));
      final header = env.openEncHeader(
        encHeader: Uint8List.fromList(base64Decode(headerB64)),
        fileKey: suiteKeys.headerKey,
      );
      setState(() {
        _previewFilename = header.filename;
        _previewByteCount = header.plaintextLength;
      });
    } on Object {
      // Fragment key doesn't match the envelope — leave preview null;
      // the download step will fail more informatively.
    }
  }

  Future<void> _download() async {
    final key = _fileKey;
    if (key == null) return;
    final cancel = CancelToken();
    setState(() {
      _busy = true;
      _error = null;
      _passwordRejected = false;
      _phase = null;
      _phaseDone = null;
      _phaseTotal = null;
      _cancel = cancel;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final res = await svc.receiveLinkMode(
        transferId: widget.transferId,
        fileKey: key,
        password: _password.text.isEmpty ? null : _password.text,
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
      if (!mounted) return;
      // The server returns 401 when the password field is wrong or
      // missing. Surface this specifically so the field can highlight
      // the rejection rather than a generic error.
      if (exc.statusCode == 401) {
        setState(() {
          _passwordRejected = true;
          _error = null;
        });
      } else {
        setState(() => _error = exc.message);
      }
    } on Object catch (exc) {
      if (mounted) setState(() => _error = 'Download failed: $exc');
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
    if (mounted) setState(() {});
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
        savedPath = await saveBytesWeb(
          bytes: decrypted.plaintextBytes!,
          filename: decrypted.filename,
          mimeType: decrypted.mime,
        );
        if (savedPath == null) return;
      } else if (decrypted.plaintextLength > _saveBytesWarnThreshold) {
        savedPath = await _saveLargeFile(decrypted);
      } else {
        final bytes = await File(decrypted.plaintextPath!).readAsBytes();
        final result = await FilePicker.platform.saveFile(
          dialogTitle: 'Save decrypted file',
          fileName: decrypted.filename,
          bytes: bytes,
        );
        if (result == null) return;
        final saved = File(result);
        savedPath = saved.existsSync() ? saved.path : result;
      }
    } on Object catch (exc) {
      setState(() => _error = 'Save failed: $exc');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (savedPath == null) return;
    setState(() => _savedPath = savedPath);
    await _ack(autoTriggered: true);
  }

  Future<String?> _saveLargeFile(DecryptedTransfer decrypted) async {
    final saf = ref.read(safSaverProvider);
    SafPickedDestination? destination;
    try {
      destination = await saf.pickSaveUri(
        suggestedFilename: decrypted.filename,
      );
    } on SafSaveWriteException catch (exc) {
      setState(() => _error = 'Picker failed: ${exc.message}');
      return _saveToExternalStorage(decrypted);
    }
    if (destination == null) {
      if (!Platform.isAndroid) return _saveToExternalStorage(decrypted);
      return null;
    }
    try {
      await saf.writeFileToUri(
        sourcePath: decrypted.plaintextPath!,
        uri: destination.uri,
      );
    } on SafSaveWriteException catch (exc) {
      setState(() => _error = 'SAF save failed: ${exc.message}');
      return _saveToExternalStorage(decrypted);
    }
    await _deleteIfExists(decrypted.plaintextPath!);
    return destination.displayName;
  }

  Future<String?> _saveToExternalStorage(DecryptedTransfer decrypted) async {
    final Directory? baseDir;
    try {
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
    final saveDir = Directory('${baseDir.path}/Nduzem');
    if (!await saveDir.exists()) {
      await saveDir.create(recursive: true);
    }
    final finalPath = await _uniquePath(saveDir.path, decrypted.filename);
    try {
      await File(decrypted.plaintextPath!).copy(finalPath);
      await _deleteIfExists(decrypted.plaintextPath!);
    } on Object catch (exc) {
      await _deleteIfExists(finalPath);
      setState(() => _error = 'Save failed: $exc');
      return null;
    }
    return finalPath;
  }

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
    return candidate;
  }

  Future<void> _ack({bool autoTriggered = false}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      // Same secret the download used. The server now requires it on
      // ack for password-protected links, because acking is a state
      // change that can trigger the burn.
      await svc.linkAck(
        widget.transferId,
        password: _password.text.isEmpty ? null : _password.text,
      );
      final path = _decrypted?.plaintextPath;
      if (path != null) await _deleteIfExists(path);
      final decrypted = _decrypted;
      if (decrypted != null) {
        await ref.read(transferHistoryProvider.notifier).log(
              ReceivedHistoryEntry(
                transferId: decrypted.transferId,
                timestamp: DateTime.now().toUtc(),
                filename: decrypted.filename,
                sizeBytes: decrypted.plaintextLength,
                // Link mode has no on-platform sender identity.
                senderIdShort: null,
                senderHandle: null,
                signatureVerified: decrypted.senderSignatureVerified,
                savedPath: _savedPath,
              ),
            );
      }
      if (!mounted) return;
      setState(() => _acked = true);
    } on ApiException catch (exc) {
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
      appBar: AppBar(title: const Text('Receive a shared file')),
      body: MaxWidthContent(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(children: _body(context)),
          ),
        ),
      ),
    );
  }

  List<Widget> _body(BuildContext context) {
    if (_fragmentError != null) {
      return [_InvalidLinkPanel(message: _fragmentError!)];
    }
    return _linkInfo.when(
      loading: () => const [
        Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: CircularProgressIndicator(),
          ),
        ),
      ],
      error: (err, _) => [
        _InvalidLinkPanel(
          message: 'Could not look up this link: $err',
        ),
      ],
      data: (info) => _bodyForInfo(context, info),
    );
  }

  List<Widget> _bodyForInfo(BuildContext context, LinkInfo info) {
    if (!info.exists) {
      return const [
        _InvalidLinkPanel(
          message: 'This link is unknown to the server. It may have '
              'been mistyped, or the file has been fully removed.',
        ),
      ];
    }
    if (info.expired) {
      return const [
        _InvalidLinkPanel(
          message: 'This link has expired — the server no longer has '
              'the file. Ask the sender to share it again.',
        ),
      ];
    }
    if (info.consumed) {
      return const [
        _InvalidLinkPanel(
          message: 'This file has already been received — the '
              'sender-set download cap was reached. Ask the sender '
              'to share a fresh link if you still need the file.',
        ),
      ];
    }
    if (_decrypted != null) {
      return _postDecryptBody(context);
    }
    return _preDownloadBody(context, info);
  }

  List<Widget> _preDownloadBody(BuildContext context, LinkInfo info) {
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Ready to receive',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (_previewFilename != null)
                SelectableText(_previewFilename!)
              else
                const Text(
                  '(filename decoded after download)',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              if (_previewByteCount != null) ...[
                const SizedBox(height: 4),
                Text('$_previewByteCount bytes'),
              ],
              const SizedBox(height: 8),
              const Text(
                'Anonymous sender — link-mode transfers have no '
                'on-platform sender identity, so the signature '
                "badge doesn't apply here.",
                style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      if (info.passwordRequired) ...[
        TextField(
          controller: _password,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Link password',
            helperText: 'The sender shared this password out-of-band '
                '(not in the link itself).',
            errorText: _passwordRejected ? 'Password incorrect.' : null,
          ),
        ),
        const SizedBox(height: 12),
      ],
      if (_busy && _phase != null)
        _LinkReceiveProgress(
          phase: _phase,
          done: _phaseDone,
          total: _phaseTotal,
        )
      else
        FilledButton.icon(
          onPressed: _busy ? null : _download,
          icon: const Icon(Icons.download),
          label: const Text('Receive'),
        ),
      if (_busy) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          // See send_screen — "Cancelling…" state for the gap between
          // click and the receive loop's next checkpoint.
          onPressed: (_cancel?.isCancelled ?? false) ? null : _cancelDownload,
          icon: (_cancel?.isCancelled ?? false)
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cancel),
          label: Text(
            (_cancel?.isCancelled ?? false) ? 'Cancelling…' : 'Cancel',
          ),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 16),
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    ];
  }

  List<Widget> _postDecryptBody(BuildContext context) {
    final decrypted = _decrypted!;
    return [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _savedPath == null ? 'Ready to save' : 'Saved',
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
              if (_savedPath != null) ...[
                const SizedBox(height: 8),
                SelectableText(
                  _savedPath!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      // iOS large-file heads-up: SAF isn't wired there yet, so the
      // save falls back to the app-docs dir (ADR-0010 open follow-up).
      // Web has FSA / `<a download>` — no size caveat there.
      if (!kIsWeb &&
          !Platform.isAndroid &&
          decrypted.plaintextLength > _saveBytesWarnThreshold &&
          _savedPath == null) ...[
        const SizedBox(height: 12),
        _IosLargeFileNotice(
          destinationPath: _externalBaseDir == null
              ? null
              : '$_externalBaseDir/Nduzem/${decrypted.filename}',
        ),
      ],
      const SizedBox(height: 16),
      if (_savedPath == null)
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
        )
      else if (!_acked)
        FilledButton.icon(
          onPressed: _busy ? null : _ack,
          icon: const Icon(Icons.local_fire_department),
          label: const Text("Burn the sender's copy"),
        )
      else ...[
        const Text(
          'Done — the sender-side copy is burnt.',
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: () => context.go('/'),
          icon: const Icon(Icons.check),
          label: const Text('Finish'),
        ),
      ],
      if (_error != null) ...[
        const SizedBox(height: 16),
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    ];
  }
}

class _InvalidLinkPanel extends StatelessWidget {
  const _InvalidLinkPanel({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.link_off, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Text(
                  'This link can\'t be used',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ],
        ),
      ),
    );
  }
}

class _IosLargeFileNotice extends StatelessWidget {
  const _IosLargeFileNotice({required this.destinationPath});
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
          Text(
            'Large file — will save to app documents',
            style: TextStyle(
              color: scheme.onTertiaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (path != null) ...[
            const SizedBox(height: 4),
            SelectableText(
              path,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _LinkReceiveProgress extends StatelessWidget {
  const _LinkReceiveProgress({
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(phaseLabel, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 4),
        LinearProgressIndicator(value: value),
      ],
    );
  }
}
