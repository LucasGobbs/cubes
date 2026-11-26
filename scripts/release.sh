#!/bin/sh
# Release zip (macOS arm64): scripts/release.sh <version>, e.g. scripts/release.sh 0.1.0
# Builds the self-contained bundle (make dist) into dist/cubes-<version>-macos-arm64/, adds README/LICENSE/CREDITS
# when present and RUN.txt, then zips it to dist/cubes-<version>-macos-arm64.zip. Publishes nothing: prints the gh command.
set -eu
version=${1:?usage: scripts/release.sh <version>}
name=cubes-$version-macos-arm64
cd "$(dirname "$0")/.."
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo "release.sh: needs macOS on Apple Silicon (arm64)" >&2; exit 1; }

make dist DIST="dist/$name"
for f in README.md LICENSE CREDITS.md; do
	if [ -f "$f" ]; then cp "$f" "dist/$name/"; else echo "warning: $f missing, not in the package" >&2; fi
done
cat > "dist/$name/RUN.txt" <<EOF
cubes $version - macOS (Apple Silicon, arm64) build

Requirements: Apple Silicon Mac, macOS 15 or later. Graphics run on Metal.

Unsigned build: macOS Gatekeeper blocks it the first time. Run this once in Terminal, inside this folder:
    xattr -dr com.apple.quarantine .
or open System Settings > Privacy & Security and click "Open Anyway" after the first refusal.

Run (from inside this folder: assets are read by relative path):
    ./main city                 scene 'city' (fullscreen by default)
    ./main city --WINDOWED      same scene in a window
    ./main --display 2 city     on monitor 2 (1 = first)
    ./main skinned              any scene: city, forest_instanced, skinned, game, ...
    ./main city --bench 10      run 10 seconds without input, print stats, exit

Keys: number keys 1-9 switch scene; F12 screenshot. Full controls are in README.md.
EOF
rm -f "dist/$name.zip"
(cd dist && ditto -c -k --keepParent "$name" "$name.zip")

zip="dist/$name.zip"
echo "package: $zip"
echo "size:    $(stat -f %z "$zip") bytes ($(du -h "$zip" | cut -f1))"
echo "sha256:  $(shasum -a 256 "$zip" | cut -d' ' -f1)"
echo
echo "not published. To publish by hand (gh must be installed and logged in):"
echo "  gh release create v$version $zip --title \"cubes $version\" --notes-file <notes.md>"
