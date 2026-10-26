# Lists: one core, two apps. See README.md.

JAVA_HOME ?= /opt/homebrew/opt/openjdk@21
ANDROID_HOME ?= $(HOME)/Library/Android/sdk
export JAVA_HOME ANDROID_HOME

.PHONY: test lint deny fmt apple apple-run apple-lint android android-lint android-screenshots android-install web clean

# --locked: a lockfile that no longer matches Cargo.toml is an error here, as it
# is in the Docker build, instead of being rewritten on the way.
test:
	cd core && cargo test --locked
	cd web && cargo test --locked

lint:
	cd core && cargo fmt --check && cargo clippy --locked --all-targets --all-features -- -D warnings
	cd web && cargo fmt --check && cargo clippy --locked --all-targets --all-features -- -D warnings

# Advisories, licenses and sources of the dependencies (deny.toml).
# Both workspaces are checked even when the first fails, so one run shows every finding.
deny:
	@status=0; \
	cargo deny --manifest-path core/Cargo.toml --config deny.toml check || status=1; \
	cargo deny --manifest-path web/Cargo.toml --config deny.toml check || status=1; \
	exit $$status

fmt:
	cd core && cargo fmt
	cd web && cargo fmt

web:
	cd web && cargo build --release

apple:
	./scripts/build-apple-app.sh Debug

apple-run: apple
	open apple/build/Build/Products/Debug/Lists.app

# The tests in apple/Tests run without starting the app.
apple-test:
	LISTS_XCODE_ACTION=test ./scripts/build-apple-app.sh Debug

# SwiftLint with the settings in apple/.swiftlint.yml.
apple-lint:
	cd apple && swiftlint lint --strict --quiet

android:
	./scripts/build-android.sh
	cd android && ./gradlew --quiet testDebugUnitTest -Proborazzi.test.verify=true assembleDebug

# Records the screenshots of android/app/src/test/screenshots anew, after a change of the UI meant to show (#369).
android-screenshots:
	./scripts/build-android.sh
	cd android && ./gradlew --quiet recordRoborazziDebug

# ktlint with the settings in .editorconfig; the generated bindings are left out.
android-lint:
	cd android && ktlint 'app/src/**/*.kt' '!app/src/main/java/uniffi/**'

android-install: android
	$(ANDROID_HOME)/platform-tools/adb install -r android/app/build/outputs/apk/debug/app-debug.apk

clean:
	cd core && cargo clean
	cd web && cargo clean
	rm -rf apple/build apple/Generated apple/Lists.xcodeproj android/app/build android/build android/app/src/main/jniLibs
