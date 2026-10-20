plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
    id("io.github.takahirom.roborazzi")
}

// A release is signed only when both variables are set; scripts/release-android.sh
// and the release workflow set them.
val releaseKeystore = providers.environmentVariable("LISTS_RELEASE_KEYSTORE").orNull
val releasePassword = providers.environmentVariable("LISTS_RELEASE_PASSWORD").orNull
require((releaseKeystore == null && releasePassword == null) ||
    (!releaseKeystore.isNullOrBlank() && !releasePassword.isNullOrBlank())) {
    "Set both LISTS_RELEASE_KEYSTORE and LISTS_RELEASE_PASSWORD to sign a release"
}
// CI builds the release with R8 as it is published, but signs it with the debug
// key so that it installs on an emulator; the release key never reaches CI.
val releaseDebugSigning = providers.environmentVariable("LISTS_RELEASE_DEBUG_SIGNING").orNull == "1"
require(!(releaseDebugSigning && releaseKeystore != null)) {
    "LISTS_RELEASE_DEBUG_SIGNING and LISTS_RELEASE_KEYSTORE exclude each other"
}
// The same variable as in scripts/build-android.sh: a release ships arm64-v8a,
// the CI check of the release runs on an x86_64 emulator.
val releaseAbis = providers.environmentVariable("LISTS_ANDROID_ABIS").orNull
    ?.split(" ")?.filter { it.isNotBlank() } ?: listOf("arm64-v8a")

android {
    namespace = "org.evsyukov.lists"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.evsyukov.lists"
        minSdk = 26
        targetSdk = 36
        versionCode = 27
        versionName = "0.7.1"
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
            ndk { abiFilters += releaseAbis }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (releaseKeystore != null) signingConfig = signingConfigs.getByName("release")
            if (releaseDebugSigning) signingConfig = signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }
    // Robolectric draws the screenshots with the resources and fonts of the app (#369).
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

// The screenshots are kept with the tests; `make android` compares them, `make android-screenshots` records them anew.
roborazzi {
    outputDir.set(file("src/test/screenshots"))
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
    testImplementation("junit:junit:4.13.2")
    // Screenshot tests (#369): Compose drawn by Robolectric's native graphics, compared by Roborazzi.
    testImplementation(composeBom)
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("org.robolectric:robolectric:4.17")
    testImplementation("io.github.takahirom.roborazzi:roborazzi:1.75.0")
    testImplementation("io.github.takahirom.roborazzi:roborazzi-compose:1.75.0")
    // Previews of the building blocks in the IDE (ui/Catalog.kt).
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
}
