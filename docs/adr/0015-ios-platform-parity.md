# ADR-0015 — iOS platform parity: Info.plist, entitlements, universal links

Status: Accepted
Date: 2026-07-30

## Context

The iOS target has existed since the `chore flutter platform scaffold`
commit but has never been built. It carried the stock `flutter create`
scaffold: a bare `Info.plist`, no entitlements file, no `Podfile`, and
an `IPHONEOS_DEPLOYMENT_TARGET` of 13.0. Android, by contrast, has
accumulated real platform configuration — an autoVerify App Links
intent-filter for three path prefixes, a `<queries>` block for
`otpauth://` visibility, and the SAF stream-save channel (ADR-0008).

The 2026 scale-to-business roadmap lists iOS as "gated on Mac purchase;
separate track." The Mac now exists, so the gate is lifted. This ADR
records what the first real iOS build required.

Three of the gaps were not cosmetic — they were **latent functional
bugs** that would have shipped:

1. **Received files were unreachable.** On iOS, `_saveToExternalStorage`
   (receive_screen.dart, link_receive_screen.dart) copies the decrypted
   plaintext into `getApplicationDocumentsDirectory()`. The code comment
   claims the result is visible "under `On My iPhone > OpaqueShare`" in
   the Files app. That is only true when `UIFileSharingEnabled` **and**
   `LSSupportsOpeningDocumentsInPlace` are both set. Neither was. Every
   large-file receive on iOS would have reported success and left the
   file somewhere the user cannot reach.

2. **MFA enrolment's authenticator hand-off was dead.** `url_launcher`
   on iOS gates `launchUrl` behind `UIApplication.canOpenURL`, which
   since iOS 9 returns false for any custom scheme absent from
   `LSApplicationQueriesSchemes`. The `otpauth://` launch in
   `core/external_launcher.dart` would have reported "no authenticator
   app installed" on a device that has three.

3. **Universal links did not exist.** Android claims
   `/r/*`, `/password-reset`, and `/verify-email` via App Links. iOS
   claims nothing, so every email link — verification, password reset,
   share — would have opened Safari instead of the app.

## Decision

### Info.plist

| Key | Value | Why |
|---|---|---|
| `UIFileSharingEnabled` | `true` | Exposes Documents in the Files app |
| `LSSupportsOpeningDocumentsInPlace` | `true` | Same; both are required |
| `LSApplicationQueriesSchemes` | `[otpauth]` | Unblocks `canOpenURL` for MFA enrolment |
| `NSPhotoLibraryUsageDescription` | prose | Avoids ITMS-90683 (see below) |
| `ITSAppUsesNonExemptEncryption` | `true` | Export compliance (see below) |

`NSPhotoLibraryUsageDescription` is present despite the app never
calling PHPhotoLibrary. `file_picker` links DKImagePickerController on
iOS regardless of the `FileType` requested, and we only ever call
`pickFiles(withData: false, allowMultiple: true)` — `FileType.any`,
which routes to `UIDocumentPickerViewController`. App Store static
analysis rejects binaries that link photo APIs without a purpose string
(ITMS-90683), so the string exists to clear review, and is worded
honestly for the case where a user reaches a photo through the document
picker.

`ITSAppUsesNonExemptEncryption` is `true`, not `false`. OpaqueShare's
primary function *is* encryption, so it does not qualify for the
Category 5 Part 2 exemptions the App Store Connect questionnaire asks
about; answering `false` would be a false declaration. The consequence
is an operator obligation, recorded in
[docs/dev/ios-platform-setup.md](../dev/ios-platform-setup.md): file a
year-end self-classification report with BIS (ECCN 5D992.c, mass-market)
before the first submission.

### Entitlements + universal links

New `ios/Runner/Runner.entitlements`, wired into all three Runner build
configurations via `CODE_SIGN_ENTITLEMENTS`, claiming
`applinks:opaqueshare.com`.

iOS and Android split the claim differently. The Android manifest
enumerates path prefixes inline; iOS claims only the **host** in the
entitlement and delegates path filtering to the
`apple-app-site-association` (AASA) file the host serves. The AASA
therefore lives in the server repo alongside `assetlinks.json`, and the
two must be kept in sync — a path prefix added to one is a path prefix
that must be added to the other.

Two operator steps gate this working, both documented in the
entitlements file and the setup doc: enabling the Associated Domains
capability in the Apple Developer portal, and replacing the `TEAMID`
placeholder in the AASA.

### Deployment target 13.0 → 15.0

Raised by the Flutter toolchain, not by us — `flutter build ios` rewrote
`project.pbxproj`, `AppFrameworkInfo.plist`, and the `Podfile` on first
run. Accepted as-is: iOS 15 covers the iPhone 6s and later, and the
alternative is pinning an older Flutter.

### Build system: SPM + CocoaPods, both

Flutter 3.47 added Swift Package Manager integration to the project on
first build. Most plugins resolve through SPM now; `flutter_secure_storage`
does not support SPM, so CocoaPods stays in the loop for it alone.
`Podfile.lock` and both `Package.resolved` files are committed —
reproducible builds (see `provability/reproducible-build/`) need the
dependency graph pinned on iOS the same way it is elsewhere.

## Consequences

- The client builds and runs on iOS. Verified on an iPhone 17 simulator
  (iOS 26.5): app launches to the sign-in screen, and a scratch harness
  confirmed libsodium 1.0.20 initializes with `crypto_box_seal`
  round-trip, secretstream keygen, and Ed25519 sign/verify all passing
  natively. The crypto stack is not a web/Android-only story.
- Universal links are **configured but not yet functional** — they need
  the Team ID and the Associated Domains capability. Until then, email
  links open Safari and hit the web fallbacks, which is the pre-existing
  behavior, not a regression.
- Two known iOS gaps remain deliberately open, tracked in the setup doc:
  IAP is Android-only (`iap_purchase_service.dart` returns early unless
  `Platform.isAndroid`), so iOS falls back to the ADR-0002 stub receipt
  path and cannot take payment; and large-file receive uses the
  documents-directory fallback rather than a native picker, because SAF
  (ADR-0008) has no iOS equivalent wired up.
- The Android `assetlinks.json` and the iOS AASA are now a matched pair.
  Changing deep-link paths means editing three files, not two.
