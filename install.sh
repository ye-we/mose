#!/bin/bash
# Installs or updates Mose (github.com/ye-we/mose) on this Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/ye-we/mose/main/install.sh | bash
#
# It reads the newest version from Mose's update feed (appcast.xml), downloads
# that release's DMG from GitHub, checks the app is signed by Mose's developer
# (team ZBYTA87RP2), copies it into /Applications (or ~/Applications if that
# isn't writable) and opens it. Mose isn't notarized by Apple, so a DMG
# downloaded in a browser has to be allowed under Privacy & Security; a
# download by curl isn't marked as downloaded, so there's nothing to allow.
# After that, Mose updates itself.
#
# For testing: MOSE_INSTALL_FOLDER=/some/folder installs there, and
# MOSE_INSTALL_DONT_OPEN=1 leaves it closed.
set -euo pipefail

update_feed_url="https://raw.githubusercontent.com/ye-we/mose/main/appcast.xml"
expected_download_prefix="https://github.com/ye-we/mose/releases/download/"
expected_team_identifier="ZBYTA87RP2"
expected_bundle_identifier="com.yewe.mose"

fail() {
  printf 'Mose install: %s\n' "$*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Mose is a Mac app."
macos_version="$(sw_vers -productVersion)"
macos_major_version="${macos_version%%.*}"
macos_minor_version="$(echo "$macos_version" | cut -d. -f2)"
if (( macos_major_version < 14 || (macos_major_version == 14 && ${macos_minor_version:-0} < 2) )); then
  fail "Mose needs macOS 14.2 or later; this Mac has $macos_version."
fi

# The newest release is the first item in the feed
update_feed_text="$(curl -fsSL "$update_feed_url")" || fail "couldn't reach $update_feed_url"
dmg_url="$(printf '%s\n' "$update_feed_text" | grep -o 'enclosure url="[^"]*"' | head -1 | sed -e 's/^enclosure url="//' -e 's/"$//')"
newest_version="$(printf '%s\n' "$update_feed_text" | grep -o '<sparkle:shortVersionString>[^<]*' | head -1 | sed 's/.*>//')"
[[ "$dmg_url" == "$expected_download_prefix"* ]] || fail "couldn't find the newest version in the update feed"

work_folder="$(mktemp -d)"
mount_point="$work_folder/mounted"
cleanup() {
  if [[ -d "$mount_point" ]]; then
    hdiutil detach "$mount_point" -quiet 2> /dev/null || hdiutil detach "$mount_point" -force -quiet 2> /dev/null || true
  fi
  rm -rf "$work_folder"
}
trap cleanup EXIT

echo "Downloading Mose $newest_version..."
curl -fL --progress-bar -o "$work_folder/Mose.dmg" "$dmg_url" || fail "the download failed"

mkdir -p "$mount_point"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount_point" "$work_folder/Mose.dmg" > /dev/null \
  || fail "couldn't open the downloaded DMG"
downloaded_app_path="$mount_point/Mose.app"
[[ -d "$downloaded_app_path" ]] || fail "the DMG has no Mose.app"

# The download came over HTTPS from GitHub; this also checks it's really
# Mose, signed by its developer and unchanged since.
codesign --verify --deep --strict "$downloaded_app_path" 2> /dev/null || fail "the app's signature doesn't check out; nothing was installed"
signing_team_identifier="$(codesign -dv "$downloaded_app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[[ "$signing_team_identifier" == "$expected_team_identifier" ]] || fail "the app isn't signed by Mose's developer; nothing was installed"
downloaded_bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$downloaded_app_path/Contents/Info.plist")"
[[ "$downloaded_bundle_identifier" == "$expected_bundle_identifier" ]] || fail "unexpected app ($downloaded_bundle_identifier); nothing was installed"

if [[ -n "${MOSE_INSTALL_FOLDER:-}" ]]; then
  install_folder="$MOSE_INSTALL_FOLDER"
  mkdir -p "$install_folder"
elif [[ -w /Applications ]]; then
  install_folder="/Applications"
else
  install_folder="$HOME/Applications"
  mkdir -p "$install_folder"
fi
installed_app_path="$install_folder/Mose.app"

# A running Mose is asked to quit, the way its Quit menu does
if [[ -z "${MOSE_INSTALL_FOLDER:-}" ]] && [[ "$(osascript -e "application id \"$expected_bundle_identifier\" is running" 2> /dev/null)" == "true" ]]; then
  echo "Quitting the Mose that's running..."
  osascript -e "tell application id \"$expected_bundle_identifier\" to quit" > /dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ "$(osascript -e "application id \"$expected_bundle_identifier\" is running" 2> /dev/null)" == "true" ]] || break
    sleep 1
  done
fi

# Copied next to the old one first, so a failed copy never leaves no Mose
staging_app_path="$install_folder/.Mose-installing.app"
rm -rf "$staging_app_path"
ditto "$downloaded_app_path" "$staging_app_path" || fail "couldn't copy Mose into $install_folder"
if [[ -e "$installed_app_path" ]]; then
  rm -rf "$installed_app_path" || { rm -rf "$staging_app_path"; fail "couldn't replace $installed_app_path"; }
fi
mv "$staging_app_path" "$installed_app_path"

echo "Installed Mose $newest_version in $install_folder."
if [[ -z "${MOSE_INSTALL_DONT_OPEN:-}" ]]; then
  open "$installed_app_path"
  echo "Mose is opening; its setup walks you through the rest. From now on it updates itself."
fi
