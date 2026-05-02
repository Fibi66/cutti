# AnimationSkill (placeholder)

This directory is intentionally empty in the open-source build of cutti.

The full Remotion overlay skill pack — including ~24 hand-crafted animation
templates, a style guide, plugins, and the cutti-specific authoring rules —
is **not** part of the open-source release. It powers the high-quality
`generate_overlay` output in the hosted version at https://cutti.app and is
proprietary.

## What this means for OSS users

- The `generate_overlay` agent tool is fully present in source and runs.
- Without a skill pack here, the LLM is asked to synthesize Remotion code
  from scratch based on user intent. Output quality will be noticeably
  lower than the hosted experience.
- You can drop your own templates / rules into this directory; they'll be
  bundled into the app via SwiftPM `.copy(...)` and picked up at runtime.

## Running the hosted experience

Sign in inside the app to your cutti.app account. The relay backend
injects the proprietary skill pack into LLM requests on the server side,
so you get the full template library without it ever shipping in the
client binary.
