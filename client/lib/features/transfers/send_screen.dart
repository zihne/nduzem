import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mime/mime.dart' show lookupMimeType;

import '../../api/api_client.dart';
import '../../api/users_api.dart';
import '../../core/recipient_query.dart';
import '../../crypto/fingerprint.dart';
import '../../crypto/plaintext_source.dart';
import '../auth/auth_providers.dart';
import '../history/transfer_history_entry.dart';
import '../history/transfer_history_provider.dart';
import '../verify_contact/verified_contacts_repo.dart';
import 'picked_file.dart';
import 'send_queue.dart';
import 'transfer_service.dart';
import 'web_file_picker.dart';
import '../../widgets/max_width_content.dart';

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
  PickedFile? _file;

  /// Populated when the user picked ≥ 2 files (ADR-0009 batch). Empty
  /// on single-file picks; the existing single-file path continues to
  /// use [_file]. Never overlaps with [_file] being non-null.
  final List<PickedFile> _batchFiles = <PickedFile>[];
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

  /// Set alongside [_error] when the server refused the commit for
  /// lack of storage budget (HTTP 402 `quota_exceeded`). Non-null →
  /// the error surface renders a "Buy more credit" CTA that routes
  /// to the paywall.
  QuotaExceededException? _quotaError;

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
    // On Android with SAF, `pickFiles` copies the selected file into
    // the app cache before returning — for a multi-GB file that
    // copy can take tens of seconds with no visible activity.
    // `_picking` becomes visible while the picker runs so the user
    // sees "Reading file…" during that gap. Same busy-flag on web
    // for a shorter blob-hoist.
    setState(() {
      _picking = true;
      _error = null;
      _quotaError = null;
    });
    try {
      final List<PickedFile> picked;
      try {
        picked = kIsWeb ? await pickFilesWeb() : await _pickFilesMobile();
      } on _PickError catch (exc) {
        if (mounted) setState(() => _error = exc.message);
        return;
      }
      if (picked.isEmpty) return;
      if (!mounted) return;
      setState(() {
        if (picked.length == 1) {
          _file = picked.single;
          _batchFiles.clear();
        } else {
          _file = null;
          _batchFiles
            ..clear()
            ..addAll(picked);
          // Link mode is app-mode-only for batches (ADR-0009). If the
          // user was on the link tab, snap back to app so the send
          // button + recipient UI make sense.
          if (_mode == SendMode.link) _mode = SendMode.app;
        }
        _error = null;
        _quotaError = null;
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Mobile file pick via `file_picker`. `withData: false` so the
  /// plugin doesn't eagerly load bytes at pick time — the streaming
  /// send (ADR-0013) reads the file on demand.
  Future<List<PickedFile>> _pickFilesMobile() async {
    final res = await FilePicker.platform.pickFiles(
      withData: false,
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty) return const [];
    final picked = <PickedFile>[];
    for (final f in res.files) {
      if (f.path == null) {
        throw _PickError('Could not read "${f.name}" — no path was returned.');
      }
      final int size;
      try {
        size = await File(f.path!).length();
      } on Object catch (exc) {
        throw _PickError('Could not stat "${f.name}": $exc');
      }
      final mime = lookupMimeType(f.name);
      picked.add(
        PickedFile(
          source: FilePlaintextSource(
            path: f.path!,
            filename: f.name,
            lengthBytes: size,
            mimeType: mime,
          ),
          name: f.name,
          mime: mime,
          length: size,
        ),
      );
    }
    return picked;
  }

  Future<void> _lookupRecipient() async {
    final query = RecipientQuery.parse(_lookup.text);
    if (query == null) {
      setState(() => _error = 'Enter the recipient email or @handle.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _quotaError = null;
      _recipient = null;
      _recipientFp = null;
      _priorVerification = null;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final res = query.isEmail
          ? await svc.lookupRecipient(email: query.value)
          : await svc.lookupRecipient(handle: query.value);

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
    } on Object catch (exc) {
      // Anything that isn't the API talking — in practice a
      // PlatformException out of secure_storage when
      // VerifiedContactsRepo.read() hits Android's EncryptedSharedPrefs
      // in a BAD_DECRYPT state (see SecureStore.resetOnCorruption).
      //
      // This used to escape the try entirely, because the only catch
      // here was `on ApiException`. The lookup would succeed, _recipient
      // would never be assigned, `finally` would clear the spinner, and
      // the user got no fingerprint AND no error — a silent dead end in
      // the middle of the send flow.
      //
      // Failing CLOSED is deliberate. `prior` is the key-change alert:
      // if we can't read whether this contact was verified before, we
      // must not render the fingerprint as though they were new, or a
      // substituted key would sail past the one check meant to catch it.
      setState(
        () => _error =
            "Couldn't read your saved verification for this contact, so "
                "the fingerprint isn't being shown — a key change could "
                'go unnoticed. Restart the app and try again; if it '
                'persists, re-verify the contact. ($exc)',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    // Batch branch (ADR-0009): ≥ 2 picked files → hand off to the
    // queue controller and route to /send/batch. Batches are
    // app-mode-only in v1 so a resolved recipient is required.
    if (_batchFiles.isNotEmpty) {
      final recipient = _recipient;
      if (recipient == null) return;
      final router = GoRouter.of(context);
      final recipientLabel = _lookup.text.trim();
      final files = List<PickedFile>.unmodifiable(_batchFiles);
      // Fire-and-forget: the batch screen watches the queue state
      // and doesn't need to await here. This send-screen just needs
      // to navigate and clear its own busy flag.
      final SendQueueController queue = ref.read(sendQueueProvider.notifier);
      unawaited(
        queue.start(
          recipient: recipient,
          recipientLabel: recipientLabel,
          files: files,
        ),
      );
      router.go('/send/batch');
      return;
    }

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
      _quotaError = null;
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
        source: file.source,
        linkPassword: _mode == SendMode.link && linkPassword.isNotEmpty
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
      // Log to local history BEFORE the completion dialog so a user
      // who force-quits the app after seeing the dialog still has the
      // entry on next launch (ADR-0007).
      await ref.read(transferHistoryProvider.notifier).log(
            SentHistoryEntry(
              transferId: result.transferId,
              timestamp: DateTime.now().toUtc(),
              filename: file.name,
              sizeBytes: file.length,
              mode: result.mode == SendMode.link ? 'link' : 'app',
              recipientLabel: result.mode == SendMode.link
                  ? null
                  : (recipientLabel.isEmpty ? null : recipientLabel),
              maxDownloads: result.mode == SendMode.link ? _maxDownloads : 1,
              hasPassword:
                  result.mode == SendMode.link && linkPassword.isNotEmpty,
            ),
          );
      if (!mounted) return;
      // Forced-acknowledgement dialog. `barrierDismissible: false` so
      // a distracted user cannot swipe past it — the only way out is
      // the button, which then navigates home. Distinct dialog per
      // mode (app-mode confirms the recipient; link-mode surfaces the
      // shareable URL — ADR-0005).
      if (result.mode == SendMode.link) {
        // Share URLs point at the marketing / bare-domain host, NOT
        // the api. subdomain — see AppConfig doc comment.
        final shareUrl = _buildLinkUrl(
          appConfig.shareUrlBase,
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
    } on QuotaExceededException catch (exc) {
      // Special-case the quota-exhausted class: the error panel below
      // switches to a "Buy more credit" CTA when `_quotaError` is set.
      // Stay on-screen so the user can top up their balance and hit
      // Send again without re-picking the file.
      setState(() {
        _error = exc.message;
        _quotaError = exc;
      });
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
    // Trigger a rebuild so the button flips to "Cancelling…" before
    // the send loop notices — the checkpoint is per-part / per-chunk
    // and can lag the click by a couple of seconds.
    if (mounted) setState(() {});
  }

  /// Whether the Send button should be enabled given the current state.
  /// - Batch (≥ 2 files): recipient resolved (app-mode only per ADR-0009).
  /// - Single-file app mode: file picked AND recipient resolved.
  /// - Single-file link mode: file picked.
  bool get _sendEnabled {
    if (_busy) return false;
    if (_batchFiles.isNotEmpty) return _recipient != null;
    if (_file == null) return false;
    if (_mode == SendMode.app) return _recipient != null;
    return true;
  }

  /// Assemble `<origin>/r/<transferId>#<K_file>` — the URL the web
  /// decrypt page (ADR-0035) expects. `origin` is the marketing /
  /// bare-domain host (`AppConfig.shareUrlBase`), NOT the `api.`
  /// subdomain — Android universal-link verification and
  /// user-facing URL hygiene both require the bare host. See
  /// AppConfig doc comment for the full reasoning.
  ///
  /// K_file is base64url without padding to match the JS side's
  /// `atob` restoration logic. The fragment is client-side only;
  /// the server never sees K_file.
  String _buildLinkUrl(
    Uri shareUrlBase,
    String transferId,
    List<int> fileKey,
  ) {
    final k = base64UrlEncode(fileKey).replaceAll('=', '');
    // shareUrlBase may or may not end in `/` — normalise before
    // appending the /r/<id> path.
    final base = shareUrlBase.replace(
      path: shareUrlBase.path.endsWith('/')
          ? '${shareUrlBase.path}r/$transferId'
          : '${shareUrlBase.path}/r/$transferId',
    );
    return '$base#$k';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Send a file')),
      body: MaxWidthContent(
          child: Padding(
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
                    ? 'Reading file(s)…'
                    : (_batchFiles.isNotEmpty
                        ? '${_batchFiles.length} files picked'
                        : (_file == null ? 'Pick file(s)' : _file!.name)),
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
            if (_batchFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              _BatchFilesSummary(files: _batchFiles),
            ],

            const SizedBox(height: 24),

            // Stage 1b: mode selector — user vs shareable link (ADR-0005).
            // Link mode is disabled for batches (ADR-0009): a batch of N
            // link-mode sends produces N URLs which the completion
            // surface doesn't handle yet.
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
              onSelectionChanged: (_busy || _batchFiles.isNotEmpty)
                  ? null
                  : (s) => setState(() {
                        _mode = s.first;
                        _error = null;
                        _quotaError = null;
                      }),
            ),
            if (_batchFiles.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Link mode supports one file at a time in this version. '
                'Batches always send to a user.',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],

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
                // Disable + re-label once the user has clicked once;
                // the actual send loop can take a moment to notice
                // (current part PUT / chunk read has to finish before
                // the next cancel checkpoint fires).
                onPressed:
                    (_cancel?.isCancelled ?? false) ? null : _cancelSend,
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
              if (_quotaError != null)
                _QuotaExceededPanel(exception: _quotaError!)
              else
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
            ],
          ],
        ),
      ),),
    );
  }
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
    // Only two active phases fire from TransferService.send now
    // (ADR-0013 Phase 7 polish): preparing during /initiate, then
    // uploading. The encrypting label is kept for the deprecated
    // enum value so a fallback exists if any external caller still
    // ships it.
    final phaseLabel = switch (phase) {
      // ignore: deprecated_member_use_from_same_package
      SendPhase.encrypting => 'Sending',
      SendPhase.preparing => 'Preparing upload',
      SendPhase.uploading => 'Sending',
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

/// Error surface for the 402 `quota_exceeded` case (ADR-0033 IAP
/// paywall route + server `services/quota.py::InsufficientQuota`).
///
/// A plain "HTTP 402" line is not actionable — the user needs to
/// know why the send stopped AND how to unstick themselves. So we
/// render the numbers the server sent (required vs. available) plus
/// a primary CTA that routes to `/paywall`. Retry stays implicit:
/// the user comes back to the send screen with a topped-up balance
/// and taps Send again — the file is still picked and encrypted.
class _QuotaExceededPanel extends StatelessWidget {
  const _QuotaExceededPanel({required this.exception});
  final QuotaExceededException exception;

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
                Icon(Icons.wallet, color: scheme.onErrorContainer),
                const SizedBox(width: 8),
                Text(
                  'Not enough storage budget',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'This send needs ${exception.requiredMb} MiB. You have '
              '${exception.subRemainingMb} MiB left on your plan and '
              '${exception.creditMb} MiB in credits.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => context.push('/paywall'),
                icon: const Icon(Icons.add_shopping_cart),
                label: const Text('Buy more credit'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact "N files, X.Y MiB total" summary + a tap-to-expand list of
/// filenames. Shown under the pick button when the user picked ≥ 2
/// files (ADR-0009 batch). Kept small so it doesn't push the recipient
/// UI below the fold on smaller phones.
class _BatchFilesSummary extends StatelessWidget {
  const _BatchFilesSummary({required this.files});
  final List<PickedFile> files;

  @override
  Widget build(BuildContext context) {
    final total = files.fold<int>(0, (acc, f) => acc + f.length);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.surfaceContainerHighest,
      child: ExpansionTile(
        title: Text(
          '${files.length} files · ${_prettyBytes(total)} total',
        ),
        subtitle: const Text('Batch send — same recipient for all.'),
        childrenPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 4,
        ),
        children: [
          for (final f in files)
            ListTile(
              dense: true,
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(
                f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(_prettyBytes(f.length)),
            ),
        ],
      ),
    );
  }
}

/// User-facing pick failure. Thrown by [_pickFilesMobile] /
/// [_pickFilesWeb] to short-circuit their loops with a message the
/// send-screen surfaces via `_error`.
class _PickError implements Exception {
  const _PickError(this.message);
  final String message;
}
