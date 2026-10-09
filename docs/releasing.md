# Releasing

A release is a tag. Pushing `v<version>` starts the [Release workflow](../.github/workflows/release.yml), which checks the sources, builds the Android APK, the macOS disk image and the Docker image for amd64 and arm64, and publishes them: the files on the GitHub release, the image to `ghcr.io/juev/lists`.

## Steps

1. Set the new version in four places: `core/Cargo.toml`, `web/Cargo.toml`, `MARKETING_VERSION` in `apple/project.yml`, `versionName` in `android/app/build.gradle.kts`. Run `cargo build` in `core/` and `web/` so that both `Cargo.lock` files follow.
2. Raise `versionCode` in `android/app/build.gradle.kts` and `CURRENT_PROJECT_VERSION` in `apple/project.yml` by one. Android refuses to install an APK whose `versionCode` is lower than the installed one.
3. Update the version in the Status section of the README.
4. `./scripts/check-version.sh` confirms that the four places agree. The workflow runs it again with the tag, so a tag that names another version stops the release.
5. Commit, push, wait for CI.
6. Tag and push the tag:

   ```sh
   git tag -s v0.2.0 -m "Lists 0.2.0"
   git push origin v0.2.0
   ```

A tag with a hyphen, such as `v0.2.0-rc.1`, is published as a pre-release and does not move `latest`.

To try the pipeline without publishing, start the Release workflow by hand (Actions → Release → Run workflow). It builds the APK and the disk image and leaves them on the run; the Docker image is built into the cache only and is not pushed. The run needs the secrets of the Android key as a release does.

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

The released APK is built for arm64-v8a only and goes through R8, which renames and removes code. Code reached by name or by reflection must be listed in `android/app/proguard-rules.pro`; a missing rule shows up as a crash at run time, not as a build error, so start the release APK on a device or an arm64 emulator before tagging.

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

Without the certificate the workflow still releases: the app is signed ad hoc, the run shows a warning, and the release notes tell how to remove the quarantine flag. In such a build the share extension does not work, because the App Group it shares with the app needs a team.

`./scripts/release-macos.sh` does the same locally and writes the image to `dist/`. The signed and notarized path has not been run yet: the project has no Developer ID certificate so far. Signing with the hardened runtime and a timestamp was checked with a development certificate.

## Docker image

Each architecture is built on a runner of its own and joined into one manifest. The image gets the tags `<version>`, `<major>.<minor>` and `latest`; pre-releases get the version tag only. The package is published with the workflow's own token and needs no secret.
