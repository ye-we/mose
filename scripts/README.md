# Release scripts

## `publish-release.sh`: ship a new version of Mose

A release is two steps, so the DMG can be tried before anyone gets it:

```bash
scripts/publish-release.sh build 1.3 5              # set the versions, build and check the DMG, sign it for Sparkle
scripts/publish-release.sh publish 1.3 notes.md     # commit, push, GitHub release, then add it to appcast.xml
```

- `1.3` is `MARKETING_VERSION`; `5` is `CURRENT_PROJECT_VERSION`, the build number Sparkle compares. It must be higher than every build already in `appcast.xml`, or nobody is offered the update.
- `build` makes `releases/Mose-1.3.dmg` with `build-shareable-dmg.sh`, checks it (versions, bundle id, update feed, public key, code signature, no `/Users/` paths or debug hooks, `hdiutil verify`) and signs it with Sparkle's `sign_update` (the key is in the login keychain, account `mose`).
- `publish` adds the release to the feed only after the DMG is on GitHub and downloads back with the same SHA-256. `notes.md` is markdown, shown on the release page and in Mose's update window.
- Back up the Sparkle key once: `generate_keys --account mose -x FILE`, kept somewhere safe. Without it no update can ever be signed again.

`AGENTS.md` ("Releasing") has the full steps, including testing an update locally.

## `build-shareable-dmg.sh`

Builds the universal, signed release copy (`com.yewe.mose`) and its DMG. `VERSION_OVERRIDE`, `BUILD_NUMBER_OVERRIDE`, `UPDATE_FEED_URL` and `DMG_OUTPUT_FOLDER` build an older test copy pointed at a local feed without touching the project.

## `appcast/`

The `appcast` command (`add`, `list`, `empty`) that edits `appcast.xml`; `scripts/run-sketch-tests.sh` tests its pure part (`Appcast.swift`).
