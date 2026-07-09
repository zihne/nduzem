import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (spec: Play Console won't accept debug-signed AABs).
//
// The keystore lives OUTSIDE the repo — `key.properties` is
// gitignored, and the pointed-at `.jks` file should live somewhere
// the developer machine (or CI) can reach it but the repo can't.
// See `android/key.properties.example` for the expected shape.
//
// When `key.properties` isn't present (fresh clone, dev laptop
// without the upload key, CI without secrets provisioned), we fall
// back to signing release with the debug key so `flutter run
// --release` still works locally. Play Console upload requires the
// real config, so operators MUST populate `key.properties` before
// building a distributable AAB.
val keystoreProperties = Properties()
val keystoreFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystoreFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystoreFile))
}

android {
    namespace = "com.opaqueshare.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.opaqueshare.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Real upload key when key.properties is provisioned;
            // debug key otherwise so local `flutter run --release`
            // still boots. Play Console will reject the debug-key
            // AAB, which is the intended signal.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
