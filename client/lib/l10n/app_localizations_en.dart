// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Nduzem';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSignedIn => 'Signed in';

  @override
  String get settingsSectionEncryptionKey => 'Encryption key';

  @override
  String get settingsBackUpKey => 'Back up your key';

  @override
  String get settingsBackUpKeySubtitle =>
      'Save a recovery key so you can restore access on another device.';

  @override
  String get settingsRestoreKey => 'Restore from recovery key';

  @override
  String get settingsRestoreKeySubtitle =>
      'Bring your original key back onto this device.';

  @override
  String get settingsReplaceKey => 'Replace encryption key';

  @override
  String get settingsSectionDangerZone => 'Danger zone';

  @override
  String get settingsDeleteAccount => 'Delete my account';

  @override
  String get settingsDeleteAccountSubtitle =>
      'Permanently erase your account and everything in it.';

  @override
  String get settingsSectionAboutLegal => 'About & legal';

  @override
  String get legalPrivacyPolicy => 'Privacy Policy';

  @override
  String get legalPrivacyPolicyBlurb =>
      'What we collect, what we cannot see, and who processes it.';

  @override
  String get legalTermsOfService => 'Terms of Service';

  @override
  String get legalTermsOfServiceBlurb =>
      'The agreement between you and Zihne Ltd.';

  @override
  String get legalAccountDeletion => 'Account deletion';

  @override
  String get legalAccountDeletionBlurb =>
      'What deletion removes, and what is retained.';

  @override
  String openInBrowser(String url) {
    return 'Open this in a browser: $url';
  }
}
