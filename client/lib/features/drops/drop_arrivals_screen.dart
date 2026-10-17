import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/drops_api.dart';
import '../../widgets/max_width_content.dart';
import '../auth/auth_providers.dart';

/// What has arrived through one upload link (ADR-0040 phase 4c).
///
/// **Deliberately not presented as a folder.** A drop is a capability,
/// not a container: every item here is an independent transfer with its
/// own expiry that burns when collected. A folder would promise that
/// the contents are still there next month, and they are not — so each
/// row states when it goes, and the header says it in words.
///
/// Arrivals also stay in the inbox. Two places to check is how a
/// document gets missed, and for a firm that is the failure that costs
/// something; this view answers a different question — "did anything
/// come in through the link I set up for this client?"
class DropArrivalsScreen extends ConsumerStatefulWidget {
  const DropArrivalsScreen({super.key, required this.dropId});
  final String dropId;

  @override
  ConsumerState<DropArrivalsScreen> createState() =>
      _DropArrivalsScreenState();
}

class _DropArrivalsScreenState extends ConsumerState<DropArrivalsScreen> {
  DropArrivals? _data;
  String? _error;

  /// transfer_id -> filename, decrypted on this device. Absent means we
  /// could not open the envelope (keys from another device, say), and
  /// the row falls back to showing its size.
  final Map<String, String> _names = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final api = await ref.read(dropsApiProvider.future);
      final data = await api.arrivals(widget.dropId);
      if (mounted) setState(() => _data = data);
      await _resolveNames(data);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// Open each envelope locally to recover the filename.
  ///
  /// This is on-device work with this account's own keys — the server
  /// cannot do it and is not asked to. It happens after the list is
  /// already on screen so a slow keystore never delays the view.
  Future<void> _resolveNames(DropArrivals data) async {
    final session = ref.read(authSessionProvider).valueOrNull;
    if (session == null) return;
    final peek = await ref.read(envelopePeekProvider.future);
    for (final a in data.items) {
      final header = await peek.peek(
        userId: session.userId,
        wrappedKeyB64: a.wrappedKeyB64,
        encHeaderB64: a.encHeaderB64,
        cryptoSuite: a.cryptoSuite,
      );
      if (header != null && mounted) {
        setState(() => _names[a.transferId] = header.filename);
      }
    }
  }

  static String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Plain, and rounded down: "in 6 days" is better than a timestamp
  /// nobody converts, and over-stating the remaining time on a file
  /// someone needs would be the wrong direction to round.
  static String _expiry(DateTime at) {
    final left = at.difference(DateTime.now());
    if (left.isNegative) return 'Gone';
    if (left.inHours < 1) return 'Goes in under an hour';
    if (left.inHours < 24) return 'Goes in ${left.inHours} hours';
    return 'Goes in ${left.inDays} days';
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(data?.label ?? 'Upload link')),
      body: MaxWidthContent(
        child: RefreshIndicator(
          onRefresh: _load,
          child: _error != null
              ? ListView(
                  children: [
                    const SizedBox(height: 80),
                    Center(child: Text(_error!)),
                  ],
                )
              : data == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text(
                          '${data.uploadsUsed} of ${data.maxUploads} files '
                          'used.',
                          style: text.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        // The sentence that stops this reading as
                        // storage.
                        Text(
                          'Files sent here are not stored. Each one is '
                          'deleted once you open it, or after 7 days, '
                          'whichever comes first.',
                          style: text.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        // Said once, here, rather than as a warning on
                        // every row. "We can't confirm who sent it" is
                        // true and reads as a failure; this is equally
                        // true and actually informative — the sender is
                        // someone the owner chose to give the link to,
                        // not a stranger.
                        Text(
                          'Only people you gave this link and its password '
                          'to can send files here. We cannot tell you which '
                          'of them sent which file.',
                          style: text.bodySmall,
                        ),
                        const Divider(height: 32),
                        if (data.items.isEmpty)
                          Text(
                            data.uploadsUsed > 0
                                // A reserved-but-abandoned slot: the
                                // allowance is spent and no file came.
                                // Saying "nothing yet" alone would make
                                // the counter above look wrong.
                                ? 'Nothing has arrived. A file was '
                                    'started but never finished, which '
                                    'still uses one of the allowance.'
                                : 'Nothing has arrived yet.',
                            style: text.bodyMedium,
                          )
                        else
                          ...data.items.map(
                            (a) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                a.collectable
                                    ? Icons.insert_drive_file_outlined
                                    : Icons.history,
                              ),
                              // The filename, decrypted on this device.
                              // Falls back to "File" only when the
                              // envelope cannot be opened here — keys
                              // from another device, typically — rather
                              // than inventing a name.
                              title: Text(
                                [
                                  _names[a.transferId] ?? 'File',
                                  _bytes(a.byteCount),
                                  if (!a.collectable) 'no longer available',
                                ].join(' · '),
                              ),
                              subtitle: Text(
                                a.collectable
                                    ? _expiry(a.expiresAt)
                                    : 'Arrived ${a.createdAt.toLocal()}',
                              ),
                              trailing: a.collectable
                                  ? const Icon(Icons.chevron_right)
                                  : null,
                              onTap: a.collectable
                                  ? () => context
                                      .push('/receive/${a.transferId}')
                                  : null,
                            ),
                          ),
                      ],
                    ),
        ),
      ),
    );
  }
}
