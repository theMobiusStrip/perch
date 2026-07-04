#!/bin/bash
set -euo pipefail

VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo 0.1.0)}"
VERSION="${VERSION#v}"
ARCH="$(uname -m)"
DMG_NAME="Perch-${VERSION}-${ARCH}.dmg"
BUILD_DIR="$(mktemp -d)"

trap 'rm -rf "$BUILD_DIR"' EXIT

if [ "${SKIP_BUILD:-}" != "1" ]; then
    echo "==> Building Perch ${VERSION} (${ARCH})…"
    make app
fi

echo "==> Creating DMG layout…"
mkdir -p "${BUILD_DIR}/dmg"
cp -R dist/Perch.app "${BUILD_DIR}/dmg/Perch.app"
ln -s /Applications "${BUILD_DIR}/dmg/Applications"

echo "==> Stamping version ${VERSION}…"
plutil -replace CFBundleShortVersionString -string "${VERSION}" \
    "${BUILD_DIR}/dmg/Perch.app/Contents/Info.plist"
# Editing Info.plist breaks the bundle seal; re-sign the stamped copy.
codesign --force -s - "${BUILD_DIR}/dmg/Perch.app"

echo "==> Creating DMG…"
# hdiutil create intermittently fails with "Resource busy" on GitHub runners.
for attempt in 1 2 3; do
    if hdiutil create \
        -volname "Perch ${VERSION}" \
        -srcfolder "${BUILD_DIR}/dmg" \
        -ov \
        -format UDZO \
        "dist/${DMG_NAME}"; then
        break
    fi
    if [ "$attempt" = 3 ]; then
        echo "hdiutil create failed after 3 attempts" >&2
        exit 1
    fi
    echo "==> hdiutil failed (attempt ${attempt}), retrying…" >&2
    sleep 5
done

echo "==> Generating checksums…"
cd dist
shasum -a 256 "${DMG_NAME}" > "${DMG_NAME}.sha256"
echo "SHA-256: $(cat "${DMG_NAME}.sha256")"

if command -v gpg &>/dev/null && gpg --list-secret-keys --keyid-format SHORT 2>/dev/null | grep -q sec; then
    echo "==> GPG signing checksum…"
    gpg --batch --yes --armor --detach-sign "${DMG_NAME}.sha256"
    echo "GPG signature: ${DMG_NAME}.sha256.asc"
else
    echo "==> Skipping GPG sign (no secret key found)"
fi

echo ""
echo "Done:"
echo "  dist/${DMG_NAME}"
echo "  dist/${DMG_NAME}.sha256"
# Plain `[ -f … ] && echo` as the last command would make the script exit 1
# whenever the .asc is absent (always true in CI, which has no GPG key).
if [ -f "${DMG_NAME}.sha256.asc" ]; then
    echo "  dist/${DMG_NAME}.sha256.asc"
fi
