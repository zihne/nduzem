import 'picked_file.dart';

/// Non-web stub. [SendScreen] guards with `kIsWeb` before calling, so
/// this only exists so the conditional-imported symbol resolves at
/// compile time on non-web builds.
Future<List<PickedFile>> pickFilesWeb() =>
    throw UnsupportedError('web-only');
