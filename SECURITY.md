# Security policy

## Reporting a vulnerability

Photo2Mac reads, edits and writes image files including embedded XMP
metadata. If you find a vulnerability — anything that lets a crafted
image execute code, corrupt user files outside the chosen output path,
leak data through XMP, or break the non-destructive save round-trip in
a way that loses pixels — **please do not open a public issue**.

Instead, email me directly:

**razvan@cremenescu.ro**

Use the subject line `[Photo2Mac security]`. If you want to use PGP,
ask in the first message and I'll send a key.

I'll acknowledge within a few days, work on a fix, and credit you in
the release notes unless you prefer to stay anonymous.

## Scope

In scope:

- The Photo2Mac app itself (Swift source under `App/`).
- The XMP read/write pipeline (CGImageMetadata + the custom `p2m`
  namespace).
- Save-in-place / Save As (NSFileVersion handling, autosave on disk
  under `~/Library/Application Support/Photo2Mac/`).
- The bundled `.dmg` (anything exploitable via the install flow).

Out of scope:

- The fact that ad-hoc signing triggers a Gatekeeper warning — that is
  intentional until I get an Apple Developer ID.
- Social-engineering or local-attack scenarios that already assume the
  attacker has full access to the machine.
- Upstream issues in Apple frameworks (ImageIO, Core Image) — please
  report those to Apple.

## Supported versions

This is alpha software. Only the latest release receives fixes. Older
tags are not patched.

| Version       | Supported |
|---------------|-----------|
| latest alpha  | yes       |
| anything else | no        |
