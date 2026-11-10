// A copy of Google's Media3 "effect" library, version 1.11.1 (Apache License
// 2.0, see LICENSE), with one change: its video blender
// (DefaultVideoCompositor) accepts HDR video and lets the app draw the blend
// itself. That is what makes transitions and picture in picture possible on
// HDR clips. Every other file is unchanged. The app uses this copy in place of
// the published one (see app/build.gradle.kts).
plugins {
    id("com.android.library")
    // A few of its files are Kotlin.
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "androidx.media3.effect"
    compileSdk = 36

    defaultConfig {
        minSdk = 23
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
        freeCompilerArgs.add("-Xannotation-default-target=param-property")
    }
}

dependencies {
    val media3 = "1.11.1"
    api("androidx.media3:media3-common:$media3")
    implementation("androidx.media3:media3-datasource:$media3")
    implementation("androidx.annotation:annotation:1.6.0")
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-guava:1.9.0")
    compileOnly("org.checkerframework:checker-qual:3.13.0")
    compileOnly("com.google.errorprone:error_prone_annotations:2.15.0")
    compileOnly("com.google.code.findbugs:jsr305:3.0.2")
    compileOnly("org.jetbrains.kotlin:kotlin-annotations-jvm:1.9.24")
}
