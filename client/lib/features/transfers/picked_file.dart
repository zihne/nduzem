import '../../crypto/plaintext_source.dart';

/// UI-facing wrapper around a picked file on its way through the
/// send flow (single-file + ADR-0009 batch). Carries the streaming
/// [PlaintextSource] the send pipeline actually reads bytes from —
/// mobile packs a [FilePlaintextSource] (filesystem path); web packs
/// a [BlobPlaintextSource] (browser `Blob`). The rest of the fields
/// are display metadata for the queue / batch screen.
class PickedFile {
  const PickedFile({
    required this.source,
    required this.name,
    required this.length,
    this.mime,
  });

  /// Streaming plaintext view — the send pipeline calls
  /// `source.openRead()` when it's ready to encrypt.
  final PlaintextSource source;

  final String name;
  final String? mime;
  final int length;
}
