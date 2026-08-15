/// App-wide config values. Runtime overrides via `--dart-define`.
///
/// The client talks to the API at [apiBaseUrl] (typically the
/// `api.<host>` subdomain). It also assembles user-facing share
/// URLs for link-mode transfers (`<origin>/r/<id>#<K_file>`) using
/// [shareUrlBase] — this is a DIFFERENT origin (the marketing /
/// bare-domain host) because:
///
///   1. The Android universal-link intent-filter is registered
///      against the bare host, not the `api.` subdomain
///      (see client ADR-0010 + AndroidManifest.xml). API-domain
///      URLs never trigger the in-app deep link.
///   2. `assetlinks.json` lives on the bare host — Android App
///      Links verification only checks that host.
///   3. Users read URLs; `nduzem.com/r/…` looks like a link
///      you'd want to tap. `api.nduzem.com/r/…` looks like a
///      developer accidentally pasted an internal URL.
///
/// Dev setup:
///   flutter run \
///     --dart-define=NDUZEM_API_BASE=http://10.0.2.2:8000 \
///     --dart-define=NDUZEM_SHARE_URL_BASE=http://10.0.2.2:8000
///     (Android emulator — API + share both go to the same dev host)
///
/// Release build (see `scripts/build-release.sh`):
///   flutter build appbundle --release \
///     --dart-define=NDUZEM_API_BASE=https://api.nduzem.com \
///     --dart-define=NDUZEM_SHARE_URL_BASE=https://nduzem.com
class AppConfig {
  const AppConfig({required this.apiBaseUrl, required this.shareUrlBase});

  /// Where the client talks to the API. Usually `api.<host>`.
  final Uri apiBaseUrl;

  /// Where user-facing share URLs (`/r/<id>#<K_file>`) point. Usually
  /// the bare host (`nduzem.com`), NOT the `api.` subdomain.
  /// See class docstring for why.
  final Uri shareUrlBase;

  /// URL of a published legal page — privacy policy, terms, deletion
  /// policy. They are served from the marketing origin, the same one
  /// share links use, so a dev build pointed at localhost opens the
  /// local copies.
  ///
  /// A method rather than the two-line expression inlined at each call
  /// site: the settings screen and the sign-up screen both need these,
  /// and a construction copied into two files is one that can be
  /// correct in one of them. The first version was — it shipped
  /// `'/\$file'` with an escaped dollar in one place, which produces a
  /// link to the literal path `/$file` and analyses perfectly cleanly.
  Uri legalPage(String file) => shareUrlBase.replace(path: '/$file');

  /// Compile-time defaults; harmless placeholder in production because
  /// the launcher must inject real values via --dart-define. The URIs
  /// parse eagerly so a bad build flag surfaces at startup, not on the
  /// first request.
  static AppConfig fromEnv() {
    const rawApi = String.fromEnvironment(
      'NDUZEM_API_BASE',
      defaultValue: 'http://10.0.2.2:8000',
    );
    const rawShare = String.fromEnvironment(
      'NDUZEM_SHARE_URL_BASE',
      defaultValue: '',
    );
    final apiBaseUrl = Uri.parse(rawApi);
    // If share URL base isn't provided explicitly, derive from the
    // API base by stripping a leading `api.` if present — matches
    // the standard `api.<host>` / `<host>` convention. Callers that
    // deploy behind a different scheme (e.g. an ngrok tunnel where
    // API + share are the same host) can override explicitly.
    final shareUrlBase = rawShare.isNotEmpty
        ? Uri.parse(rawShare)
        : _deriveShareUrlBase(apiBaseUrl);
    return AppConfig(apiBaseUrl: apiBaseUrl, shareUrlBase: shareUrlBase);
  }

  /// Strip a leading `api.` from `apiBaseUrl`'s host if present.
  /// `https://api.nduzem.com` → `https://nduzem.com`.
  /// `http://localhost:8000` → unchanged (no `api.` prefix).
  static Uri _deriveShareUrlBase(Uri apiBase) {
    final host = apiBase.host;
    if (host.startsWith('api.')) {
      return apiBase.replace(host: host.substring(4));
    }
    return apiBase;
  }
}
