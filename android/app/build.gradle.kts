plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// A release is signed only when both variables are set; scripts/release-android.sh
// and the release workflow set them.
val releaseKeystore = providers.environmentVariable("LISTS_RELEASE_KEYSTORE").orNull
val releasePassword = providers.environmentVariable("LISTS_RELEASE_PASSWORD").orNull
require((releaseKeystore == null && releasePassword == null) ||
    (!releaseKeystore.isNullOrBlank() && !releasePassword.isNullOrBlank())) {
    "Set both LISTS_RELEASE_KEYSTORE and LISTS_RELEASE_PASSWORD to sign a release"
}

android {
    namespace = "org.evsyukov.lists"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.evsyukov.lists"
        minSdk = 26
        targetSdk = 36
        versionCode = 3
        versionName = "0.1.0-rc.3"
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = releasePassword
                keyAlias = "lists"
                keyPassword = releasePassword
            }
        }
    }

    buildTypes {
        // The ABIs must be among those built by scripts/build-android.sh.
        debug {
            ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        }
        release {
            // Phones are arm64; x86_64 is only needed for the emulator.
            ndk { abiFilters += "arm64-v8a" }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.09.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.11.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.4")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.4")
    implementation("androidx.work:work-runtime-ktx:2.10.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // Talks to the UnifiedPush distributor installed on the device (ntfy, for one).
    implementation("org.unifiedpush.android:connector:3.3.5")
    // Runtime of the UniFFI bindings to the Rust core.
    implementation("net.java.dev.jna:jna:5.17.0@aar")
}
