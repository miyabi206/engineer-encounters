#!/bin/sh
# Run from the repository root. Requires full Xcode and XcodeGen outside the sandbox.
set -eu

derived="$PWD/.build/release-artifact"
mkdir -p "$derived"
xcodegen generate --spec ios/project.yml
for configuration in Development Release; do
    xcodebuild -project ios/EngineerEncounters.xcodeproj -scheme EngineerEncounters \
        -configuration "$configuration" -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$derived/$configuration" CODE_SIGNING_ALLOWED=NO build
done

failed=0
for configuration in Development Release; do
    app="$derived/$configuration/Build/Products/$configuration-iphonesimulator/EngineerEncounters.app"
    binary_report="$derived/$configuration-binary.txt"
    bundle_report="$derived/$configuration-bundle.txt"
    if [ ! -f "$app/EngineerEncounters" ]; then
        echo "$configuration: missing app binary: $app/EngineerEncounters" >&2
        exit 1
    fi
    strings "$app/EngineerEncounters" > "$binary_report"
    find "$app" -type f -name '*.debug.dylib' > "$derived/$configuration-dylibs.txt"
    while IFS= read -r dylib; do
        strings "$dylib" >> "$binary_report"
    done < "$derived/$configuration-dylibs.txt"
    find "$app" -type f > "$bundle_report"
    # Inspect bundled resources as well as filenames and the executable/debug dylibs.
    find "$app" -type f ! -name EngineerEncounters ! -name '*.dylib' > "$derived/$configuration-resources.txt"
    while IFS= read -r resource; do
        strings "$resource" >> "$bundle_report"
    done < "$derived/$configuration-resources.txt"

    for marker in DiagnosticsView TrialRecorder TrialLog DemoSwitchSetting LocalTestTokenIssuer; do
        if [ "$configuration" = Development ]; then
            if ! grep -F -q "$marker" "$binary_report"; then
                echo "Development: missing binary marker: $marker" >&2
                failed=1
            fi
        elif grep -F -q "$marker" "$binary_report" "$bundle_report"; then
            echo "Release: forbidden marker: $marker" >&2
            failed=1
        fi
    done
    for marker in Diagnostics.strings DevelopmentDiagnostics.strings; do
        if [ "$configuration" = Development ]; then
            if ! grep -F -q "/$marker" "$bundle_report"; then
                echo "Development: missing bundled strings table: $marker" >&2
                failed=1
            fi
        elif grep -F -q "$marker" "$binary_report" "$bundle_report"; then
            echo "Release: forbidden strings table: $marker" >&2
            failed=1
        fi
    done
done
if [ "$failed" -ne 0 ]; then exit 1; fi
echo 'Release artifact check passed: Development markers present; Release markers absent'
