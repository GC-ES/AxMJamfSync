# Moving AxM Jamf Sync from Claude chat to Claude Code

## 1. Install

```bash
npm install -g @anthropic-ai/claude-code
```
(Requires Node.js 18+. A native installer and a standalone desktop app also
exist if you'd rather not deal with npm — see https://code.claude.com/docs/en/overview
for both.)

```bash
claude --version   # confirm it installed
```

First run in any project prompts an interactive login through your browser —
credentials persist across sessions after that.

## 2. Get the project into a real folder, under git

This is the actual unlock versus the chat workflow: Claude Code works directly
on files on disk, and can run `xcodebuild` itself. No more zip round-trips.

```bash
mkdir -p ~/Developer/AxMJamfSync
cd ~/Developer/AxMJamfSync
unzip ~/Downloads/AxMJamfSync_v2_8_mdmfield_fix.zip -d .
git init
git add -A
git commit -m "Initial import into git"
```

Git isn't optional here — it's your undo button. Every meaningful change should
be its own commit, so a bad edit is one `git checkout -- .` away from gone,
rather than "hope the last zip still has it."

## 3. Drop in the three files

- `CLAUDE.md` → project root. This is loaded automatically at the start of
  every session — it replaces having to re-explain the architecture, the
  invariants, and the gotchas every single time, which is most of what made
  the chat-based workflow token-heavy.
- `.claude/settings.json` → lets Claude read/write files and run `git`/`xcodebuild`
  without a permission prompt on every single call, while still asking before
  anything destructive (`rm`, `git push --force`). Commit this — it's meant to
  be shared/versioned, not personal.
- `.claude/commands/build.md` and `.claude/commands/new-field.md` → two custom
  slash commands. `/build` is a one-word way to say "compile and fix whatever's
  broken." `/new-field <name>` walks through the exact safe sequence for the
  single most error-prone thing in this codebase — adding a field to `Device`/
  `SyncDevice`/`RawJamfComputer` — the same class of bug that caused several
  of the back-and-forth fixes in our chat sessions.

```bash
cd ~/Developer/AxMJamfSync
# copy CLAUDE.md, .claude/settings.json, .claude/commands/*.md into place
git add -A
git commit -m "Add Claude Code project configuration"
```

## 4. Start working

```bash
cd ~/Developer/AxMJamfSync
claude
```

Claude Code reads `CLAUDE.md` automatically. Describe what you want, same as
in chat — but now it edits the real files, and can verify its own work:

```
Add the SECURITY section to the computer fetch (activationLockEnabled,
lockdownModeEnabled, firewallEnabled), wire it through to Device, and build
to confirm it compiles.
```

For anything sizeable, it's worth explicitly asking for a plan first — the
same "present the plan, get a go-ahead, then implement" pattern this project's
CLAUDE.md already documents as the expected workflow:

```
Don't implement yet — just tell me the plan for adding a "Software Updates
Pending" card to the Jamf dashboard.
```

## 5. When to open Xcode

Claude Code is genuinely strong at Swift logic, Core Data mapping, and
concurrency-correctness — the things we spent most of our chat sessions on.
It's weaker at:

- **The `.pbxproj` file.** It's a fragile, non-human-friendly format. Claude
  *can* create new Swift files, but they won't automatically join the Xcode
  target — you'll need to drag them into the project in Xcode once, or ask
  Claude to add the new code to an *existing* file instead where that's a
  reasonable option (which is how nearly all of this project's changes so far
  have actually happened anyway).
- **SwiftUI preview/canvas verification, actual UI look-and-feel, and running
  the app against your real 21k-device Jamf/ABM environment.** `xcodebuild`
  confirms it compiles; it doesn't confirm the dashboard looks right or the
  sync behaves correctly against production data. Keep testing that part in
  Xcode exactly as before.
- **Core Data model changes.** Claude Code can edit the `.xcdatamodeld`
  contents file directly (it's XML), but changes there deserve the same
  scrutiny we've been giving them in chat — review the diff before committing,
  especially anything touching an *existing* attribute (per CLAUDE.md
  invariant #6).

## Best practices for this project specifically

- **Let it build.** After any Swift change, either it runs `xcodebuild` itself
  (the `/build` command makes this a one-word ask) or you ask for it
  explicitly. This single habit eliminates the entire category of bug we hit
  repeatedly in chat — field-ordering mistakes, the Swift 6 concurrency error,
  balance mismatches — because a real compiler catches all of those instantly,
  where I was doing it by hand with `grep` and brace-counting.
- **Commit before big changes, not after.** A checkpoint commit costs nothing
  and means "that made things worse" is a `git diff` + `git checkout` away,
  not a re-explain-everything-and-redo-it conversation.
- **Review the diff on anything touching `.xcdatamodeld` or `PersistenceController.swift`
  yourself**, even if the build passes — a clean compile doesn't guarantee a
  safe migration path for your existing production store.
- **Keep CLAUDE.md a living document.** When something surprises you or costs
  real debugging time (like the `mdmProfileExpiration` vs `mdmCertificateExpiration`
  mix-up did), add a line to CLAUDE.md's invariants section right then. That's
  the exact mechanism that turns "we already learned this the hard way" into
  "Claude never makes that mistake again," instead of relying on either of us
  remembering it next time.
- **Use `/new-field` for anything touching Device/SyncDevice/RawJamfComputer.**
  That's the single highest-recurrence bug class this project has had.

## Using tokens effectively

- **CLAUDE.md is the single biggest lever.** In the chat workflow, every new
  conversation started from zero — architecture, invariants, and conventions
  all had to be re-established or re-discovered from the zip each time.
  CLAUDE.md is read once per session automatically, for free, forever. Keep it
  focused (this one is intentionally under 100 lines) — it's injected into
  *every* session, so padding it with things that don't actually prevent
  mistakes just costs tokens on every future turn.
- **Scope requests to specific files when you know them**, e.g. "in
  `JamfDashboardView.swift`, add X" rather than "look through my whole app and
  add X somewhere sensible." Claude Code can and will search the codebase
  itself when needed, but a precise pointer skips that search entirely.
- **Use `/clear` between unrelated tasks.** It resets the conversation while
  keeping `CLAUDE.md` loaded — cheaper than starting a brand new session, and
  keeps an unrelated earlier task's context from bleeding into the current one.
- **Break large asks into stages**, same as we've generally been doing in
  chat — "add the field to the decode layer" as one step, "wire it through
  Core Data" as the next, rather than one enormous multi-file request. Smaller
  steps are also easier to verify with a build in between.
- **Model choice**: Sonnet is the right default for the bulk of this work —
  Swift logic, wiring fields through layers, fixing compiler errors. Save
  Opus for the genuinely hard calls — a real architecture decision, or a
  gnarly concurrency-correctness question you want maximum scrutiny on.
  Switch anytime with `/model`.
- **Let the compiler be the source of truth instead of manual verification.**
  Every "let me check the balance of braces/parens" step in our chat sessions
  was a token-expensive substitute for something `xcodebuild` does instantly
  and for free. That entire category of overhead goes away in Claude Code.
