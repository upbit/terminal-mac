#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'terminal-mac currently requires Apple silicon.' >&2
  exit 1
fi
configuration="${CONFIGURATION:-release}"
source scripts/release-config.sh
identity="${SIGN_IDENTITY:-}"
# A stable identity keeps the guest helper's Screen Recording and Accessibility approvals across
# updates; ad-hoc signatures change with every build. SIGN_IDENTITY=- forces ad-hoc signing.
if [[ -z "$identity" ]]; then
  if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGNING_NAME\""; then identity="$SIGNING_NAME"
  else identity=-; echo "No \"$SIGNING_NAME\" identity; signing ad-hoc. Run scripts/create-signing-identity.sh to keep guest permissions across updates." >&2
  fi
fi
echo "Signing with: $identity"
version="${VERSION:-0.2.0}"
build_number="${BUILD_NUMBER:-6}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo 'VERSION must be x.y.z and BUILD_NUMBER a positive integer.' >&2
  exit 1
fi
# Only Apple-issued certificates get a secure timestamp; it is required for notarization.
case "$identity" in
  -) sign_options=(--timestamp=none) ;;
  'Developer ID Application: '*) sign_options=(--options runtime --timestamp) ;;
  *) sign_options=(--options runtime --timestamp=none) ;;
esac
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
build_options=(--disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/configuration" --security-path "$PWD/.build/security")
swift build "${build_options[@]}" -c "$configuration"
binary_dir="$(swift build "${build_options[@]}" -c "$configuration" --show-bin-path)"
app="$PWD/dist/TerminalMac.app"
guest="$app/Contents/Resources/guest-tools/TerminalMacGuest.app"
mkdir -p "$app/Contents/MacOS" "$guest/Contents/MacOS" \
         "$app/Contents/Resources" "$guest/Contents/Resources"
# Replace rather than overwrite: rewriting a running VM's executable in place can kill it.
rm -f "$app/Contents/MacOS/terminal-mac" "$guest/Contents/MacOS/terminal-mac"
cp "$binary_dir/terminal-mac" "$app/Contents/MacOS/terminal-mac"
cp "$binary_dir/terminal-mac" "$guest/Contents/MacOS/terminal-mac"
# SwiftPM resources must travel with both copies of the shared executable.
for name in terminal-mac_TerminalObserver.bundle swift-nio_NIOPosix.bundle; do
  resource="$binary_dir/$name"
  [[ -d "$resource" ]] || { echo "Resource is missing: $name" >&2; exit 1; }
  rm -rf "$app/Contents/Resources/$name" "$guest/Contents/Resources/$name"
  cp -R "$resource" "$app/Contents/Resources/"
  cp -R "$resource" "$guest/Contents/Resources/"
done
make_plist() {
  local destination="$1" identifier="$2" name="$3"
  /usr/libexec/PlistBuddy -c 'Clear dict' "$destination" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" "$destination"
  /usr/libexec/PlistBuddy -c "Add :CFBundleName string $name" "$destination"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string terminal-mac' "$destination"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$destination"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $version" "$destination"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $build_number" "$destination"
  /usr/libexec/PlistBuddy -c 'Add :LSMinimumSystemVersion string 14.0' "$destination"
  /usr/libexec/PlistBuddy -c 'Add :NSHighResolutionCapable bool true' "$destination"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$destination"
}
# The agent skill ships inside the app so `terminal-mac skills get` always matches this build.
rm -rf "$app/Contents/Resources/skills"
mkdir -p "$app/Contents/Resources/skills"
cp -R skills/terminal-mac "$app/Contents/Resources/skills/"
# Both apps show the same icon: the host for the VM window and Dock, the guest for the copy users
# open inside the virtual Mac during setup. The .icns is the committed source of truth; regenerate
# it from new artwork with: iconutil --convert icns -o resources/AppIcon.icns <iconset>
icon_source="$PWD/resources/AppIcon.icns"
[[ -f "$icon_source" ]] || { echo "Icon is missing: $icon_source" >&2; exit 1; }
for bundle in "$guest" "$app"; do
  rm -f "$bundle/Contents/Resources/AppIcon.icns"
  cp "$icon_source" "$bundle/Contents/Resources/AppIcon.icns"
done
make_plist "$guest/Contents/Info.plist" dev.terminal-mac.guest TerminalMacGuest
make_plist "$app/Contents/Info.plist" dev.terminal-mac.host TerminalMac
# Guest has no Virtualization entitlement. Its guarded mode only controls the VM desktop.
codesign --force --sign "$identity" "${sign_options[@]}" "$guest"
codesign --force --sign "$identity" "${sign_options[@]}" --entitlements resources/terminal-mac.entitlements "$app"
ln -sfn TerminalMac.app/Contents/MacOS/terminal-mac dist/terminal-mac
codesign --verify --deep --strict "$app"
echo "Built: $PWD/dist/terminal-mac"
