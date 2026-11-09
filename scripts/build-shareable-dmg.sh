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
# Release copies update themselves with Sparkle from the feed in the Release
# configuration (MOSE_UPDATE_FEED_URL); scripts/publish-release.sh builds,
# signs and publishes a release with this script.
#
# Usage: scripts/build-shareable-dmg.sh
# Optional environment:
#   SIGNING_TEAM        team whose Apple Development certificate signs it (default: the project's team)
#   SHARED_BUNDLE_ID    bundle id of the shared copy (default: com.yewe.mose)
#   For local update tests only, without touching the project:
#   VERSION_OVERRIDE       MARKETING_VERSION to build instead of the project's (e.g. 1.1.9)
#   BUILD_NUMBER_OVERRIDE  CURRENT_PROJECT_VERSION to build instead of the project's
#   UPDATE_FEED_URL        the appcast this copy checks (e.g. http://127.0.0.1:8765/appcast.xml)
#   DMG_OUTPUT_FOLDER      where the DMG goes (default: releases/)
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
marketing_version="${VERSION_OVERRIDE:-$(read_app_build_setting MARKETING_VERSION)}"
build_number="${BUILD_NUMBER_OVERRIDE:-$(read_app_build_setting CURRENT_PROJECT_VERSION)}"
update_feed_url="${UPDATE_FEED_URL:-$(read_app_build_setting MOSE_UPDATE_FEED_URL)}"

# Built outside the home folder: libraries record their build paths in the
# binary, and the shared copy shouldn't carry the builder's username
build_folder="/private/tmp/shareable-app-build"
releases_folder="${DMG_OUTPUT_FOLDER:-$repository_root/releases}"
mkdir -p "$build_folder" "$releases_folder"

echo "Building version $marketing_version ($build_number) as $shared_bundle_id, signed by team $signing_team..."
echo "Checks for updates at: ${update_feed_url:-nowhere}"
# Manual signing with no provisioning profile: the app uses no entitlements
# that need one, and a development profile would stop it opening on other Macs.
xcodebuild \
  -project "$project_path" \
  -scheme leanring-buddy \
  -configuration Release \
  -derivedDataPath "$build_folder/DerivedData" \
  PRODUCT_BUNDLE_IDENTIFIER="$shared_bundle_id" \
  MARKETING_VERSION="$marketing_version" \
  CURRENT_PROJECT_VERSION="$build_number" \
  MOSE_UPDATE_FEED_URL="$update_feed_url" \
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

built_info_plist="$app_path/Contents/Info.plist"
built_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$built_info_plist" 2>/dev/null || true)"
built_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$built_info_plist" 2>/dev/null || true)"
if [[ "$built_feed_url" != "$update_feed_url" || -z "$built_public_key" ]]; then
  echo "❌ The app's update feed or public key is wrong (feed: '$built_feed_url')" >&2
  exit 1
fi

dmg_path="$releases_folder/$product_name-$marketing_version.dmg"
dmg_staging_folder="$(mktemp -d)"
cp -R "$app_path" "$dmg_staging_folder/"
ln -s /Applications "$dmg_staging_folder/Applications"
rm -f "$dmg_path"
hdiutil create -volname "$product_name $marketing_version" -srcfolder "$dmg_staging_folder" -ov -format UDZO "$dmg_path" > /dev/null
rm -rf "$dmg_staging_folder"
codesign --sign "$signing_authority" "$dmg_path"

echo "✅ $dmg_path ($(du -h "$dmg_path" | cut -f1))"
