plugins {
    id("com.android.application") version "9.4.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.2.20" apply false
    // Screenshots of the UI on the JVM, compared with the ones in app/src/test/screenshots (#369).
    id("io.github.takahirom.roborazzi") version "1.75.0" apply false
}
