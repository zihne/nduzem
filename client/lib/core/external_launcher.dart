import 'dart:io' show Platform;

import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'package:url_launcher/url_launcher.dart';

/// Result of an external-app launch attempt.
///
/// [ok]         — the OS accepted the intent (an app was found).
/// [noHandler]  — no installed app can handle the URI.
enum ExternalLaunchResult { ok, noHandler }

/// Launch an external URI (e.g. `otpauth://…`) in a way that leaves the
/// target app **independent of Nduzem's task stack**.
///
/// Why this exists: `url_launcher` on Android only attaches
/// `FLAG_ACTIVITY_NEW_TASK`. Under our MainActivity's empty task
/// affinity, that flag isn't enough — the target activity gets stacked
/// into our task instead of getting its own recent-apps entry. Users
/// then see the authenticator app "linked" to Nduzem: swiping the
/// authenticator away also closes us.
///
/// Fix: on Android, use `AndroidIntent` with both
/// `FLAG_ACTIVITY_NEW_TASK` and `FLAG_ACTIVITY_MULTIPLE_TASK` so the
/// target gets a truly separate task even when one already exists.
/// iOS doesn't have this quirk — `launchUrl` handles it cleanly —
/// so we keep the url_launcher path there.
///
/// The distinction between "no handler" and "generic failure" lets the
/// caller show a targeted message ("install an authenticator app") vs.
/// the platform's own error.
Future<ExternalLaunchResult> launchExternalUri(Uri uri) async {
  if (Platform.isAndroid) {
    return _launchOnAndroid(uri);
  }
  return _launchViaUrlLauncher(uri);
}

Future<ExternalLaunchResult> _launchOnAndroid(Uri uri) async {
  final intent = AndroidIntent(
    action: 'action_view',
    data: uri.toString(),
    flags: <int>[
      // Force a new task so the target isn't grouped into ours.
      Flag.FLAG_ACTIVITY_NEW_TASK,
      // If the target already has a task, make ours its own instance —
      // otherwise Android brings the existing task forward but keeps
      // our activity linked, which is the exact behaviour we're
      // avoiding.
      Flag.FLAG_ACTIVITY_MULTIPLE_TASK,
    ],
  );

  final canResolve = await intent.canResolveActivity();
  if (canResolve != true) {
    // Fall through to url_launcher's canLaunch check as a second
    // opinion — some devices' `PackageManager.queryIntentActivities`
    // is conservative under Android 11+ visibility rules.
    return _launchViaUrlLauncher(uri);
  }
  await intent.launch();
  return ExternalLaunchResult.ok;
}

Future<ExternalLaunchResult> _launchViaUrlLauncher(Uri uri) async {
  final launched = await launchUrl(
    uri,
    mode: LaunchMode.externalApplication,
  );
  return launched ? ExternalLaunchResult.ok : ExternalLaunchResult.noHandler;
}
