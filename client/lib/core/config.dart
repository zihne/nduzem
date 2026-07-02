/// App-wide config values. Runtime overrides via `--dart-define`.
///
/// The backend URL must resolve to the API conduit — this is the ONLY
/// origin the client talks to. Everything else (object storage) flows via
/// presigned URLs the backend returns.
///
/// Dev setup:
///   flutter run --dart-define=OPAQUESHARE_API_BASE=http://10.0.2.2:8000 (Android emulator)
///   flutter run --dart-define=OPAQUESHARE_API_BASE=http://localhost:8000 (iOS simulator)
class AppConfig {
  const AppConfig({required this.apiBaseUrl});

  final Uri apiBaseUrl;

  /// Compile-time defaults; harmless placeholder in production because the
  /// launcher must inject a real value. The URI parses eagerly so a bad
  /// build flag surfaces at startup, not on the first request.
  static AppConfig fromEnv() {
    const raw = String.fromEnvironment(
      'OPAQUESHARE_API_BASE',
      defaultValue: 'http://10.0.2.2:8000',
    );
    return AppConfig(apiBaseUrl: Uri.parse(raw));
  }
}
