# AGENTS.md

This file sets the ground rules for **AI coding agents** (Copilot,
Claude, Cursor, Codex, etc.) operating on the **cutti** repository.

It is split in two parts:

- **Part A — Universal rules.** Everyone follows these, maintainers
  included. They exist to protect users and the project itself.
- **Part B — Rules for external contributors.** Anyone preparing a pull
  request from a fork must follow these. Maintainers may use their own
  judgment when working directly on the canonical repo.

If you are a human contributor: these rules also apply to any agent
**you** drive on this codebase. You are responsible for what your agent
commits under your name.

cutti is an AGPL-3.0, open-source macOS + iOS app. Treat the repository
accordingly: every change is public, every commit is permanent, every
secret leak is forever.

---

# Part A — Universal rules

These apply to **every** agent operating on this repo, regardless of
who is driving it. Maintainers hold themselves to the same standard.

## A1. Secrets and tokens — hard ban

- **Never** commit API keys, OpenAI tokens, Azure keys, Apple Developer
  Team IDs, signing certificates, `.p8` keys, `.mobileprovision` files,
  or any `.env*` file. The `.gitignore` already excludes the common
  cases; do not work around it.
- **Never** paste a real token into test fixtures, source comments,
  commit messages, or PR descriptions. Use obvious placeholders such
  as `REDACTED`, `YOUR_API_KEY_HERE`, or `sk-test-xxxxxxxx`.
- **Never** print, log, or echo environment variables that may carry
  tokens (`OPENAI_API_KEY`, `AZURE_*`, `APP_STORE_CONNECT_*`, etc.).
- If you discover a leaked secret in history, stop, rotate it, and
  tell a maintainer. Do not attempt to rewrite history yourself.

## A2. Privacy and user data

- Do not transmit repository contents, user video footage, audio,
  transcripts, or model outputs to third-party LLM or cloud services.
  The only outbound AI traffic permitted is through the OpenAI relay
  already wired into this project.
- Do not add telemetry, analytics, crash reporters, or any code path
  that exfiltrates user media, project files, transcripts, or
  inference results off-device beyond what is already configured.
- Test fixtures must use synthetic or clearly-licensed sample media.
  Do not commit real user-recorded video, audio, or transcripts —
  even short clips, even "just for debugging."
- Do not weaken existing on-device-by-default behaviour (e.g. routing
  something currently handled by the local Qwen3-ASR sidecar to a
  remote transcription service) without an explicit, deliberate
  decision.

---

# Part B — Rules for external contributors

These apply to anyone (and any agent driven by anyone) preparing a
pull request from a fork. Maintainers may exercise their own
judgment — but the rules below are the default, and "I'm a maintainer"
is not an excuse to be sloppy.

## B1. Respect the CuttiKit boundary

`shared/CuttiKit/` is the cross-platform contract between the macOS
and iOS apps. **Read `shared/CuttiKit/BOUNDARIES.md` before adding,
moving, or modifying anything in that directory.**

- No `import AppKit`, `import UIKit`, or `import SwiftUI` inside the
  kit.
- No view models, editor session state, or platform-specific I/O in
  the kit.
- When you add a new AI action case, register it in the capability
  matrix in `BOUNDARIES.md` (Both / macOS-only / iOS-only) in the
  same PR.

## B2. Build and test discipline

Before opening a PR, build **and** test all three targets:

```bash
cd shared/CuttiKit && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

cd macos/CuttiMac && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

cd ios/CuttiMobile && xcodegen generate && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project CuttiMobile.xcodeproj -scheme CuttiMobile \
    -sdk iphonesimulator \
    -destination 'generic/platform=iOS Simulator' \
    -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

- Do **not** "fix" a failing test by deleting it, weakening its
  assertion, marking it `XCTSkip`, or wrapping the failing call in
  `try?` to swallow the error.
- Swift 6 strict concurrency stays on. Do not use `@unchecked
  Sendable`, `nonisolated(unsafe)`, or `@preconcurrency` to paper
  over a real data race. If you genuinely need one of those,
  justify it in the PR.
- If a test is flaky, say so explicitly in the PR — do not silently
  retry-loop it.

## B3. Do not touch without an explicit request

Leave the following alone unless a maintainer-authored issue or PR
explicitly asks for the change:

- `LICENSE` (AGPL-3.0).
- `.github/workflows/` and any other CI / release configuration.
- Version numbers, release notes, signing configuration.
- `ios/CuttiMobile/project.yml`'s `DEVELOPMENT_TEAM` and
  `bundleIdPrefix` — those are local-developer fields and must not
  be committed with anyone's personal values.
- Anything currently `.gitignore`d, including but not limited to:
  - generated `*.xcodeproj` (re-run `xcodegen generate` instead),
  - `macos/CuttiMac/Vendor/*.xcframework/`,
  - `.build/`, `.build-device/`, `.build-simulator/`, `DerivedData/`.

## B4. Dependencies

- Do not add new SwiftPM dependencies casually, and **especially**
  not to CuttiKit. Open an issue first and get a maintainer's
  go-ahead.
- Do not bump or downgrade existing dependency versions to make a
  build pass; fix the underlying problem.
- Do not introduce non-Apple system frameworks into CuttiKit (see
  the three-criteria rule in `BOUNDARIES.md`).

## B5. Scope and git hygiene

- One logical change per PR. No drive-by reformatting, rename
  storms, or "while I'm here" refactors mixed into a feature PR.
- Make precise, surgical edits. Do not touch files unrelated to the
  task.
- Do not rewrite published git history. No `git push --force` /
  `--force-with-lease` against `main` or any shared branch.
- Work on a feature branch in your fork — never on `main`.

## B6. PR descriptions and disclosure

- Every PR description must clearly explain **what** changed and
  **why**, in plain prose. Do not dump raw chain-of-thought, tool
  transcripts, or auto-generated filler. A maintainer should be
  able to review the diff with the description as their map.
- Disclose, in the PR description, that an AI agent was used and
  which one. This is not a barrier to merge — it is just honest.
- By opening the PR you confirm that you, the human, have reviewed
  every line of the diff and take responsibility for it under
  AGPL-3.0.
- If the agent gets stuck or repeatedly fails, stop and ask a
  human. Do not loop on the same broken approach.

---

## Quick checklist for external contributors

Before you click "Create pull request":

- [ ] No secrets, tokens, `.env*`, or signing material in the diff.
- [ ] No real user media in test fixtures.
- [ ] `shared/CuttiKit` + `macos/CuttiMac` + `ios/CuttiMobile` all
      build and test green locally.
- [ ] You did not modify `LICENSE`, `.github/workflows/`,
      `project.yml`'s team/bundle ID, or any gitignored path.
- [ ] No new SwiftPM dependency added without prior issue/discussion.
- [ ] PR description is plain prose, names the AI agent used, and
      maps to the diff.
- [ ] You read every line of the diff yourself.

Violations of Part A — especially A1 (secrets) and A2 (privacy) —
are grounds to close a PR without review.
