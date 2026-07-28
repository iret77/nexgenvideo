# Musicvideo pipeline start contract

> **LOCKED — owner-approved 2026-07-26.** This is the normative, user-observable contract for the
> beginning of a musicvideo production. Changing the order or semantics requires stopping and asking
> the owner. `hardsteps.json`, phase instructions, host code, tests, and release gates implement this
> contract; none of them may silently redefine it.

## One ordered flow

1. **Track — required.**
   - The first visible pipeline card is always Track for a fresh production.
   - A track already imported into the Media library is offered as a candidate, but importing it does
     not assign it as the project song.
   - The user assigns exactly one track. The host copies it into `audio/` and anchors it at frame zero.
   - The copy in `audio/`, the intake card, and the agent context use the original filename. The
     content-addressed Media-library storage name remains internal.
2. **Lyrics — optional.**
   - The host offers Lyrics directly after Track.
   - Supplying lyrics writes `lyrics/lyrics.txt`; continuing without them is an explicit valid choice.
   - A document imported into the Media library is only a candidate until the user assigns it here.
3. **Project Init.**
   - The agent may confirm song identity and the presence or absence of lyrics.
   - It must not request, infer, or develop a story in this phase.
4. **Audio Analysis — mandatory and approved.**
   - The native analysis runs on the assigned track.
   - Lyrics may label measured sections but never replace measured timing.
   - The analysis gate cannot be approved without a real analysis artifact and interpretation.
5. **Existing creative material — optional, only after approved analysis.**
   - The host offers, in order: existing story/script, prepared characters, prepared locations, and
     style references.
   - Each card accepts material the user already has; every card is skippable.
   - An asset assigned to one role must not appear as a candidate for an incompatible role.
6. **Story development.**
   - With existing story material, the agent develops the production from it and preserves its facts.
   - Without existing story material, the agent starts at zero using the approved song analysis and
     optional lyrics as creative context.

At most one host card or agent decision is visible at a time. The host owns declared file intake; the
agent never duplicates, combines, reorders, or replaces it.

## Durable truth

The current pipeline phase and the phase-scoped hard-step manifest form the runtime state machine.
Files at their deterministic pipeline destinations prove completed assignments:

- track → `audio/`
- lyrics → `lyrics/lyrics.txt`
- existing story → `import/script.md`
- prepared characters → `import/characters/<slug>/`
- prepared locations → `import/locations/<slug>/`
- style references → loose image files in `import/`

Media-library presence alone proves none of these assignments. Optional declines are persisted so a
restart neither repeats nor skips a decision. The media manifest records the role of a library asset
after assignment solely to prevent incompatible reuse in later cards; the deterministic pipeline file
remains the completion proof. Resume derives the next step from phase, pipeline files, and decline
ledger rather than chat history. Once host-owned intake for the current phase is complete, every
agent start, resume, and gate transition includes the pack's instructions for that actual phase.

## Release acceptance

A release candidate is blocked unless independent tests prove this observable trace:

1. A fresh project with a track and lyrics already in the Media library still opens with Track.
2. Assigning Track opens Lyrics; skipping or assigning Lyrics never opens Story next.
3. Project Init advances to Audio Analysis.
4. Existing-story intake cannot appear while Audio Analysis is unapproved.
5. After valid analysis approval, Existing story is the next optional material card.
6. Skipping Existing story reaches story development with analysis context and no invented upload
   requirement.
7. Supplying Existing story reaches story development with both the script and analysis context.
8. Save, close, reopen, and agent resume preserve the same order without duplicate cards or hidden
   agent turns.
9. A content-addressed Media-library track is shown and attached under its original filename; no
   storage hash reaches visible copy or song-title inference.

Static agreement between this document, `hardsteps.json`, phase prose, and source code is not release
evidence. The release test must drive state transitions and assert the visible cards and handoff
context from expectations written independently of those implementation sources.
