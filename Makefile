# Lists: one core, two apps. See README.md.

JAVA_HOME ?= /opt/homebrew/opt/openjdk@21
ANDROID_HOME ?= $(HOME)/Library/Android/sdk
export JAVA_HOME ANDROID_HOME

.PHONY: test lint fmt apple apple-run android android-install web clean

test:
	cd core && cargo test
	cd web && cargo test

lint:
	cd core && cargo fmt --check && cargo clippy --all-targets -- -D warnings
	cd web && cargo fmt --check && cargo clippy --all-targets -- -D warnings

fmt:
	cd core && cargo fmt
	cd web && cargo fmt

web:
	cd web && cargo build --release

apple:
	./scripts/build-apple-app.sh Debug

apple-run: apple
	open apple/build/Build/Products/Debug/Lists.app

android:
	./scripts/build-android.sh
	cd android && ./gradlew --quiet assembleDebug

android-install: android
	$(ANDROID_HOME)/platform-tools/adb install -r android/app/build/outputs/apk/debug/app-debug.apk

clean:
	cd core && cargo clean
	cd web && cargo clean
	rm -rf apple/build apple/Generated apple/Lists.xcodeproj android/app/build android/build android/app/src/main/jniLibs
