import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppL10n
/// returned by `AppL10n.of(context)`.
///
/// Applications need to include `AppL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppL10n.localizationsDelegates,
///   supportedLocales: AppL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppL10n.supportedLocales
/// property.
abstract class AppL10n {
  AppL10n(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppL10n of(BuildContext context) {
    return Localizations.of<AppL10n>(context, AppL10n)!;
  }

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Product name. Do NOT translate — it is a registered trade mark (UK00004433239) and a coined word with no meaning in any language.
  ///
  /// In en, this message translates to:
  /// **'Nduzem'**
  String get appTitle;

  /// App bar title on the settings screen.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// Section heading above the current account's email address.
  ///
  /// In en, this message translates to:
  /// **'Signed in'**
  String get settingsSignedIn;

  /// Section heading for key backup and restore actions.
  ///
  /// In en, this message translates to:
  /// **'Encryption key'**
  String get settingsSectionEncryptionKey;

  /// Menu item: start the key-backup flow, which produces a recovery key.
  ///
  /// In en, this message translates to:
  /// **'Back up your key'**
  String get settingsBackUpKey;

  /// Explains what backing up achieves. 'Recovery key' is a distinct concept from the 2FA 'recovery codes' — keep the two clearly different words in translation, because conflating them is a known user-safety hazard.
  ///
  /// In en, this message translates to:
  /// **'Save a recovery key so you can restore access on another device.'**
  String get settingsBackUpKeySubtitle;

  /// Menu item: bring an existing key onto this device using a saved recovery key.
  ///
  /// In en, this message translates to:
  /// **'Restore from recovery key'**
  String get settingsRestoreKey;

  /// Explains what restoring achieves.
  ///
  /// In en, this message translates to:
  /// **'Bring your original key back onto this device.'**
  String get settingsRestoreKeySubtitle;

  /// Menu item: generate a new identity key, abandoning the old one.
  ///
  /// In en, this message translates to:
  /// **'Replace encryption key'**
  String get settingsReplaceKey;

  /// Section heading for irreversible actions. Convey seriousness, not alarm.
  ///
  /// In en, this message translates to:
  /// **'Danger zone'**
  String get settingsSectionDangerZone;

  /// Menu item: permanently erase the account.
  ///
  /// In en, this message translates to:
  /// **'Delete my account'**
  String get settingsDeleteAccount;

  /// Explains the consequence of account deletion.
  ///
  /// In en, this message translates to:
  /// **'Permanently erase your account and everything in it.'**
  String get settingsDeleteAccountSubtitle;

  /// Section heading above links to the published legal pages.
  ///
  /// In en, this message translates to:
  /// **'About & legal'**
  String get settingsSectionAboutLegal;

  /// Link to the published privacy policy. Use the established legal term in the target language.
  ///
  /// In en, this message translates to:
  /// **'Privacy Policy'**
  String get legalPrivacyPolicy;

  /// Summary of the privacy policy. 'What we cannot see' is the product's central claim — keep the emphasis on inability rather than on a promise not to look.
  ///
  /// In en, this message translates to:
  /// **'What we collect, what we cannot see, and who processes it.'**
  String get legalPrivacyPolicyBlurb;

  /// Link to the published terms. Use the established legal term in the target language.
  ///
  /// In en, this message translates to:
  /// **'Terms of Service'**
  String get legalTermsOfService;

  /// Summary of the terms. 'Zihne Ltd' is a company name — never translate it.
  ///
  /// In en, this message translates to:
  /// **'The agreement between you and Zihne Ltd.'**
  String get legalTermsOfServiceBlurb;

  /// Link to the published account-deletion policy page.
  ///
  /// In en, this message translates to:
  /// **'Account deletion'**
  String get legalAccountDeletion;

  /// Summary of the deletion policy.
  ///
  /// In en, this message translates to:
  /// **'What deletion removes, and what is retained.'**
  String get legalAccountDeletionBlurb;

  /// Shown when no app could handle a link, so the user must open it manually.
  ///
  /// In en, this message translates to:
  /// **'Open this in a browser: {url}'**
  String openInBrowser(String url);
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  Future<AppL10n> load(Locale locale) {
    return SynchronousFuture<AppL10n>(lookupAppL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

AppL10n lookupAppL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppL10nEn();
  }

  throw FlutterError(
      'AppL10n.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
