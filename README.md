# ferry

**Two-way mirror between a NAS folder and OneDrive, without remembering a single rclone flag.**

`ferry` wraps [`rclone bisync`](https://rclone.org/bisync/) in the safety rails a two-way
mirror of real data actually needs, and hides them behind a handful of commands. Set it up
once per machine, then it runs itself.

```console
$ ferry setup
$ ferry markers
$ ferry resync
$ ferry schedule install
```

That is the whole install on a new Mac. Everything after it is `ferry status`.

## Why not just run rclone

`rclone bisync` is powerful and unforgiving. The default invocation will, given an
unreachable NAS, cheerfully conclude that you deleted everything and empty your cloud to
match. `ferry` is the set of decisions that stop that:

| Rail | What it prevents |
|---|---|
| `--check-access` with marker files on both sides | An unreachable or empty-mounting share reading as "the user deleted everything" |
| `MAX_DELETE=5` (a **percentage**) | A runaway deletion propagating in either direction. rclone's own default is 50% |
| An attic on the NAS, outside the synced tree | Deleted and overwritten files becoming unrecoverable |
| `--conflict-resolve newer --conflict-loser num` | An edit on one side silently destroying an edit on the other |
| Durable workdir under `~/.local/state` | macOS purging `~/Library/Caches` and forcing a full resync |
| A lock, and a refusal to run while blocked | Runs stacking up, or a schedule grinding on through a problem that needs you |

## Install

```sh
brew install stphung/tap/ferry
ferry setup
```

That is the whole thing on a fresh Mac. The formula pulls in `rclone`, and puts the man
page and shell completions where Homebrew already looks — no `PATH` fiddling.

<details>
<summary>Installing from source instead</summary>

`ferry` is a single self-contained shell script. It needs `rclone` (≥ 1.66, for
`--backup-dir1`) at runtime, and nothing else.

```sh
brew install rclone
make install                    # → ~/.local, no sudo
ferry setup
```

`make install` places the script, its man page, and shell completions under `PREFIX`,
which defaults to `~/.local`:

```sh
make install PREFIX=/opt/homebrew        # alongside your other brew tools
sudo make install PREFIX=/usr/local      # system-wide
make uninstall                           # removes all four files
```

For development, `make link` symlinks the script instead of copying it.

</details>

## Setting up a new machine

`ferry setup` is interactive and asks about six things:

- **the NAS remote** — picks up an existing SMB remote, or creates one from a host,
  username and password (obscured for you)
- **the folder that pairs with the cloud** — default `Vault`
- **the cloud remote** — picks up an existing OneDrive remote, or hands you to
  `rclone config` for the browser sign-in, then carries on
- **the attic** — where deleted files go, and it refuses any path inside the synced tree
- **how often to sync** — default every 4 hours

It writes `~/.config/ferry/config`, runs `ferry doctor`, and prints the exact remaining
steps. Nothing is synced until you ask.

Then, once:

```sh
ferry markers      # place the safety markers on both sides
ferry resync -n    # preview establishing the pair
ferry resync       # establish it — asks you to type 'resync'
```

`markers` shows you the top-level entry count of both sides *before* it writes anything,
because a share that mounts empty is the failure mode worth catching by eye.

## Daily use

```sh
ferry sync -n      # what would a run do?
ferry sync         # do it
ferry status       # what happened last time, and is the pair healthy?
ferry check        # compare both sides directly, read-only
ferry doctor       # every precondition, including cloud headroom
```

`ferry schedule install` hands `ferry sync` to launchd. Missed runs (Mac asleep) fire on
wake, overlapping runs are skipped by the lock, and a failure posts a macOS notification —
success is silent.

## When it stops

A two-way mirror sometimes needs a human, and `ferry` is built to stop rather than guess.
When it does, `~/.local/state/ferry/blocked` appears, `ferry status` shows it, and every
`ferry sync` refuses until it's resolved. Two causes:

**Too many deletes.** More than `MAX_DELETE` percent of files were about to disappear.
This is the rail working. Read the log, decide whether the deletions are real, then
`ferry resync`.

**Lost state.** bisync can no longer tell a deletion from a file it has never seen.
Re-establishing means choosing which side is truth:

```sh
ferry resync                  # the NAS wins where they differ (default)
ferry resync --mode path2     # OneDrive wins
ferry resync --mode newer     # the newer file wins, per file
```

## Recovering a deleted file

```sh
ferry attic list                  # dated directories, with sizes
ferry attic restore 2026-08-01    # copy that day's files back, never overwriting
ferry attic prune                 # drop anything past ATTIC_KEEP_DAYS
```

## Configuration

`~/.config/ferry/config`, `KEY=value`, one per line. It is **parsed, not sourced** — a
typo is an error rather than a silent no-op.

```sh
PATH1=unas-vault:Vault        # the NAS side, and the default winner at resync
PATH2=onedrive:               # the cloud side
ATTIC=unas-vault:ferry-attic  # MUST be outside PATH1

MAX_DELETE=5                  # percent, not a count
ATTIC_KEEP_DAYS=90
INTERVAL=14400                # 4 hours

TRANSFERS=8
CHECKERS=16
TPSLIMIT=10
LOG_KEEP=30
NOTIFY=1
```

See `man ferry` for every key.

## Limits worth knowing

- **Exactly one machine may own the schedule.** bisync's state is machine-local; two Macs
  syncing the same pair each hold a stale view of the other's work and will produce
  spurious deletes.
- **Cloud quota is a hard ceiling.** `ferry doctor` prints the headroom. Anything you move
  into the NAS folder gets pushed up, so check before you move a large tree.
- **Filenames.** Going NAS → OneDrive, files containing `: * ? " < > |`, trailing dots or
  spaces, or paths beyond ~400 characters will need attention. rclone encodes around most
  of it, but not all.
- **A run lists both sides in full.** bisync does not use OneDrive's delta API, so even a
  no-op run against a large drive takes minutes. That is why the default cadence is hours,
  not minutes.

## Related

[`salvage`](https://github.com/stphung/salvage) answers the other question — *if I delete
this, what do I lose?* Use it to check a folder's contents are already in the paired tree
before you consolidate it in.

## Development

```sh
make test           # full suite; every group drives real rclone bisync, no mocks
make test T="9"     # one group; T="-k conflict" filters by name
make list-tests
make lint           # static analysis — the exact command CI runs
make lint-tools     # brew install shellcheck actionlint
make hooks          # enable the committed git hooks (once per clone)
make deps           # verify rclone is present and new enough
make check-version  # VERSION= in ferry must match the man page
```

### Git hooks

The hooks are committed in `.githooks/`, but `core.hooksPath` is per-clone git config,
so a fresh checkout needs one command:

```sh
make hooks          # make unhooks reverses it
```

- **pre-commit** — `make check-version` and `make lint`. The fast half, about a second.
- **pre-push** — those plus `make test`. The last gate before code becomes public, so it
  repeats the static analysis deliberately: a commit made with `--no-verify` would
  otherwise reach the remote having been checked by nothing.

They invoke the same make targets CI does rather than restating the commands, so the two
cannot drift. What they **cannot** catch is a tool version difference between your machine
and the runner — that class is handled in `.shellcheckrc`.

### Releasing

The Homebrew formula points at GitHub's auto-generated tag tarball, so cutting a version
needs only a pushed tag — no release assets.

```sh
# 1. bump VERSION= in ferry and the .TH line in doc/ferry.1, then:
make check-version
git tag -a v0.2.0 -m "ferry 0.2.0" && git push origin v0.2.0

# 2. bump the formula in stphung/homebrew-tap:
curl -fsSL https://github.com/stphung/ferry/archive/refs/tags/v0.2.0.tar.gz | shasum -a 256
```

Update `url` and `sha256` in `Formula/ferry.rb` and commit.
