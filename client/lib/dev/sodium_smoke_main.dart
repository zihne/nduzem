/// sodium_libs peak-memory smoke test on Flutter web.
///
/// **Purpose** (per docs/roadmap/2026-scale-to-business.md Workstream 3):
/// answer the go/no-go question for shipping OpaqueShare's web app on
/// Flutter web with libsodium.js — specifically, whether we can push a
/// multi-GB plaintext through `crypto_secretstream_xchacha20poly1305`
/// via `sodium_libs`' `pushChunked` and keep peak JS heap **bounded by
/// chunk size, not total size**.
///
/// If peak heap stays under ~200 MB while total plaintext is 2 GB,
/// streaming works and the web app can support large file sends. If
/// peak heap balloons to match total plaintext, sodium_libs on web
/// materializes the whole input internally — we'd need to cap web
/// uploads at ~500 MB in v1 and defer larger to mobile.
///
/// **Run** (standalone from the client dir):
///
///     flutter run -d chrome --target=lib/dev/sodium_smoke_main.dart
///
/// Then click through the size buttons in order. Watch the "Peak JS
/// heap" column — for 100 MB / 500 MB / 1 GB / 2 GB it should stay in
/// the same ballpark, growing roughly linearly with **chunk size**
/// (not total). The synthetic input stream never allocates the whole
/// plaintext — it yields the same 64 KB chunk repeatedly — so any
/// heap growth beyond the ciphertext buffer + a few MB of overhead is
/// sodium_libs holding state internally.
///
/// The test writes NOTHING to disk or network. Ciphertext chunks are
/// counted and discarded. This isolates the crypto-only memory
/// profile.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:sodium_libs/sodium_libs.dart';
import 'package:web/web.dart' as web;

// --- interop shim for performance.memory (Chromium-only) -----------

extension type _PerformanceMemory._(JSObject _) implements JSObject {
  external int get usedJSHeapSize;
  external int get totalJSHeapSize;
  external int get jsHeapSizeLimit;
}

extension type _PerformanceExtras._(JSObject _) implements JSObject {
  external _PerformanceMemory? get memory;
}

int? _usedJSHeapBytes() {
  if (!kIsWeb) return null;
  final perf = web.window.performance as _PerformanceExtras;
  final mem = perf.memory;
  return mem?.usedJSHeapSize;
}

// --- test scaffolding ---------------------------------------------

void main() {
  runApp(const _SmokeApp());
}

class _SmokeApp extends StatelessWidget {
  const _SmokeApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sodium_libs smoke — OpaqueShare',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const _SmokeScreen(),
    );
  }
}

class _SmokeScreen extends StatefulWidget {
  const _SmokeScreen();

  @override
  State<_SmokeScreen> createState() => _SmokeScreenState();
}

class _SmokeScreenState extends State<_SmokeScreen> {
  Sodium? _sodium;
  String _status = 'Initializing libsodium…';
  final List<_Result> _results = [];
  bool _busy = false;

  // Chunk size we push through pushChunked. Matches the size used by
  // the mobile encryptFileToTempFile path so measurements compare
  // apples-to-apples. 64 KiB is also the natural secretstream chunk.
  static const int _chunkSize = 64 * 1024;

  static const List<int> _sizes = [
    10 * 1024 * 1024,
    100 * 1024 * 1024,
    500 * 1024 * 1024,
    1024 * 1024 * 1024,
    2 * 1024 * 1024 * 1024,
  ];

  @override
  void initState() {
    super.initState();
    _initSodium();
  }

  Future<void> _initSodium() async {
    try {
      final s = await SodiumInit.init();
      setState(() {
        _sodium = s;
        _status = 'libsodium ${s.version} ready. Pick a size to run.';
      });
    } on Object catch (e) {
      setState(() => _status = 'libsodium init failed: $e');
    }
  }

  Future<void> _run(int totalBytes) async {
    final s = _sodium;
    if (s == null || _busy) return;
    setState(() {
      _busy = true;
      _status = 'Encrypting ${_fmtBytes(totalBytes)}…';
    });

    final heapBefore = _usedJSHeapBytes();
    final key = s.crypto.secretStream.keygen();
    final sw = Stopwatch()..start();
    var ciphertextBytes = 0;
    var heapPeak = heapBefore ?? 0;
    Object? err;

    try {
      final cipherStream = s.crypto.secretStream.pushChunked(
        messageStream: _syntheticStream(totalBytes: totalBytes),
        key: key,
        chunkSize: _chunkSize,
      );

      // Consume and DISCARD ciphertext chunks. Sampling the JS heap
      // between chunks so we catch the peak, not just the final.
      var sampleCounter = 0;
      await for (final chunk in cipherStream) {
        ciphertextBytes += chunk.length;
        // Sample roughly 1 in 128 chunks to avoid perf noise but
        // still catch a peak in a multi-GB run.
        sampleCounter++;
        if (sampleCounter & 127 == 0) {
          final now = _usedJSHeapBytes();
          if (now != null && now > heapPeak) heapPeak = now;
        }
      }
    } on Object catch (e) {
      err = e;
    } finally {
      key.dispose();
      sw.stop();
    }

    final result = _Result(
      inputBytes: totalBytes,
      ciphertextBytes: ciphertextBytes,
      elapsedMs: sw.elapsedMilliseconds,
      heapBeforeBytes: heapBefore,
      heapPeakBytes: heapPeak,
      error: err?.toString(),
    );
    setState(() {
      _results.insert(0, result);
      _busy = false;
      _status = err != null
          ? 'FAILED at ${_fmtBytes(totalBytes)}: $err'
          : 'Done. ${_fmtBytes(totalBytes)} in ${sw.elapsedMilliseconds} ms.';
    });
  }

  // Return type widened to `List<int>` on purpose. `pushChunked`'s
  // signature is `Stream<List<int>>` and its internal chunker is
  // typed `StreamTransformer<List<int>, Uint8List>`. On Dart VM
  // (mobile), covariance handles `Stream<Uint8List>` flowing in.
  // On Dart-to-JS (web), the same code fails with a runtime cast
  // error at the internal `.transform()` step because generics are
  // reified less precisely — the JS runtime tries to cast the
  // internal transformer to `StreamTransformer<Uint8List, Uint8List>`
  // and blows up. Yielding as `List<int>` matches sodium's declared
  // parameter type exactly and sidesteps the reified-generic bug.
  Stream<List<int>> _syntheticStream({required int totalBytes}) async* {
    // Reuse one buffer. This is the critical bit — if we allocated a
    // new Uint8List per chunk, the test would measure our own leak,
    // not sodium's. Same reference yielded repeatedly.
    final chunk = Uint8List(_chunkSize)..fillRange(0, _chunkSize, 0x42);
    var emitted = 0;
    while (emitted < totalBytes) {
      final take = totalBytes - emitted;
      if (take >= _chunkSize) {
        yield chunk;
        emitted += _chunkSize;
      } else {
        yield Uint8List.sublistView(chunk, 0, take);
        emitted += take;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('sodium_libs peak-memory smoke test'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            _MemoryStatBar(),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final size in _sizes)
                  FilledButton(
                    onPressed: _sodium == null || _busy ? null : () => _run(size),
                    child: Text('Test ${_fmtBytes(size)}'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Chunk size: 64 KiB. Synthetic input never allocates the '
              'full plaintext — heap growth beyond ~1-2 MiB indicates '
              'sodium_libs is buffering internally.',
              style: TextStyle(fontStyle: FontStyle.italic, fontSize: 12),
            ),
            const Divider(height: 32),
            Expanded(
              child: ListView.separated(
                itemCount: _results.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) => _ResultTile(result: _results[i]),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryStatBar extends StatefulWidget {
  @override
  State<_MemoryStatBar> createState() => _MemoryStatBarState();
}

class _MemoryStatBarState extends State<_MemoryStatBar> {
  Timer? _timer;
  int? _current;

  @override
  void initState() {
    super.initState();
    _current = _usedJSHeapBytes();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _current = _usedJSHeapBytes());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_current == null) {
      return const Text(
        'Live JS heap: unavailable (Firefox/Safari) — Chrome required for '
        'meaningful peak-memory data.',
        style: TextStyle(fontSize: 12),
      );
    }
    return Text(
      'Live JS heap: ${_fmtBytes(_current!)}',
      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.result});
  final _Result result;

  @override
  Widget build(BuildContext context) {
    final Color fg = result.error == null
        ? Theme.of(context).colorScheme.onSurface
        : Theme.of(context).colorScheme.error;
    final heapDelta = (result.heapBeforeBytes != null)
        ? result.heapPeakBytes - result.heapBeforeBytes!
        : null;
    return ListTile(
      dense: true,
      title: Text(
        '${_fmtBytes(result.inputBytes)}  →  '
        '${_fmtBytes(result.ciphertextBytes)}   '
        '(${result.elapsedMs} ms, '
        '${(result.ciphertextBytes / result.elapsedMs * 1000 / (1024 * 1024))
            .toStringAsFixed(1)} MiB/s)',
        style: TextStyle(color: fg, fontFamily: 'monospace'),
      ),
      subtitle: Text(
        result.error != null
            ? 'ERROR: ${result.error}'
            : 'Peak JS heap: ${_fmtBytes(result.heapPeakBytes)}'
              '${heapDelta != null ? "   (Δ ${_fmtBytes(heapDelta)})" : ""}',
        style: TextStyle(color: fg, fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}

class _Result {
  const _Result({
    required this.inputBytes,
    required this.ciphertextBytes,
    required this.elapsedMs,
    required this.heapBeforeBytes,
    required this.heapPeakBytes,
    required this.error,
  });
  final int inputBytes;
  final int ciphertextBytes;
  final int elapsedMs;
  final int? heapBeforeBytes;
  final int heapPeakBytes;
  final String? error;
}

String _fmtBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '$bytes B';
}
