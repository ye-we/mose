#!/usr/bin/env bash
# Builds a copy of the app that other people can install, and wraps it in a
# DMG with an Applications shortcut to drag it onto.
#
# It's signed with a free Apple Development certificate (any Apple ID added
# to Xcode has one), not a paid Developer ID, so it isn't notarized: the
# first time someone opens it, macOS says it can't check the app and they
# allow it once under System Settings → Privacy & Security → Open Anyway.
# Because the signing identity stays the same from build to build, people
# keep their permissions (Accessibility, Screen Recording) across updates.
#
# The shared copy has its own bundle id, so it never mixes its settings or
# permissions with the copy you run from Xcode.
#
# Usage: scripts/build-shareable-dmg.sh
# Optional environment:
#   SIGNING_TEAM        team whose Apple Development certificate signs it (default: the project's team)
#   SHARED_BUNDLE_ID    bundle id of the shared copy (default: com.yewe.mose)
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
project_path="$repository_root/leanring-buddy.xcodeproj"

# The app target's own settings (the test targets have a different team)
app_build_settings="$(xcodebuild -project "$project_path" -scheme leanring-buddy -configuration Release -showBuildSettings 2>/dev/null)"
read_app_build_setting() {
  echo "$app_build_settings" | awk -v setting_name="$1" '$1 == setting_name && $2 == "=" { print $3; exit }'
}
signing_team="${SIGNING_TEAM:-$(read_app_build_setting DEVELOPMENT_TEAM)}"
shared_bundle_id="${SHARED_BUNDLE_ID:-com.yewe.mose}"
product_name="$(read_app_build_setting PRODUCT_NAME)"
marketing_version="$(read_app_build_setting MARKETING_VERSION)"
build_number="$(read_app_build_setting CURRENT_PROJECT_VERSION)"

# Built outside the home folder: libraries record their build paths in the
# binary, and the shared copy shouldn't carry the builder's username
build_folder="/private/tmp/shareable-app-build"
releases_folder="$repository_root/releases"
mkdir -p "$build_folder" "$releases_folder"

echo "Building version $marketing_version ($build_number) as $shared_bundle_id, signed by team $signing_team..."
# Manual signing with no provisioning profile: the app uses no entitlements
# that need one, and a development profile would stop it opening on other Macs.
xcodebuild \
  -project "$project_path" \
  -scheme leanring-buddy \
  -configuration Release \
  -derivedDataPath "$build_folder/DerivedData" \
  PRODUCT_BUNDLE_IDENTIFIER="$shared_bundle_id" \
  DEVELOPMENT_TEAM="$signing_team" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Development" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  build 2>&1 | grep -E "error:|warning: .*[Ss]ign|BUILD (SUCCEEDED|FAILED)" || true

app_path="$build_folder/DerivedData/Build/Products/Release/$product_name.app"
if [[ ! -d "$app_path" ]]; then
  echo "❌ The build didn't produce $product_name.app" >&2
  exit 1
fi
if [[ -e "$app_path/Contents/embedded.provisionprofile" ]]; then
  echo "❌ The app embeds a provisioning profile, so it would only open on this Mac" >&2
  exit 1
fi

codesign --verify --deep --strict "$app_path"
signing_authority="$(codesign -dvv "$app_path" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2 || true)"
if [[ -z "$signing_authority" ]]; then
  echo "❌ The app isn't signed with a certificate" >&2
  exit 1
fi
echo "Signed by: $signing_authority"
echo "Runs on: $(lipo -archs "$app_path/Contents/MacOS/$product_name")"

dmg_path="$releases_folder/$product_name-$marketing_version.dmg"
dmg_staging_folder="$(mktemp -d)"
cp -R "$app_path" "$dmg_staging_folder/"
ln -s /Applications "$dmg_staging_folder/Applications"
rm -f "$dmg_path"
hdiutil create -volname "$product_name $marketing_version" -srcfolder "$dmg_staging_folder" -ov -format UDZO "$dmg_path" > /dev/null
rm -rf "$dmg_staging_folder"
codesign --sign "$signing_authority" "$dmg_path"

echo "✅ $dmg_path ($(du -h "$dmg_path" | cut -f1))"
