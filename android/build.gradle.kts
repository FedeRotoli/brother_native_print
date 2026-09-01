group = "com.teknysrl.brother_native_print"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

// Project-level repositories also apply when this project is included as a
// subproject of the Flutter host app.
repositories {
    google()
    mavenCentral()
    // Local Maven repository containing the Brother SDK AAR.
    // AGP 9 does not support direct local .aar dependencies when building an
    // AAR (bundleDebugAar), so the SDK is published in android/maven-repo.
    maven { url = uri("${projectDir}/maven-repo") }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.teknysrl.brother_native_print"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // SDK Brother (Brother Print SDK for Android, com.brother.sdk.lmprinter).
    // minSdkVersion richiesto dall'AAR: 21 (il plugin usa 24, quindi compatibile).
    implementation("com.brother.sdk:BrotherPrintLibrary:1.0.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // Needed for com.brother.ptouch.sdk.Logging#addCallback (androidx.core.util.Consumer),
    // used to surface the real reason of a failed channel open: the SDK often
    // reports NoError with a null driver, hiding the actual failure.
    implementation("androidx.core:core:1.13.1")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
