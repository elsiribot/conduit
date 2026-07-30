#!/usr/bin/env bash
# Android build for NixOS hosts (no Docker/cross): cargo-ndk + steam-run FHS
# wrapper for the prebuilt NDK/SDK binaries. Expects:
#   - rustup toolchain with the aarch64-linux-android target
#   - cargo-ndk and flutter_rust_bridge_codegen 2.10.0 in ~/.cargo/bin
#   - Android SDK (platform-tools, platforms, build-tools) and NDK
#     28.2.13676358 in ~/android-sdk
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
NDK_VERSION="28.2.13676358"

export NIXPKGS_ALLOW_UNFREE=1

nix-shell -p steam-run flutter rustup gcc pkg-config openssl clang cmake gnumake ninja perl go llvmPackages.libclang jdk17 --run "
set -e
export RUSTUP_HOME=\$HOME/.rustup CARGO_HOME=\$HOME/.cargo
export PATH=\$CARGO_HOME/bin:\$PATH
export LIBCLANG_PATH=\$(nix-build '<nixpkgs>' -A llvmPackages.libclang.lib --no-out-link)/lib
export ANDROID_HOME=\$HOME/android-sdk
export ANDROID_NDK_HOME=\$ANDROID_HOME/ndk/$NDK_VERSION
export RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384'
# steam-run's sandbox only mounts /tmp; session TMPDIRs break NDK clang
export TMPDIR=/tmp
export ANDROID_NDK_ROOT=\$ANDROID_NDK_HOME
# aws-lc-sys' cmake builder trips over the sandbox; its cc builder works
unset CMAKE
export AWS_LC_SYS_CMAKE_BUILDER=0

echo '🔧 Generating Rust bridge code...'
cd $ROOT
flutter_rust_bridge_codegen generate

echo '🔨 Building Rust library for Android ARM64...'
cd $ROOT/rust
# API 24: rocksdb needs POSIX_MADV_* (Android 23+); matches Flutter's minSdk
steam-run cargo ndk -t arm64-v8a --platform 24 rustc --release --crate-type=cdylib

echo '📦 Copying libraries to jniLibs...'
mkdir -p $ROOT/android/app/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/libconduit.so $ROOT/android/app/src/main/jniLibs/arm64-v8a/
cp \$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so \
   $ROOT/android/app/src/main/jniLibs/arm64-v8a/

echo '📱 Building APK...'
cd $ROOT
steam-run \$(which flutter) build apk --release

echo '✅ APK: build/app/outputs/flutter-apk/app-release.apk'
"
