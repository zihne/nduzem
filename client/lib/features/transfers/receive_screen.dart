import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../api/api_client.dart';
import '../auth/auth_providers.dart';
import 'transfer_service.dart';

/// Fetches, decrypts, and saves a single transfer. Split into three
/// stages so the user can pause between them:
///
///   1. **Ready**  — the tile explains what is about to happen.
///   2. **Downloading** — spinner + server round-trip + AEAD decrypt.
///   3. **Saved** — shows the destination path and the plaintext
///      filename, plus a big red "Delete the sender's copy" button
///      that fires `/ack` (server enqueues the R2 burn).
///
/// Ack is a separate step because it's destructive — the user might
/// want to keep the transfer around briefly if their disk is full or
/// they need to move the file elsewhere first.
class ReceiveScreen extends ConsumerStatefulWidget {
  const ReceiveScreen({super.key, required this.transferId});
  final String transferId;

  @override
  ConsumerState<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends ConsumerState<ReceiveScreen> {
  ReceiveResult? _result;
  bool _acked = false;
  bool _busy = false;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final svc = await ref.read(transferServiceProvider.future);
      final dir = await getApplicationDocumentsDirectory();
      final res = await svc.receive(transferId: widget.transferId, destDir: dir);
      setState(() => _result = res);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } on Object catch (exc) {
      setState(() => _error = 'Download failed: $exc');
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
      setState(() => _acked = true);
    } on ApiException catch (exc) {
      setState(() => _error = exc.message);
    } finally {
      if (mounted) setState(() => _busy = false);
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
            if (_result == null) ...[
              const Text(
                'This will download the encrypted bytes, verify the '
                'ciphertext hash, decrypt locally with your device key, '
                'and save the file into the app documents folder.',
              ),
              const SizedBox(height: 16),
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
              _SavedCard(result: _result!),
              const SizedBox(height: 16),
              if (!_acked) ...[
                const Text(
                  'Once you have saved / moved / read the file, ack the '
                  "transfer to burn the sender's server-side copy. The R2 "
                  'object is unrecoverable after this.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _ack,
                  icon: const Icon(Icons.local_fire_department),
                  label: const Text("Delete the sender's copy (ack)"),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor:
                        Theme.of(context).colorScheme.onError,
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

            const SizedBox(height: 32),
            TextButton(
              onPressed: () => context.go('/inbox'),
              child: const Text('Back to inbox'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedCard extends StatelessWidget {
  const _SavedCard({required this.result});
  final ReceiveResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Saved', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(result.filename),
            const SizedBox(height: 4),
            Text(
              '${result.byteCount} bytes'
              '${result.mime == null ? '' : ' · ${result.mime}'}',
              style: const TextStyle(fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 8),
            SelectableText(
              result.savedPath,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
