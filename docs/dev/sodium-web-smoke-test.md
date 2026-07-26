# sodium_libs peak-memory smoke test (Flutter web)

The go/no-go probe for [Workstream 3 of the scale-to-business
roadmap](../../../opaqueshare-server/docs/roadmap/2026-scale-to-business.md).
Answers one question: **can we push multi-GB plaintext through
`sodium_libs`' `pushChunked` on Flutter web while keeping peak JS heap
bounded by chunk size, not by total plaintext size?**

If yes → the web app can support the same file caps as the mobile app.
If no → cap web uploads at whatever the peak heap tolerates in Chrome
(~500 MB is a safe guess), and direct users to mobile for larger.

## What it tests

- `client/lib/dev/sodium_smoke_main.dart` is a **standalone Flutter
  web app** — separate `main()`, separate widget tree, does not share
  state with the real client. Runs the crypto in isolation.
- Synthetic input stream that never allocates the full plaintext (one
  reused 64 KiB buffer, yielded repeatedly). Any heap growth beyond
  ~1-2 MiB is sodium_libs holding state internally.
- Ciphertext chunks are counted and immediately discarded — the test
  measures peak-during-encryption, not peak-with-ciphertext-retained.
- Peak JS heap sampled every 128 chunks via
  `window.performance.memory.usedJSHeapSize` (Chromium-only API).

## How to run

**One-time setup** (already done for this repo, but if `web/sodium.js`
ever goes missing or after a `sodium_libs` upgrade):

```bash
cd client
flutter pub run sodium_libs:update_web
```

That copies `sodium.js` into `client/web/` and injects a `<script>`
tag into `client/web/index.html` so the WASM loader is available
before Flutter boots. Without this step, `SodiumInit.init()` hangs
forever with no error — it's just waiting for a global that never
appears.

**Actually running the test**, from the `client/` directory:

```bash
flutter run -d chrome --target=lib/dev/sodium_smoke_main.dart
```

The browser opens on the smoke test screen. Click through the size
buttons in order (10 MiB → 100 MiB → 500 MiB → 1 GiB → 2 GiB). Wait
for each to finish before starting the next — the JS heap needs a
moment to settle between runs.

## How to interpret the results

Watch two columns:

**Peak JS heap** — should stay roughly constant across sizes. If the
100 MiB run shows ~50 MB peak and the 2 GiB run shows ~55 MB peak,
sodium_libs is genuinely streaming. If the 2 GiB run shows ~2 GB peak
(or crashes with a JS heap OOM), sodium_libs is materializing the
whole input.

**Throughput (MiB/s)** — sanity check. Should be roughly linear across
sizes (i.e., 2 GiB takes ~10× as long as 200 MiB). Anomalies suggest
GC pressure or JIT warmup effects — re-run to confirm.

Expected chrome heap-limit ceiling: ~2-4 GB per tab (`jsHeapSizeLimit`).
If a run OOMs, Chrome DevTools console will log a heap allocation
failure.

## Green (streaming works)

- All 5 sizes complete
- Peak heap grows sub-linearly with total plaintext (delta < 100 MB
  between smallest and largest run)
- Throughput at 2 GiB is at least 50 MiB/s

**Action**: proceed with Flutter web for the v1 web app. Ship the same
file caps as mobile.

## Yellow (partial streaming)

- Runs up to some size N complete cleanly with bounded heap
- Above N, heap grows linearly with plaintext
- No hard OOM at 2 GiB

**Action**: cap web uploads at N/2 (safety margin). Ship v1 with a
"for files > N/2 MB, use the mobile app" nudge on the upload screen.
File a follow-up to migrate to a hand-rolled libsodium.js secretstream
loop in v1.1 (bypassing sodium_libs' web wrapper).

## Red (materialization)

- Small sizes work, but ≥500 MB OOMs Chrome
- Peak heap tracks total plaintext regardless of chunk size

**Action**: sodium_libs' web wrapper isn't streaming. Two options:
1. Cap v1 web uploads at 250 MB (safe for most Chromium tabs) and
   push large-file use to mobile.
2. Skip Flutter web entirely for v1 and build the web app on
   SvelteKit + hand-rolled libsodium.js. ~6 weeks of work vs. the
   4-week Flutter web estimate — worth it if the ceiling is too low.

## What this test does NOT prove

- **Byte-identical output vs mobile.** The test measures memory + time,
  not ciphertext correctness. Follow-up test: pull the ciphertext bytes
  into a hash, run the same synthetic input through the mobile client,
  compare hashes. Belongs in a separate file if we ever need it.
- **Real browser file picker.** The synthetic input avoids the whole
  Blob/FileReader path. If the smoke test passes but real file
  uploads OOM, the culprit is on the input side (browser reading the
  File into memory before we can stream it), not on the crypto side.
  Different test.
- **Cross-browser behavior.** Chrome only. Firefox and Safari don't
  expose `performance.memory`, so we can't measure heap. Assume Chrome
  numbers hold as a lower bound; Firefox tends to be similar; Safari
  is usually stricter (tab memory caps ~1 GB).

## Results — 2026-07-26 baseline (v1 gate)

Ran on Chrome (CPU-only rendering; headless-style — see the
`webGLVersion is -1` warning on start), Chromium heap-limit
default (~4 GiB). Widened `_syntheticStream`'s return type to
`Stream<List<int>>` to sidestep a dart2js reified-generic issue
in sodium's internal `.transform()` chain — see the inline comment
in the smoke test file for the full story.

| Input | Time | Throughput | Peak heap | Δ heap |
|---|---|---|---|---|
| 10 MiB | 145 ms | 76.2 MiB/s | 247 MiB | +17 MiB |
| 100 MiB | 1,312 ms | 76.2 MiB/s | 296 MiB | +58 MiB |
| 500 MiB | 7,044 ms | 71.0 MiB/s | 314 MiB | +98 MiB |
| 1 GiB | 14,497 ms | 70.7 MiB/s | 304 MiB | +104 MiB |
| 2 GiB | 27,684 ms | 74.0 MiB/s | 286 MiB | +59 MiB |

**Verdict: GREEN.** Peak heap fluctuates in a ~247–314 MiB band
regardless of input size — sodium_libs on web is genuinely
streaming. Delta across the range: 39 MiB (green threshold: <100).
Throughput at 2 GiB: 74 MiB/s (green threshold: ≥50). Ciphertext
overhead matches secretstream's ~0.03% (17 bytes / 64 KiB chunk).

**Decision**: v1 web app ships on Flutter web with the same
file caps as mobile.

**Caveats to keep in mind** as we build:

- Throughput on web is ~3–4× slower than mobile native crypto.
  A 2 GiB send takes ~30 s to encrypt on web vs ~10 s on mobile.
  Acceptable for background operation; UX-relevant because the
  upload progress bar needs to show "encrypting" as a distinct
  phase before "uploading."
- Baseline ~247 MiB is Flutter web itself (widget tree, CanvasKit,
  Dart runtime). Sodium adds ~50–100 MiB during a run. Total peak
  ~314 MiB is comfortable in every modern browser tab.
- Browser-side FileReader / Blob overhead was NOT tested here — the
  synthetic stream bypasses it. When real file uploads land, we
  need a similar smoke test on the `FilePicker → readAsArrayBuffer`
  path to confirm the browser's file-reading doesn't OOM before
  the crypto path sees the bytes.

## Removing the smoke test

Once the web app v1 ships and Workstream 3 is behind us, this file can
stay (useful for future sodium_libs upgrades that might regress
streaming behavior) or be moved to `client/example/` under a different
name. It's zero cost in the mobile build — the file has its own
`main()` and is only reachable via explicit `--target=`.
