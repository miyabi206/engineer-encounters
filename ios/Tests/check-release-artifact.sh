#!/bin/sh
# Run from the repository root. Requires full Xcode and XcodeGen outside the sandbox.
set -eu

derived="$PWD/.build/release-artifact"
rm -rf "$derived"
mkdir -p "$derived"
xcodegen generate --spec ios/project.yml
for configuration in Development Internal Release; do
    xcodebuild -project ios/EngineerEncounters.xcodeproj -scheme EngineerEncounters \
        -configuration "$configuration" -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$derived/$configuration" CODE_SIGNING_ALLOWED=NO build
done

failed=0
for configuration in Development Internal Release; do
    app="$derived/$configuration/Build/Products/$configuration-iphonesimulator/EngineerEncounters.app"
    binary_report="$derived/$configuration-binary.txt"
    bundle_report="$derived/$configuration-bundle.txt"
    if [ ! -f "$app/EngineerEncounters" ]; then
        echo "$configuration: missing app binary: $app/EngineerEncounters" >&2
        exit 1
    fi
    extension="$app/PlugIns/SessionActivity.appex"
    if [ ! -f "$extension/SessionActivity" ]; then
        echo "$configuration: missing embedded SessionActivity extension" >&2
        exit 1
    fi
    if [ "$(plutil -extract NSSupportsLiveActivities raw "$app/Info.plist")" != true ]; then
        echo "$configuration: app does not declare Live Activity support" >&2
        failed=1
    fi
    if [ "$(plutil -extract BuildConfiguration raw "$extension/Info.plist")" != "$configuration" ]; then
        echo "$configuration: extension configuration mismatch" >&2
        failed=1
    fi
    if [ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$extension/Info.plist")" != com.apple.widgetkit-extension ]; then
        echo "$configuration: extension is not a WidgetKit extension" >&2
        failed=1
    fi
    extension_report="$derived/$configuration-extension.txt"
    strings -a "$extension/SessionActivity" > "$extension_report"
    find "$extension" -type f -name '*.debug.dylib' > "$derived/$configuration-extension-dylibs.txt"
    while IFS= read -r dylib; do
        strings -a "$dylib" >> "$extension_report"
    done < "$derived/$configuration-extension-dylibs.txt"
    for marker in SessionLiveActivity StartSessionControl StartSessionIntent StopSessionIntent; do
        if ! grep -F -q "$marker" "$extension_report"; then
            echo "$configuration: missing extension marker: $marker" >&2
            failed=1
        fi
    done
    for marker in AppComposition SessionHolder SessionAdapter KeychainSessionStore EncounterBackend BackendURL BackendPublicKey; do
        if grep -F -q "$marker" "$extension_report"; then
            echo "$configuration: forbidden app infrastructure in extension: $marker" >&2
            failed=1
        fi
    done
    for key in BackendURL BackendPublicKey; do
        if plutil -extract "$key" raw "$extension/Info.plist" >/dev/null 2>&1; then
            echo "$configuration: forbidden extension Info.plist key: $key" >&2
            failed=1
        fi
    done
    for language in ja en; do
        if [ ! -f "$extension/$language.lproj/SessionActivity.strings" ]; then
            echo "$configuration: missing extension $language session strings" >&2
            failed=1
        fi
    done
    strings -a "$app/EngineerEncounters" > "$binary_report"
    find "$app" -type f -name '*.debug.dylib' > "$derived/$configuration-dylibs.txt"
    while IFS= read -r dylib; do
        strings -a "$dylib" >> "$binary_report"
    done < "$derived/$configuration-dylibs.txt"
    find "$app" -type f > "$bundle_report"
    # Inspect bundled resources as well as filenames and the executable/debug dylibs.
    find "$app" -type f ! -name EngineerEncounters ! -name '*.dylib' > "$derived/$configuration-resources.txt"
    while IFS= read -r resource; do
        strings -a "$resource" >> "$bundle_report"
    done < "$derived/$configuration-resources.txt"

    for marker in ProductDiagnosticsDestination DiagnosticsView DiagnosticsParticipationControl TrialRecorder TrialLog DemoSwitchSetting DemoRevealController SystemDemoNotificationCenter demoNotificationReady LocalTestTokenIssuer DevelopmentDiagnosticsEntry LocalTestTokens DevelopmentTemporaryAccountSignIn DevelopmentTemporaryAccountText DevelopmentWelcomeView; do
        case "$marker:$configuration" in
            LocalTestTokenIssuer:Internal|DevelopmentDiagnosticsEntry:Internal|LocalTestTokens:Internal|DevelopmentTemporaryAccountSignIn:Internal|DevelopmentTemporaryAccountText:Internal|DevelopmentWelcomeView:Internal|*:Release) expected=absent ;;
            *) expected=present ;;
        esac
        if [ "$expected" = present ]; then
            if ! grep -F -q "$marker" "$binary_report"; then
                echo "$configuration: missing binary marker: $marker" >&2
                failed=1
            fi
        elif grep -F -q "$marker" "$binary_report" "$bundle_report"; then
            echo "$configuration: forbidden marker: $marker" >&2
            failed=1
        fi
    done
    for marker in Diagnostics.strings DevelopmentDiagnostics.strings DevelopmentAccount.strings; do
        case "$marker:$configuration" in
            DevelopmentDiagnostics.strings:Internal|DevelopmentAccount.strings:Internal|*:Release) expected=absent ;;
            *) expected=present ;;
        esac
        if [ "$expected" = present ]; then
            for language in ja en; do
                if ! grep -F -q "/$language.lproj/$marker" "$bundle_report"; then
                    echo "$configuration: missing bundled $language strings table: $marker" >&2
                    failed=1
                fi
            done
        elif grep -F -q "$marker" "$binary_report" "$bundle_report"; then
            echo "$configuration: forbidden strings table: $marker" >&2
            failed=1
        fi
    done
    if [ "$configuration" = Development ]; then
        if [ "$(plutil -extract NSAppTransportSecurity.NSAllowsLocalNetworking raw "$app/Info.plist")" != true ]; then
            echo 'Development: missing local networking allowance' >&2
            failed=1
        fi
        if ! plutil -extract NSLocalNetworkUsageDescription raw "$app/Info.plist" >/dev/null 2>&1; then
            echo 'Development: missing local network description' >&2
            failed=1
        fi
    else
        backend_address=$(plutil -extract BackendURL raw "$app/Info.plist")
        case "$backend_address" in
            ""|[hH][tT][tT][pP][sS]://?*) ;;
            *)
                echo "$configuration: backend address must use HTTPS" >&2
                failed=1
                ;;
        esac
        for key in NSAppTransportSecurity NSLocalNetworkUsageDescription; do
            if plutil -extract "$key" raw "$app/Info.plist" >/dev/null 2>&1; then
                echo "$configuration: forbidden Info.plist key: $key" >&2
                failed=1
            fi
        done
    fi
done
if [ "$failed" -ne 0 ]; then exit 1; fi
echo 'Release artifact check passed: Development markers present; Internal diagnostics only; Release markers absent'
