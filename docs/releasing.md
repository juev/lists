# Releasing

A release is a tag. Pushing `v<version>` starts the [Release workflow](../.github/workflows/release.yml), which checks the sources, builds the Android APK, the macOS disk image and the Docker image for amd64 and arm64, and publishes them: the files on the GitHub release, the image to `ghcr.io/juev/lists`.

## Steps

1. Set the new version in four places: `core/Cargo.toml`, `web/Cargo.toml`, `MARKETING_VERSION` in `apple/project.yml`, `versionName` in `android/app/build.gradle.kts`. Run `cargo build` in `core/` and `web/` so that both `Cargo.lock` files follow.
2. Raise `versionCode` in `android/app/build.gradle.kts` and `CURRENT_PROJECT_VERSION` in `apple/project.yml` by one; the two stay the same number. Android refuses to install an APK whose `versionCode` is lower than the installed one.
3. Update the version in the Status section of the README, in the image tags of the install commands in `README.md` and `docs/self-hosting.md`, and in `LISTS_VERSION` of `.env.example`. A pre-release leaves these on the last release.
4. `./scripts/check-version.sh` confirms that the four places, both `Cargo.lock` files and the documentation agree, that `versionCode` and `CURRENT_PROJECT_VERSION` are equal, and that the build number is above that of every earlier release tag. CI runs it on every push; the Release workflow runs it again with the tag, so a tag that names another version stops the release.
5. Commit, push, wait for CI.
6. Tag and push the tag:

   ```sh
   git tag -s v0.2.0 -m "Lists 0.2.0"
   git push origin v0.2.0
   ```

A tag with a hyphen, such as `v0.2.0-rc.1`, is published as a pre-release and does not move `latest`.

To try the pipeline without publishing, start the Release workflow by hand (Actions → Release → Run workflow). It builds the APK and the disk image and leaves them on the run; the Docker image is built into the cache only and is not pushed. The run needs the secrets of the Android key as a release does.

## What is checked before a release, and what is not

- `make test` and `make lint`, in CI and again in the Release workflow. Both run with `--locked`, so a lockfile that does not match `Cargo.toml` fails there and not first in the Docker build; `make lint` runs Clippy with all features, `cli` included. `make deny` runs `cargo-deny` with `deny.toml` on both workspaces in CI: a published advisory against a dependency, a license outside the list, or a crate from another registry or a git repository fails the build. An advisory that does not apply is ignored in `deny.toml` with the reason next to it. After the builds `scripts/check-clean-tree.sh` fails when a build changed a tracked file or left a new one that is not ignored.
- **The Android release APK starts** on an x86_64 emulator in CI, R8 included (see [Android signing key](#android-signing-key)).
- **The macOS app starts.** CI runs `scripts/check-launch.sh … debug` on the Debug build: the helper of quick entry is switched on and the app is started with a probe that stops it when the event loop is run while the model is built. That is how 0.3.1 stopped at every launch (#239); the check fails on that code and passes after the fix. The Release workflow mounts the disk image it has just packed with `scripts/check-dmg.sh` and starts the app from it with `scripts/check-launch.sh … release`; the app must still be running fifteen seconds after its start, and when it is not, nothing is published.
- **Both architectures.** CI builds the Debug app for Apple silicon and Intel, and `scripts/check-universal.sh` fails when the app, the share extension or the helper of quick entry lacks one of them; `scripts/release-macos.sh` runs the same check on the Release build (#375). The job "macOS app on Intel" builds the app on an Intel runner (`macos-15-intel`) and starts it with `scripts/check-launch.sh … debug`.
- **The disk image.** `scripts/check-dmg.sh` checks that the image holds `Lists.app` of the version in its name and the link to `/Applications`, and that the signature of the app verifies. A notarized image must also carry a stapled ticket and be accepted by Gatekeeper (`spctl`), the image and the app alike.
- **The Docker image.** CI builds it, starts it as `compose.yaml` runs it (read-only root filesystem, no capabilities) and uploads a file through it with `scripts/check-image.sh`; the container must report itself healthy. Trivy checks the Dockerfile. It finds no packages in the image, whose only program is a static binary, so the dependencies of that binary are left to `cargo-deny`.
- **The published files.** After the upload the workflow downloads the release again and checks every file against `SHA256SUMS`, and that the release holds the files that were built and no others.
- **Not checked by a machine:** what the apps show on a screen, the arm64 APK and the Android app on a phone, and a launch of the macOS Release build under the real conditions of a Mac in use: with the installed helper, with notifications allowed and planned, with the keychain asking. The probe covers one way a launch can go wrong, not all of them. Before a tag, install the build on the Mac it is meant for and start it several times.

## Pinned dependencies

What the release jobs run, with the signing secrets in their environment, is pinned to content, not to a name that can be moved:

| What | Where | How |
|---|---|---|
| GitHub Actions | `.github/workflows/*.yml` | by commit, the version in a comment next to it |
| the build image of the Docker image | `Dockerfile` | `rust:<version>-alpine` with its digest |
| Gradle | `android/gradle/wrapper/gradle-wrapper.properties` | `distributionSha256Sum` of the distribution |
| Swift packages | `apple/project.yml`, `apple/Package.resolved` | an exact version, and the revision in `Package.resolved`; `scripts/build-apple-app.sh` puts the file into the generated project and builds with `-onlyUsePackageVersionsFromResolvedFile`, so a pin that does not match stops the build |

Dependabot (`.github/dependabot.yml`) proposes new pins of the actions and the image every week. A new Gradle version needs a new checksum, from `https://services.gradle.org/distributions/gradle-<version>-bin.zip.sha256`. A new version of a Swift package is set in `apple/project.yml`; then, in `apple/`, run `xcodegen generate` and `xcodebuild -resolvePackageDependencies -project Lists.xcodeproj -scheme Lists` and copy `Lists.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` to `apple/Package.resolved`.

## Android signing key

Every APK must be signed with the same key, or it will not install over the previous version. The workflow refuses to publish an APK whose certificate differs from the pinned fingerprint.

| Where | What |
|---|---|
| `~/.local/share/lists/release.jks` on the maintainer's Mac | the keystore, alias `lists` |
| macOS Keychain, service `org.evsyukov.lists.release`, account `lists` | its password |
| repository secret `LISTS_RELEASE_KEYSTORE_B64` | the keystore, base64 |
| repository secret `LISTS_RELEASE_PASSWORD` | its password |

Keep a copy of the keystore and the password outside the Mac. GitHub secrets cannot be read back.

`./scripts/release-android.sh` builds the signed APK locally into `dist/`.

The released APK is built for arm64-v8a only and goes through R8, which renames and removes code. Code reached by name or by reflection must be listed in `android/app/proguard-rules.pro`; a missing rule shows up at run time, not as a build error. CI therefore builds the release APK with R8 on every push to `main` and on every pull request that changes `android/`, `core/`, the Rust toolchain, the Android build scripts or the CI workflow, for x86_64 (`LISTS_ANDROID_ABIS=x86_64`) and signed with the debug key (`LISTS_RELEASE_DEBUG_SIGNING=1`), and `scripts/check-launch-android.sh` starts it on an emulator: the app must not crash, must still run after fifteen seconds, and the Rust core must have created its database. Without the JNA rules the app does not crash but the core never opens, and without the Room rule WorkManager stops the app at start; the check fails on both. It does not cover code that runs only later: sync, notifications, the widget, the share target. The arm64 APK itself is not started by a machine, so start it on a device before tagging.

## macOS signing and notarization

A disk image that opens without warnings needs a Developer ID Application certificate, which comes with the paid Apple Developer Program, and notarization by Apple. The workflow does both when these repository secrets exist:

| Secret | What |
|---|---|
| `LISTS_MACOS_CERTIFICATE_B64` | the Developer ID Application certificate with its private key, exported from Keychain Access as `.p12`, base64 |
| `LISTS_MACOS_CERTIFICATE_PASSWORD` | the password of that `.p12` |
| `LISTS_NOTARY_KEY_B64` | an App Store Connect API key (`.p8`), base64 |
| `LISTS_NOTARY_KEY_ID` | the id of that key |
| `LISTS_NOTARY_ISSUER_ID` | the issuer id shown next to the keys in App Store Connect |

```sh
base64 -i DeveloperID.p12 | gh secret set LISTS_MACOS_CERTIFICATE_B64
```

Without the certificate the workflow still releases: the app is signed ad hoc, the run shows a warning, and the release notes tell how to remove the quarantine flag. In such a build the share extension does not work, because the App Group it shares with the app needs a team. With the certificate but without all three notarization secrets the workflow stops: a signed image that is not notarized would be published with notes that describe neither case.

`./scripts/release-macos.sh` does the same locally and writes the image to `dist/`. The signed and notarized path has not been run yet: the project has no Developer ID certificate so far. Signing with the hardened runtime and a timestamp was checked with a development certificate.

## Docker image

Each architecture is built on a runner of its own and joined into one manifest. The image gets the tags `<version>`, `<major>.<minor>` and `latest`; pre-releases get the version tag only. The package is published with the workflow's own token and needs no secret.
