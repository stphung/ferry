# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ferry` keeps a NAS folder and OneDrive as a two-way mirror. It is a wrapper around
`rclone bisync` whose real content is the set of safety decisions around that command,
plus a setup wizard so a new Mac needs no rclone knowledge.

The CLI is one file: `ferry`, bash, targeting **bash 3.2** (what macOS ships). Nothing
is sourced. `app/` holds Ferry.app, a ~350-line SwiftUI menu bar shell over the CLI —
it renders `ferry status --porcelain` and shells out for actions. The porcelain contract
is the API boundary between them; all logic stays in the script.

Design centre: the four things the user actually does are **configure, preview, run,
schedule**. `ferry --help` is grouped by exactly those, and any new command should belong
to one of them or not exist.

## Commands

```sh
make test           # full suite; ./tests/run.sh
make test T="9"     # only that group; T="-k conflict" filters by name
make list-tests
make lint           # shellcheck (skips cleanly if absent)
make deps           # rclone present and new enough for --backup-dir1
make install        # → ~/.local; PREFIX=... to override
make link           # symlink instead of copy, for development
make check-version  # VERSION= in ferry must equal the .TH line in doc/ferry.1
make dist
bash -n ferry       # syntax check
```

## Facts established empirically — do not re-derive, do not assume

These were each verified against rclone v1.75 on macOS. Several contradict the
documentation or the obvious reading of `--help`.

1. **`--max-delete` in bisync is a PERCENTAGE, not a count.** `rclone bisync --help` lists
   the global `--max-delete int` as "limit the number of deletes", which is wrong for
   bisync. Verified: with 21 files and `--max-delete 5`, deleting 6 produces
   `Safety abort: too many deletes (>5%, 6 of 21)`. The config key is documented as a
   percentage everywhere for this reason.

2. **`--check-access` blocks its own bootstrap.** It requires the marker on *both* sides
   before it will run anything — including the `--resync` that would otherwise have
   copied the marker across. This is why `ferry markers` exists as a separate command.
   Do not "fix" this by dropping `--check-access` from `resync`: a `--mode path1` resync
   against an empty-mounting NAS is exactly the case that empties the cloud.

3. **The marker must be *copied*, not touched twice.** Two independent `rclone touch`
   calls produce modtimes milliseconds apart, and bisync validates listings by modtime
   after a resync — it aborts on its own marker with
   `Modtime not equal in listing ... RCLONE_TEST`. `cmd_markers` touches Path1 then
   `copyto`s to Path2 so the two are byte- and time-identical.

4. **A max-delete abort also logs a generic bisync error.** The blocked-reason branches in
   `cmd_sync` are ordered specific-before-general for this reason. Reordering them makes
   every safety abort report itself as lost state, which sends the user to the wrong fix.

5. **`rclone listremotes --type smb --exact`** returns just the matching remote names.
   Used instead of parsing `rclone config dump`.

## Architecture

One script, dispatched from `main`. The parts that carry the design:

**`load_config`** parses `KEY=value` against a whitelist and rejects anything else. It
does not source the file. A typo in a config key is a hard error — silently ignoring
`MAXDELETE=5` would disarm a safety rail without telling anyone.

**`attic_overlaps`** is load-bearing. The attic receives files bisync would delete from
Path1. If it sits inside Path1 it becomes part of the synced tree: every deleted file is
re-uploaded and the attic grows forever inside the cloud. Both `sync` and `resync` refuse
to run when it overlaps, and `doctor` reports it.

**The lock is a directory**, because `mkdir` is atomic and a `-f` test is not. A lock whose
recorded pid is gone is cleared and reported, so a crash cannot wedge the schedule forever.

**`WORKDIR` is under `~/.local/state`**, not rclone's default of `~/Library/Caches/rclone/bisync`.
macOS is free to purge Caches, and losing those listings silently costs a full `--resync`.

**Blocking is deliberate.** When a run fails in a way that needs a human, `cmd_sync` writes
`$STATE_DIR/blocked` containing the explanation, and every subsequent `sync` refuses until
`resync` clears it. The alternative — retrying on a schedule — turns a recoverable problem
into a mystery.

**`resync` and `markers` refuse to run without a terminal** unless passed `--yes`. Both
make decisions about which side is truth; neither may be made by launchd at 3am.

`cmd_doctor` returns non-zero rather than calling `die`, because `cmd_setup` runs it before
the markers exist, where failure is the expected outcome and must not abort setup.

## Tests

`tests/run.sh`, same shape as salvage's: each group is a function `test_<NN>_<slug>`,
discovered with `declare -F` (which sorts alphabetically, so the zero-padded prefix gives
run order and there is no registry to maintain).

**Every group drives the real `rclone bisync` against two local directories.** Nothing is
mocked. Local paths take the same code path as remotes, so conflict resolution, the attic
and the safety rails are exercised rather than asserted about. This is why `is_remote`
exists — a local path is a valid side and has no `listremotes` entry.

Tests override `FERRY_CONFIG`, `FERRY_STATE_DIR` and `FERRY_PLIST` so nothing touches the
real config, state, or `~/Library/LaunchAgents`.

146 assertions across 33 groups. Groups 9 (max-delete blocks the pair), 12 (check-access
guards an empty side) and 22 (a commented config value still arms the rail) are the ones
covering the rails that matter most; if any starts failing, stop and understand why before
changing anything else. The suite also sandboxes `FERRY_SWIFTBAR_DIR` and
`FERRY_APP_DEST` — both exist because a missing override once let the suite delete the
developer's real installation.

Group 22 exists because of a real bug: `ferry setup` writes
`MAX_DELETE=5          # PERCENT of files`, and the original parser took everything after
the `=` as the value. The rail was silently disarmed by the tool's own output. The parser
now strips inline comments (only when preceded by whitespace, so paths containing `#`
survive) and trims padding from both key and value.

## Machine interfaces (what the app consumes)

Single-value surfaces are key=value (`status --porcelain`). List surfaces are
TAB-separated records, one per line, because their rows repeat:
`activity` (epoch, action, path), `attic list` (date, bytes),
`doctor` (ok|bad|info, slug, detail). `config-set KEY VALUE` is the only write
interface — same whitelist as load_config plus per-key value checks, and the
attic-overlap rail holds at write time.

## Ferry.app

One panel: an AppKit NSStatusItem whose click opens a single SwiftUI Window with
sidebar pages (Status, Activity, Attic, Doctor, Settings); onboarding replaces the
panel content while `state=unconfigured`. MenuBarExtra was used in 0.3–0.4 and
replaced deliberately: it cannot open a window on click (it owns its content), and
its labels render monochrome. NSStatusItem does both — the attributed title carries
state by colour AND symbol.

Built by `make app`: SwiftPM produces the binary, the bundle is assembled by hand
(Info.plist.in + codesign -s -) because this machine may have only the CLT — no
xcodebuild. `ferry app install` copies it to ~/Applications (FERRY_APP_DEST overrides,
which is how the test suite stays sandboxed) and drives login registration by running
the app binary with --register-login / --unregister-login — SMAppService can only be
called from inside the app.

UI rules learned the hard way, do not regress them:

- **Every actionable control carries a text label.** Icon-only buttons shipped once
  (the 0.4 popover footer) and were explicitly called out as not understandable.
  SwiftUI toolbars strip Label text by default — use .labelStyle(.titleAndIcon).
- **The wizard is `ferry setup` with a face**: every choice discovers (remotes,
  folders via `browse`) or creates (`remote-create-smb`, `remote-create-onedrive`,
  `mkdir`) through CLI primitives. Nothing — remote names, hosts, providers — is
  hardcoded anywhere.
- **OneDrive onboarding uses rclone's non-interactive config state machine**,
  verified step by step: create(token) → *oauth-confirm(false) →
  choose_type(onedrive) → driveid_final(id) → driveid_final_end(true). `rclone
  backend drives` does NOT work for this (onedrive doesn't support backend
  commands). The only rclone call the app makes itself is `rclone authorize
  onedrive` — the browser sign-in that produces the token.
- FERRY_UI_PAGE / FERRY_UI_STEP are screenshot scaffolding: they preselect a page
  or wizard step and auto-open the panel, because nothing can click the status item
  in an automated capture. Never set in normal use.

The app deliberately has no timer-driven sync (launchd owns the schedule), no network
access of its own, and no one-click resync (the typed ritual lives in ResyncSheet).
Keep it that way.

## Constraints

- **bash 3.2.** No associative arrays, no `${var^^}`, no `mapfile` in `ferry` itself
  (the bash completion may use it; it is only sourced by bash 4+ users' completion setup).
- **macOS only, deliberately.** `date -v-Nd`, `launchctl`, `osascript`, `stty` are used
  freely. A Linux port would need `date -d` and a systemd timer; it was scoped out.
- **Exactly one machine may own the schedule.** bisync state is machine-local. Two hosts
  syncing the same pair each hold a stale view of the other's work.

## Deliberately not here

- **The SwiftBar plugin.** v0.2.x shipped `ferry menubar` + a SwiftBar plugin; v0.3.0
  replaced both with Ferry.app and removed them. `ferry app install` still detects and
  offers to retire a leftover plugin so two indicators never coexist.
- **`consolidate`.** Comparing a folder's contents against the paired tree is
  [`salvage`](https://github.com/stphung/salvage)'s job and it does it better; duplicating
  its rmlint/jq set-difference here was considered and rejected. `doctor` reports cloud
  headroom so the quota question can still be answered before moving a tree in.
- **Filters / selective sync.** The pair is a full mirror. If the cloud quota forces a
  subset later, the filter file becomes a contract both directions must honour identically
  or files get deleted as "missing" — that is a design change, not a config tweak.
- **Running on the NAS.** Considered; the Mac was chosen and macOS idioms used freely.
