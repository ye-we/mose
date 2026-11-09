#!/usr/bin/env bash
# Releases a new version of Mose in two steps, so the DMG can be tried before
# anyone gets it:
#
#   scripts/publish-release.sh build 1.3 5
#     Sets MARKETING_VERSION to 1.3 and CURRENT_PROJECT_VERSION (the build
#     number Sparkle compares; it must go up every release) to 5, builds
#     releases/Mose-1.3.dmg with build-shareable-dmg.sh, checks it, and signs
#     it with the Sparkle key in the login keychain (sign_update).
#
#   scripts/publish-release.sh publish 1.3 path/to/notes.md
#     Commits the version bump (when that's the only change), fast-forwards
#     main, pushes both branches, creates the GitHub release with the DMG,
#     downloads it back to compare, and only then adds the release to
#     appcast.xml and pushes that, so the feed never offers a DMG that isn't
#     there yet. Everyone on 1.2 or later is offered it within a day.
#
# The notes (markdown) go on the GitHub release and in Sparkle's update window.
# The private key never leaves the keychain: sign_update reads it there. Back
# it up once with generate_keys --account mose -x FILE; without it, no
# release can be signed again and nobody gets updates.
#
# Pushes and releases go to github.com/ye-we/mose with the ye-we token from
# gh, whatever gh's active account is.
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$repository_root/leanring-buddy.xcodeproj/project.pbxproj"
appcast_path="$repository_root/appcast.xml"
releases_folder="$repository_root/releases"
release_bundle_id="com.yewe.mose"
release_feed_url="https://raw.githubusercontent.com/ye-we/mose/main/appcast.xml"
github_repository="ye-we/mose"
github_account="ye-we"
release_branch="feature/claude-code-app"
sparkle_key_account="mose"
minimum_macos_version="14.2"

fail() {
  echo "❌ $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 build VERSION BUILD_NUMBER" >&2
  echo "       $0 publish VERSION NOTES_FILE" >&2
  exit 2
}

find_sparkle_tools() {
  local candidate
  for candidate in \
    /private/tmp/shareable-app-build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin \
    "$HOME"/Library/Developer/Xcode/DerivedData/leanring-buddy-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
    if [[ -x "$candidate/sign_update" ]]; then
      echo "$candidate"
      return
    fi
  done
  fail "Sparkle's sign_update wasn't found. Build the project in Xcode once so Swift Package Manager downloads Sparkle."
}

project_setting() {
  # The app target's value (every target carries the same versions)
  awk -v setting_name="$1" '$1 == setting_name { gsub(/[";]/, "", $3); print $3; exit }' "$project_file"
}

build_appcast_tool() {
  local appcast_tool_path
  appcast_tool_path="$(mktemp -d)/appcast"
  swiftc -o "$appcast_tool_path" "$repository_root/scripts/appcast/Appcast.swift" "$repository_root/scripts/appcast/main.swift"
  echo "$appcast_tool_path"
}

highest_build_number_in_feed() {
  local appcast_tool_path="$1"
  "$appcast_tool_path" list --feed "$appcast_path" | awk '{ print $3 }' | sort -n | tail -1
}

sha256_of() {
  shasum -a 256 "$1" | awk '{ print $1 }'
}

# Pushing as ye-we without switching gh's active account
git_as_github_account() {
  git -c credential.helper= \
    -c "credential.helper=!f() { echo username=$github_account; echo \"password=\$(gh auth token -u $github_account)\"; }; f" \
    "$@"
}

push_both_branches() {
  # GitHub sometimes answers a push with "Internal Server Error"; again works.
  local attempt
  for attempt in 1 2 3; do
    if git_as_github_account -C "$repository_root" push origin main "$release_branch"; then
      return
    fi
    echo "Push failed (attempt $attempt), trying again..."
    sleep 3
  done
  fail "Couldn't push to origin"
}

# Mounts the DMG and checks the app inside: versions, bundle id, update feed
# and key, signature, and nothing private or debug-only in the binary.
check_dmg() {
  local dmg_path="$1" expected_version="$2" expected_build_number="$3" expected_public_key="$4"
  local mount_point app_path info_plist binary_path problem=""
  hdiutil verify "$dmg_path" > /dev/null 2>&1 || fail "hdiutil verify failed for $dmg_path"
  # Gatekeeper refuses to open a DMG signed with a development certificate
  if codesign -dv "$dmg_path" > /dev/null 2>&1; then fail "$dmg_path is code-signed; macOS would block it before it opens"; fi
  mount_point="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mount_point" "$dmg_path" > /dev/null
  app_path="$mount_point/Mose.app"
  info_plist="$app_path/Contents/Info.plist"
  binary_path="$app_path/Contents/MacOS/Mose"
  plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$info_plist" 2>/dev/null || true; }

  [[ -d "$app_path" ]] || problem="no Mose.app in the DMG"
  [[ -z "$problem" && "$(plist_value CFBundleShortVersionString)" != "$expected_version" ]] && problem="version is $(plist_value CFBundleShortVersionString), not $expected_version"
  [[ -z "$problem" && "$(plist_value CFBundleVersion)" != "$expected_build_number" ]] && problem="build is $(plist_value CFBundleVersion), not $expected_build_number"
  [[ -z "$problem" && "$(plist_value CFBundleIdentifier)" != "$release_bundle_id" ]] && problem="bundle id is $(plist_value CFBundleIdentifier)"
  [[ -z "$problem" && "$(plist_value SUFeedURL)" != "$release_feed_url" ]] && problem="update feed is '$(plist_value SUFeedURL)'"
  [[ -z "$problem" && "$(plist_value SUPublicEDKey)" != "$expected_public_key" ]] && problem="SUPublicEDKey doesn't match the key in the keychain"
  [[ -z "$problem" && "$(plist_value SUEnableSystemProfiling)" != "false" ]] && problem="system profiling isn't off"
  if [[ -z "$problem" ]] && ! codesign --verify --deep --strict "$app_path" 2> /dev/null; then problem="the app's code signature doesn't verify"; fi
  if [[ -z "$problem" ]] && strings "$binary_path" | grep -q "/Users/"; then problem="the binary contains a /Users/ path"; fi
  if [[ -z "$problem" ]] && strings "$binary_path" | grep -q "com.clicky.debug"; then problem="the binary contains the debug hooks"; fi

  hdiutil detach "$mount_point" -quiet || hdiutil detach "$mount_point" -force -quiet || true
  rmdir "$mount_point" 2> /dev/null || true
  [[ -z "$problem" ]] || fail "$dmg_path: $problem"
}

build_release() {
  local version="$1" build_number="$2"
  local appcast_tool_path highest_build_number sparkle_tools public_key dmg_path signature_path

  [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "VERSION should look like 1.3 or 1.3.1"
  [[ "$build_number" =~ ^[0-9]+$ ]] || fail "BUILD_NUMBER should be a whole number"

  appcast_tool_path="$(build_appcast_tool)"
  highest_build_number="$(highest_build_number_in_feed "$appcast_tool_path")"
  if [[ -n "$highest_build_number" ]] && (( build_number <= highest_build_number )); then
    fail "Build $build_number isn't higher than build $highest_build_number in appcast.xml, so Sparkle would never offer it"
  fi
  if git -C "$repository_root" rev-parse -q --verify "refs/tags/v$version" > /dev/null; then
    fail "Tag v$version already exists"
  fi

  sparkle_tools="$(find_sparkle_tools)"
  public_key="$("$sparkle_tools/generate_keys" --account "$sparkle_key_account" -p 2> /dev/null || true)"
  [[ -n "$public_key" && "$public_key" != *ERROR* ]] || fail "No Sparkle key for account '$sparkle_key_account' in the login keychain"

  # Every target carries the same two versions
  sed -i '' -E \
    -e "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $version;/" \
    -e "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $build_number;/" \
    "$project_file"
  [[ "$(project_setting MARKETING_VERSION)" == "$version" && "$(project_setting CURRENT_PROJECT_VERSION)" == "$build_number" ]] \
    || fail "Couldn't set the versions in project.pbxproj"

  "$repository_root/scripts/build-shareable-dmg.sh"

  dmg_path="$releases_folder/Mose-$version.dmg"
  [[ -f "$dmg_path" ]] || fail "No DMG at $dmg_path"
  check_dmg "$dmg_path" "$version" "$build_number" "$public_key"

  # The signature and length go in the appcast item; neither is secret.
  signature_path="$dmg_path.sparkle-signature"
  "$sparkle_tools/sign_update" --account "$sparkle_key_account" "$dmg_path" > "$signature_path"
  local ed_signature
  ed_signature="$(sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/' "$signature_path")"
  "$sparkle_tools/sign_update" --account "$sparkle_key_account" --verify "$dmg_path" "$ed_signature" > /dev/null 2>&1 \
    || fail "The EdDSA signature doesn't verify"

  echo
  echo "✅ Built and signed $dmg_path"
  echo "   version $version, build $build_number, $(du -h "$dmg_path" | cut -f1)"
  echo "   SHA-256 $(sha256_of "$dmg_path")"
  echo "   $(cat "$signature_path")"
  echo "Try it, then: $0 publish $version NOTES_FILE"
}

publish_release() {
  local version="$1" notes_path="$2"
  local dmg_path signature_path sparkle_tools public_key build_number ed_signature
  local unexpected_changes release_commit local_sha downloaded_folder downloaded_sha appcast_tool_path

  [[ -f "$notes_path" ]] || fail "No notes file at $notes_path"
  dmg_path="$releases_folder/Mose-$version.dmg"
  signature_path="$dmg_path.sparkle-signature"
  [[ -f "$dmg_path" && -f "$signature_path" ]] || fail "Run '$0 build $version BUILD_NUMBER' first"
  [[ "$(git -C "$repository_root" branch --show-current)" == "$release_branch" ]] || fail "Publish from $release_branch"
  [[ "$(project_setting MARKETING_VERSION)" == "$version" ]] || fail "project.pbxproj isn't at version $version"
  build_number="$(project_setting CURRENT_PROJECT_VERSION)"

  sparkle_tools="$(find_sparkle_tools)"
  public_key="$("$sparkle_tools/generate_keys" --account "$sparkle_key_account" -p 2> /dev/null || true)"
  check_dmg "$dmg_path" "$version" "$build_number" "$public_key"
  ed_signature="$(sed -E 's/.*sparkle:edSignature="([^"]+)".*/\1/' "$signature_path")"
  "$sparkle_tools/sign_update" --account "$sparkle_key_account" --verify "$dmg_path" "$ed_signature" > /dev/null 2>&1 \
    || fail "The DMG changed since it was signed; build it again"

  # Only the version bump may be uncommitted (HANDOFF.txt and Xcode's user
  # data are never committed). Anything else should be committed first, so
  # the tag matches what was built.
  unexpected_changes="$(git -C "$repository_root" status --porcelain \
    | grep -v -E '^\?\? (HANDOFF\.txt|leanring-buddy\.xcodeproj/xcuserdata/)' \
    | grep -v -E '^ M leanring-buddy\.xcodeproj/project\.pbxproj$' || true)"
  [[ -z "$unexpected_changes" ]] || fail "Commit these first:
$unexpected_changes"
  if ! git -C "$repository_root" diff --quiet -- "$project_file"; then
    if git -C "$repository_root" diff -U0 -- "$project_file" | grep -E '^[-+][^-+]' | grep -v -q -E 'MARKETING_VERSION|CURRENT_PROJECT_VERSION'; then
      fail "project.pbxproj has changes besides the versions; commit them first"
    fi
    git -C "$repository_root" commit -q -m "Release $version" -- "$project_file"
  fi
  if [[ -n "$(git -C "$repository_root" ls-remote --tags origin "refs/tags/v$version")" ]]; then
    fail "Tag v$version is already on GitHub"
  fi
  git -C "$repository_root" fetch -q . "$release_branch:main"
  release_commit="$(git -C "$repository_root" rev-parse HEAD)"
  push_both_branches

  echo "Creating the GitHub release v$version at $release_commit..."
  GH_TOKEN="$(gh auth token -u "$github_account")" gh release create "v$version" "$dmg_path" \
    --repo "$github_repository" \
    --target "$release_commit" \
    --title "Mose $version" \
    --notes-file "$notes_path" \
    --latest

  # Compare what people will download with what was built and signed
  local_sha="$(sha256_of "$dmg_path")"
  downloaded_folder="$(mktemp -d)"
  GH_TOKEN="$(gh auth token -u "$github_account")" gh release download "v$version" \
    --repo "$github_repository" --pattern "Mose-$version.dmg" --dir "$downloaded_folder"
  downloaded_sha="$(sha256_of "$downloaded_folder/Mose-$version.dmg")"
  rm -rf "$downloaded_folder"
  [[ "$downloaded_sha" == "$local_sha" ]] || fail "The DMG on GitHub ($downloaded_sha) isn't the one built ($local_sha); the feed was NOT updated"

  # Only now does the feed offer it
  appcast_tool_path="$(build_appcast_tool)"
  "$appcast_tool_path" add \
    --feed "$appcast_path" \
    --version "$version" \
    --build "$build_number" \
    --dmg-url "https://github.com/$github_repository/releases/download/v$version/Mose-$version.dmg" \
    --sign-update-output "$(cat "$signature_path")" \
    --notes-file "$notes_path" \
    --notes-page "https://github.com/$github_repository/releases/tag/v$version" \
    --minimum-macos "$minimum_macos_version"
  git -C "$repository_root" commit -q -m "Offer $version to Mose's updater" -- "$appcast_path"
  git -C "$repository_root" fetch -q . "$release_branch:main"
  push_both_branches

  echo
  echo "✅ Mose $version is out: https://github.com/$github_repository/releases/tag/v$version"
  echo "   SHA-256 $local_sha"
  echo "   The feed ($release_feed_url) may take a few minutes to refresh."
}

case "${1:-}" in
  build)
    [[ $# -eq 3 ]] || usage
    build_release "$2" "$3"
    ;;
  publish)
    [[ $# -eq 3 ]] || usage
    publish_release "$2" "$3"
    ;;
  *)
    usage
    ;;
esac
