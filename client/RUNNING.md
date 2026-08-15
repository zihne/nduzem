# Running Nduzem (dev)

Smoke-test guide for the M1 identity flow. Assumes the backend is running
locally (see `../nduzem-server`'s README).

## Prerequisites

- Flutter `>=3.24`, tested at 3.41.5 stable (`.metadata` pins the SDK
  revision for reproducible builds — see spec §13.1).
- Backend up locally: `.venv/bin/uvicorn app.main:app --host 0.0.0.0 --port 8000`
  from `../nduzem-server/backend/`. Note the `--host 0.0.0.0` — needed
  so a phone on the LAN can reach it.
- For iOS: macOS with Xcode. Linux workstations can only target Android.
- For Android: emulator OR a real device with USB debugging enabled.

## Pick your backend URL

The client reads `NDUZEM_API_BASE` at compile time via `--dart-define`.

| Scenario | URL |
|---|---|
| Android emulator hitting host loopback | `http://10.0.2.2:8000` (default) |
| iOS simulator hitting host loopback | `http://localhost:8000` |
| Real Android device on same LAN | `http://<your-workstation-lan-ip>:8000` |

The debug build permits cleartext HTTP to `10.0.2.2`, `localhost`, `127.0.0.1`,
`192.168.0.1`, `192.168.1.1` (see
`android/app/src/debug/res/xml/network_security_config.xml`). If your LAN
uses a different range, add it to that file — the config is scoped to
debug builds only, so release builds stay strict.

## Run

```sh
# From `client/`.
cd client

# Android emulator (default URL is fine):
flutter run --debug

# Real Android device on LAN (adjust the IP):
flutter run --debug \
  --dart-define=NDUZEM_API_BASE=http://192.168.1.42:8000

# iOS simulator (macOS only):
flutter run --debug -d "iPhone" \
  --dart-define=NDUZEM_API_BASE=http://localhost:8000
```

## What to smoke-test

The M1 flow the client covers end-to-end:

1. **Register** with a new email + password. Confirm the response returns
   a `user_id` and both tokens; the safety-number appears on the home
   screen after auto-navigation to `/verify-email`.
2. **Verify email**: copy the 6-digit code from your backend's stdout
   (dev email backend prints to logs) and paste it. Land on `/`.
3. **Sign out** from the home screen's overflow, then **sign in** with
   the same credentials. Confirm you land on `/` again.
4. **Enable 2FA** from the home screen → shows a base32 secret + otpauth
   URI + 10 recovery codes. Enter a TOTP from any authenticator app.
5. Sign out, sign in — this time you should hit `/login/totp` with the
   6-digit prompt. Confirm; land on `/`.
6. Kill the app, relaunch — the auth session should be restored from
   secure storage without re-prompting.
7. **Password reset** (M1.7): sign out, tap **Forgot password?** on the
   login screen, enter your email. You should always see "if an account
   exists, we sent a reset link" regardless of whether the email exists
   (anti-enumeration). For a verified account, copy the reset URL from
   the backend stdout and paste it into your device's browser — the
   universal-link path is a later milestone; for now the URL opens the
   app via the router, and you'll be prompted for a new password.
   Confirm; you should be bounced back to `/login`. Sign in with the
   new password; the old password should no longer work.

## Known limitations

- **`sodium_libs` is discontinued** in favour of standalone `sodium 4.x`.
  Migration deferred per ADR-0001; may surface as a runtime issue on some
  older Android devices. If it does, swap the dep and adapt the
  `KeypairGenerator` boot path.
- **No app icon on iOS simulator** for the first few launches after an
  icon regeneration — Xcode caches. Force a clean rebuild if it matters.
- **No certificate pinning yet** — the debug build talks to your local
  backend over HTTP. Pinning lands as part of the client hardening pass
  (mirrors server-side M8/M9).
