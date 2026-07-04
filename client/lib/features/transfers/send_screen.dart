import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mime/mime.dart' show lookupMimeType;

import '../../api/api_client.dart';
import '../../api/users_api.dart';
import '../../crypto/fingerprint.dart';
import '../auth/auth_providers.dart';
import '../verify_contact/verified_contacts_repo.dart';
import 'transfer_service.dart';

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
  final _linkPassword = TextEditingController();
  _PickedFile? _file;
  UserLookup? _recipient;
  Fingerprint? _recipientFp;
  VerifiedContact? _priorVerification;

  /// Which end-to-end send path the UI is composed for (ADR-0005).
  /// `app` shows the recipient-lookup + fingerprint UX; `link` shows
  /// the optional-password + max-downloads UX and skips the
  /// recipient-side plumbing entirely.
  SendMode _mode = SendMode.app;

  /// Server allows 1-10; UI offers a small set of sensible values.
  int _maxDownloads = 1;

  bool _busy = false;
  String? _error;

  // True while the file_picker SAF flow is running — including the
  // plugin's post-selection copy of the SAF-picked file into app
  // cache, which can take real time on large files. Distinct from
  // `_busy` (which is the send flow) so the button label + spinner
  // can reflect "picking / reading" separately from "sending".
  bool _picking = false;

  // M4 send progress. Non-null while a send is in flight. Cleared on
  // completion, error, or cancel. `_phase` distinguishes the
  // encrypt / preparing / upload phases so the UI can label + reset
  // the bar between them (ADR-0004).
  SendPhase? _phase;
  int? _uploadedBytes;
  int? _totalBytes;
  CancelToken? _cancel;

  @override
  void dispose() {
    _lookup.dispose();
    _linkPassword.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    // `withData: false` so the plugin doesn't eagerly load bytes at
    // pick time. Streaming send (ADR-0004) reads the file on demand.
    // On Android with SAF, `pickFiles` still copies the selected
    // file into app cache before returning — for a multi-GB file
    // that copy can take tens of seconds with no visible activity.
    // `_picking` becomes visible when SAF dismisses, so the user
    // sees "Reading file…" during that gap.
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final res = await FilePicker.platform.pickFiles(withData: false);
      if (res == null || res.files.isEmpty) return;
      final f = res.files.single;
      if (f.path == null) {
        if (mounted) {
          setState(
            () =>
                _error = 'Could not read that file — no path was returned.',
          );
        }
        return;
      }
      final int size;
      try {
        size = await File(f.path!).length();
      } on Object catch (exc) {
        if (mounted) {
          setState(() => _error = 'Could not stat that file: $exc');
        }
        return;
      }
      if (!mounted) return;
      setState(() {
        _file = _PickedFile(
          name: f.name,
          mime: lookupMimeType(f.name),
          path: f.path!,
          length: size,
        );
        _error = null;
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
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
    if (file == null) return;
    // App mode requires a resolved recipient; link mode never uses one.
    if (_mode == SendMode.app && _recipient == null) return;
    final linkPassword = _linkPassword.text.trim();
    if (_mode == SendMode.link &&
        linkPassword.isNotEmpty &&
        linkPassword.length < 4) {
      setState(
        () => _error = 'Password must be at least 4 characters.',
      );
      return;
    }
    final cancel = CancelToken();
    setState(() {
      _busy = true;
      _error = null;
      _uploadedBytes = 0;
      _totalBytes = null;
      _cancel = cancel;
    });
    // Grab these BEFORE the async gap so they're still valid after
    // we navigate away — the widget context becomes stale otherwise.
    // ScaffoldMessenger sits above MaterialApp so its SnackBars keep
    // showing across a `router.go('/')`.
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final recipientLabel = _lookup.text.trim();
    final appConfig = ref.read(appConfigProvider);
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final result = await svc.send(
        mode: _mode,
        recipient: _mode == SendMode.app ? _recipient : null,
        plaintextPath: file.path,
        plaintextLength: file.length,
        filename: file.name,
        mime: file.mime,
        linkPassword:
            _mode == SendMode.link && linkPassword.isNotEmpty
                ? linkPassword
                : null,
        maxDownloads: _mode == SendMode.link ? _maxDownloads : 1,
        onProgress: (phase, done, total) {
          if (!mounted) return;
          setState(() {
            _phase = phase;
            _uploadedBytes = done;
            _totalBytes = total;
          });
        },
        cancel: cancel,
      );
      if (!mounted) return;
      // Forced-acknowledgement dialog. `barrierDismissible: false` so
      // a distracted user cannot swipe past it — the only way out is
      // the button, which then navigates home. Distinct dialog per
      // mode (app-mode confirms the recipient; link-mode surfaces the
      // shareable URL — ADR-0005).
      if (result.mode == SendMode.link) {
        final shareUrl = _buildLinkUrl(
          appConfig.apiBaseUrl,
          result.transferId,
          result.linkFileKey!,
        );
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => _LinkCreatedDialog(
            filename: file.name,
            byteCount: result.byteCountOnServer,
            hasPassword: linkPassword.isNotEmpty,
            maxDownloads: _maxDownloads,
            shareUrl: shareUrl,
          ),
        );
      } else {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => _SendCompleteDialog(
            filename: file.name,
            byteCount: result.byteCountOnServer,
            recipientLabel: recipientLabel,
            transferId: result.transferId,
          ),
        );
      }
      router.go('/');
      return;
    } on SendCancelledException {
      // Cancel was user-initiated — they know it happened, no need
      // to block on a modal. A snackbar suffices.
      messenger.showSnackBar(
        const SnackBar(content: Text('Send cancelled.')),
      );
      router.go('/');
      return;
    } on ApiException catch (exc) {
      // Stay on-screen so the user can retry without re-picking.
      setState(() => _error = exc.message);
    } on Object catch (exc) {
      setState(() => _error = 'Send failed: $exc');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _uploadedBytes = null;
          _totalBytes = null;
          _cancel = null;
        });
      }
    }
  }

  void _cancelSend() {
    _cancel?.cancel();
  }

  /// Whether the Send button should be enabled given the current state.
  /// - App mode: file picked AND recipient resolved.
  /// - Link mode: file picked (password + max downloads are optional).
  bool get _sendEnabled {
    if (_busy || _file == null) return false;
    if (_mode == SendMode.app) return _recipient != null;
    return true;
  }

  /// Assemble `<origin>/r/<transferId>#<K_file>` — the URL the web
  /// decrypt page (ADR-0035) expects. K_file is base64url without
  /// padding to match the JS side's `atob` restoration logic. The
  /// fragment is client-side only; the server never sees K_file.
  String _buildLinkUrl(
    Uri apiBaseUrl,
    String transferId,
    List<int> fileKey,
  ) {
    final k = base64UrlEncode(fileKey).replaceAll('=', '');
    // apiBaseUrl may or may not end in `/` — use `resolve` to compose.
    final base = apiBaseUrl.replace(
      path: apiBaseUrl.path.endsWith('/')
          ? '${apiBaseUrl.path}r/$transferId'
          : '${apiBaseUrl.path}/r/$transferId',
    );
    return '$base#$k';
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
              onPressed: (_busy || _picking) ? null : _pickFile,
              icon: _picking
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.attach_file),
              label: Text(
                _picking
                    ? 'Reading file…'
                    : (_file == null ? 'Pick a file' : _file!.name),
              ),
            ),
            if (_file != null) ...[
              const SizedBox(height: 4),
              Text(
                '${_file!.length} bytes'
                '${_file!.mime == null ? '' : ' · ${_file!.mime}'}',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ],

            const SizedBox(height: 24),

            // Stage 1b: mode selector — user vs shareable link (ADR-0005).
            SegmentedButton<SendMode>(
              segments: const [
                ButtonSegment(
                  value: SendMode.app,
                  label: Text('To a user'),
                  icon: Icon(Icons.person),
                ),
                ButtonSegment(
                  value: SendMode.link,
                  label: Text('Share as link'),
                  icon: Icon(Icons.link),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: _busy
                  ? null
                  : (s) => setState(() {
                        _mode = s.first;
                        _error = null;
                      }),
            ),

            const SizedBox(height: 24),

            if (_mode == SendMode.app) ...[
              // Stage 2a — app mode: recipient lookup + fingerprint.
              const Text(
                'To',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _lookup,
                keyboardType: TextInputType.emailAddress,
                decoration:
                    const InputDecoration(labelText: 'Email or @handle'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _lookupRecipient,
                icon: const Icon(Icons.search),
                label: const Text('Look up recipient'),
              ),
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
              ],
            ] else ...[
              // Stage 2b — link mode: optional password + max downloads.
              const Text(
                'Password (optional)',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _linkPassword,
                obscureText: true,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'At least 4 characters',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Share this password with the recipient out-of-band. '
                'It gates the download but does not encrypt the file.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  const Text(
                    'Max downloads: ',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 8),
                  DropdownButton<int>(
                    value: _maxDownloads,
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _maxDownloads = v ?? 1),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1')),
                      DropdownMenuItem(value: 3, child: Text('3')),
                      DropdownMenuItem(value: 10, child: Text('10')),
                    ],
                  ),
                ],
              ),
            ],

            // Send action (shared across modes) — disabled unless the
            // required state per mode is in place.
            const SizedBox(height: 20),
            if (_busy && _cancel != null) ...[
              _SendProgress(
                phase: _phase,
                done: _uploadedBytes,
                total: _totalBytes,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _cancelSend,
                icon: const Icon(Icons.cancel),
                label: const Text('Cancel'),
              ),
            ] else
              FilledButton.icon(
                onPressed: _sendEnabled ? _send : null,
                icon: Icon(
                  _mode == SendMode.link ? Icons.link : Icons.send,
                ),
                label: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        _mode == SendMode.link
                            ? 'Create shareable link'
                            : 'Encrypt and send',
                      ),
              ),

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

class _PickedFile {
  const _PickedFile({
    required this.name,
    required this.mime,
    required this.path,
    required this.length,
  });
  final String name;
  final String? mime;

  /// Filesystem path of the plaintext file. The streaming send flow
  /// reads chunks straight from here; the screen never loads the
  /// bytes into memory.
  final String path;
  final int length;
}

/// Modal acknowledgement after a successful send. `barrierDismissible:
/// false` at the caller ensures the user has to tap Done — otherwise a
/// distracted user might miss the confirmation entirely and there's no
/// transfer-history screen to fall back on yet (M9.x). Transfer ID is
/// shown selectable so the user can copy it for debugging / support.
class _SendCompleteDialog extends StatelessWidget {
  const _SendCompleteDialog({
    required this.filename,
    required this.byteCount,
    required this.recipientLabel,
    required this.transferId,
  });
  final String filename;
  final int byteCount;
  final String recipientLabel;
  final String transferId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.check_circle, color: scheme.primary, size: 32),
      title: const Text('Transfer sent'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DialogRow(label: 'File', value: filename),
          const SizedBox(height: 8),
          _DialogRow(label: 'Size', value: _prettyBytes(byteCount)),
          const SizedBox(height: 8),
          _DialogRow(label: 'To', value: recipientLabel),
          const SizedBox(height: 12),
          Text(
            'Transfer ID',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: 2),
          SelectableText(
            transferId,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

/// Modal acknowledgement after a successful link-mode send
/// (ADR-0005). Primary content is the shareable URL — presented as
/// selectable monospace text with a big "Copy link" button beneath.
/// Barrier-dismissible false at the caller so the user MUST tap
/// Done, avoiding the "screen closed before I copied the URL" bug
/// that killed the earlier snackbar-based flow.
class _LinkCreatedDialog extends StatelessWidget {
  const _LinkCreatedDialog({
    required this.filename,
    required this.byteCount,
    required this.hasPassword,
    required this.maxDownloads,
    required this.shareUrl,
  });
  final String filename;
  final int byteCount;
  final bool hasPassword;
  final int maxDownloads;
  final String shareUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.link, color: scheme.primary, size: 32),
      title: const Text('Link created'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DialogRow(label: 'File', value: filename),
            const SizedBox(height: 6),
            _DialogRow(label: 'Size', value: _prettyBytes(byteCount)),
            const SizedBox(height: 6),
            _DialogRow(
              label: 'Uses',
              value: maxDownloads == 1
                  ? '1 download'
                  : 'up to $maxDownloads downloads',
            ),
            if (hasPassword) ...[
              const SizedBox(height: 6),
              _DialogRow(
                label: 'Extra',
                value: 'password required at download',
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Shareable link',
              style: Theme.of(context).textTheme.labelSmall,
            ),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                shareUrl,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Anyone with this link can decrypt the file. Share it '
              "out-of-band; don't post it publicly.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: shareUrl));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Link copied.')),
            );
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy link'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _DialogRow extends StatelessWidget {
  const _DialogRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 56,
          child: Text(label, style: t.labelSmall),
        ),
        Expanded(
          child: Text(value, style: t.bodyMedium),
        ),
      ],
    );
  }
}

/// Multi-phase progress bar (ADR-0004). `phase` labels which stage
/// of the send we're in — encrypting (streaming plaintext through
/// secretstream into a temp file), preparing (enc_header + seal +
/// sign + /initiate — indeterminate), or uploading (PUTting parts).
/// The bar reset between phases makes the transition visually
/// obvious.
class _SendProgress extends StatelessWidget {
  const _SendProgress({
    required this.phase,
    required this.done,
    required this.total,
  });
  final SendPhase? phase;
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
      SendPhase.encrypting => 'Encrypting',
      SendPhase.preparing => 'Preparing upload',
      SendPhase.uploading => 'Uploading',
      null => 'Preparing…',
    };
    String label;
    if (phase == SendPhase.preparing) {
      // Indeterminate on purpose — /initiate + seal + sign together
      // are unbounded from the UI's perspective.
      value = null;
      label = '$phaseLabel…';
    } else if (value != null && d != null && t != null) {
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

  static String _mib(int bytes) => _prettyBytes(bytes);
}

/// KiB / MiB / GiB with sensible precision. Used by the progress
/// label and the post-send confirmation SnackBar.
String _prettyBytes(int bytes) {
  final gib = bytes / (1024 * 1024 * 1024);
  if (gib >= 1) return '${gib.toStringAsFixed(2)} GiB';
  final mib = bytes / (1024 * 1024);
  if (mib >= 100) return '${mib.toStringAsFixed(0)} MiB';
  if (mib >= 1) return '${mib.toStringAsFixed(1)} MiB';
  return '${(bytes / 1024).toStringAsFixed(0)} KiB';
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
