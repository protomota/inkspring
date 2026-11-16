#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
output="${1:-/Volumes/Expand/Codex Media/Inkspring Native}"
case "$output" in
    /*) ;;
    *) echo "Use an absolute output directory." >&2; exit 2 ;;
esac
if [[ "$output" == /Volumes/Expand/* && ! -d /Volumes/Expand ]]; then
    echo "Mount Expand before building Inkspring." >&2
    exit 1
fi

mkdir -p "$output/tmp"
export TMPDIR="$output/tmp"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
# Keep the real SDK version in the linked executable for macOS appearance selection.
build_flags=(--package-path "$project" --scratch-path "$output/swift-build" --build-system native --sdk "$sdk" --disable-sandbox -c release)
swift build "${build_flags[@]}"
binary="$(swift build "${build_flags[@]}" --show-bin-path)"
installed_bundle="$output/Inkspring.app"
staging="$(mktemp -d "$output/.inkspring-build.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Inkspring.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bundle/Contents/Library/LaunchAgents"
mkdir -p "$bundle/Contents/Frameworks"
cp "$binary/Inkspring" "$bundle/Contents/MacOS/Inkspring"
cp "$project/Info.plist" "$bundle/Contents/Info.plist"
sparkle="$bundle/Contents/Frameworks/Sparkle.framework"
ditto "$binary/Sparkle.framework" "$sparkle"
if [[ -n "${INKSPRING_UPDATE_FEED:-}" || -n "${INKSPRING_UPDATE_PUBLIC_KEY:-}" ]]; then
    : "${INKSPRING_UPDATE_FEED:?Set the Sparkle appcast URL.}"
    : "${INKSPRING_UPDATE_PUBLIC_KEY:?Set the Sparkle Ed25519 public key.}"
    : "${INKSPRING_MAC_SIGNING_IDENTITY:?Sparkle releases require Developer ID signing.}"
    [[ "$INKSPRING_UPDATE_FEED" == https://* ]] || { echo "Use an HTTPS Sparkle appcast." >&2; exit 2; }
    plutil -insert SUFeedURL -string "$INKSPRING_UPDATE_FEED" "$bundle/Contents/Info.plist"
    plutil -insert SUPublicEDKey -string "$INKSPRING_UPDATE_PUBLIC_KEY" "$bundle/Contents/Info.plist"
    plutil -insert SUVerifyUpdateBeforeExtraction -bool YES "$bundle/Contents/Info.plist"
    plutil -insert SURequireSignedFeed -bool YES "$bundle/Contents/Info.plist"
    plutil -insert SUAllowsAutomaticUpdates -bool NO "$bundle/Contents/Info.plist"
fi
if [[ -n "${INKSPRING_MAC_BUILD_NUMBER:-}" ]]; then
    plutil -replace CFBundleVersion -string "$INKSPRING_MAC_BUILD_NUMBER" "$bundle/Contents/Info.plist"
fi
cp "$project/com.protomota.inkspring.native.daily-backup.plist" "$bundle/Contents/Library/LaunchAgents/"
cp "$project/Resources/models.json" "$bundle/Contents/Resources/models.json"
cp "$project/../build/icon.icns" "$bundle/Contents/Resources/Inkspring.icns"
cp "$project/iPhone/Assets.xcassets/ProtomotaLogo.imageset/protomota-logo.png" "$bundle/Contents/Resources/"
cp -R "$project/Resources/PlatformIcons" "$bundle/Contents/Resources/"
cp "$project/../build/installer-background.tiff" "$bundle/Contents/Resources/"
cp -R "$project/Resources/Fonts" "$bundle/Contents/Resources/Fonts"
signature_options=(--force)
embedded_profile="$bundle/Contents/embedded.provisionprofile"
if [[ -n "${INKSPRING_MAC_ICLOUD_PROFILE:-}" ]]; then
    if [[ -z "${INKSPRING_MAC_SIGNING_IDENTITY:-}" ]]; then
        echo "Set INKSPRING_MAC_SIGNING_IDENTITY for the iCloud-provisioned build." >&2
        exit 2
    fi
    cp "$INKSPRING_MAC_ICLOUD_PROFILE" "$embedded_profile"
    signature_options+=(--entitlements "${INKSPRING_MAC_ICLOUD_ENTITLEMENTS:-$project/macOSCloudKit.entitlements}")
fi
if [[ -n "${INKSPRING_MAC_SIGNING_IDENTITY:-}" ]]; then
    sparkle_sign=(--force --sign "$INKSPRING_MAC_SIGNING_IDENTITY" --options runtime --timestamp
        --keychain "$HOME/Library/Keychains/login.keychain-db")
    sparkle_version="$sparkle/Versions/Current"
    codesign "${sparkle_sign[@]}" "$sparkle_version/Autoupdate"
    codesign "${sparkle_sign[@]}" "$sparkle_version/Updater.app"
    for service in "$sparkle_version"/XPCServices/*.xpc; do
        codesign "${sparkle_sign[@]}" "$service"
    done
    codesign "${sparkle_sign[@]}" "$sparkle"
    codesign --sign "$INKSPRING_MAC_SIGNING_IDENTITY" --options runtime --timestamp \
        --keychain "$HOME/Library/Keychains/login.keychain-db" "${signature_options[@]}" "$bundle"
else
    codesign --force --sign - "$bundle"
fi
codesign --verify --strict --deep "$bundle"

if [[ "${INKSPRING_MAC_NOTARIZE:-0}" == 1 ]]; then
    : "${INKSPRING_MAC_SIGNING_IDENTITY:?Set the Developer ID signing identity for notarization.}"
    : "${APPLE_API_KEY:?Set the App Store Connect private key path.}"
    : "${APPLE_API_KEY_ID:?Set the App Store Connect key ID.}"
    : "${APPLE_API_ISSUER:?Set the App Store Connect issuer ID.}"
    credentials=(--key "$APPLE_API_KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER")
    archive="$staging/Inkspring.zip"
    /usr/bin/ditto -c -k --keepParent "$bundle" "$archive"
    xcrun notarytool submit "$archive" "${credentials[@]}" --output-format json > "$staging/submission.json"
    submission="$(/usr/bin/plutil -extract id raw -o - "$staging/submission.json")"
    printf 'Apple notarization submission %s\n' "$submission"
    xcrun notarytool wait "$submission" "${credentials[@]}" --timeout 20m --output-format json > "$staging/result.json"
    status="$(/usr/bin/plutil -extract status raw -o - "$staging/result.json")"
    if [[ "$status" != Accepted ]]; then
        xcrun notarytool log "$submission" "${credentials[@]}"
        exit 1
    fi
    printf 'Apple notarization status: %s\n' "$status"
    xcrun stapler staple "$bundle"
    xcrun stapler validate "$bundle"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$bundle"
fi

# Swap the signed contents in one filesystem operation. The app path stays
# registered and MCP and launchd can keep opening the previous build until then.
if [[ -L "$installed_bundle" || -L "$installed_bundle/Contents" ]]; then
    echo "Choose an output directory without an Inkspring app symlink." >&2
    exit 1
fi
xcrun clang -isysroot "$sdk" -x c -o "$staging/install-bundle" - <<'C'
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    unsigned flags = argv[3][0] == 's' ? RENAME_SWAP : RENAME_EXCL;
    if (renamex_np(argv[1], argv[2], flags) == 0) return 0;
    perror("Could not install the signed Inkspring build");
    return 1;
}
C
if [[ -d "$installed_bundle/Contents" ]]; then
    "$staging/install-bundle" "$bundle/Contents" "$installed_bundle/Contents" swap
else
    "$staging/install-bundle" "$bundle" "$installed_bundle" install
fi
if [[ "${INKSPRING_MAC_NOTARIZE:-0}" == 1 ]]; then
    xcrun stapler validate "$installed_bundle"
    /usr/sbin/spctl --assess --type execute --verbose=2 "$installed_bundle"
fi
printf '%s\n' "$installed_bundle"
