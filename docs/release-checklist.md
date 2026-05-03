# Release checklist — going PUBLIC

This repo is currently **PRIVATE**. A handful of things have to be flipped
before flipping `Settings → General → Change visibility → Public`.

## Before flipping the switch

### 1. Switch SwiftPM binary targets to remote URL mode

`macos/CuttiMac/Package.swift` currently uses `path: "Vendor/..."` so
local builds work without a public release URL. The remote URLs +
checksums are already kept in comments next to each `binaryTarget`.

```swift
// from
.binaryTarget(name: "SherpaOnnxC",  path: "Vendor/sherpa-onnx.xcframework")
.binaryTarget(name: "OnnxRuntimeC", path: "Vendor/onnxruntime.xcframework")

// to
.binaryTarget(
    name: "SherpaOnnxC",
    url: "https://github.com/Fibi66/cutti/releases/download/vendor-sherpa-v1.12.39-ort-1.24.4/sherpa-onnx.xcframework.zip",
    checksum: "bbceeaf8b562017eedb5303460ae2615a217f415fea8306b026fe438feb4f57a"
)
.binaryTarget(
    name: "OnnxRuntimeC",
    url: "https://github.com/Fibi66/cutti/releases/download/vendor-sherpa-v1.12.39-ort-1.24.4/onnxruntime.xcframework.zip",
    checksum: "4ad2c3906fbaf9ed6454e796b1be80389780b9865d7ab2e379d5b37b1940555b"
)
```

The release at
`https://github.com/Fibi66/cutti/releases/tag/vendor-sherpa-v1.12.39-ort-1.24.4`
is already created with both assets uploaded.

### 2. Stop tracking the local Vendor/ workaround

In `.gitignore`, remove these four lines:

```
# Vendored xcframeworks (private-repo mode). When the repo goes public,
# Package.swift switches to remote `url:` binaryTargets and these lines
# can be removed.
macos/CuttiMac/Vendor/sherpa-onnx.xcframework/
macos/CuttiMac/Vendor/onnxruntime.xcframework/
```

Then locally `rm -rf macos/CuttiMac/Vendor/` so the working tree is
clean. SwiftPM will re-fetch the binaries from the release URLs into
its global cache on the next build.

### 3. Verify a clean build picks up the public release

```bash
cd macos/CuttiMac
rm -rf .build
swift build
```

Expected: SwiftPM logs `Downloading binary artifact …` for both
xcframeworks, build succeeds. If you see `404`, the repo isn't actually
public yet — release assets follow repo visibility.

### 4. Configure the in-app bug-report → GitHub Issues bridge

The macOS app's Settings → Support → Report a Bug flow posts to
`POST /v1/feedback` on the relay (`xiaoyu-work/cutti-backend`). Reports
that pass the trust gate are auto-promoted to public issues in
`Fibi66/cutti` via a GitHub App.

This is a one-time setup. Once it's done, every push to
`xiaoyu-work/cutti-backend` syncs the secrets to Cloudflare and
deploys — no manual `wrangler` runs ever again.

#### 4.1 Add `D1:Edit` to the Cloudflare API token used by Actions

The token already has `Workers:Edit`; add D1:

1. <https://dash.cloudflare.com/profile/api-tokens>
2. Edit the token used by `xiaoyu-work/cutti-backend` Actions.
3. Permissions → add a row: **Account → D1 → Edit**.
4. Continue → Update Token.

#### 4.2 Register the GitHub App

1. <https://github.com/settings/apps/new>
2. Fill in:
   - **Name:** `cuttiapp` (or any name; just must be unique on GitHub)
   - **Homepage URL:** `https://cutti.app`
   - **Webhook → Active:** ❌ uncheck (we don't use webhooks)
   - **Repository permissions → Issues:** **Read & write**
   - **Where can this be installed?** Only on this account
3. Click **Create GitHub App**.
4. On the App's settings page, note the **App ID** (numeric, top of
   the "About" section).
5. Scroll to **Private keys** → **Generate a private key** → a `.pem`
   file downloads automatically. Keep it; you'll paste it in 4.4.

#### 4.3 Install the App on `Fibi66/cutti`

1. Left sidebar → **Install App** → click **Install** next to your
   user/org.
2. Choose **Only select repositories** → pick `Fibi66/cutti`.
3. After clicking Install, the URL bar shows
   `https://github.com/settings/installations/<NNNNN>` — that
   `<NNNNN>` is the **Installation ID**. Note it.

#### 4.4 Add 4 secrets to the **cutti-backend** repo

<https://github.com/xiaoyu-work/cutti-backend/settings/secrets/actions>
→ New repository secret. Add each of these exactly:

| Name | Value |
|---|---|
| `GITHUB_APP_ID` | App ID from 4.2.4 (e.g. `3583044`) |
| `GITHUB_APP_INSTALLATION_ID` | Installation ID from 4.3.3 |
| `GITHUB_APP_PRIVATE_KEY` | Open the downloaded `.pem` in a text editor and paste **all** of it (including `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` lines) |
| `FEEDBACK_IP_HASH_SECRET` | Output of `openssl rand -hex 32` |

#### 4.5 Trigger a deploy

1. <https://github.com/xiaoyu-work/cutti-backend/actions/workflows/deploy-cloudflare.yml>
2. Click **Run workflow** → Run workflow.
3. Watch the run: it should ① apply any pending D1 migrations,
   ② sync the four secrets to Cloudflare, ③ `wrangler deploy`.
4. Smoke test: open Cutti macOS → Settings → Support → Report a Bug
   → submit a one-line test → check
   <https://github.com/Fibi66/cutti/issues> for an `auto-reported`
   labeled issue authored by the App's bot user.

#### Recovery

- **Lost the `.pem`?** Generate a new one in the App's settings and
  update the `GITHUB_APP_PRIVATE_KEY` repo secret. Old keys can be
  revoked on the same page.
- **App is rate-limited / unavailable?** Reports still queue in the
  relay's `feedback_tickets` D1 table with `status='pending'`. SQL
  recipes for manual triage are at the bottom of
  `xiaoyu-work/cutti-backend/backend/cloudflare-relay/README.md`.

### 5. Sanity-sweep the README + docs

Open `README.md` and confirm it doesn't reference any private-only
flow (it shouldn't — the public flow is just `swift build && swift
run`).

### 6. Delete this file

```bash
git rm docs/release-checklist.md
```

It's only here as a reminder; it has no value once the switch is done.

## After flipping the switch

- Watch the [Releases page](https://github.com/Fibi66/cutti/releases) —
  the `vendor-sherpa-…` assets should now be downloadable anonymously.
- Try a fresh `git clone` in `/tmp` and run `swift build` to confirm
  the open-source experience works end-to-end.
- Update the local-machine `git remote` URL if you'd like (no change
  needed if the repo name stays the same).

## Things that stay the same

- `https://api.cutti.app` relay base URL — public DNS, no harm.
- Bundle ID `app.cutti.*` — your namespace; forks must change theirs.
- `DEVELOPMENT_TEAM` is already empty; forks fill in their own.
- LICENSE (AGPL-3.0) — no change.
