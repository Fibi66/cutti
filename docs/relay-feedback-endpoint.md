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

`Authorization` is omitted when the user is signed out. The relay
should still accept anonymous reports but apply a stricter rate
limit (e.g. 1 per IP per hour) compared to authenticated submitters
(e.g. 5 per account per hour).

### Body

```jsonc
{
  // Required. UTF-8, ≥ 10 chars trimmed, ≤ 10 000 bytes raw.
  "description": "The app froze when I dragged a 4K clip onto an empty timeline.",

  // Optional. ≤ 5000 bytes.
  "reproSteps": "1. Open a fresh project\n2. Drop a 4K H.265 clip\n3. Wait",

  // Optional. Empty string when the user opts out of follow-up.
  "contactEmail": "user@example.com",

  // Optional. Present iff the user kept the "Include diagnostics"
  // toggle on. When omitted (or `null`), the user explicitly opted
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
    // Cutti.app account ID when signed in; null otherwise.
    "signedInUserID": "user_abc123",
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

## Response

### Success

`HTTP 200` (or `201`) with a JSON body:

```jsonc
{
  // GitHub issue URL when the relay successfully opened one.
  // null when GitHub creation failed but the report was stored —
  // the client still treats this as success and shows the
  // generic confirmation.
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

## GitHub issue layout (server-side recommendation)

When the relay opens the issue, suggested format:

- **Title**: first 80 chars of `description`, prefixed with
  `[in-app]`. e.g. `[in-app] The app froze when I dragged…`
- **Labels**: `auto-reported`, plus `os:macos` and a version
  label like `v:1.0.40`.
- **Body**:
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

  <details>
    <summary>Raw report</summary>

    ```json
    <full body, pretty-printed>
    ```
  </details>
  ```
- **Account email** (`contactEmail` from request, or the address
  on the cutti.app account when signed in) is **never** posted
  publicly. Store it in the relay DB only and use for follow-up.

## Privacy notes

- The client deliberately does NOT send the user's cutti.app
  account email — only the user ID. If the user wants a reply,
  they re-type their address into the contact field. This avoids
  accidentally publishing an email when the GitHub issue body is
  generated from the request.
- The client does NOT upload OS unified logs or media files in
  this iteration.
