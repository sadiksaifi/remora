# Releasing Remora

A release is a pushed `vX.Y.Z` tag. The tag push runs [the release workflow](../.github/workflows/release.yml), which builds, signs, notarizes and publishes the DMG as a GitHub release. The signing credentials live in the `Remora` vault in 1Password, and `mise run release:secrets` copies them to GitHub.

## Make a release

1. Switch to `main` and bring it up to date with `git switch main && git pull --ff-only`. The tag goes on `HEAD`.
2. Preview the next version with `mise run release:preview minor`. Use `major`, `minor` or `patch`. The JSON output shows the version and the tag.
3. Read the release notes with `mise run release:notes`. [cliff.toml](../cliff.toml) groups the Conventional Commits since the last release.
4. Create and push the tag with `mise run release:tag 0.2.0`, using the version that the preview printed. Only a repository admin can create a `v*` tag.
5. Follow the run with `gh run list --workflow release.yml --limit 1` and `gh run watch <run-id>`.

The workflow has three jobs:

- `validate` checks the tag with Tagsmith against [.tagsmith.jsonc](../.tagsmith.jsonc).
- `build` builds the RDP and VNC engines from scratch, signs the app with the Developer ID certificate, and builds and signs the DMG. It then notarizes and staples the DMG, assesses it with Gatekeeper and writes `SHA256SUMS`.
- `publish` creates the GitHub release.

The release appears at `https://github.com/sadiksaifi/remora/releases/tag/v0.2.0` with the title `Remora 0.2.0`. It holds `Remora-0.2.0-macos-arm64.dmg` and `SHA256SUMS`. The notes start with a download badge, followed by the notes from `mise run release:notes:tag v0.2.0`. The release is marked latest, so `https://github.com/sadiksaifi/remora/releases/latest` serves it.

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

A manual run on `main` builds, signs and notarizes version `0.0.0` without creating a release. Run it after the secrets are first set, and again after any credential changes.

```sh
gh workflow run release.yml --ref main
gh run list --workflow release.yml --limit 1
gh run watch <run-id>
gh run download <run-id> --name Remora-0.0.0 --dir build/rehearsal
spctl --assess --type open --context context:primary-signature --verbose=2 build/rehearsal/Remora-0.0.0-macos-arm64.dmg
```

The DMG stays on the run as an artifact for 14 days. A rehearsal skips the `validate` and `publish` jobs, so it does not test the release notes or `gh release create`.

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

1. In Xcode, open Settings > Accounts, select the Account Holder's account, and click Manage Certificates.
2. Click the add button and choose Developer ID Application. Xcode puts the certificate and its private key in the login keychain.
3. In Keychain Access, open My Certificates in the login keychain and find `Developer ID Application: <name> (LZ3V3WUPWR)`. Check that it holds a private key.
4. Right-click it, choose Export, and save it as `developer-id.p12`. Protect it with a password that 1Password generates.
5. In the `Developer ID Application` item, attach `developer-id.p12` and save the password in `password`. Set `expires` to the certificate's expiry date from Keychain Access.
6. Delete the exported `developer-id.p12` from disk.

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

The EdDSA key signs each update for Sparkle. Installed copies of Remora accept only updates signed with the private key that matches the public key they ship with.

1. Take `generate_keys` from the `bin` folder of the Sparkle release that the app uses.
2. Run `./generate_keys --account remora`. It stores the private key in the login keychain as `Private key for signing Sparkle updates` and prints the public key. The `remora` account keeps it apart from other apps' Sparkle keys. If the command prints a key without creating one, a key for that account already exists.
3. Run `./generate_keys --account remora -x sparkle-private-key.txt` to export the private key. The file holds one line of base64 text.
4. In the `Sparkle EdDSA key` item, paste that line into `private key` and the public key into `public key`.
5. Delete `sparkle-private-key.txt` from disk.
6. Delete the private key from the login keychain. In Keychain Access, find `Private key for signing Sparkle updates` with the account `remora`, and delete it.

Deleting the keychain copy leaves 1Password and the write-only GitHub secret as the only copies. The release workflow signs every update, so a copy on this Mac adds exposure and no capability the release needs. The trade-off is that signing an update by hand needs the key back first, with `./generate_keys --account remora -f <file>`. Before you delete it, check that `private key` holds the whole line from the export.

### Restore the GitHub secrets

`mise run release:secrets` copies every secret in the table from 1Password to the `release` environment. It needs the 1Password CLI signed in, for example through Settings > Developer > Integrate with 1Password CLI in the 1Password app. It also needs `gh` signed in as a repository admin.

```sh
mise run release:secrets --dry-run
mise run release:secrets
```

The dry run lists each secret name, its encoding and its reference, and reads nothing from 1Password. The real run reads every value before it changes anything, so a missing item or field stops it with the reference that failed. It then pipes each value into `gh secret set <name> --env release`. No value reaches the disk or the terminal.

Run it after you create or rotate a credential, then rehearse.

### Expiry and rotation

| Credential | Expires | Rotate |
| --- | --- | --- |
| Developer ID Application | 5 years after creation | A month before `expires`, or at once if the private key leaked. |
| Notary API key | Never | Once a year, and at once if the .p8 leaked or a person who saw it should lose access. |
| Sparkle EdDSA key | Never | Only if the private key leaked. |

To rotate the Developer ID certificate, create a new one as above, replace the attachment and the password, run `mise run release:secrets`, and rehearse. Copies signed with the old certificate keep launching after it expires, because notarization and the signature's secure timestamp prove it was valid at signing time.

To rotate the notary key, create the new key first, replace the attachment and the IDs, run `mise run release:secrets`, and rehearse. Revoke the old key in App Store Connect only after the rehearsal passes, because notarization fails at once with a revoked key.

Never rotate the Sparkle key casually. Installed copies trust only the public key built into them, so an update signed with a new key fails on every one of them. A rotation needs one release signed with the old key that ships the new public key. Keep the old key until users have installed that release.

## Beta and alpha channels later

Remora releases only a stable channel today. A beta or alpha channel would change these parts:

- Tagsmith: add a channel such as `{ "name": "beta", "strategy": "prerelease" }` to `.tagsmith.jsonc`. Beta tags look like `v0.3.0-beta.1`, and `--bump prerelease` makes `v0.3.0-beta.2`. `release:preview` and `release:tag` pass `--channel stable` today and would take the channel as an argument.
- Version numbers: `release:app` accepts only `X.Y.Z` and sets `CFBundleVersion` to it, which Sparkle compares. A prerelease needs a build version that sorts below its stable release.
- Release notes: `release:notes:tag` and `cliff.toml` accept only stable tags. A beta's notes would cover the commits since the last stable release.
- GitHub: `release:publish` passes `--latest`. A beta release would pass `--prerelease` instead, so `releases/latest` keeps serving the newest stable release. The workflow can choose by the `strategy` value that `tagsmith validate` writes.
- Sparkle: each beta item in the appcast carries `<sparkle:channel>beta</sparkle:channel>`. Items without a channel are stable, and every copy sees them. The app returns the channels a person opted into from `allowedChannels(for:)` in its `SPUUpdaterDelegate`, for example from a setting to receive beta updates.
- Secrets: none change. The `release` environment rule `v*` and both tag rulesets already match prerelease tags.
