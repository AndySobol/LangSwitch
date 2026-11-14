#!/bin/zsh
# Builds dist/LangSwitch.app from the Swift package.
#
#   ./scripts/build.sh                 release build for this Mac's architecture
#   UNIVERSAL=1 ./scripts/build.sh     arm64 + x86_64
#   LANGSWITCH_SIGNING_IDENTITY="Apple Development: …" ./scripts/build.sh
#
# Without a signing identity the bundle is signed ad hoc. macOS ties the Accessibility permission to the
# signature, so an ad hoc build has to be re-approved after every rebuild; a stable identity avoids that.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app="${1:-$root/dist/LangSwitch.app}"
identity="${LANGSWITCH_SIGNING_IDENTITY:--}"

flags=(-c release -Xswiftc -warnings-as-errors)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then flags+=(--arch arm64 --arch x86_64); fi

swift build --package-path "$root" "${flags[@]}" --product LangSwitch
bin=$(swift build --package-path "$root" "${flags[@]}" --show-bin-path)

if pgrep -xq LangSwitch; then
    echo "LangSwitch is running. Quit it before replacing the bundle." >&2
    exit 1
fi

stage=$(mktemp -d "${TMPDIR:-/tmp}/langswitch-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
bundle="$stage/LangSwitch.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"

cp "$bin/LangSwitch" "$bundle/Contents/MacOS/LangSwitch"
cp "$root/Resources/Info.plist" "$bundle/Contents/Info.plist"
cp "$root/Resources/AppIcon.icns" "$bundle/Contents/Resources/AppIcon.icns"
if [[ -n "${LANGSWITCH_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LANGSWITCH_VERSION" "$bundle/Contents/Info.plist"
fi
if [[ -n "${LANGSWITCH_BUILD:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LANGSWITCH_BUILD" "$bundle/Contents/Info.plist"
fi

# SwiftPM resource bundles. ResourceLocator looks for them in Contents/Resources.
for name in LangSwitch_LangSwitchCore LangSwitch_LangSwitchLexicon; do
    [[ -d "$bin/$name.bundle" ]] || { echo "Missing resource bundle: $name" >&2; exit 1; }
    cp -R "$bin/$name.bundle" "$bundle/Contents/Resources/"
done

# Third-party notices travel with the binary.
mkdir -p "$bundle/Contents/Resources/Licenses"
cp "$root/LICENSE" "$bundle/Contents/Resources/Licenses/LangSwitch-LICENSE.txt"
cp "$root/THIRD_PARTY_NOTICES.md" "$bundle/Contents/Resources/Licenses/"
cp "$root/ThirdParty/Hunspell/COPYING.MPL" "$bundle/Contents/Resources/Licenses/Hunspell-MPL-1.1.txt"

plutil -lint "$bundle/Contents/Info.plist" >/dev/null
codesign --force --options runtime --timestamp=none --sign "$identity" "$bundle"
codesign --verify --strict "$bundle"

mkdir -p "$(dirname "$app")"
rm -rf "$app"
mv "$bundle" "$app"
echo "$app"
