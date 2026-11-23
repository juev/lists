// Maven Central rate limits the shared addresses of GitHub runners with HTTP 429, and a
// download that fails that way fails the build rather than falling through to the next
// repository (#477). Google's mirror of Central answers first; mavenCentral() stays behind
// it for an artifact the mirror does not have yet. The URL is written out in both blocks:
// pluginManagement is a separate script scope and cannot see a value declared above it.
pluginManagement {
    repositories {
        google()
        maven("https://maven-central.storage-download.googleapis.com/maven2")
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        maven("https://maven-central.storage-download.googleapis.com/maven2")
        mavenCentral()
    }
}
rootProject.name = "Lists"
include(":app")
