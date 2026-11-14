import 'package:flutter/foundation.dart' show kIsWeb;

import 'web_saver.dart';

/// Whether pressing save will actually ask the user where the file
/// goes.
///
/// Stated once, here, because the condition has a subtlety that would
/// be wrong if each screen worked it out for itself: the web saver's
/// capability getter is false on non-web builds, because there it is a
/// stub — but mobile ALWAYS prompts, through SAF on Android and the
/// document picker on iOS. So `webSaveAsksForLocation` on its own
/// would describe Android as if it were Safari.
bool get saveWillPromptForLocation => !kIsWeb || webSaveAsksForLocation;

/// Label for the save button.
///
/// "Save to..." when a chooser is coming, "Download" when one is not.
/// Safari and Firefox ship no File System Access API, so the save goes
/// through an `<a download>` anchor and the browser puts the file in
/// its own download folder without asking. Calling that "Save to..."
/// sends the user hunting for a dialog that will never appear, which
/// is how this surfaced: a drop arrival, saved in Safari on macOS,
/// landing silently in Downloads.
String saveButtonLabelFor({required bool prompts}) =>
    prompts ? 'Save to...' : 'Download';

/// What to say after a save.
///
/// On the chooser paths the saver returns a real destination. On the
/// anchor fallback it returns only the FILENAME, because the page
/// never learns where the file went — `<a download>` reports nothing
/// back. The receive screens rendered that bare filename in a
/// monospace block, where it reads as a path and tells the user
/// nothing about where to look.
String saveOutcomeDescriptionFor(String saved, {required bool prompts}) =>
    prompts ? saved : 'Saved as $saved in your browser’s download folder.';

/// A second line, only where it helps.
///
/// Safari and Firefox both have a setting that makes them ask for every
/// download, which is the nearest thing to the chooser this page cannot
/// summon. Worth saying once, at the moment it is relevant, rather than
/// leaving the user to conclude the app ignored them.
String? saveOutcomeHintFor({required bool prompts}) => prompts
    ? null
    : 'Your browser chooses the folder. To be asked each time, turn on '
        '"ask for each download" in its settings.';

// Convenience wrappers bound to the running platform. The `...For`
// variants above take the capability explicitly so both branches are
// reachable from a test: `kIsWeb` is a compile-time constant, so a VM
// test can only ever see the non-web side of these.
String get saveButtonLabel =>
    saveButtonLabelFor(prompts: saveWillPromptForLocation);

String saveOutcomeDescription(String saved) =>
    saveOutcomeDescriptionFor(saved, prompts: saveWillPromptForLocation);

String? get saveOutcomeHint =>
    saveOutcomeHintFor(prompts: saveWillPromptForLocation);
