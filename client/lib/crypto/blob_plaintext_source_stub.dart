import 'plaintext_source.dart';

/// Non-web stub for [BlobPlaintextSource]. The type exists so callers
/// can reference it in shared code; constructing it on any non-web
/// platform is a bug (mobile has [FilePlaintextSource]).
class BlobPlaintextSource implements PlaintextSource {
  BlobPlaintextSource({
    Object? blob,
    String? filename,
    String? mimeType,
    int? chunkSize,
  }) {
    throw UnsupportedError(
      'BlobPlaintextSource is web-only; use FilePlaintextSource on mobile.',
    );
  }

  @override
  int get lengthBytes => throw UnimplementedError();

  @override
  String get filename => throw UnimplementedError();

  @override
  String? get mimeType => throw UnimplementedError();

  @override
  Stream<List<int>> openRead() => throw UnimplementedError();
}
