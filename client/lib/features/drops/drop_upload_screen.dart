import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    required this.fragment,
  });

  final String dropId;

  /// Raw URL fragment, e.g. `k=<base64url owner identity pub>`. Never
  /// transmitted to the server by the browser.
  final String fragment;

  @override
  ConsumerState<DropUploadScreen> createState() => _DropUploadScreenState();
}

class _DropUploadScreenState extends ConsumerState<DropUploadScreen> {
  final _password = TextEditingController();
  PickedFile? _file;
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
    _loadInfo();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  /// The owner's X25519 public key, lifted out of `#k=`.
  ///
  /// Parsing lives in `drop_link.dart` beside the builder that produced
  /// the link, so the two cannot drift, and so it can be tested without
  /// a widget.
  Uint8List? get _ownerKey => parseDropFragmentKey(widget.fragment);

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
      _file = picked.first;
      _error = null;
    });
  }

  Future<void> _send() async {
    final file = _file;
    final key = _ownerKey;
    if (file == null || key == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _progressDone = 0;
      _progressTotal = file.length;
    });
    try {
      final svc = await ref.read(dropUploadServiceProvider.future);
      await svc.upload(
        dropId: widget.dropId,
        password: _password.text.trim(),
        source: file.source,
        ownerIdentityPub: key,
        onProgress: (phase, done, total) {
          if (!mounted) return;
          setState(() {
            _phase = phase;
            _progressDone = done;
            _progressTotal = total == 0 ? 1 : total;
          });
        },
      );
      if (mounted) setState(() => _done = true);
    } on DropFileTooLargeException catch (e) {
      if (mounted) {
        setState(
          () => _error = 'That file is too big. The limit for this link is '
              '${(e.maxBytes / (1024 * 1024)).toStringAsFixed(0)} MB.',
        );
      }
    } on DropClosedException {
      if (mounted) {
        setState(() {
          _open = false;
          _error = null;
        });
      }
    } catch (e) {
      // The server answers a uniform 404 for a wrong password, a closed
      // link and an unknown one. We cannot tell them apart and must not
      // guess — so the message covers the cause the uploader can
      // actually act on, and mentions the others as possibilities.
      if (mounted) {
        setState(
          () => _error =
              'That did not work. Check the password you were given. If it '
              'is correct, the link may have expired or already been used.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
      return _Message(
        title: 'Sent',
        body: 'Your file was encrypted in this browser before it was '
            'uploaded, so it can only be opened by the person who gave you '
            'this link. We cannot read it.\n\n'
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
            label: Text(_file == null ? 'Choose a file' : 'Choose a different file'),
          ),
          if (_file != null) ...[
            const SizedBox(height: 8),
            Text(
              '${_file!.name} · ${(_file!.length / (1024 * 1024)).toStringAsFixed(1)} MB',
              style: text.bodySmall,
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
              switch (_phase) {
                DropUploadPhase.encrypting => 'Encrypting…',
                DropUploadPhase.uploading => 'Uploading…',
                DropUploadPhase.done => 'Finishing…',
              },
              style: text.bodySmall,
            ),
          ] else
            FilledButton(
              onPressed: (_file == null || _password.text.trim().isEmpty)
                  ? null
                  : _send,
              child: const Text('Send'),
            ),
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
