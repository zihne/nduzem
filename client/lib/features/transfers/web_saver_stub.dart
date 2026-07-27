import 'dart:typed_data';

/// Non-web stub. `_saveAs` on the receive screens gates the actual
/// call with `kIsWeb`, so this only exists to keep the conditional
/// import resolvable at compile time on non-web builds.
Future<String?> saveBytesWeb({
  required Uint8List bytes,
  required String filename,
  String? mimeType,
}) =>
    throw UnsupportedError('web-only');
