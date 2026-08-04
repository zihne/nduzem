import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium_libs/sodium_libs.dart';

import 'package:opaqueshare/crypto/file_crypto.dart';
import 'sodium_test_support.dart';

/// Adversarial integrity tests for the OS4S container.
///
/// The existing suite covers a flipped byte and a wrong key. It does
/// not cover the manipulations the format's design specifically claims
/// to stop — truncation ("Receiver hard-fails if the last chunk isn't
/// finalized"), and the chunk reordering/replay that a *chained* AEAD
/// is supposed to prevent but a per-chunk one would not.
///
/// These run against `decryptToStream`, not `decryptFile`, because that
/// is what the receive path actually calls. The streaming path has its
/// own hand-written `_rechunkStream` that re-frames arbitrary inbound
/// I/O chunks back onto sodium's chunk boundaries; a framing bug there
/// would not show up through `decryptFile`, which slices a whole
/// in-memory buffer instead.
///
/// Every case asserts only that decryption FAILS. Which exception
/// surfaces is libsodium's business and not a contract worth pinning.
// `main` is async on purpose: `skip:` is evaluated when the tests are
// *declared*, so libsodium has to be resolved before the first `test()`
// call rather than in `setUpAll`, which runs later. package:test awaits
// main before running anything.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final maybeSodium = await tryInitSodium();
  final skipReason = sodiumSkipReason(maybeSodium);

  // Non-nullable and `late`: bodies only run when `skip: skipReason` is
  // null. A stray run fails loudly instead of silently passing.
  late final Sodium sodium;
  late final FileCrypto fc;
  if (maybeSodium != null) {
    sodium = maybeSodium;
    fc = FileCrypto(sodium);
  }

  /// Plaintext spanning several chunks plus a partial tail, so that
  /// "drop the last chunk" and "swap two middle chunks" are both
  /// meaningful operations.
  Uint8List samplePlaintext() => Uint8List.fromList(
        List<int>.generate(
          FileCrypto.plaintextChunkBytes * 3 + 5000,
          (i) => (i * 31 + 11) & 0xff,
        ),
      );

  /// Byte offset where the first ciphertext chunk begins: the OS4S
  /// magic followed by the secretstream header.
  int bodyStart(FileCrypto crypto, Sodium sodium) =>
      FileCrypto.magicPrefix.length + sodium.crypto.secretStream.headerBytes;

  Future<void> expectDecryptFails(
    FileCrypto crypto,
    Uint8List ciphertext,
    Uint8List key, {
    required String because,
  }) async {
    // Feed the bytes in awkwardly-sized pieces rather than one buffer,
    // so the rechunker's buffering path is the one under test — that is
    // how the real receive path sees data off a socket or a file.
    Stream<List<int>> dribble() async* {
      const step = 7777;
      for (var i = 0; i < ciphertext.length; i += step) {
        final end = (i + step).clamp(0, ciphertext.length);
        yield Uint8List.sublistView(ciphertext, i, end);
      }
    }

    final handle = crypto.decryptToStream(
      ciphertextStream: dribble(),
      key: key,
      ciphertextTotalBytes: ciphertext.length,
    );
    // Attach the `done` handler BEFORE draining. `decryptToStream`
    // reports failure on both the stream and `done`; if the stream
    // throws first we never reach an `await handle.done`, and its error
    // surfaces as an unhandled async error that fails the test for the
    // wrong reason. Folding the error into a value keeps both channels
    // observable.
    final doneOutcome =
        handle.done.then<Object?>((_) => null, onError: (Object e) => e);

    Object? caught;
    try {
      await for (final _ in handle.stream) {
        // Drain. A tampered stream may emit valid leading chunks before
        // failing; only how it finishes matters.
      }
    } on Object catch (exc) {
      caught = exc;
    }
    caught ??= await doneOutcome;
    expect(caught, isNotNull, reason: because);
  }

  test(
    'truncating the final chunk is refused',
    () async {
      final key = fc.generateFileKey();
      final ct = await fc.encryptFile(plaintext: samplePlaintext(), key: key);

      // Drop the whole trailing (short, FINAL-tagged) chunk. What remains
      // is a sequence of individually valid, correctly ordered chunks —
      // only the end-of-stream marker is gone. Nothing but the final tag
      // distinguishes this from a complete file.
      final chunkLen = fc.ciphertextChunkBytes;
      final start = bodyStart(fc, sodium);
      final fullChunks = (ct.length - start) ~/ chunkLen;
      final truncated =
          Uint8List.sublistView(ct, 0, start + fullChunks * chunkLen);
      expect(truncated.length, lessThan(ct.length));

      await expectDecryptFails(
        fc,
        truncated,
        key,
        because: 'a truncated stream must not decrypt as a complete file — '
            'without this, an attacker who can cut the transfer short '
            'silently delivers a partial file that looks authentic',
      );
    },
    skip: skipReason,
  );

  test(
    'truncating mid-chunk is refused',
    () async {
      final key = fc.generateFileKey();
      final ct = await fc.encryptFile(plaintext: samplePlaintext(), key: key);
      final cut = Uint8List.sublistView(ct, 0, ct.length - 100);

      await expectDecryptFails(
        fc,
        cut,
        key,
        because: 'a partial trailing chunk fails its Poly1305 tag',
      );
    },
    skip: skipReason,
  );

  test(
    'a header with no chunks at all is refused',
    () async {
      final key = fc.generateFileKey();
      final ct = await fc.encryptFile(plaintext: samplePlaintext(), key: key);
      final headerOnly = Uint8List.sublistView(ct, 0, bodyStart(fc, sodium));

      await expectDecryptFails(
        fc,
        headerOnly,
        key,
        because: 'an empty stream is not a valid finalized stream',
      );
    },
    skip: skipReason,
  );

  test(
    'reordering two chunks is refused',
    () async {
      final key = fc.generateFileKey();
      final ct = await fc.encryptFile(plaintext: samplePlaintext(), key: key);

      // secretstream chains chunks, so chunk N's tag depends on every
      // chunk before it. A per-chunk AEAD would happily accept this.
      final chunkLen = fc.ciphertextChunkBytes;
      final start = bodyStart(fc, sodium);
      final swapped = Uint8List.fromList(ct);
      for (var i = 0; i < chunkLen; i++) {
        final a = start + i;
        final b = start + chunkLen + i;
        final tmp = swapped[a];
        swapped[a] = swapped[b];
        swapped[b] = tmp;
      }

      await expectDecryptFails(
        fc,
        swapped,
        key,
        because: 'chunk order is authenticated by the chained AEAD',
      );
    },
    skip: skipReason,
  );

  test(
    'replaying a chunk in place of the next one is refused',
    () async {
      final key = fc.generateFileKey();
      final ct = await fc.encryptFile(plaintext: samplePlaintext(), key: key);

      final chunkLen = fc.ciphertextChunkBytes;
      final start = bodyStart(fc, sodium);
      final replayed = Uint8List.fromList(ct);
      // Overwrite chunk 1 with a copy of chunk 0.
      replayed.setRange(
        start + chunkLen,
        start + 2 * chunkLen,
        Uint8List.sublistView(ct, start, start + chunkLen),
      );

      await expectDecryptFails(
        fc,
        replayed,
        key,
        because: 'a duplicated chunk breaks the chain state',
      );
    },
    skip: skipReason,
  );

  test(
    'a header from a different stream is refused',
    () async {
      final key = fc.generateFileKey();
      final plain = samplePlaintext();
      final ct = await fc.encryptFile(plaintext: plain, key: key);
      final other = await fc.encryptFile(plaintext: plain, key: key);

      // Same key, same plaintext, different random header. Splicing one
      // stream's header onto another's body must not decrypt.
      final headerLen = sodium.crypto.secretStream.headerBytes;
      final spliced = Uint8List.fromList(ct);
      spliced.setRange(
        FileCrypto.magicPrefix.length,
        FileCrypto.magicPrefix.length + headerLen,
        Uint8List.sublistView(
          other,
          FileCrypto.magicPrefix.length,
          FileCrypto.magicPrefix.length + headerLen,
        ),
      );

      await expectDecryptFails(
        fc,
        spliced,
        key,
        because: 'the header seeds the stream state and is bound to its body',
      );
    },
    skip: skipReason,
  );
}
