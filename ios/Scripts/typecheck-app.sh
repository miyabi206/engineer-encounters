#!/bin/sh
set -eu

case "${1-}" in
    Development|Internal|Release) configuration=$1 ;;
    *) echo "Usage: sh ios/Scripts/typecheck-app.sh Development|Internal|Release" >&2; exit 2 ;;
esac
if [ "$#" -ne 1 ]; then
    echo "Expected exactly one build configuration" >&2
    exit 2
fi

platform=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform
sdk=$platform/Developer/SDKs/iPhoneSimulator.sdk
triple=arm64-apple-ios26.0-simulator
sandbox=$PWD/.build/sandbox
output=$PWD/.build/typecheck-app/$configuration
export XDG_CACHE_HOME=$sandbox/xdg
export CLANG_MODULE_CACHE_PATH=$sandbox/clang
export SWIFTPM_MODULECACHE_OVERRIDE=$sandbox/manifest

fail() {
    echo "Failed step: $1 ($configuration)" >&2
    exit "$2"
}
mkdir -p "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE" "$output" \
    || fail "prepare cache and output directories" "$?"

set --
for package in EncounterDomain EncounterBluetooth EncounterStorage EncounterBackend EncounterUI; do
    swift build --disable-sandbox --package-path "ios/Packages/$package" \
        --triple "$triple" --sdk "$sdk" \
        --cache-path "$sandbox/swiftpm-cache" --config-path "$sandbox/swiftpm-config" \
        --security-path "$sandbox/swiftpm-security" --manifest-cache local \
        -Xswiftc -warnings-as-errors || fail "build $package" "$?"
    set -- "$@" -I "ios/Packages/$package/.build/out/Products/Debug-iphonesimulator"
done

# Match project.yml exclusions anchored to $(SRCROOT)/App, regardless of checkout ancestors.
# App/Development includes DevelopmentWelcomeView, temporary account Auth construction and both DevelopmentDiagnostics
# and DevelopmentAccount string tables; neither source nor table ships in Internal/Release.
# Collect arguments individually, preserving the package include paths above.
case "$configuration" in
    Development) set -- "$@" -D DEVELOPMENT_BUILD ;;
    Internal) set -- "$@" -D INTERNAL_BUILD ;;
esac
for source in $(find ios/App -type f -name '*.swift' | sort); do
    case "$configuration:$source" in
        Internal:ios/App/Development/*|Release:ios/App/Development/*|Release:ios/App/Diagnostics/*) continue ;;
    esac
    set -- "$@" "$source"
done
xcrun swiftc -emit-module -module-name EngineerEncounters -parse-as-library -enable-testing \
    -swift-version 6 -warnings-as-errors -sdk "$sdk" -target "$triple" \
    -emit-module-path "$output/EngineerEncounters.swiftmodule" "$@" \
    || fail "type-check app" "$?"

set --
case "$configuration" in
    Development) set -- "$@" -D DEVELOPMENT_BUILD ;;
    Internal) set -- "$@" -D INTERNAL_BUILD ;;
esac
for package in EncounterDomain EncounterBluetooth EncounterStorage EncounterBackend EncounterUI; do
    set -- "$@" -I "ios/Packages/$package/.build/out/Products/Debug-iphonesimulator"
done
for source in $(find ios/Tests -type f -name '*.swift' | sort); do
    set -- "$@" "$source"
done
xcrun swiftc -typecheck -module-name EngineerEncountersTests -parse-as-library -enable-testing \
    -swift-version 6 -warnings-as-errors -sdk "$sdk" -target "$triple" \
    -I "$output" -F "$platform/Developer/Library/Frameworks" -I "$platform/Developer/usr/lib" \
    "$@" || fail "type-check app tests" "$?"
echo "Type-check passed: $configuration"
