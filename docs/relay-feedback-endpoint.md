# Relay `/feedback` endpoint contract

The in-app **Report a Bug** flow (Settings → Support) posts a JSON
report to the cutti relay (`https://api.cutti.app/feedback`). The
relay is responsible for turning that report into a GitHub issue
in [`Fibi66/cutti`](https://github.com/Fibi66/cutti) and storing
a copy in its own database for triage.

The client-side implementation is in:

- `macos/CuttiMac/Sources/CuttiMac/Core/Cloud/BugReportService.swift`
- `macos/CuttiMac/Sources/CuttiMac/UI/BugReportSheet.swift`

This document describes the wire format the relay must accept.

## Request

```
POST https://api.cutti.app/feedback
Content-Type: application/json
Authorization: Bearer <session-jwt>     # optional
User-Agent: cutti/<app-version>
```

`Authorization` is omitted when the user is signed out. See **Anonymous
submissions** below — they MUST NOT auto-create public GitHub issues.

When the JWT is present, the relay derives the cutti.app account ID
from the token. The client deliberately does **not** include it in
the body so a careless server-side projection can't accidentally
publish it into the public GitHub issue.

### Body

```jsonc
{
  // Required. UTF-8, ≥ 10 chars trimmed, ≤ 10 000 bytes raw.
  "description": "The app froze when I dragged a 4K clip onto an empty timeline.",

  // Optional. ≤ 5000 bytes.
  "reproSteps": "1. Open a fresh project\n2. Drop a 4K H.265 clip\n3. Wait",

  // Optional. Empty string when the user opts out of follow-up.
  // Treat as PRIVATE — never include verbatim in the public GitHub
  // issue body. Store it only in the relay DB for follow-up.
  "contactEmail": "user@example.com",

  // Optional. Present iff the user kept the "Include diagnostics"
  // toggle on. When the field is omitted, the user explicitly opted
  // out — record that intent.
  "diagnostics": {
    "appName": "cutti",
    "appVersion": "1.0.40",
    "appBuild": "100",
    "osVersion": "macOS Version 14.5 (Build 23F79)",
    "hardwareModel": "MacBookPro18,3",
    "physicalMemoryGB": 32,
    "locale": "en_US",
    "timezone": "America/Los_Angeles",
    // ISO-8601 UTC.
    "submittedAt": "2026-05-02T19:30:00Z"
  }
}
```

The client guarantees:

- The total encoded body is ≤ 64 KB.
- Username paths (`/Users/<realname>/`) in `description` and
  `reproSteps` have already been replaced with `/Users/<user>/`.
  The relay should NOT have to scrub paths.
- `description` is non-empty (already validated client-side).
- The body contains no account email or account ID — the relay
  derives those from the JWT itself.

## Response

### Success

`HTTP 200` (or `201`) with a JSON body:

```jsonc
{
  // GitHub issue URL when the relay successfully opened one.
  // null when GitHub creation failed but the report was stored —
  // the client still treats this as success and shows the
  // generic confirmation. The client only opens https://github.com
  // URLs from this field; other schemes/hosts are silently dropped.
  "issueURL": "https://github.com/Fibi66/cutti/issues/123",

  // Server-side ticket id; surfaced read-only in the success view
  // so the user can quote it in follow-up emails. Optional.
  "ticketID": "fb_2026_05_02_abcd1234"
}
```

An empty body is also accepted as a success signal — the client
falls back to a generic "thanks, we got it" message.

### Errors

- `400 Bad Request` — body invalid; client surfaces the response
  text as the error message (truncated to 500 chars).
- `429 Too Many Requests` — include a `Retry-After` header in
  seconds. Client surfaces "Try again in N seconds."
- `5xx` — generic server error; client surfaces the status + first
  500 chars of the body.

## Anonymous submissions and abuse

This client is part of an **open-source AGPL** repository. Anyone can
fork it and call `/feedback` from a modified binary. The relay is the
only line of defence against spam, and it MUST treat unauthenticated
traffic as untrusted:

- **Do not auto-open public GitHub issues for anonymous reports.**
  Store them in a private moderation queue instead. A human or a
  trust-scored heuristic promotes them to GitHub.
- Apply per-account, per-IP, and global rate limits server-side.
  Suggested defaults: 5/hour/account, 1/hour/IP for anonymous,
  with sharper bursts blocked outright.
- Detect and dedupe near-identical descriptions before creating issues.
- Require a verified, non-trivial-age cutti.app account before any
  authenticated submission auto-creates a public issue. New / spammy
  accounts also go to the private queue.

These are server-side responsibilities; the client cannot enforce them.

## GitHub issue layout (server-side recommendation)

When the relay opens a public issue, suggested format:

- **Title**: first 80 chars of `description`, prefixed with
  `[in-app]`. e.g. `[in-app] The app froze when I dragged…`
- **Labels**: `auto-reported`, plus `os:macos` and a version
  label like `v:1.0.40`.
- **Body**: a **redacted projection** of the request — never the
  raw request body. Include only fields safe for public visibility:
  ```markdown
  > Reported via the in-app **Report a Bug** flow.
  > Ticket: `fb_2026_05_02_abcd1234`

  ## Description
  <description>

  ## Steps to reproduce
  <reproSteps or "_none provided_">

  ## Diagnostics
  - cutti **1.0.40** (build 100)
  - macOS Version 14.5 (Build 23F79)
  - MacBookPro18,3, 32 GB
  - locale `en_US`, timezone `America/Los_Angeles`
  ```

  Specifically, the public body MUST NOT contain:
  - `contactEmail`
  - the account ID derived from the JWT
  - the account email associated with the JWT
  - the raw request JSON

  Anything that needs to round-trip to the user (email reply, account
  correlation, etc.) belongs in the relay DB only.

## Privacy notes

- The client deliberately does NOT send the user's cutti.app
  account email or account ID — only the JWT, which the relay can
  use server-side without exposing it to the public issue body.
- `contactEmail` is opt-in and treated as private (relay-only).
  If the user wants a reply, they re-type their address into the
  contact field. This avoids accidentally publishing an email when
  the GitHub issue body is generated from the request.
- The client does NOT upload OS unified logs or media files in
  this iteration.
- The client only opens `issueURL` values that are `https://` URLs
  on `github.com` (or its subdomains). A relay misconfiguration
  cannot launch arbitrary apps on the user's machine.
