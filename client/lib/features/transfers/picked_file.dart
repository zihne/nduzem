/// One picked, statted file on its way through the send flow. Shared
/// by the single-file [SendScreen] surface and the multi-file batch
/// controller (ADR-0009). The `path` points at the plaintext file
/// on disk — the streaming send pipeline reads chunks straight from
/// there, so we never hold the whole file in memory.
class PickedFile {
  const PickedFile({
    required this.name,
    required this.mime,
    required this.path,
    required this.length,
  });
  final String name;
  final String? mime;
  final String path;
  final int length;
}
