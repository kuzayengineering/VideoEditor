// Release signing. The automatic build (GitHub Actions) provides these from
// the repository's secrets. Every update must be signed with the same key,
// otherwise Android (and Obtainium) refuse to install it over the old version.
val releaseKeystore: String? = System.getenv("ANDROID_KEYSTORE_PATH")
val releaseKeystorePassword: String? = System.getenv("ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias: String = System.getenv("ANDROID_KEY_ALIAS") ?: "release"

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.kuzayengineering.video_editor"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // Auto captions: whisper.cpp speech recognition (native/captions).
    externalNativeBuild {
        cmake {
            path = file("../../native/captions/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.kuzayengineering.video_editor"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 10+: needed for saving to Movies without storage permission.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = releaseKeystorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeystorePassword
            }
        }
    }

    buildTypes {
        release {
            // Without the release key (e.g. a local build) fall back to the
            // debug key so the app can still be built and tried.
            signingConfig = if (releaseKeystore != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    lint {
        // Media3's newer APIs are marked "unstable" (may change between
        // versions); we pin the version, so that's fine.
        disable += "UnsafeOptInUsageError"
    }
}

dependencies {
    val media3 = "1.11.1"
    implementation("androidx.media3:media3-common:$media3")
    implementation("androidx.media3:media3-exoplayer:$media3")
    implementation("androidx.media3:media3-transformer:$media3")
    // Our patched copy (HDR-capable blending), used everywhere in place of
    // the published media3-effect.
    implementation(project(":media3-effect"))
}

configurations.configureEach {
    resolutionStrategy.dependencySubstitution {
        substitute(module("androidx.media3:media3-effect"))
            .using(project(":media3-effect"))
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
