// The copy around saving is the whole fix here, so it is what gets
// tested. The defect was not a crash: pressing a button labelled
// "Save to..." in Safari saved the file to Downloads without asking,
// and then the screen printed a bare filename in a monospace block as
// though it were the path the user had chosen.
//
// `kIsWeb` is a compile-time constant, so a VM test only ever sees the
// non-web branch. That is why the production helpers delegate to
// `...For(prompts:)` variants — both branches are reachable here.
import 'package:flutter_test/flutter_test.dart';
import 'package:nduzem/features/transfers/save_destination.dart';

void main() {
  group('when the platform will ask where to save', () {
    test('the button offers to choose', () {
      expect(saveButtonLabelFor(prompts: true), 'Save to...');
    });

    test('the outcome is the destination, verbatim', () {
      expect(
        saveOutcomeDescriptionFor(
          '/Users/x/Documents/passport.pdf',
          prompts: true,
        ),
        '/Users/x/Documents/passport.pdf',
      );
    });

    test('no hint, because nothing needs explaining', () {
      expect(saveOutcomeHintFor(prompts: true), isNull);
    });
  });

  group('when the browser will not ask', () {
    test('the button does not promise a chooser', () {
      final label = saveButtonLabelFor(prompts: false);
      expect(label, 'Download');
      // The specific regression: the label must not imply a dialog.
      expect(label, isNot(contains('to...')));
    });

    test('the outcome says where to look instead of printing a path', () {
      final text = saveOutcomeDescriptionFor('passport.pdf', prompts: false);
      expect(text, contains('passport.pdf'));
      expect(text, contains('download folder'));
      // Not a bare filename: that is what read as a path before.
      expect(text, isNot('passport.pdf'));
    });

    test('the hint points at the browser setting that does ask', () {
      final hint = saveOutcomeHintFor(prompts: false);
      expect(hint, isNotNull);
      expect(hint, contains('each time'));
    });
  });

  test('on this VM build the platform is treated as prompting', () {
    // Mobile always prompts (SAF / document picker), and a VM test is
    // not web. Guards the subtlety the shared helper exists for: using
    // the web capability alone would report false here and label
    // Android "Download".
    expect(saveWillPromptForLocation, isTrue);
    expect(saveButtonLabel, 'Save to...');
    expect(saveOutcomeHint, isNull);
  });
}
