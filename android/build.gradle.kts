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

// I repositories a livello di progetto si applicano anche quando questo
// progetto è incluso come subproject nell'app host Flutter.
repositories {
    google()
    mavenCentral()
    // Repository Maven locale con l'AAR dell'SDK Brother.
    // AGP 9 non supporta le dipendenze .aar locali dirette quando si compila
    // un AAR (bundleDebugAar), quindi l'SDK è pubblicato in android/maven-repo.
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

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
