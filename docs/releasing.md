# Releasing Remora

A release is a pushed `vX.Y.Z` tag. The tag push runs [the release workflow](../.github/workflows/release.yml), which builds, signs, notarizes and publishes the DMG and its Sparkle update feed as a GitHub release. The signing credentials live in the `Remora` vault in 1Password, and `mise run release:secrets` copies them to GitHub.

## Make a release

1. Switch to `main` and bring it up to date with `git switch main && git pull --ff-only`. The tag goes on `HEAD`.
2. Preview the next version with `mise run release:preview minor`. Use `major`, `minor` or `patch`. The JSON output shows the version and the tag.
3. Read the release notes with `mise run release:notes`. [cliff.toml](../cliff.toml) groups the Conventional Commits since the last release.
4. Create and push the tag with `mise run release:tag 0.2.0`, using the version that the preview printed. The task fetches `main` from origin first and stops unless `HEAD` is that exact commit, so a local commit that never merged cannot become a release. Only a repository admin can create a `v*` tag.
5. Find the run with `gh run list --workflow release.yml --branch v0.2.0`, and follow it with `gh run watch <run-id> --exit-status`.

The workflow has three jobs:

- `validate` checks the tag with Tagsmith against [.tagsmith.jsonc](../.tagsmith.jsonc).
- `build` first runs `mise run release:keys --private`, which stops the run unless both Sparkle keys are set. It builds the RDP and VNC engines from scratch, signs the app with the Developer ID certificate, and builds and signs the DMG. It then notarizes and staples the DMG, assesses it with Gatekeeper and writes `SHA256SUMS`. Last, `release:appcast` runs Sparkle's `generate_appcast` on the notarized DMG, embeds the release notes, and keeps `appcast.xml` only if its signature verifies with the public key in the app inside the DMG.
- `publish` creates the GitHub release.

The release appears at `https://github.com/sadiksaifi/remora/releases/tag/v0.2.0` with the title `Remora 0.2.0`. It holds `Remora-0.2.0-macos-arm64.dmg`, `SHA256SUMS` and `appcast.xml`. The notes start with a download badge, followed by the notes from `mise run release:notes:tag v0.2.0`. The release is marked latest, so `https://github.com/sadiksaifi/remora/releases/latest` serves it. Installed copies of Remora read their feed from `https://github.com/sadiksaifi/remora/releases/latest/download/appcast.xml`, so they see the new version as soon as the release is published.

If the tag push fails, `release:tag` keeps the local tag and refuses to create it again. Push it with `git push origin refs/tags/v0.2.0`.

### Rewrite the notes

The notes of v0.1.0 print the placeholder `First release of Remora.`. Write the real notes after the release is published:

```sh
gh release view v0.1.0 --json body --jq .body > notes.md
# Edit notes.md. Keep the download badge on the first line.
gh release edit v0.1.0 --notes-file notes.md
```

The same commands rewrite the notes of any release.

## Rehearse before the first release

A manual run on `main` builds, signs and notarizes version `0.0.0` and writes its appcast without creating a release. Run it after the secrets and the Sparkle public key are first set, and again after any credential changes. Until both Sparkle keys are set, it stops at `release:keys`.

```sh
run=$(gh api --hostname github.com --method POST repos/sadiksaifi/remora/actions/workflows/release.yml/dispatches -f ref=main --jq .workflow_run_id)
gh run watch "$run" --repo github.com/sadiksaifi/remora --exit-status
gh run download "$run" --repo github.com/sadiksaifi/remora --name Remora-0.0.0 --dir build/rehearsal
spctl --assess --type open --context context:primary-signature --verbose=2 build/rehearsal/Remora-0.0.0-macos-arm64.dmg
```

The dispatch API returns the ID of the run it started, so the commands follow that run and no other. `--exit-status` makes `gh run watch` fail when the run fails.

The DMG and its `appcast.xml` stay on the run as an artifact for 14 days. A rehearsal skips the `validate` and `publish` jobs, so it does not test the release notes or `gh release create`.

## Fix a broken release

Release tags are immutable. Two rulesets cover `refs/tags/v*`:

- `Release tag creation` (ID 27739075) lets only repository admins create a tag.
- `Release tags are immutable` (ID 27739517) blocks updating and deleting a tag for everyone, admins included.

Fix a release by releasing again:

- If the run failed for a transient reason, such as a notarization timeout or a runner fault, rerun it with `gh run rerun <run-id> --failed`. The tag has not changed, so `validate` passes again.
- If the cause is in the code or the configuration, fix it on `main` through a pull request. Then tag the next patch version with `mise run release:preview patch` and `mise run release:tag <version>`. The failed tag stays without a release.
- If a published release is broken, tag the next patch version the same way. The new release becomes latest. Edit the notes of the broken release to point to the fix.

Deleting or moving a `v*` tag requires editing the `Release tags are immutable` ruleset first, at Settings > Rules > Rulesets. Restore the ruleset afterwards.

## Credentials

The `release` environment on GitHub holds the release secrets. Its deployment rules allow only tags `v*` and the `main` branch. GitHub never shows a secret again after it is set, so the `Remora` vault in 1Password is the only copy you can read.

### Vault layout

The vault has one item per credential. Create each item as a Secure Note and add the fields with the exact names below. `release:secrets` finds each value by item and field name, so renaming either breaks it.

| Item | Field | Kind | GitHub secret |
| --- | --- | --- | --- |
| `Developer ID Application` | `developer-id.p12` | File attachment | `DEVELOPER_ID_P12_BASE64`, base64 |
| `Developer ID Application` | `password` | Password | `DEVELOPER_ID_P12_PASSWORD` |
| `Notary API key` | `notary.p8` | File attachment | `NOTARY_KEY_P8_BASE64`, base64 |
| `Notary API key` | `key id` | Text | `NOTARY_KEY_ID` |
| `Notary API key` | `issuer id` | Text | `NOTARY_ISSUER_ID` |
| `Sparkle EdDSA key` | `private key` | Password | `SPARKLE_ED_PRIVATE_KEY` |
| `Sparkle EdDSA key` | `public key` | Text | None. It is `REMORA_SPARKLE_PUBLIC_KEY` in [project.yml](../project.yml). |

Each secret's reference is `op://Remora/<item>/<field>`, for example `op://Remora/Notary API key/key id`. `mise run release:secrets --dry-run` lists them all.

Every item also has four text fields:

- `source`: where the credential came from, for example `Xcode > Settings > Accounts, team LZ3V3WUPWR`.
- `created`: the creation date, as `YYYY-MM-DD`.
- `expires`: the expiry date, as `YYYY-MM-DD`, or `never`.
- `rotation`: how to replace it, or a link to its section below.

The .p12 and .p8 files are attachments, because one item then holds the file together with its password or IDs and its metadata. `op read` reads an attachment by its file name, and the task base64-encodes it for GitHub. The fixed names `developer-id.p12` and `notary.p8` keep the references the same after a rotation, so rename each file before you attach it. The Sparkle export is one line of text, so it is a field.

### Developer ID Application certificate

The certificate signs the app and the DMG. Only the Account Holder of team LZ3V3WUPWR can create it.

1. List the signing identities you already have with `security find-identity -v -p codesigning`.
2. In Xcode, open Settings > Accounts, select the Account Holder's account, and click Manage Certificates.
3. Click the add button and choose Developer ID Application. Xcode puts the certificate and its private key in the login keychain. If you create it on the developer website instead and it asks for a Developer ID Certificate Intermediary, choose G2 Sub-CA, as [Apple's replacement guide](https://developer.apple.com/help/account/certificates/replace-developer-id-certificates) says.
4. Run `security find-identity -v -p codesigning` again. The new `Developer ID Application: <name> (LZ3V3WUPWR)` line is the new certificate, and the 40-character hex value before the name is its SHA-1 fingerprint. Save it in a `sha-1` text field of the `Developer ID Application` item. During a rotation the old and new certificates have the same name, and the fingerprint tells them apart.
5. In Keychain Access, open My Certificates in the login keychain and find `Developer ID Application: <name> (LZ3V3WUPWR)`. Open Get Info on each match, and pick the one whose SHA-1 fingerprint equals `sha-1`. Check that it holds a private key.
6. Right-click it, choose Export, and save it as `developer-id.p12`. Protect it with a password that 1Password generates.
7. In the `Developer ID Application` item, attach `developer-id.p12` and save the password in `password`. Copy the certificate's Expires date from Keychain Access into `expires`.
8. Delete the exported `developer-id.p12` from disk.

The certificate can stay in the login keychain. `mise run release:app` needs it there to build a release locally.

### Notary API key

The App Store Connect API key lets `notarytool` notarize the DMG.

1. In App Store Connect, open Users and Access > Integrations > App Store Connect API > Team Keys.
2. Generate a key named `Remora notary` with the Developer role.
3. Download the key. App Store Connect offers the `AuthKey_<key id>.p8` file only once.
4. Copy the Key ID from the key's row and the Issuer ID from above the table.
5. Rename the file to `notary.p8` and attach it to the `Notary API key` item. Save the IDs in `key id` and `issuer id`.
6. Delete the downloaded file from disk.

### Sparkle EdDSA key

The EdDSA key signs each update for Sparkle. Installed copies of Remora check each update against the public key built into them, before they open the DMG. The public key is `REMORA_SPARKLE_PUBLIC_KEY` in the Release configuration of [project.yml](../project.yml). The release workflow signs each update with `SPARKLE_ED_PRIVATE_KEY`, and only `generate_appcast` reads it, on standard input.

1. Take `generate_keys` from the `bin` folder of the Sparkle release that the app uses.
2. Run `./generate_keys --account remora`. It stores the private key in the login keychain as `Private key for signing Sparkle updates` and prints the public key. The `remora` account keeps it apart from other apps' Sparkle keys. If the command prints a key without creating one, a key for that account already exists.
3. Export the private key into a private folder. `generate_keys -x` writes a file readable by every user unless the umask says otherwise.

   ```sh
   dir=$(mktemp -d)
   (umask 077 && ./generate_keys --account remora -x "$dir/private-key")
   pbcopy < "$dir/private-key"
   ```

4. In the `Sparkle EdDSA key` item, paste the clipboard into `private key`, and paste the public key into `public key`. Then clear the clipboard with `pbcopy < /dev/null`.
5. Check that 1Password holds the same value. The comparison turns off xtrace so no value is printed, and it prints `differ` on a missing export or a failed read:

   ```sh
   (
       set +x
       set -o pipefail
       test -s "$dir/private-key" &&
           op read --no-newline 'op://Remora/Sparkle EdDSA key/private key' | cmp -s - "$dir/private-key"
   ) && echo match || echo differ
   ```

6. After it prints `match`, delete the export with `rm -r "$dir"`.
7. Delete the private key from the login keychain. In Keychain Access, find `Private key for signing Sparkle updates` with the account `remora`, and delete it.
8. Put the public key in `REMORA_SPARKLE_PUBLIC_KEY` in [project.yml](../project.yml), replacing `""` in the Release configuration, and merge it through a pull request. `mise run release:keys` checks that it is a 44-character standard Base64 key. Then run `mise run release:secrets` and rehearse.

Deleting the keychain copy leaves 1Password and the write-only GitHub secret as the only copies. The release workflow signs every update, so a copy on this Mac adds exposure and no capability the release needs. The trade-off is that signing an update by hand needs the key back first, with `./generate_keys --account remora -f <file>`.

### Restore the GitHub secrets

`mise run release:secrets` copies every secret in the table from 1Password to the `release` environment. It needs the 1Password CLI signed in, for example through Settings > Developer > Integrate with 1Password CLI in the 1Password app. It also needs `gh` signed in as a repository admin.

```sh
mise run release:secrets --dry-run
mise run release:secrets
```

The dry run lists each secret name, its encoding and its reference, and reads nothing from 1Password. The real run reads every value before it changes anything, so a missing item or field stops it with the reference that failed. It then pipes each value into `gh secret set <name> --env release`. No value reaches the disk or the terminal.

GitHub sets each secret on its own. If one fails, the task names it and the secrets it already changed, and the environment holds a mix of old and new values. Run the task again until it succeeds before you release or rehearse.

Run it after you create or rotate a credential, then rehearse.

### Expiry and rotation

| Credential | Expires | Rotate |
| --- | --- | --- |
| Developer ID Application | On the date in its `expires` field | A month before that date, or at once if the private key leaked. |
| Notary API key | Never | Once a year, and at once if the .p8 leaked or a person who saw it should lose access. |
| Sparkle EdDSA key | Never | Only if the private key leaked or was lost. |

#### Developer ID Application certificate

A team can hold up to five Developer ID Application certificates at a time, so create and test the replacement before the current one expires. Create a new certificate as above, replace the attachment, the password, `sha-1` and `expires`, run `mise run release:secrets`, and rehearse. Copies signed while the old certificate was valid keep launching after it expires, as [Apple's Developer ID page](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) says.

If the private key leaked or may have leaked, email product-security@apple.com at once. Section 5.1 of the [Apple Developer Program License Agreement](https://developer.apple.com/support/terms/apple-developer-program-license-agreement/) requires immediate written notice of a suspected compromise. The developer account cannot revoke a Developer ID certificate, as [Revoking privileges](https://developer.apple.com/help/account/reference/revoking-privileges) says, so agree the revocation time with Apple.

While you wait for Apple, create a new certificate, run `mise run release:secrets`, and prepare a patch release signed with it. A revoked certificate stops every copy signed with it from installing or launching, as [Apple's Developer ID page](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) says. Copies that update before the revocation keep working. A person whose copy no longer launches must download the new DMG directly from `https://github.com/sadiksaifi/remora/releases/latest`.

#### Notary API key

For a routine rotation, create the new key first, replace the attachment and the IDs, run `mise run release:secrets`, and rehearse. Then revoke the old key in App Store Connect.

If the .p8 leaked, revoke the key at once, as [Revoking API Keys](https://developer.apple.com/documentation/appstoreconnectapi/revoking-api-keys) says. Notarization fails until the new key is in place, and a revoked key cannot be restored. Then create the new key and continue as above.

#### Sparkle EdDSA key

Never rotate the Sparkle key casually. Installed copies accept a new key only through [Sparkle's rotation path](https://sparkle-project.org/documentation/#rotating-signing-keys). An app signed with Developer ID that also ships an EdDSA public key accepts an update that changes either the Developer ID certificate or the EdDSA key, but not both. Remora meets this, and its updates are Developer ID signed DMGs, which the path also requires. Remora sets `SUVerifyUpdateBeforeExtraction`, so after a key change an installed copy accepts the DMG by its Developer ID signature only when the team matches its own.

Use the same path when the private key leaked or was lost:

1. Generate the new key under a new account name, for example `./generate_keys --account remora-2027`. `generate_keys` returns the existing key for an account it already knows, so reusing `remora` would not make a new key.
2. Check that the public key it prints differs from the `public key` field.
3. Export it and save it in the `Sparkle EdDSA key` item as in steps 3 to 6 above, with `--account remora-2027`, replacing `private key` and `public key`. Record the new account name in `source`. Keep its login keychain copy until the upgrade test passes, because `generate_appcast` signs with it.
4. Put the new public key in `REMORA_SPARKLE_PUBLIC_KEY`. Sign the release with the same Developer ID certificate as the previous release, and do not rotate the certificate in the same release.
5. Test the upgrade before publishing, as below.
6. Run `mise run release:secrets` and release. Then delete the new key from the login keychain, as in step 7 above.

To test the upgrade, update a copy of the previous release from a temporary appcast. Use a copy in a test folder, never the installed `/Applications/Remora.app`. `generate_appcast` comes from the `bin` folder of the same Sparkle release as `generate_keys`. Sparkle's command-line updater, `sparkle.app`, is not in the release archive, so [build it from Sparkle's source](https://sparkle-project.org/documentation/sparkle-cli/) at the same version, with `xcodebuild -project Sparkle.xcodeproj -scheme sparkle-cli -configuration Release -derivedDataPath build build` in that checkout.

```sh
test=$(mktemp -d)
# Open the previous release's DMG, then copy its app.
ditto /Volumes/Remora/Remora.app "$test/Remora.app"
# Build the new version with the new public key. The version must be above the previous release.
mise run release:app 0.4.0 && mise run release:dmg
mkdir "$test/feed" && cp build/release/dist/Remora-0.4.0-macos-arm64.dmg "$test/feed/"
./generate_appcast --account remora-2027 --download-url-prefix http://127.0.0.1:8000/ "$test/feed"
python3 -m http.server 8000 --bind 127.0.0.1 --directory "$test/feed"
```

In a second terminal, point the old copy at that feed with the updater from `build/Build/Products/Release` in the Sparkle checkout:

```sh
# Set test to the same folder as in the first terminal.
./sparkle.app/Contents/MacOS/sparkle "$test/Remora.app" --feed-url http://127.0.0.1:8000/appcast.xml --check-immediately --verbose
plutil -extract CFBundleShortVersionString raw "$test/Remora.app/Contents/Info.plist"
```

The test passes when the update installs and the copy reports the new version. If it fails, do not publish.

## Beta and alpha channels later

Remora releases only a stable channel today. A beta or alpha channel would change these parts:

- Tagsmith: add a channel such as `{ "name": "beta", "strategy": "prerelease" }` to `.tagsmith.jsonc`. Beta tags look like `v0.3.0-beta.1`, and `--bump prerelease` makes `v0.3.0-beta.2`. `release:preview` and `release:tag` pass `--channel stable` today and would take the channel as an argument.
- Version numbers: `release:app` accepts only `X.Y.Z` and sets `CFBundleVersion` to it, which Sparkle compares. A prerelease needs a build version that sorts below its stable release.
- Release notes: `release:notes:tag` and `cliff.toml` accept only stable tags. A beta's notes would cover the commits since the last stable release.
- GitHub: `release:publish` passes `--latest`. A beta release would pass `--prerelease` instead, so `releases/latest` keeps serving the newest stable release. The workflow can choose by the `strategy` value that `tagsmith validate` writes.
- Sparkle: each beta item in the appcast carries `<sparkle:channel>beta</sparkle:channel>`. Items without a channel are stable, and every copy sees them. The app returns the channels a person opted into from `allowedChannels(for:)` in its `SPUUpdaterDelegate`, for example from a setting to receive beta updates.
- Secrets: none change. The `release` environment rule `v*` and both tag rulesets already match prerelease tags.
