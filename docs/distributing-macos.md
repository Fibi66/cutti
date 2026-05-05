# Distributing Cutti on macOS

This guide covers how to release a new version of Cutti for direct
download (Developer ID + DMG + GitHub Releases + Sparkle auto-update).

This is **not** for the Mac App Store path — Apple handles updates
for App Store builds and Sparkle is not bundled there.

## One-time setup

### 1. Apple Developer account

You already have one. Make sure your **Developer ID Application**
certificate is installed in Keychain Access. Verify with:

```bash
security find-identity -p codesigning -v | grep "Developer ID Application"
```

You should see exactly one identity. Copy the full string into your
shell profile:

```bash
export DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
```

### 2. Notarization credentials

Create an [app-specific password](https://account.apple.com) for
`notarytool` and store it in your Keychain so the script never sees it
in plaintext:

```bash
xcrun notarytool store-credentials cutti-notary \
  --apple-id you@example.com \
  --team-id TEAMID \
  --password <app-specific-password>
```

Then:

```bash
export NOTARYTOOL_KEYCHAIN_PROFILE=cutti-notary
```

### 3. Sparkle EdDSA keys

Sparkle signs every update with EdDSA so users can trust the binary
even if GitHub is compromised. Generate keys once, **back them up**,
and then forget about the private key (it stays in your login Keychain):

```bash
# Inside Sparkle's 'bin' folder (after `brew install --cask sparkle`
# or building from source). The Cask installs the CLIs at
# /Applications/Sparkle/bin — adjust as needed.
generate_keys
```

It prints a base64 public key. Save it:

```bash
export SPARKLE_PUBLIC_ED_KEY="<paste the base64 string here>"
```

Add `SPARKLE_PUBLIC_ED_KEY`, `DEVELOPER_ID_APPLICATION`, and
`NOTARYTOOL_KEYCHAIN_PROFILE` to your shell rc so they're set on every
shell. **Do not commit them.**

Back up the private key (in case you wipe the Mac):

```bash
generate_keys -x sparkle-ed-key-backup.txt
# Store sparkle-ed-key-backup.txt somewhere safe (1Password, encrypted
# disk, etc). NOT in this repo.
```

### 4. That's it

Sparkle's feed URL is hardcoded to
`https://github.com/Fibi66/cutti/releases/latest/download/appcast.xml`
— a stable GitHub-provided alias that always serves whichever
`appcast.xml` is attached to the most recent (non-pre)release. The
release script writes a fresh appcast.xml each time and uploads it as
a release asset, so there's nothing to host yourself: no domain, no
server, no CDN, no Pages.

## Cutting a release

Two paths:

### Option A — GitHub Actions (recommended; works from any machine)

Once the secrets below are configured (one-time), every release is:

```bash
git tag v1.0.0
git push origin v1.0.0
```

A workflow at `.github/workflows/release-macos.yml` picks up the tag,
runs the same `scripts/release-macos.sh` on a `macos-14` runner, and
publishes the GitHub Release. **You do not need this Mac to release any
more.**

#### Required GitHub Actions secrets

In `Settings → Secrets and variables → Actions → New repository secret`:

| Name | Value |
|------|-------|
| `DEVELOPER_ID_APPLICATION`    | `Developer ID Application: Your Name (TEAMID)` (literal string from `security find-identity`) |
| `DEVELOPER_ID_P12_BASE64`     | Output of `base64 -i developer-id-application.p12 \| tr -d '\n'` |
| `DEVELOPER_ID_P12_PASSWORD`   | The password used when exporting the .p12 (leave empty if exported with no password) |
| `ASC_API_KEY_ID`              | App Store Connect API key id, e.g. `ABC123XYZ0` |
| `ASC_API_KEY_ISSUER_ID`       | The team's issuer UUID from App Store Connect |
| `ASC_API_KEY_P8_BASE64`       | Output of `base64 -i AuthKey_*.p8 \| tr -d '\n'` |
| `SPARKLE_ED_PRIVATE_KEY`      | The 44-char base64 raw private key (the one in your password manager) |
| `SPARKLE_PUBLIC_ED_KEY`       | The matching base64 public key |

`GITHUB_TOKEN` is provided automatically — no manual setup needed.

You can also trigger a release manually from the Actions tab
(`workflow_dispatch`) and supply the version inline.

### Option B — Run locally

```bash
# Bump version, commit, and push first. Then:
scripts/release-macos.sh --version 1.0.0
```

Only useful if you want to debug the pipeline interactively. Otherwise
Option A is strictly better.

### What the script does

1. Build `Cutti.app` for arm64
2. Sign nested Sparkle helpers, then the framework, then the app
3. Notarize and staple the .app
4. Create a DMG with a drag-to-Applications layout
5. Sign + notarize + staple the DMG
6. Sign the DMG with Sparkle's EdDSA key
7. Generate a fresh `appcast.xml` advertising this version
8. Push a `v1.0.0` tag (skipped if already present at HEAD, e.g. when
   the workflow was triggered by the tag itself) and create a GitHub
   release with **both** the DMG and the appcast.xml attached as assets

Use `--draft` for dry-runs (local only):

```bash
scripts/release-macos.sh --version 0.0.1-test --draft
```

## How users get updates

- **First install**: user downloads the DMG from
  `https://github.com/Fibi66/cutti/releases`, drags Cutti to
  `/Applications`, opens it. Gatekeeper accepts because the DMG is
  notarized.
- **Subsequent updates**: Cutti checks
  `https://github.com/Fibi66/cutti/releases/latest/download/appcast.xml`
  once a day in the background. GitHub redirects this URL to
  whichever `appcast.xml` is attached to your latest release. When a
  new `<sparkle:version>` shows up, the user sees Sparkle's standard
  "A new version is available" dialog. They click *Install Update*,
  Cutti downloads the DMG, verifies the EdDSA signature, replaces
  itself, relaunches.
- Users can also trigger a check manually: **Settings → Updates →
  Check Now**.

## Troubleshooting

**`codesign` fails with `errSecInternalComponent`** — your private
key is locked. Run `security unlock-keychain login.keychain` and
retry.

**Notarization rejects with "The signature does not include a secure
timestamp"** — make sure every `codesign` call uses `--timestamp`.
The package script does, but if you've manually re-signed something
double-check.

**Users on macOS 14 see "App is damaged" on first launch** — the
DMG wasn't stapled. Re-run `xcrun stapler staple Cutti-X.Y.Z.dmg`.

**Sparkle says "Update Error: An error occurred while extracting the
archive"** — almost always a signature mismatch between the EdDSA
public key in `Info.plist` and the key that signed the DMG. Verify
`SPARKLE_PUBLIC_ED_KEY` matches what `sign_update` is using.
