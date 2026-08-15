# iOS — build, run, and what's still open

Companion to [ADR-0015](../adr/0015-ios-platform-parity.md), which
records *why* the platform configuration looks the way it does. This doc
is the operational side: how to build it, what an operator still has to
do before the first TestFlight or App Store submission, and which iOS
gaps are known and deliberate.

## Toolchain

Verified working on this configuration:

| | |
|---|---|
| Flutter | 3.47.0-0.2.pre (beta) |
| Xcode | 26.6 (17F113) |
| iOS SDK | 26.5 |
| CocoaPods | 1.17.0 |
| Deployment target | iOS 15.0 |

**The iOS platform must be installed separately.** A fresh Xcode ships
the SDK stub only, so `xcodebuild -showsdks` lists iOS 26.5 while
`xcrun simctl list runtimes` is empty and every build fails with a
misleading `No Xcode build settings have been found`. The underlying
error only surfaces from a direct `xcodebuild` invocation:

```
iOS 26.5 is not installed. Please download and install the platform
from Xcode > Settings > Components.
```

Fix, once, multi-GB:

```bash
xcodebuild -downloadPlatform iOS
```

## Build + run

```bash
cd client

# Simulator
flutter build ios --simulator --debug
xcrun simctl boot "iPhone 17"
xcrun simctl install booted build/ios/iphonesimulator/Runner.app
xcrun simctl launch booted com.opaqueshare.app

# …or just
flutter run -d "iPhone 17"

# Device, unsigned — compile check only
flutter build ios --no-codesign
```

Point at a backend the same way as the web app:

```bash
flutter run -d "iPhone 17" \
  --dart-define=NDUZEM_API_BASE=http://localhost:8000 \
  --dart-define=NDUZEM_SHARE_URL_BASE=http://localhost:8000
```

**The `--dart-define`s are effectively mandatory on iOS.** The default in
`lib/core/config.dart` is `http://10.0.2.2:8000`, which is the *Android
emulator's* alias for the host machine and means nothing on iOS. The
simulator reaches a host-machine backend at `localhost` directly.

### App Transport Security does not apply — don't add exceptions

There is deliberately no `NSAppTransportSecurity` block in Info.plist,
and adding one would be dead config. ATS governs Apple's networking
stack (`NSURLSession`, `WKWebView`); `package:http` sits on `dart:io`'s
`HttpClient`, which is sockets + BoringSSL inside the Dart VM and never
touches NSURLSession. Cleartext HTTP from Dart is therefore unaffected
by ATS.

Measured on the iOS 26.5 simulator with no exceptions configured — all
three returned 200:

| Target | Result |
|---|---|
| `http://localhost:8765/` | 200 |
| `http://127.0.0.1:8765/` | 200 |
| `http://192.168.1.105:8765/` (LAN IP, non-loopback) | 200 |

So iOS needs no counterpart to Android's debug-only
`network_security_config.xml`. That file is required on Android because
the platform enforces cleartext policy at the OS level for *all* sockets,
including Dart's — a genuine platform difference, not an oversight on
the iOS side.

The caveat: if a future plugin routes API traffic through NSURLSession,
or a WebView is added, ATS *will* apply to that traffic and this note
stops holding.

## Build system: SPM and CocoaPods coexist

Flutter 3.47 wires Swift Package Manager into `project.pbxproj` on the
first build; most plugins resolve through it. `flutter_secure_storage`
does not support SPM, so CocoaPods stays in the loop for that one
plugin, and every build prints:

```
The following plugins do not support Swift Package Manager for ios:
  - flutter_secure_storage
```

This is a warning, not a failure. It becomes an error in some future
Flutter release; the fix is upstream (or swapping the plugin), not
local. Both `Podfile.lock` and the two `Package.resolved` files are
committed so the dependency graph is pinned for reproducible builds.

## Operator TODO before first submission

These are the items nothing in the repo can satisfy on its own.

### 1. Export compliance (blocks submission)

`ITSAppUsesNonExemptEncryption` is `true` — Nduzem's primary
function is encryption, so it does not qualify for the Category 5 Part 2
exemptions, and answering otherwise would be a false declaration.

Before the first submission, file a **year-end self-classification
report** with BIS covering ECCN 5D992.c (mass-market encryption), and
keep the reference on file. App Store Connect asks once per app, not per
build. This is the same paperwork Signal and WhatsApp file annually; it
is a form, not an audit.

### 2. Universal links (two steps, both required)

Configured in `ios/Runner/Runner.entitlements` as
`applinks:nduzem.com`, but inert until:

1. **Associated Domains capability** enabled for `com.opaqueshare.app`
   in the Apple Developer portal, and the provisioning profile
   regenerated afterwards.
2. **Team ID** substituted for the `TEAMID` placeholder in
   `infra/www/.well-known/apple-app-site-association` (server repo), and
   the file deployed.

Verify after deploying — iOS fetches the AASA at install time and gives
no error when it fails:

```bash
curl -sI https://nduzem.com/.well-known/apple-app-site-association \
  | grep -i content-type          # must be application/json, no redirect
```

The Caddyfile sets that header explicitly, because the file has no
extension (Apple's spec forbids one) and `file_server` would otherwise
sniff it as `text/plain`, which iOS rejects silently.

Paths are claimed in two places that must stay in sync: the Android
`<intent-filter>` in `AndroidManifest.xml` enumerates prefixes inline;
iOS claims only the host and delegates path filtering to the AASA.
Changing a deep-link path means editing three files.

### 3. Signing

`CODE_SIGN_STYLE = Automatic` with no `DEVELOPMENT_TEAM` set. Open
`ios/Runner.xcworkspace` in Xcode once and pick the team, or pass
`--export-options-plist` in CI. Untouched here because the value is
account-specific and belongs in local config, not the repo.

## Known iOS gaps (deliberate)

### In-app purchase does not work on iOS

`iap_purchase_service.dart` returns early unless `Platform.isAndroid`,
so iOS falls through to the ADR-0002 stub receipt path
(`STUB:<sku>:<txn>`). The paywall already sends `platform: 'apple'` and
the server has an Apple verification seam, but StoreKit products, an App
Store Connect catalog, and receipt verification against Apple's servers
are all unbuilt. **iOS cannot take payment today.** Anyone testing
billing must use Android.

### Large-file receive lands in the app documents directory

SAF stream-save (ADR-0008) is Android-only. On iOS, `_saveLargeFile`
falls through to `_saveToExternalStorage`, which copies the plaintext
into the app's Documents directory under `Nduzem/`. Thanks to
`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`, that
directory is reachable in the Files app as **On My iPhone >
Nduzem** — but the user does not get to choose the destination the
way an Android user does. A native `UIDocumentPickerViewController`
export path would close the gap; not scoped yet.

Small files (under the warn threshold) use `file_picker.saveFile`, which
does present the iOS document picker, so the two size classes behave
differently. Worth knowing when testing.

### Not yet verified on iOS

The simulator run confirmed the app launches, Keychain reads succeed at
startup, and libsodium 1.0.20 initializes with `crypto_box_seal`,
secretstream, and Ed25519 all round-tripping natively. Everything below
needs a backend and, for some rows, real hardware:

- End-to-end send + receive against a live API
- Keychain persistence across app restarts and reinstalls
- Universal link routing (needs the operator steps above)
- `otpauth://` hand-off to a real authenticator app (simulator has none)
- Background upload behavior when the app is suspended mid-transfer
- Multi-GB transfers under real memory pressure

A cross-browser-QA-style checklist for iOS, mirroring
[web-cross-browser-qa.md](web-cross-browser-qa.md), is worth writing
before the first TestFlight build.
