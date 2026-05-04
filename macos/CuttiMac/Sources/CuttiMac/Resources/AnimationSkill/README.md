# AnimationSkill (placeholder)

This directory is intentionally empty in the open-source build of cutti.

The full Remotion overlay skill pack — including ~24 hand-crafted animation
templates, a style guide, plugins, and the cutti-specific authoring rules —
is **not** part of the open-source release. It powers the high-quality
`generate_overlay` output in the hosted version at https://cutti.app and is
proprietary.

## What this means at runtime

Skill activation happens server-side in the cutti-relay (Cloudflare Worker).
Whenever a chat-completions request from the client registers
`generate_overlay` as one of the agent's tools, the relay prepends the
proprietary skill pack as a `system` message before forwarding to Azure
OpenAI. Detection is **tool-based**, not envelope-based, so every entry
point that can call `generate_overlay` — the B-roll suggestion strip, the
free-form chat agent loop, anything future — gets the skill automatically
without client-side coordination.

The injected pack carries:

- `SKILL.md` — what the skill is for, output specs, transparent-render flags
- `rules/cutti-templates.md` — house styles + intent → template lookup table
- `rules/cutti-staging.md` — entrance / hold / exit timing
- `rules/cutti-constraints.md` — Remotion hard constraints
- `rules/cutti-fonts.md` — font catalog
- `rules/cutti-checklist.md` — pre-merge checklist

So:

- **Signed-in cuttiCloud users** get full house-style guidance every time
  the agent might emit a `generate_overlay` call. There is nothing to
  configure on the client.
- **BYOK (Bring-Your-Own-Key) users** route their requests directly to
  the third-party OpenAI-compatible endpoint they configured; the relay
  is bypassed entirely, so no skill injection happens. The agent falls
  back to the catalog enumeration in the in-app instruction prompt and
  the model's own intuition. Quality will be noticeably lower than the
  hosted experience.
- **Open-source self-hosters** can drop their own templates / rules into
  this directory; they'll be bundled into the app via SwiftPM `.copy(...)`
  and become reachable through the local `list_animation_rules` /
  `read_animation_rule` tools. (Server-side injection, however, still
  requires a cuttiCloud relay deployment with the proprietary pack
  baked in.)

## Running the hosted experience

Sign in inside the app to your cutti.app account. The relay injects the
proprietary skill pack into chat requests on the server side, so you get
the full template library without it ever shipping in the client binary.
