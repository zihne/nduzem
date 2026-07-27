import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Save `bytes` to disk via the browser (ADR-0013 Phase 6).
///
/// Two paths, tried in order:
///
/// 1. **File System Access API** (`showSaveFilePicker`) — user picks
///    the destination, we write via a `WritableStream`. Available on
///    Chromium (Chrome / Edge / Opera). True streaming under the
///    hood; peak browser memory ≈ writer's internal buffer.
/// 2. **`<a download>` fallback** — construct a `blob:` object URL
///    and click a synthetic anchor. Works everywhere (Firefox,
///    Safari, older Chromium). No location picker; the browser drops
///    the file into the default downloads folder.
///
/// Returns a short human-readable label of where the file went
/// (the FSA-picked name or the fallback filename), or `null` when
/// the user cancelled the FSA picker. Any other failure throws.
Future<String?> saveBytesWeb({
  required Uint8List bytes,
  required String filename,
  String? mimeType,
}) async {
  final blob = _blobFromBytes(bytes, mimeType);
  final win = web.window;
  final hasFsa = win.has('showSaveFilePicker');
  if (hasFsa) {
    try {
      return await _saveViaFsa(win, blob, filename);
    } on _FsaUserAbort {
      return null;
    } on Object {
      // Any FSA-side failure (permission denied, write mid-stream
      // failure, …) falls through to the anchor fallback so the user
      // still gets their file.
    }
  }
  _saveViaAnchor(blob, filename);
  return filename;
}

web.Blob _blobFromBytes(Uint8List bytes, String? mimeType) {
  final part = bytes.toJS as JSAny;
  final parts = [part].toJS;
  final options = web.BlobPropertyBag(
    type: mimeType ?? 'application/octet-stream',
  );
  return web.Blob(parts, options);
}

Future<String> _saveViaFsa(
  web.Window win,
  web.Blob blob,
  String filename,
) async {
  final options = _SaveFilePickerOptions(suggestedName: filename);
  final handleJs = await _showSaveFilePicker(win, options).toDart;
  if (handleJs.isUndefinedOrNull) {
    throw const _FsaUserAbort();
  }
  final handle = handleJs as _FileSystemFileHandle;
  final writable = await handle.createWritable().toDart;
  try {
    await writable.write(blob).toDart;
  } finally {
    await writable.close().toDart;
  }
  return handle.name;
}

void _saveViaAnchor(web.Blob blob, String filename) {
  final url = web.URL.createObjectURL(blob);
  try {
    final anchor = web.HTMLAnchorElement()
      ..href = url
      ..download = filename
      ..style.display = 'none';
    web.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
  } finally {
    web.URL.revokeObjectURL(url);
  }
}

/// User cancelled the FSA picker. Internal signal so the fallback
/// stays out of the picture — the user explicitly said "no", we do
/// NOT then drop the file into Downloads without asking.
class _FsaUserAbort implements Exception {
  const _FsaUserAbort();
}

extension on web.Window {
  bool has(String name) =>
      (this as JSObject).hasProperty(name.toJS).toDart;
}

/// Minimal FSA bindings — `package:web` doesn't ship them yet.
@JS('showSaveFilePicker')
external JSPromise<JSAny?> _showSaveFilePicker(
  web.Window window,
  _SaveFilePickerOptions options,
);

extension type _SaveFilePickerOptions._(JSObject _) implements JSObject {
  external factory _SaveFilePickerOptions({String suggestedName});
}

extension type _FileSystemFileHandle._(JSObject _) implements JSObject {
  external String get name;
  external JSPromise<_FileSystemWritableFileStream> createWritable();
}

extension type _FileSystemWritableFileStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(web.Blob data);
  external JSPromise<JSAny?> close();
}
