# Releasing

How to cut a new version: an **Apple Silicon (arm64)**, Developer ID–signed,
Apple-notarized, stapled `.app`, published as a GitHub Release. Targets the
latest macOS release.

The build/sign/notarize/staple mechanics live in [`scripts/make-release.sh`](../scripts/make-release.sh).
This runbook covers the whole flow around it, so a fresh agent (or a fresh machine)
can repeat it end to end.

Key constants:

- **Team ID:** `7H2524M5TN`
- **Notary keychain profile:** `claude-usage-notary` (shared with AI Spend Tracker —
  it's Apple credentials, not app-specific)
- **GitHub repo:** `chris-spare/voiceop`
- App / bundle / zip names come from `Resources/Info.plist` and `scripts/make-release.sh`.
  The commands below use the current names; if it's renamed again, the script prints
  the exact output paths.

## One-time setup (per machine)

Only needed once on a given Mac. Skip if both of these already work:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"   # prints an identity
xcrun notarytool history --keychain-profile claude-usage-notary              # succeeds (not an auth error)
```

Otherwise:

1. **Developer ID Application certificate** — needs an Apple Developer Program
   membership ($99/yr). In Xcode → Settings → Accounts → your Apple ID →
   **Manage Certificates…** → **+** → **Developer ID Application**.
   - If Apple returns *"Unable to process request — PLA Update available"*, accept the
     latest agreement at <https://developer.apple.com/account> (Membership/Agreements),
     wait a minute, then retry.

2. **Notarization credentials** stored under the `claude-usage-notary` profile:
   - Create an app-specific password at <https://appleid.apple.com> → Sign-In &
     Security → **App-Specific Passwords**.
   - Store it (paste the password at the hidden prompt):
     ```bash
     xcrun notarytool store-credentials "claude-usage-notary" \
       --apple-id "<your-apple-id-email>" --team-id 7H2524M5TN
     ```

## Cutting a release

The commands below derive the app/zip/title from `Resources/Info.plist` and the
build output, so they keep working if the app is renamed. Run them from the repo root.

0. **Make sure the tree is releasable.** `git status` should be clean and pushed. If
   there are uncommitted code changes, commit and push them first (a release should
   correspond to a real commit on `main`) — or, if you're unsure whether they're ready,
   ask the user before releasing.

1. **Bump the version.**
   ```bash
   ./scripts/bump-version.sh          # next patch on the current release line
   ./scripts/bump-version.sh 0.2      # or open a new MAJOR.MINOR line
   ```
   It allocates the next patch from the build counter and writes both
   `CFBundleShortVersionString` and `CFBundleVersion` into `Resources/Info.plist`.
   That counter is shared with local `make-app.sh` builds, so a release version is
   never one a local build has already shown in its menu, and the patch component
   will *jump* — it counts builds, not releases. Commit and push (the release must
   correspond to a real commit on `main`, and `make-release.sh` builds exactly the
   version recorded here):
   ```bash
   git add Resources/Info.plist
   git commit -m "Bump version to X.Y.Z"
   git push origin main
   ```
   Only edit the file by hand if you must, and then **as text** — PlistBuddy is fine
   for *reading* (as below) but `-c Set` rewrites the whole file: it alphabetizes the
   keys, converts the indentation to tabs, and silently deletes the XML comments.

2. **Build + notarize + staple:**
   ```bash
   ./scripts/make-release.sh
   ```
   It builds the arm64 binary (with the Kokoro server files in `Resources/kokoro`),
   signs with Developer ID, submits to Apple, waits
   for notarization, staples, and writes the distributable zip — printing its path at
   the end (`distributable: build/…zip`).
   - **This can run for up to ~an hour and looks idle while it waits on Apple.** Run it
     in the background and do **not** kill it — notarization time is Apple-side (usually
     a few minutes, occasionally 30–60 min when their queue is backed up).
   - **Don't run a debug build (`make-app.sh`) while this is in flight.** The release
     builds into `build/release/` to avoid a collision, and aborts if the signed
     bundle changes before stapling.

   Derive the exact output paths from `Info.plist` — **don't glob `build/`**, it
   accumulates stale `.app`s and `.zip`s from earlier builds/renames, so a glob
   returns several matches. `CFBundleName` is the `.app`; `CFBundleExecutable` is the
   zip stem and the inner binary. (These are also printed by the script at the end.)

3. **Verify the artifact** (the script checks internally; confirm independently):
   ```bash
   NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' Resources/Info.plist)
   EXE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' Resources/Info.plist)
   APP="build/release/$NAME.app"
   lipo -archs "$APP/Contents/MacOS/$EXE"   # expect: arm64
   ls "$APP/Contents/Resources/kokoro"      # expect: blocked_voices.json kokoro_server.py requirements.txt
   xcrun stapler validate "$APP"            # expect: The validate action worked!
   spctl -a -vvv -t install "$APP"          # expect: accepted / source=Notarized Developer ID
   ```

4. **Publish the GitHub Release.** Tag `vX.Y.Z` matches the version; keep older
   releases — don't delete them.
   ```bash
   NAME=$(/usr/libexec/PlistBuddy -c 'Print CFBundleName' Resources/Info.plist)
   EXE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' Resources/Info.plist)
   VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
   gh release create "v$VER" \
     "build/$EXE.zip#$NAME.app (Apple Silicon, notarized)" \
     --repo chris-spare/voiceop \
     --target main \
     --title "$NAME v$VER" \
     --notes "What changed, plus install steps."
   ```

5. **Confirm the asset uploaded:**
   ```bash
   VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
   gh release view "v$VER" --repo chris-spare/voiceop \
     --json assets --jq '.assets[] | {name, state}'
   ```

## Installing on another Mac

Download the zip from the release → unzip → drag the `.app` into `/Applications` →
open it (first launch shows a one-time *"downloaded from the internet → Open"*).
It's stapled, so it also verifies offline.

## Gotchas

- **Stapling fails with "Record not found" right after acceptance** — Apple's ticket
  CDN is lagging. The script retries for ~20 min. If it still fails, notarization
  itself already succeeded; just re-run `xcrun stapler staple "<app>"` a few minutes
  later, then re-zip.
- **`spctl`/Gatekeeper rejects the app on the other Mac** — it wasn't notarized or
  wasn't stapled. Re-run the release; don't hand-sign around it.
- **The patch number is a build counter, not a release counter.** It lives in the
  untracked `.build-number` and every `make-app.sh` build takes one, so consecutive
  releases are not consecutive versions. Nothing is wrong; the numbers only have to
  rise. If the file is missing (fresh clone) the counter resumes from the version in
  the committed `Info.plist`, which is why step 1 commits it.
- **`make-release.sh` builds whatever version `Info.plist` records** — it never
  allocates one. Skipping step 1 therefore re-releases the version already published,
  and `gh release create` then fails on the existing tag. Run `bump-version.sh` first.
