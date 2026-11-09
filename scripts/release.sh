#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/release-config.sh
# public (default): self-signed with SIGNING_NAME, for the curl installer. No Apple account involved.
# --local: ad-hoc signed test package. --notarized: Developer ID signed and notarized by Apple; the
# certificate carries the developer's legal name, so it is not the default.
mode=public
case "${1:-}" in
  --local) mode=local; shift ;;
  --notarized) mode=notarized; shift ;;
  --help|-h) echo 'Usage: [VERSION=x.y.z BUILD_NUMBER=N] bash scripts/release.sh [--local|--notarized]'; exit 0 ;;
esac
[[ $# -eq 0 ]] || { echo 'Unexpected arguments. Use --help.' >&2; exit 1; }
export VERSION="${VERSION:-0.2.4}" BUILD_NUMBER="${BUILD_NUMBER:-17}"
case "$mode" in
  local) export SIGN_IDENTITY=- ;;
  public)
    export SIGN_IDENTITY="${SIGN_IDENTITY:-$SIGNING_NAME}"
    security find-identity -p codesigning | grep -qF "\"$SIGN_IDENTITY\"" || { echo "No \"$SIGN_IDENTITY\" identity. Run scripts/create-signing-identity.sh, or restore your backup of it." >&2; exit 1; } ;;
  notarized)
    if [[ -z "${SIGN_IDENTITY:-}" ]]; then
      SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)"
    fi
    export SIGN_IDENTITY
    [[ "$SIGN_IDENTITY" = 'Developer ID Application: '* ]] || { echo 'Set SIGN_IDENTITY to your Developer ID Application certificate.' >&2; exit 1; }
    [[ -n "${NOTARY_PROFILE:-}" ]] || { echo 'Set NOTARY_PROFILE to a configured notarytool Keychain profile.' >&2; exit 1; } ;;
esac
bash scripts/build.sh
output="$PWD/dist/releases"
mkdir -p "$output"
suffix=""; if [[ "$mode" = local ]]; then suffix="-local"; fi
name="terminal-mac-$VERSION-$BUILD_NUMBER-macos-arm64$suffix"
archive="$output/$name.zip"
[[ ! -e "$archive" && ! -e "$archive.sha256" ]] || { echo "Release already exists: $archive. Increment BUILD_NUMBER; releases are immutable." >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-mac-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
payload="$work/$name"; mkdir -p "$payload"
ditto dist/TerminalMac.app "$payload/TerminalMac.app"
if [[ "$mode" = notarized ]]; then
  # Both independent apps need stapled tickets: the guest app is copied out on setup.
  guest="$payload/TerminalMac.app/Contents/Resources/guest-tools/TerminalMacGuest.app"
  ditto -c -k --sequesterRsrc --keepParent "$guest" "$work/guest.zip"
  xcrun notarytool submit "$work/guest.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$work/guest-notary.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/guest-notary.plist")" = Accepted ]] || { cat "$work/guest-notary.plist"; echo 'Guest notarization was not accepted.' >&2; exit 1; }
  xcrun stapler staple "$guest"
  xcrun stapler validate "$guest"
  # Re-seal the host after stapling its embedded, independently installed helper.
  codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements resources/terminal-mac.entitlements "$payload/TerminalMac.app"
  ditto -c -k --sequesterRsrc --keepParent "$payload/TerminalMac.app" "$work/host.zip"
  xcrun notarytool submit "$work/host.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist > "$work/host-notary.plist"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/host-notary.plist")" = Accepted ]] || { cat "$work/host-notary.plist"; echo 'Host notarization was not accepted.' >&2; exit 1; }
  xcrun stapler staple "$payload/TerminalMac.app"
  xcrun stapler validate "$payload/TerminalMac.app"
  spctl --assess --type execute --verbose=2 "$payload/TerminalMac.app"
fi
codesign --verify --deep --strict "$payload/TerminalMac.app"
cp scripts/install.sh "$payload/install.sh"
chmod +x "$payload/install.sh"
cat > "$payload/README.txt" <<'TEXT'
terminal-mac — a separate Mac for your agents

Install: bash install.sh
Run:     ~/.local/bin/terminal-mac

No Xcode or other runtime packages are required. First run downloads macOS
from Apple, creates a virtual Mac and guides its initial setup. In the guest,
complete macOS setup, open the bundled helper once and grant its privacy
permissions. Later runs reuse the VM. Ctrl+] exits inline viewing.

The guest has separate apps/accounts/files. VM data remains in your user
Library/Application Support/terminal-mac folder across CLI updates.
TEXT
if [[ "$mode" = local ]]; then echo 'LOCAL TEST BUILD: ad-hoc signed, not notarized; not a public release.' >> "$payload/README.txt"; fi
ditto -c -k --sequesterRsrc --keepParent "$payload" "$archive"
(cd "$output" && shasum -a 256 "$name.zip" > "$name.zip.sha256")
echo "Packaged ($mode): $archive"
# Upload-ready files: the archive and a curl installer pinned to its checksum.
if [[ -n "${GITHUB_REPO:-}" ]]; then
  [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]] || { echo 'GITHUB_REPO must be OWNER/NAME.' >&2; exit 1; }
  publish="$output/$name-publish"
  mkdir -p "$publish"
  tag="v$VERSION-$BUILD_NUMBER"
  sha="$(cut -d' ' -f1 "$archive.sha256")"
  render() {
    sed -e "s|@REPO@|$GITHUB_REPO|g" -e "s|@REPO_OWNER@|${GITHUB_REPO%%/*}|g" -e "s|@TAG@|$tag|g" -e "s|@ARCHIVE@|$name.zip|g" \
        -e "s|@VERSION@|$VERSION|g" -e "s|@BUILD@|$BUILD_NUMBER|g" -e "s|@SHA256@|$sha|g" "$1" > "$2"
  }
  cp "$archive" "$archive.sha256" "$publish/"
  render packaging/get.sh "$publish/get.sh"
  ! grep -q '@[A-Z_]*@' "$publish/get.sh" || { echo 'Unfilled template placeholder.' >&2; exit 1; }
  echo "Publish: GitHub release $tag in $GITHUB_REPO with every file in $publish. See RELEASING.md."
fi
