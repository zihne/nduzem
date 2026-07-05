import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// Native Storage Access Framework stream-save (ADR-0008).
///
/// Two round-trips:
///   1. [pickSaveUri] — launches the platform's document-create UI
///      and returns the resulting `content://` URI (or null on
///      user-cancel).
///   2. [writeFileToUri] — copies the source file into the URI,
///      streaming end-to-end so peak memory stays around one 64 KiB
///      buffer regardless of file size.
///
/// The receive screen calls this only for large plaintexts (above the
/// `file_picker.saveFile(bytes:)` OOM threshold on Android). Small
/// files continue to use `file_picker` because it's the simplest path
/// and the OOM doesn't fire there.
///
/// Non-Android platforms currently get [_UnsupportedSafSaver] — every
/// call returns null / throws [SafSaveUnsupportedException], and the
/// receive screen routes to the ADR-0006 external-storage fallback.
abstract class SafSaver {
  const SafSaver();

  /// Default implementation: real MethodChannel on Android, a
  /// stub-that-declines on every other platform. Instantiated once by
  /// the provider layer.
  factory SafSaver.platformDefault() {
    if (Platform.isAndroid) return const _MethodChannelSafSaver();
    return const _UnsupportedSafSaver();
  }

  /// Testing seam. Returns the MethodChannel-backed impl regardless
  /// of platform so tests running on the host VM can exercise its
  /// round-trip behavior against a mock BinaryMessenger.
  factory SafSaver.methodChannelForTest() => const _MethodChannelSafSaver();

  /// Launch the system "save file" UI. `suggestedFilename` seeds the
  /// filename field. Returns the chosen `content://` URI as a string,
  /// or null if the user cancelled.
  Future<String?> pickSaveUri({required String suggestedFilename});

  /// Stream-copy [sourcePath] into [uri]. Both must be non-empty;
  /// throws [SafSaveWriteException] on I/O failure or if the source
  /// file is gone. The URI is expected to have come from
  /// [pickSaveUri] on this platform.
  Future<void> writeFileToUri({
    required String sourcePath,
    required String uri,
  });
}

/// Thrown when the platform doesn't support native SAF save and the
/// caller invoked [SafSaver.pickSaveUri] anyway. The receive screen
/// checks `SafSaver` before calling — this exists as a safety net.
class SafSaveUnsupportedException implements Exception {
  const SafSaveUnsupportedException();
  @override
  String toString() =>
      'SafSaveUnsupportedException(native SAF save is Android-only in v1)';
}

/// Thrown when the native write fails. The `code` mirrors the Kotlin
/// side (`WRITE_FAILED`, `SOURCE_MISSING`, `BAD_URI`, `BAD_ARGS`) and
/// `message` carries a human-readable reason for the receive screen
/// to render.
class SafSaveWriteException implements Exception {
  const SafSaveWriteException({required this.code, required this.message});
  final String code;
  final String message;
  @override
  String toString() => 'SafSaveWriteException($code: $message)';
}

class _MethodChannelSafSaver extends SafSaver {
  const _MethodChannelSafSaver();

  static const _channel =
      MethodChannel('com.opaqueshare.opaqueshare/saf_stream_save');

  @override
  Future<String?> pickSaveUri({required String suggestedFilename}) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'pickSaveUri',
        <String, dynamic>{'suggestedFilename': suggestedFilename},
      );
      return result;
    } on PlatformException catch (exc) {
      // Fold "the user closed the picker" and "the launcher failed"
      // both to null — the receive screen already knows to route to
      // the fallback in that case, and there's no meaningful "why"
      // to expose here.
      throw SafSaveWriteException(
        code: exc.code,
        message: exc.message ?? 'pickSaveUri failed',
      );
    }
  }

  @override
  Future<void> writeFileToUri({
    required String sourcePath,
    required String uri,
  }) async {
    try {
      await _channel.invokeMethod<void>(
        'writeFileToUri',
        <String, dynamic>{'sourcePath': sourcePath, 'uri': uri},
      );
    } on PlatformException catch (exc) {
      throw SafSaveWriteException(
        code: exc.code,
        message: exc.message ?? 'writeFileToUri failed',
      );
    }
  }
}

class _UnsupportedSafSaver extends SafSaver {
  const _UnsupportedSafSaver();

  @override
  Future<String?> pickSaveUri({required String suggestedFilename}) async =>
      null;

  @override
  Future<void> writeFileToUri({
    required String sourcePath,
    required String uri,
  }) async {
    throw const SafSaveUnsupportedException();
  }
}
