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
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
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
                          '${data.uploadsUsed} of ${data.maxUploads} uploads '
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
                        const Divider(height: 32),
                        if (data.items.isEmpty)
                          Text(
                            data.uploadsUsed > 0
                                // A reserved-but-abandoned slot: the
                                // allowance is spent and no file came.
                                // Saying "nothing yet" alone would make
                                // the counter above look wrong.
                                ? 'Nothing has arrived. An upload was '
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
                              // The filename is inside `enc_header` and
                              // only the owner's key opens it. Decrypting
                              // it here needs the receive pipeline, so
                              // until that is wired in the row is honest
                              // about what it can show rather than
                              // inventing a name.
                              title: Text(
                                a.collectable
                                    ? 'File · ${_bytes(a.byteCount)}'
                                    : 'File · ${_bytes(a.byteCount)} · no longer available',
                              ),
                              subtitle: Text(
                                a.collectable
                                    ? '${_expiry(a.expiresAt)} · '
                                        "we can't confirm who sent it"
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
