import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart';
import '../../api/drop_uploads_api.dart';
import '../../widgets/max_width_content.dart';
import '../auth/auth_providers.dart';
import '../transfers/picked_file.dart';
import '../transfers/web_file_picker.dart';
import 'drop_link.dart';
import 'drop_upload_service.dart';

/// The page someone lands on from an upload link (ADR-0040 phase 4b).
///
/// No account, no sign-in. The router exempts `/drop/` from its auth
/// redirect for exactly this reason.
///
/// Web only, deliberately: a drop link is opened from an email on
/// whatever device the recipient happens to have, and that is a browser.
/// There is no mobile route to this screen.
///
/// WHAT THIS PAGE PROMISES, AND WHAT IT MUST NOT. The file is encrypted
/// here, in this browser, to a key taken from the URL fragment — so the
/// server cannot read it. But nothing here identifies the uploader to
/// the recipient, and the page must not imply otherwise: no "verified",
/// no "signed by". See the closing note in the success state.
class DropUploadScreen extends ConsumerStatefulWidget {
  const DropUploadScreen({
    super.key,
    required this.dropId,
    required this.ownerKeyParam,
  });

  final String dropId;

  /// The `k` parameter of the client-side route — the owner's X25519
  /// public key, base64url. It lives inside the URL fragment, which
  /// browsers never transmit, so the server never sees it.
  final String? ownerKeyParam;

  @override
  ConsumerState<DropUploadScreen> createState() => _DropUploadScreenState();
}

class _DropUploadScreenState extends ConsumerState<DropUploadScreen> {
  final _password = TextEditingController();

  /// Chosen files, in the order they will be sent. One file is one
  /// transfer and one upload slot — there is no batch on the server and
  /// a drop is a capability, not a container.
  List<PickedFile> _files = const [];

  /// Per-file outcome, by index. Absent means not attempted yet.
  final Map<int, String?> _results = {};

  int _current = 0;
  bool _busy = false;
  String? _error;
  bool _done = false;
  DropUploadPhase _phase = DropUploadPhase.encrypting;
  int _progressDone = 0;
  int _progressTotal = 0;

  bool? _open;
  int _maxBytes = 0;

  @override
  void initState() {
    super.initState();
    // The Send button's enabled state is derived from `_password.text`,
    // and a TextEditingController rebuilds nothing on its own. Without
    // this, typing the password AFTER choosing the file left Send
    // disabled — choosing a file happens to call setState, so the other
    // order worked, which is what made it look intermittent.
    _password.addListener(_onPasswordChanged);
    _loadInfo();
  }

  void _onPasswordChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _password.removeListener(_onPasswordChanged);
    _password.dispose();
    super.dispose();
  }

  /// The owner's X25519 public key, lifted out of `#k=`.
  ///
  /// Parsing lives in `drop_link.dart` beside the builder that produced
  /// the link, so the two cannot drift, and so it can be tested without
  /// a widget.
  Uint8List? get _ownerKey => decodeOwnerKeyParam(widget.ownerKeyParam);

  Future<void> _loadInfo() async {
    try {
      final svc = await ref.read(dropUploadServiceProvider.future);
      final info = await svc.info(widget.dropId);
      if (!mounted) return;
      setState(() {
        _open = info.open;
        _maxBytes = info.maxBytes;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not reach the service.');
    }
  }

  Future<void> _pick() async {
    if (!kIsWeb) return;
    final picked = await pickFilesWeb();
    if (picked.isEmpty || !mounted) return;
    setState(() {
      _files = picked;
      _results.clear();
      _error = null;
    });
  }

  /// Both halves present. Named rather than inlined so the button and
  /// the hint beneath it cannot drift apart.
  /// Most files one submission may carry.
  ///
  /// Not a product rule but a consequence of one: each file is an
  /// `/initiate` and a `/commit`, both per-IP rate limited, so a large
  /// selection used to fail part-way through on a 429 that said nothing
  /// useful. Ten fits comfortably inside the window with room for
  /// retries, and a stated limit beats a discovered one.
  ///
  /// The drop's own `max_uploads` is the real bound and applies across
  /// every submission; this only bounds one pass.
  static const _maxPerSubmission = 10;

  bool get _tooMany => _files.length > _maxPerSubmission;

  bool get _canSend =>
      _files.isNotEmpty && !_tooMany && _password.text.trim().isNotEmpty;

  int get _sentCount => _results.values.where((e) => e == null).length;
  int get _failedCount => _results.values.where((e) => e != null).length;

  Future<void> _send() async {
    final key = _ownerKey;
    if (_files.isEmpty || key == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _results.clear();
    });

    // Checked once, up front. Each file still fails individually if the
    // link fills part-way through — the server is authoritative — but
    // this stops ten files costing ten info calls against a bucket of
    // ten.
    DropUploadInfo? batchInfo;
    try {
      final svc = await ref.read(dropUploadServiceProvider.future);
      batchInfo = await svc.info(widget.dropId);
      if (!batchInfo.open) {
        if (mounted) {
          setState(() {
            _busy = false;
            _open = false;
          });
        }
        return;
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not reach the service. Check your connection '
              'and try again.';
        });
      }
      return;
    }

    // Sequential, not parallel. Three reasons, in order of how much they
    // matter: the service buffers a whole ciphertext in memory before
    // PUTting it, so N at once is N files of RAM; the per-IP rate limit
    // is a fixed window and a burst of parallel initiates is the
    // easiest way to hit it; and a serial run gives the uploader a
    // truthful "3 of 4" rather than four spinners.
    for (var i = 0; i < _files.length; i++) {
      if (!mounted) return;
      setState(() {
        _current = i;
        _progressDone = 0;
        _progressTotal = _files[i].length;
      });
      try {
        final svc = await ref.read(dropUploadServiceProvider.future);
        await svc.upload(
          dropId: widget.dropId,
          password: _password.text.trim(),
          source: _files[i].source,
          ownerIdentityPub: key,
          // One info call for the whole submission. Fetched fresh at
          // the start of the run below, so it still reflects a link
          // that was open when the user pressed Send.
          knownInfo: batchInfo,
          onProgress: (phase, done, total) {
            if (!mounted) return;
            setState(() {
              _phase = phase;
              _progressDone = done;
              _progressTotal = total == 0 ? 1 : total;
            });
          },
        );
        if (mounted) setState(() => _results[i] = null);
      } on DropFileTooLargeException catch (e) {
        if (mounted) {
          setState(
            () => _results[i] = 'Too big — the limit is '
                '${(e.maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB',
          );
        }
      } on DropClosedException {
        // The link filled up or was closed part-way through. Stop:
        // every further attempt would fail the same way, and each one
        // costs the owner a slot.
        if (mounted) {
          setState(() {
            _results[i] = 'The link stopped accepting files';
            _open = false;
          });
        }
        break;
      } on ApiException catch (e) {
        // 507 is the recipient being out of storage, which the server
        // now detects at /initiate — before the bytes move. Its own
        // wording is better than anything generic we could substitute,
        // and it is the one failure here the uploader cannot fix by
        // retrying, so it must not read as a transient error.
        //
        // Note the cumulative case handles itself: uploads run in
        // sequence and each commit charges before the next initiate, so
        // three 1 GB files against 2 GB of headroom land two and refuse
        // the third BEFORE uploading it.
        if (mounted) {
          setState(
            () => _results[i] = e.statusCode == 507
                ? 'The recipient is out of storage'
                : 'Did not send',
          );
        }
        if (e.statusCode == 507) break;
      } catch (e) {
        if (mounted) setState(() => _results[i] = 'Did not send');
      }
    }

    if (!mounted) return;
    setState(() {
      _busy = false;
      // "Done" means at least one file is now the recipient's. Anything
      // that failed is listed alongside, because a partial success
      // reported as success is how someone believes they sent a document
      // they did not send.
      _done = _sentCount > 0 && _failedCount == 0;
      if (_sentCount == 0) {
        _error = 'Nothing was sent. Check the password you were given. If '
            'it is correct, the link may have expired or already been '
            'used.';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Send a file')),
      body: MaxWidthContent(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _body(text),
        ),
      ),
    );
  }

  Widget _body(TextTheme text) {
    if (_ownerKey == null) {
      return _Message(
        title: 'This link is incomplete',
        body: 'Part of the link is missing, which can happen when a link is '
            'forwarded or copied by hand. Ask for it again, and open it '
            'directly rather than retyping it.',
      );
    }
    if (_open == false) {
      // No reason, because the server does not give one — and should
      // not: revoked, expired, used up and never-existed are one answer
      // so that a link cannot be used to probe.
      return _Message(
        title: 'This link is no longer accepting files',
        body: 'Ask the person who sent it for a new one.',
      );
    }
    if (_open == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_done) {
      final many = _sentCount > 1;
      return _Message(
        title: many ? '$_sentCount files sent' : 'Sent',
        body: '${many ? 'Your files were' : 'Your file was'} encrypted in '
            'this browser before being uploaded, so '
            '${many ? 'they' : 'it'} can only be opened by the person who '
            'gave you this link. We cannot read '
            '${many ? 'them' : 'it'}.\n\n'
            'You can close this page.',
      );
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your file is encrypted in this browser before it is uploaded. '
            'Only the person who gave you this link can open it.',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _password,
            autofillHints: const <String>[],
            decoration: const InputDecoration(
              labelText: 'Password',
              helperText: 'Sent to you separately from the link.',
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pick,
            icon: const Icon(Icons.attach_file),
            label: Text(
              _files.isEmpty ? 'Choose files' : 'Choose different files',
            ),
          ),
          if (_files.isNotEmpty) ...[
            const SizedBox(height: 12),
            // One row per file, with its outcome once sent. A partial
            // success has to be legible: "3 sent, 1 failed" told as a
            // single status line is how someone believes they sent a
            // document they did not send.
            ...List.generate(_files.length, (i) {
              final outcome = _results[i];
              final attempted = _results.containsKey(i);
              final failed = attempted && outcome != null;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(
                      !attempted
                          // Deliberately not a spinner or a clock: this
                          // row is not waiting on anything, it is just
                          // chosen.
                          ? Icons.insert_drive_file_outlined
                          : (failed ? Icons.error_outline : Icons.check),
                      size: 16,
                      color: failed
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${_files[i].name} · '
                        '${(_files[i].length / (1024 * 1024)).toStringAsFixed(1)} MB'
                        '${failed ? ' · $outcome' : ''}',
                        style: text.bodySmall,
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
            // Each file spends one of the link's allowance, so the cost
            // of pressing Send is stated before it is pressed.
            // Present tense here claimed the upload had started: the
            // list appears the moment files are chosen, and "Sending 3
            // files" next to it reads as a progress report. Nothing is
            // encrypted or sent until Send is pressed, and the copy has
            // to say which state it is describing — misreporting state
            // is worse than saying nothing.
            Text(
              _tooMany
                  ? 'Choose up to $_maxPerSubmission files at a time — you '
                      'chose ${_files.length}. Send them in two goes.'
                  : _files.length == 1
                      ? 'Ready to send. Nothing leaves this browser until '
                          'you press Send.'
                      : '${_files.length} files ready. They will be sent '
                          'one after another when you press Send.',
              style: text.bodySmall?.copyWith(
                color: _tooMany
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          ],
          if (_maxBytes > 0) ...[
            const SizedBox(height: 8),
            Text(
              'Up to ${(_maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB.',
              style: text.bodySmall,
            ),
          ],
          const SizedBox(height: 24),
          if (_busy) ...[
            LinearProgressIndicator(
              value: _progressTotal == 0
                  ? null
                  : (_progressDone / _progressTotal).clamp(0.0, 1.0),
            ),
            const SizedBox(height: 8),
            Text(
              '${switch (_phase) {
                DropUploadPhase.encrypting => 'Encrypting',
                DropUploadPhase.uploading => 'Uploading',
                DropUploadPhase.done => 'Finishing',
              }} ${_files.length > 1 ? '${_current + 1} of ${_files.length} ' : ''}'
              '— ${_files[_current].name}',
              style: text.bodySmall,
            ),
          ] else ...[
            FilledButton(
              onPressed: _canSend ? _send : null,
              child: const Text('Send'),
            ),
            // A dead button with no explanation reads as a broken page.
            // Say which of the two things is still missing.
            if (!_canSend) ...[
              const SizedBox(height: 8),
              Text(
                _files.isEmpty
                    ? 'Choose one or more files to send.'
                    : _tooMany
                        ? 'Too many files chosen.'
                        : 'Enter the password you were sent.',
                style: text.bodySmall,
              ),
            ],
          ],
          // Partial outcome: some landed, some did not. `_done` stays
          // false so the form remains usable for a retry, and this says
          // plainly where things stand — the per-file icons alone leave
          // the reader to count.
          if (!_busy && _failedCount > 0) ...[
            const SizedBox(height: 16),
            Text(
              _sentCount == 0
                  ? 'Nothing was sent.'
                  : '$_sentCount sent, $_failedCount did not. The ones that '
                      'arrived are already with the recipient — choose just '
                      'the failed files and try those again.',
              style: text.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: text.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: text.titleMedium),
        const SizedBox(height: 12),
        Text(body, style: text.bodyMedium),
      ],
    );
  }
}
