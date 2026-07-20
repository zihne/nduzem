import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';

class OpaqueShareApp extends ConsumerWidget {
  const OpaqueShareApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'OpaqueShare',
      theme: ThemeData(
        useMaterial3: true,
        // Seeded palette for the full ColorScheme (surface, secondary,
        // tertiary, error, on-*), then pin `primary` to the exact
        // `Colors.deepPurple.shade500` seed. M3's fromSeed derives a
        // more muted primary (~#65558F, tone 40) for accessibility
        // guarantees; overriding it here matches the marketing site's
        // brand purple byte-for-byte so a user landing from the web
        // sees the same colour on the app's FilledButton CTAs.
        //
        // Contrast check: white on #673AB7 is ~7.5:1 — well above
        // WCAG AA (4.5:1) for normal text, so the default `onPrimary`
        // (white) that fromSeed picked stays safe.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)
            .copyWith(primary: const Color(0xFF673AB7)),
      ),
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
