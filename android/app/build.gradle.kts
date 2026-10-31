import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by android/key.properties (kept out of source
// control — see key.properties.example). A release must use the stable key.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.picters.modulesmanager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // AIDL is off by default since AGP 8 — the root-service IPC needs it.
    buildFeatures {
        aidl = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.picters.modulesmanager"
        ndk {
            abiFilters += "arm64-v8a"
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

gradle.taskGraph.whenReady {
    if (allTasks.any { it.project == project && it.name.contains("Release", ignoreCase = true) }) {
        check(keystorePropertiesFile.isFile) { "Release signing requires android/key.properties." }
        for (name in listOf("keyAlias", "keyPassword", "storeFile", "storePassword")) {
            check(!keystoreProperties.getProperty(name).isNullOrBlank()) { "Missing release signing property: $name" }
        }
        check(file(keystoreProperties.getProperty("storeFile")).isFile) { "Release keystore file is missing." }
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

dependencies {
    testImplementation("junit:junit:4.13.2")
    // libsu: bootstraps and manages the root process that hosts the AIDL
    // RootService (KernelRootService). `core` = root shell, `service` = the
    // RootService/IPC bootstrap that hands the service's Binder back to the app.
    implementation("com.github.topjohnwu.libsu:core:6.0.0")
    implementation("com.github.topjohnwu.libsu:service:6.0.0")
}
