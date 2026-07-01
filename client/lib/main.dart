import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// OpaqueShare Flutter client.
///
/// Crypto is client-side (libsodium via `sodium_libs`). Private keys never
/// leave the device (`flutter_secure_storage`). Open-source under Apache-2.0
/// (spec §14) to enable verifiable builds + audit.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: OpaqueShareApp()));
}
