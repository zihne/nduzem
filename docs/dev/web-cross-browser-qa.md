# Cross-browser QA sweep — Workstream 3 (web send + receive)

Manual checklist to run before considering Workstream 3 shippable.
Every flow must green-light on **Chrome** (Chromium 120+), **Firefox**
(115+), and **Safari** (17+). All three run the same Flutter web
build; differences show up in file picking, streaming, and save.

## Setup

1. **Backend** — bring up the local stack:
   ```
   docker-compose -f infra/docker/docker-compose.dev.yml up
   ```
   (or point the client at staging via `--dart-define=API_BASE_URL=…`).

2. **Client dev server** — from `client/`:
   ```
   flutter run -d chrome --web-hostname 0.0.0.0 --web-port 5555
   ```
   Note the URL. Open in Firefox / Safari for the other rows.

3. **Accounts** — two verified accounts registered from any browser.
   Below they're called **Alice** (sender) and **Bob** (recipient).

4. **Test files** — three in the download folder:
   - `small.bin` — ~100 KiB. Exercises the single-shot upload branch
     (< 5 MiB threshold).
   - `mid.bin` — ~50 MiB. Exercises multipart (10+ parts).
   - `big.bin` — ~500 MiB (optional; skip if bandwidth is tight).
     Exercises the "peak memory = plaintext size" web save path;
     watch RAM in DevTools while Firefox / Safari save.

## What to look for on each browser

| Browser | File pick | Save mechanism | Notes |
| --- | --- | --- | --- |
| Chrome | `<input type="file">` via `package:web` | File System Access API (streaming) | The gold path. FSA writer opens; user picks location. |
| Firefox | same | `<a download>` fallback | No FSA. Save drops the file into the default downloads folder. |
| Safari | same | `<a download>` fallback | No FSA. Same as Firefox; also verify iOS Safari if a phone is handy. |

## Flow checklist

Fill one row per browser. Repeat the whole matrix if you touch the
send / receive pipeline. Legend: ✅ pass · ⚠️ works with caveat
(note it) · ❌ broken · — not applicable.

### 1. Send — app mode, small file (single-shot)

Alice signs in, opens `/send`, picks `small.bin`, resolves Bob as
recipient, fingerprints verify, hits Send.

Expected:
- Progress bar goes from 0 → 100 % smoothly (no jumps back to 0).
- Post-send SnackBar shows the transfer id.
- Bob's `/inbox` shows the file within a couple of seconds.

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 2. Send — app mode, mid file (multipart)

Same flow with `mid.bin`. Expect the progress bar to move steadily
(one part every few hundred ms depending on network). No
oscillation between phase labels.

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 3. Send — link mode, no password

Alice picks `small.bin`, flips to Link tab, hits Send. The result
screen shows the `/r/<id>#<K_file>` URL with the fragment.

Verify:
- The fragment is base64url and contains no `=` padding.
- Copying the URL and opening it in an incognito tab lands on the
  link-receive screen.

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 4. Send — link mode, with password + invite email

Same but set a link password + invite email. Verify the send
succeeds; the password is enforced at receive time (test 8).

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 5. Send — cancel mid-upload

Kick off `mid.bin` send. Once the progress bar starts moving, hit
**Cancel**.

Expected:
- Button immediately switches to "Cancelling…" with a spinner.
- Within a few seconds the send throws `SendCancelledException`, the
  screen shows "Send cancelled." and returns to `/`.
- Bob's inbox does NOT show the transfer (server got `/abort`).

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 6. Send — oversized file error

Not fully testable without a huge file. If you have one (or want to
lower the server cap temporarily), verify the error copy reads
*"This file is too large. The current per-transfer cap is X GiB. Try
splitting the file, or get in touch if you need a higher limit."* —
NOT the raw server message.

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 7. Receive — app mode

Bob signs in, opens the transfer from `/inbox`. Hits Download.

Expected:
- Progress bar advances (download → decrypt in two visible phases).
- Sender's handle / fingerprint shows.
- **Chrome**: Save dialog opens (FSA `showSaveFilePicker`); pick a
  location. File lands there. Filename matches the original.
- **Firefox / Safari**: Browser downloads folder receives the file
  automatically with the original name.
- The sha256 of the saved file matches what Alice sent
  (e.g. `sha256sum saved.bin` in a shell).

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 8. Receive — link mode, correct password

Open the URL from test 4 in an incognito tab (no account). Enter the
right password. Download + save.

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 9. Receive — link mode, wrong password

Enter a wrong password. Error message reads plainly ("Wrong link
password."). No cryptic 401 leak.

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 10. Receive — cancel mid-download

Kick off a `mid.bin` receive. Hit **Cancel** during the download or
decrypt phase.

Expected: immediate "Cancelling…" state, then "Download cancelled."
The ciphertext buffer is dropped (no memory leak — check
DevTools' Memory tab: heap should shrink after cancel).

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

### 11. Layout — wide viewport

Maximize a desktop-web window (1920×1080 or wider). All screens
should show the content column centered at ≤ 720 px, with the
AppBar spanning the full width.

Screens to spot-check:
- `/` (Home)
- `/send`
- `/inbox`
- `/receive/<id>`
- `/history`

| Chrome | Firefox | Safari |
| --- | --- | --- |
|  |  |  |

## Known gaps (not blockers for the current sweep)

- **Streaming FSA save.** Chrome could write chunks directly into the
  FSA writer during decrypt (peak memory ≈ chunk size) instead of
  accumulating the whole plaintext then writing. Deferred; the
  fallback path (Firefox / Safari) fundamentally needs the whole
  Blob in memory anyway.
- **Web batch send.** `/send/batch` is app-only today and mostly
  untested on web. Skip unless you're specifically testing it.
- **`WebWorker` parallel encrypt+upload.** Encrypt runs on the main
  isolate; if the CPU is the bottleneck (fast network, big file),
  the tab may feel less responsive. Deferred profiling exercise.

## Reporting

If a row breaks: open a bug with the browser + version, the flow row
number, and a screenshot / DevTools console log. File under label
`workstream-3-cross-browser`.
