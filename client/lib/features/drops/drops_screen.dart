import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/drops_api.dart';
import '../../storage/secure_storage.dart';
import '../../widgets/max_width_content.dart';
import '../auth/auth_providers.dart';
import 'drop_link.dart';

/// Upload links — the owner's side of a file drop (ADR-0040, phase 4a).
///
/// "Upload link", never "drop", in anything a user reads. `drop` is a
/// fine internal name and means nothing to a solicitor who has not read
/// the ADR.
///
/// Nothing on this screen persists the generated password, and there is
/// no way back to it: the server keeps only an argon2id hash, and
/// holding a copy here would undo the point of that.
class DropsScreen extends ConsumerStatefulWidget {
  const DropsScreen({super.key});

  @override
  ConsumerState<DropsScreen> createState() => _DropsScreenState();
}

class _DropsScreenState extends ConsumerState<DropsScreen> {
  List<DropSummary>? _drops;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final api = await ref.read(dropsApiProvider.future);
      final rows = await api.list();
      if (mounted) setState(() => _drops = rows);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// The owner's own X25519 public key, read from THIS device.
  ///
  /// Not from the API, deliberately — see `drop_link.dart`. If it is
  /// missing (a browser that has never held this account's keys, or a
  /// device awaiting a key restore) we refuse to produce a link rather
  /// than produce one nobody can upload through.
  Future<String?> _ownIdentityPub() async {
    final session = ref.read(authSessionProvider).valueOrNull;
    if (session == null) return null;
    final storage = ref.read(secureStorageProvider);
    return storage.read(SecureStore.identityPublicKeyFor(session.userId));
  }

  Future<void> _create() async {
    final spec = await showDialog<_NewLinkSpec>(
      context: context,
      builder: (_) => const _NewLinkDialog(),
    );
    if (spec == null) return;

    setState(() => _busy = true);
    try {
      final identityPub = await _ownIdentityPub();
      if (identityPub == null || identityPub.isEmpty) {
        throw StateError(
          'This device does not hold your keys, so it cannot build an '
          'upload link. Restore your key first, then try again.',
        );
      }
      final api = await ref.read(dropsApiProvider.future);
      final created = await api.create(
        label: spec.label,
        maxUploads: spec.maxFiles,
        expiresInDays: spec.expiresInDays,
      );
      final config = ref.read(appConfigProvider);
      final url = buildDropUploadUrl(
        shareUrlBase: config.shareUrlBase,
        dropId: created.dropId,
        identityPubB64: identityPub,
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _LinkAndPasswordDialog(created: created, url: url),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(DropSummary drop) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close this upload link?'),
        content: Text(
          'Nobody will be able to send you files through "${drop.label}" '
          'after this. Files already sent are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep it open'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close it'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final api = await ref.read(dropsApiProvider.future);
      await api.revoke(drop.dropId);
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final drops = _drops;
    return Scaffold(
      appBar: AppBar(title: const Text('Upload links')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _create,
        icon: const Icon(Icons.add),
        label: const Text('New upload link'),
      ),
      body: MaxWidthContent(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _error != null
              ? _Centered(
                  child: Text(_error!, textAlign: TextAlign.center),
                )
              : drops == null
                  ? const _Centered(child: CircularProgressIndicator())
                  : drops.isEmpty
                      ? const _Centered(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'An upload link lets someone send you a file '
                              'without creating an account. Useful when you '
                              'need a document from a client and would '
                              'rather they did not email it.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 88),
                          itemCount: drops.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) => _DropTile(
                            drop: drops[i],
                            onRevoke: () => _revoke(drops[i]),
                          ),
                        ),
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => ListView(
        children: [SizedBox(height: 120), Center(child: child)],
      );
}

class _DropTile extends StatelessWidget {
  const _DropTile({required this.drop, required this.onRevoke});
  final DropSummary drop;
  final VoidCallback onRevoke;

  // Plain words for each state. "Revoked", "expired" and "full" are
  // accurate and are not what someone reads once and understands.
  String get _stateLabel => switch (drop.state) {
        DropState.open => 'Open',
        DropState.revoked => 'Closed by you',
        DropState.expired => 'Expired',
        DropState.full => 'No uploads left',
        DropState.unknown => 'Unknown',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      title: Text(drop.label),
      subtitle: Text(
        // "files", not "uploads": one submission of four documents
        // spends four of the allowance, because each file is its own
        // transfer. Calling them uploads invites the reading
        // "four people sent me something".
        '$_stateLabel · ${drop.uploadsUsed} of ${drop.maxUploads} files',
      ),
      onTap: () => context.push('/drops/${drop.dropId}'),
      // `Icons.block` read as "blocked" rather than "stop accepting".
      // Still an icon here because the row is a summary — the labelled
      // action lives on the link's own page, which is where the
      // dialog's "you can close it sooner" sends people.
      trailing: drop.isOpen
          ? IconButton(
              tooltip: 'Close this link',
              icon: const Icon(Icons.link_off),
              onPressed: onRevoke,
            )
          : Icon(Icons.lock_outline, color: scheme.outline),
    );
  }
}

/// What the create dialog collects.
///
/// `max_uploads` and `expires_in_days` were accepted by the API from the
/// start but never asked for, so every link silently took the defaults —
/// ten files, thirty days. For "send me one signed contract" versus
/// "send me everything in the file", that is the difference between a
/// useful link and a careless one.
class _NewLinkSpec {
  const _NewLinkSpec({
    required this.label,
    required this.maxFiles,
    required this.expiresInDays,
  });
  final String label;
  final int maxFiles;
  final int expiresInDays;
}

class _NewLinkDialog extends StatefulWidget {
  const _NewLinkDialog();
  @override
  State<_NewLinkDialog> createState() => _NewLinkDialogState();
}

class _NewLinkDialogState extends State<_NewLinkDialog> {
  final _controller = TextEditingController();

  // Fixed choices rather than free number entry. The API bounds these
  // (1..100 files, 1..365 days) and a text field invites a 422 for a
  // value the owner had no way to know was out of range. It also makes
  // the useful cases one tap: one document, or a whole file.
  static const _fileChoices = <int>[1, 3, 5, 10, 25, 50];
  static const _dayChoices = <int>[7, 14, 30, 90];

  int _maxFiles = 10;
  int _days = 30;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final label = _controller.text.trim();
    if (label.isEmpty) return;
    Navigator.of(context).pop(
      _NewLinkSpec(
        label: label,
        maxFiles: _maxFiles,
        expiresInDays: _days,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('New upload link'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                autofocus: true,
                maxLength: 120,
                decoration: const InputDecoration(
                  labelText: 'What is it for?',
                  helperText: 'Only you can see this.',
                ),
                onSubmitted: (_) => _submit(),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: _maxFiles,
                decoration: const InputDecoration(
                  labelText: 'How many files can be sent?',
                  // "Files", not "uploads": four documents in one go
                  // spend four of the allowance, because each file is
                  // its own transfer.
                  helperText: 'Counts files, not senders.',
                ),
                items: [
                  for (final n in _fileChoices)
                    DropdownMenuItem(
                      value: n,
                      child: Text(n == 1 ? '1 file' : '$n files'),
                    ),
                ],
                onChanged: (v) => setState(() => _maxFiles = v ?? _maxFiles),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: _days,
                decoration: const InputDecoration(
                  labelText: 'How long should the link work?',
                  helperText: 'You can close it sooner at any time.',
                ),
                items: [
                  for (final d in _dayChoices)
                    DropdownMenuItem(value: d, child: Text('$d days')),
                ],
                onChanged: (v) => setState(() => _days = v ?? _days),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: _submit, child: const Text('Create')),
        ],
      );
}

/// Shown once, immediately after creation.
///
/// Not dismissible by tapping outside: the password is on screen and
/// cannot be retrieved afterwards, so losing it to a stray tap means
/// starting again.
class _LinkAndPasswordDialog extends StatelessWidget {
  const _LinkAndPasswordDialog({required this.created, required this.url});
  final DropCreated created;
  final String url;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Send these in two separate messages'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Send the link however you normally would. Email is fine.\n\n'
              'Then send the password in a separate message. A second '
              'email is fine. A text message or a phone call is safer '
              'still.\n\n'
              'The one thing to avoid is putting both in the same '
              'message. If they travel together the password protects '
              'nothing, and anyone the message is forwarded to can send '
              'you files.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 20),
            _CopyField(label: 'Upload link', value: url),
            const SizedBox(height: 12),
            _CopyField(
              label: 'Password for this upload link (send this separately)',
              value: created.password,
              monospace: true,
            ),
            const SizedBox(height: 16),
            // State the limits here, because this is the moment the
            // owner is composing the message to their client. They need
            // to be able to say "send me up to three files by the 16th"
            // without going back to look it up.
            Text(
              'Accepts ${created.maxUploads == 1 ? '1 file' : '${created.maxUploads} files'}, '
              'up to ${(created.maxBytes / (1024 * 1024 * 1024)).toStringAsFixed(0)} GB each. '
              'Stops working on ${_date(created.expiresAt)}.',
              style: text.bodySmall,
            ),
          ],
        ),
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

/// `17 November 2026` — a date someone can repeat in an email, rather
/// than an ISO timestamp they have to decode.
String _date(DateTime at) {
  const months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
  final d = at.toLocal();
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

class _CopyField extends StatelessWidget {
  const _CopyField({
    required this.label,
    required this.value,
    this.monospace = false,
  });
  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: SelectableText(
                value,
                style: monospace
                    ? const TextStyle(fontFamily: 'monospace', fontSize: 16)
                    : null,
              ),
            ),
            IconButton(
              tooltip: 'Copy',
              icon: const Icon(Icons.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: value));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Copied. Send the password in a separate message, '
                      'not the same one as the link.',
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }
}
