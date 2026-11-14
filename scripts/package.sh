#!/bin/zsh
# Packs dist/LangSwitch.app into a zip and a disk image with checksums, ready to attach to a release.
#   ./scripts/package.sh 1.0.0
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
version="${1:?usage: package.sh <version>}"
app="$root/dist/LangSwitch.app"
[[ -d "$app" ]] || { echo "Build the application first: ./scripts/build.sh" >&2; exit 1; }

out="$root/dist/release"
rm -rf "$out"
mkdir -p "$out"

ditto -c -k --keepParent "$app" "$out/LangSwitch-$version.zip"

staging=$(mktemp -d "${TMPDIR:-/tmp}/langswitch-dmg.XXXXXX")
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "LangSwitch $version" -srcfolder "$staging" -ov -format UDZO "$out/LangSwitch-$version.dmg"

(cd "$out" && shasum -a 256 LangSwitch-$version.zip LangSwitch-$version.dmg > SHA256SUMS.txt)
ls -lh "$out"
