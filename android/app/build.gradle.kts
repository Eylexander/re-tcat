plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.eylexander.retcat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.eylexander.retcat"
        // Android 8.0+: the launcher icon is an adaptive vector only (no PNG mipmaps).
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appName"] = "Re-TCAT"
    }

    // Release key: .secrets/release.p12 + .secrets/password.txt (git-ignored, on the dev PC), or the
    // RELEASE_KEYSTORE / RELEASE_KEYSTORE_PASS env vars in CI. Every published APK must use this key,
    // or phones refuse the update. Without it, release builds fall back to the debug key.
    val secrets = rootProject.file("../.secrets")
    val releaseKeystore = System.getenv("RELEASE_KEYSTORE")?.let(::file) ?: secrets.resolve("release.p12")
    val releasePassword = System.getenv("RELEASE_KEYSTORE_PASS")
        ?: secrets.resolve("password.txt").takeIf { it.exists() }?.readText()?.trim()

    signingConfigs {
        if (releaseKeystore.exists() && releasePassword != null) {
            create("release") {
                storeFile = releaseKeystore
                storeType = "PKCS12"
                storePassword = releasePassword
                keyAlias = "release"
                keyPassword = releasePassword
            }
        }
    }

    buildTypes {
        // Debug builds are signed with the local debug key, so they get their own package and install next to
        // the published app instead of replacing it.
        debug {
            applicationIdSuffix = ".debug"
            manifestPlaceholders["appName"] = "Re-TCAT (dev)"
        }
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
