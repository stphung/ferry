#!/usr/bin/env bash
#
# ferry test suite. Every group drives the real rclone bisync against two local
# directories — no mocks. Local paths exercise the same code path as remotes,
# so conflict resolution, the attic and the safety rails are tested for real
# rather than asserted about.
#
# Each numbered group is a function named test_<NN>_<slug>. The runner at the
# bottom discovers them with `declare -F`, which sorts alphabetically, so the
# zero-padded prefix gives run order with no registry to keep in sync.
#
# Usage:
#   tests/run.sh                 run everything
#   tests/run.sh 5               run group 5
#   tests/run.sh 5 9             run several
#   tests/run.sh -k conflict     run groups whose name matches a substring
#   tests/run.sh -l              list the groups
#   tests/run.sh -v              print passing assertions too

set -uo pipefail

FERRY=$(cd -- "$(dirname -- "$0")/.." && pwd)/ferry
VERBOSE=false
LIST=false
pattern=""
nums=""

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose) VERBOSE=true; shift ;;
        -l|--list)    LIST=true; shift ;;
        -k)           [[ $# -ge 2 ]] || { echo "-k needs a pattern" >&2; exit 2; }
                      pattern=$2; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        [0-9]*)       nums="$nums $1"; shift ;;
        *)            printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

pass=0
fail=0
failed_names=()

if [[ -t 1 ]]; then
    G=$'\033[32m'; R=$'\033[31m'; D=$'\033[2m'; Z=$'\033[0m'
else
    G=""; R=""; D=""; Z=""
fi

work=""
p1=""; p2=""; attic=""; state=""; conf=""

setup() {
    work=$(mktemp -d)
    p1="$work/nas"; p2="$work/cloud"; attic="$work/attic"; state="$work/state"
    conf="$work/config"
    mkdir -p "$p1" "$p2" "$attic" "$state" "$work/swiftbar" "$work/apps"
    cat > "$conf" <<-EOF
	PATH1=$p1
	PATH2=$p2
	ATTIC=$attic
	NOTIFY=0
	MAX_DELETE=5
	TPSLIMIT=0
	EOF
    # --check-access needs the marker; resync propagates it to the far side
    touch "$p1/RCLONE_TEST"
}
# Groups that exercise `schedule install` perform a real `launchctl load`. If
# such a group fails before reaching its uninstall, the agent would stay
# registered against a temp directory that is about to vanish. Unload
# unconditionally so a failing test cannot leave one behind.
teardown() {
    if [[ -n $work ]]; then
        [[ -f $work/ferry.plist ]] && launchctl unload "$work/ferry.plist" 2>/dev/null
        rm -rf "$work"
    fi
    work=""
}

# seed N numbered files on path1
seed() {
    local n=$1 i
    for ((i = 1; i <= n; i++)); do printf 'v1 file %d\n' "$i" > "$p1/f$i.txt"; done
}

# run ferry with the test config, capturing stdout, stderr and status
run() {
    out=$(FERRY_CONFIG="$conf" FERRY_STATE_DIR="$state" FERRY_PLIST="$work/ferry.plist" \
        FERRY_SWIFTBAR_DIR="$work/swiftbar" FERRY_APP_DEST="$work/apps" \
        "$FERRY" "$@" 2>"$work/err")
    status=$?
    err=$(cat "$work/err")
    return 0
}

# establish the pair; most groups need this first
establish() {
    run markers --yes >/dev/null 2>&1
    run resync  --yes >/dev/null 2>&1
}

ok() {
    local name=$1
    pass=$((pass + 1))
    $VERBOSE && printf '%s  ok  %s%s\n' "$G" "$name" "$Z"
    return 0
}
no() {
    local name=$1 detail=$2
    fail=$((fail + 1))
    failed_names+=("$name")
    printf '%sFAIL%s %s\n' "$R" "$Z" "$name"
    printf '%s%s%s\n' "$D" "$(printf '%s' "$detail" | sed 's/^/       /')" "$Z"
    return 0
}
expect_eq() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then ok "$name"
    else no "$name" "expected: [$expected]
actual:   [$actual]"; fi
}
expect_status() {
    local name=$1 expected=$2
    if [[ $status -eq $expected ]]; then ok "$name"
    else no "$name" "expected exit $expected, got $status
stderr: $err"; fi
}
expect_status_not() {
    local name=$1 unexpected=$2
    if [[ $status -ne $unexpected ]]; then ok "$name"
    else no "$name" "expected exit != $unexpected
stderr: $err"; fi
}
expect_contains() {
    local name=$1 needle=$2 hay=$3
    case $hay in
        *"$needle"*) ok "$name" ;;
        *) no "$name" "expected to contain: $needle
actual: $hay" ;;
    esac
}
expect_not_contains() {
    local name=$1 needle=$2 hay=$3
    case $hay in
        *"$needle"*) no "$name" "expected NOT to contain: $needle
actual: $hay" ;;
        *) ok "$name" ;;
    esac
}
expect_file() {
    local name=$1 f=$2
    if [[ -e $f ]]; then ok "$name"; else no "$name" "missing: $f"; fi
}
expect_no_file() {
    local name=$1 f=$2
    if [[ ! -e $f ]]; then ok "$name"; else no "$name" "should not exist: $f"; fi
}


# 1. The command surface itself
test_01_usage_and_dispatch() {
setup
run --version
expect_contains "1a --version prints the version" "ferry 0." "$out$err"
expect_status "1b --version exits 0" 0
run
expect_contains "1c bare invocation shows usage" "keep a NAS folder" "$err"
expect_status "1d bare invocation exits 0" 0
run wibble
expect_status "1e unknown command exits 1" 1
expect_contains "1f unknown command names itself" "wibble" "$err"
teardown
}

# 2. Config is parsed, not sourced — a typo must be loud
test_02_config_validation() {
setup
printf 'NONSENSE=1\n' >> "$conf"
run status
expect_status "2a unknown setting is fatal" 1
expect_contains "2b unknown setting is named" "NONSENSE" "$err"

# a config that is not KEY=value at all
printf 'just a line\n' > "$conf"
run status
expect_status "2c malformed line is fatal" 1
expect_contains "2d malformed line is reported" "not KEY=value" "$err"
teardown
}

# 3. The attic must never live inside the synced tree, or deletions come back
test_03_attic_overlap_is_refused() {
setup
seed 5
establish
printf 'ATTIC=%s/attic-inside\n' "$p1" >> "$conf"
run sync
expect_status "3a attic inside path1 is fatal" 1
expect_contains "3b the overlap is explained" "would sync itself" "$err"
run doctor
expect_contains "3c doctor flags the overlap too" "would sync itself" "$err"
teardown
}

# 4. sync must refuse to invent state — the pair has to be established first
test_04_sync_requires_established_pair() {
setup
seed 3
run sync
expect_status "4a sync before resync exits 1" 1
expect_contains "4b it says how to fix it" "ferry resync" "$err"
teardown
}

# 5. resync establishes the pair, but only once the markers exist
test_05_resync_establishes_pair() {
setup
seed 5
run resync --yes
expect_status "5a resync refuses without markers" 1
expect_contains "5b it names the fix" "ferry markers" "$err"

run markers --yes
expect_status "5c markers succeeds" 0
expect_file "5d marker placed on path2" "$p2/RCLONE_TEST"

run resync --yes
expect_status "5e resync succeeds once markers exist" 0
expect_file "5f files reached path2" "$p2/f3.txt"
run status
expect_contains "5g status reports the pair established" "established" "$err"
teardown
}

# 6. New files move in both directions
test_06_bidirectional_propagation() {
setup
seed 5
establish
printf 'from the nas\n'   > "$p1/nas-side.txt"
printf 'from the cloud\n' > "$p2/cloud-side.txt"
run sync
expect_status "6a sync succeeds" 0
expect_file "6b nas file reached the cloud" "$p2/nas-side.txt"
expect_file "6c cloud file reached the nas" "$p1/cloud-side.txt"
teardown
}

# 7. Same file edited on both sides: newer wins, loser is kept
test_07_conflict_newer_wins_loser_kept() {
setup
seed 5
establish
printf 'edited on the nas\n' > "$p1/f1.txt"
sleep 1
printf 'edited on the cloud LATER\n' > "$p2/f1.txt"
run sync
expect_status "7a sync succeeds through a conflict" 0
expect_eq "7b the newer edit is the live file" "edited on the cloud LATER" "$(cat "$p1/f1.txt")"
expect_file "7c the loser is kept, not destroyed" "$p1/f1.txt.conflict1"
teardown
}

# 8. A propagated delete lands in the attic instead of vanishing
test_08_delete_lands_in_attic() {
setup
seed 20            # 1 delete of 21 files is under the 5% rail
establish
rm "$p2/f9.txt"
run sync
expect_status "8a sync succeeds" 0
expect_no_file "8b the delete propagated to the nas" "$p1/f9.txt"
expect_eq "8c the file is recoverable from the attic" "v1 file 9" \
    "$(cat "$attic"/*/f9.txt 2>/dev/null)"
teardown
}

# 9. Too many deletes aborts, blocks the pair, and says why
test_09_max_delete_blocks_the_pair() {
setup
seed 20
establish
rm "$p2/f1.txt" "$p2/f2.txt" "$p2/f3.txt"   # 3 of 21 = 14%, over the rail
run sync
expect_status_not "9a sync does not report success" 0
expect_file "9b the nas file was NOT deleted" "$p1/f1.txt"
expect_file "9c the pair is marked blocked" "$state/blocked"
expect_contains "9d the block explains the rail" "safety rail" "$(cat "$state/blocked")"
expect_contains "9d2 the block quotes the threshold" "more than 5%" "$(cat "$state/blocked")"

run sync
expect_status "9e a blocked pair refuses to run again" 1
expect_contains "9f the refusal points at resync" "ferry resync" "$err"

run status
expect_contains "9g status surfaces the block" "safety rail" "$err"
teardown
}

# 10. resync is the documented way out of a block, and it clears it
test_10_resync_clears_the_block() {
setup
seed 20
establish
rm "$p2/f1.txt" "$p2/f2.txt" "$p2/f3.txt"
run sync
expect_file "10a precondition: blocked" "$state/blocked"
run resync --yes
expect_status "10b resync succeeds" 0
expect_no_file "10c the block is cleared" "$state/blocked"
run sync
expect_status "10d sync runs again afterwards" 0
teardown
}

# 11. resync will not make a truth decision unattended
test_11_resync_refuses_to_run_headless() {
setup
seed 3
# no --yes, and stdin is not a terminal under the runner
run resync < /dev/null
expect_status "11a headless resync is refused" 1
expect_contains "11b it explains that a human must decide" "needs a human" "$err"
teardown
}

# 12. --check-access is what stops an empty side reading as "delete everything"
test_12_check_access_guards_an_empty_side() {
setup
seed 20
establish
rm "$p1/RCLONE_TEST" "$p2/RCLONE_TEST"
run sync
expect_status_not "12a a missing marker stops the run" 0
expect_file "12b nothing was deleted from the nas" "$p1/f1.txt"
expect_file "12c nothing was deleted from the cloud" "$p2/f1.txt"
teardown
}

# 13. doctor checks the preconditions rather than assuming them
test_13_doctor() {
setup
seed 3
establish
run doctor
expect_status "13a doctor passes on a healthy pair" 0
expect_contains "13b it verifies the markers" "RCLONE_TEST" "$err"
expect_contains "13c it verifies the attic" "does not overlap" "$err"

rm "$p2/RCLONE_TEST"
run doctor
expect_status "13d doctor fails on a missing marker" 1
expect_contains "13e it explains the consequence" "deleted everything" "$err"
teardown
}

# 14. Concurrent runs are skipped, not stacked
test_14_lock_prevents_overlap() {
setup
seed 3
establish
mkdir -p "$state/lock"
printf '%s\n' "$$" > "$state/lock/pid"   # this shell is alive, so the lock is live
run sync
expect_status "14a an overlapping run exits 0 quietly" 0
expect_contains "14b it says why it did nothing" "in progress" "$err"
rm -rf "$state/lock"
teardown
}

# 15. A lock left by a dead process must not wedge the schedule forever
test_15_stale_lock_is_cleared() {
setup
seed 3
establish
mkdir -p "$state/lock"
printf '999999\n' > "$state/lock/pid"    # a pid that cannot be running
run sync
expect_status "15a a stale lock is cleared and the run proceeds" 0
expect_contains "15b the stale lock is reported" "stale lock" "$err"
teardown
}

# 16. status is honest before anything has happened
test_16_status_before_first_run() {
setup
run status
expect_contains "16a the pair is reported unestablished" "not established" "$err"
expect_contains "16b no run is claimed" "never run" "$err"
teardown
}

# 17. The attic is listable and prunable
test_17_attic_commands() {
setup
seed 20
establish
rm "$p2/f9.txt"
run sync
run attic list
expect_status "17a attic list succeeds" 0
expect_contains "17b the dated directory is listed" "$(date +%Y-%m-%d)" "$err$out"

run attic restore "$(date +%Y-%m-%d)"
expect_status "17c attic restore succeeds" 0
expect_file "17d the deleted file is back on the nas" "$p1/f9.txt"
teardown
}

# 18. Dry runs change nothing
test_18_dry_run_is_inert() {
setup
seed 5
establish
printf 'new\n' > "$p1/pending.txt"
run sync --dry-run
expect_status "18a dry run succeeds" 0
expect_no_file "18b nothing was actually transferred" "$p2/pending.txt"
teardown
}

# 19. The launchd job is generated correctly and points at this script
test_19_schedule_plist() {
setup
run schedule status
expect_contains "19a reports when not installed" "not installed" "$err"
# generate without loading: write the plist by hand through the same path
FERRY_CONFIG="$conf" FERRY_STATE_DIR="$state" FERRY_PLIST="$work/ferry.plist" \
    "$FERRY" schedule install >/dev/null 2>&1
if [[ -f $work/ferry.plist ]]; then
    expect_contains "19b the plist calls ferry sync" "<string>sync</string>" "$(cat "$work/ferry.plist")"
    expect_contains "19c the interval is four hours" "<integer>14400</integer>" "$(cat "$work/ferry.plist")"
    expect_contains "19d it points at this checkout" "$FERRY" "$(cat "$work/ferry.plist")"
else
    no "19b plist generation" "no plist written to $work/ferry.plist"
fi
teardown
}

# 20. markers reports what it sees before writing anything
test_20_markers_shows_both_sides_first() {
setup
seed 4
run markers --yes
expect_status "20a markers succeeds" 0
expect_contains "20b it counts the populated side" "5 top-level entries" "$err"
expect_contains "20c it warns that the far side is empty" "looks EMPTY" "$err"
expect_file "20d marker created on path2" "$p2/RCLONE_TEST"

run markers --yes
expect_contains "20e a second run is idempotent" "already present" "$err"
teardown
}

# 21. markers will not act unattended either
test_21_markers_refuses_headless() {
setup
seed 3
run markers < /dev/null
expect_status "21a headless markers is refused" 1
expect_contains "21b it explains why" "needs a human" "$err"
expect_no_file "21c nothing was written" "$p2/RCLONE_TEST"
teardown
}


# 22. Config values must survive inline comments and padding — 'ferry setup'
#     writes them, and a MAX_DELETE parsed as "5  # percent" is a disarmed rail
test_22_config_inline_comments() {
setup
cat > "$conf" <<-EOF
	PATH1=$p1
	PATH2=$p2
	ATTIC=$attic
	NOTIFY=0
	MAX_DELETE=5          # PERCENT of files; abort above this
	  TPSLIMIT = 0
	LOG_KEEP="7"
	EOF
seed 20
establish
rm "$p2/f1.txt" "$p2/f2.txt" "$p2/f3.txt"    # 14%, must still trip a 5% rail
run sync
expect_status_not "22a the rail still fires with a commented value" 0
expect_contains "22b the threshold was parsed as 5" "more than 5%" "$(cat "$state/blocked")"
expect_file "22c nothing was deleted" "$p1/f1.txt"
teardown
}


# 23. The porcelain contract: machine output on stdout, human report on stderr.
#     The menu bar plugin depends on this split — if the human report ever
#     leaked into stdout it would parse as garbage keys.
test_23_porcelain_contract() {
setup
seed 3
establish
run status --porcelain
expect_status "23a porcelain exits 0" 0
expect_eq "23b nothing goes to stderr" "" "$err"
expect_contains "23c state is reported" "state=" "$out"
expect_contains "23d the pair is reported established" "established=1" "$out"
expect_contains "23e paths are reported" "path1=$p1" "$out"
expect_contains "23e2 state_dir is reported (the app watches it)" "state_dir=$state" "$out"
# every line must be key=value, or the plugin's sed parser silently misreads
bad_lines=$(printf '%s\n' "$out" | grep -vc '^[a-z_0-9]*=' || true)
expect_eq "23f every line is key=value" "0" "$bad_lines"
teardown
}

# 24. state is the single field driving the indicator, so its precedence has
#     to hold: syncing > blocked > unestablished > never > failed > stale > ok
test_24_porcelain_state_precedence() {
setup
seed 3

run status --porcelain
expect_contains "24a unestablished before a resync" "state=unestablished" "$out"

establish
run status --porcelain
expect_contains "24b never, once established but not yet run" "state=never" "$out"

run sync
run status --porcelain
expect_contains "24c ok after a successful run" "state=ok" "$out"
expect_contains "24d not stale" "stale=0" "$out"

# backdate the run past 2x the interval
sed -i '' "s/^epoch=.*/epoch=$(( $(date +%s) - 40000 ))/" "$state/last-run"
run status --porcelain
expect_contains "24e stale past 2x the interval" "state=stale" "$out"
expect_contains "24f and flagged" "stale=1" "$out"

# a block outranks staleness
printf 'blocked for a reason\n' > "$state/blocked"
run status --porcelain
expect_contains "24g blocked outranks stale" "state=blocked" "$out"

# a run in progress outranks everything
mkdir -p "$state/lock"; printf '%s\n' "$$" > "$state/lock/pid"
run status --porcelain
expect_contains "24h syncing outranks blocked" "state=syncing" "$out"
rm -rf "$state/lock" "$state/blocked"
teardown
}

# 25. A failed run must surface as failed, not as a stale success
test_25_porcelain_failed_state() {
setup
seed 20
establish
rm "$p2/f1.txt" "$p2/f2.txt" "$p2/f3.txt"   # trips the max-delete rail
run sync
run status --porcelain
expect_contains "25a a tripped rail reports blocked" "state=blocked" "$out"
expect_contains "25b and the block flag is set" "blocked=1" "$out"
teardown
}


# 28. uninstall removes the integrations and keeps the data. Homebrew has no
#     uninstall hook for formulae, so an orphaned launchd agent would otherwise
#     retry a deleted binary every INTERVAL forever.
test_28_uninstall_removes_integrations() {
setup
seed 3
establish
run sync
run schedule install                      # writes to $work/ferry.plist via FERRY_PLIST
expect_file "28a precondition: agent installed" "$work/ferry.plist"

run uninstall
expect_status "28b uninstall succeeds" 0
expect_no_file "28c the launchd agent is gone" "$work/ferry.plist"
expect_file "28d state is KEPT by default" "$state/last-run"
expect_file "28e the config is KEPT by default" "$conf"
expect_contains "28f it says what it kept" "kept" "$err"
printf 'stub\n' > "$work/swiftbar/ferry.1m.sh"
run uninstall
expect_no_file "28f2 it removes the plugin from the sandboxed dir only" \
    "$work/swiftbar/ferry.1m.sh"
expect_contains "28g and points at brew" "brew uninstall ferry" "$err"
teardown
}

# 29. --purge is the destructive variant and must say what it costs
test_29_uninstall_purge() {
setup
seed 3
establish
run sync
expect_file "29a precondition: state exists" "$state/last-run"

run uninstall --purge < /dev/null
expect_status "29b purge without a terminal is refused" 1
expect_file "29c nothing was deleted" "$state/last-run"

run uninstall --purge --yes
expect_status "29d purge with --yes succeeds" 0
expect_no_file "29e state is gone" "$state/last-run"
expect_no_file "29f config is gone" "$conf"
expect_contains "29g it warned about losing the listings" "resync" "$err"
teardown
}


# 30. The app subcommand: status is honest with nothing installed, unknown
#     subcommands fail loudly, remove of nothing is quiet.
test_30_app_subcommand() {
setup
run app status
expect_status "30a app status works with nothing installed" 0
expect_contains "30b it reports not installed" "not installed" "$err"

run app wibble
expect_status "30c unknown subcommand fails" 1
expect_contains "30d and names itself" "wibble" "$err"

run app remove
expect_status "30e remove of nothing succeeds quietly" 0
expect_contains "30f and says so" "not installed" "$err"
teardown
}

# 31. app install copies the bundle into APP_DEST (sandboxed), retires the old
#     SwiftBar plugin, and ferry uninstall takes the app with it. Uses a stub
#     bundle: the real one needs a Swift build, which is CI's `make app` step.
test_31_app_install_lifecycle() {
setup
fakesrc=$(cd -- "$(dirname -- "$FERRY")" && pwd)/app/.build/Ferry.app
had_real=0
[ -d "$fakesrc" ] && had_real=1
if [[ $had_real -eq 0 ]]; then
    mkdir -p "$fakesrc/Contents/MacOS"
    printf '#!/bin/sh\nexit 0\n' > "$fakesrc/Contents/MacOS/Ferry"
    chmod +x "$fakesrc/Contents/MacOS/Ferry"
fi
mkdir -p "$work/apps"
printf 'stub plugin\n' > "$work/swiftbar/ferry.1m.sh"

# headless install: no login prompt path; `open` on a stub fails silently
FERRY_CONFIG="$conf" FERRY_STATE_DIR="$state" FERRY_PLIST="$work/ferry.plist" \
    FERRY_SWIFTBAR_DIR="$work/swiftbar" FERRY_APP_DEST="$work/apps" \
    "$FERRY" app install < /dev/null >/dev/null 2>&1
expect_file "31a the bundle was copied" "$work/apps/Ferry.app/Contents/MacOS/Ferry"

FERRY_CONFIG="$conf" FERRY_STATE_DIR="$state" FERRY_PLIST="$work/ferry.plist" \
    FERRY_SWIFTBAR_DIR="$work/swiftbar" FERRY_APP_DEST="$work/apps" \
    "$FERRY" uninstall >/dev/null 2>&1
expect_no_file "31b ferry uninstall removes the app" "$work/apps/Ferry.app"
expect_no_file "31c and retires the old SwiftBar plugin" "$work/swiftbar/ferry.1m.sh"

[[ $had_real -eq 0 ]] && rm -rf "$fakesrc"
teardown
}


# 32. config-set: validated writes — the settings UI must not be able to
#     disarm a rail with a value the CLI would reject
test_32_config_set() {
setup
run config-set MAX_DELETE 10
expect_status "32a numeric write succeeds" 0
expect_contains "32b the file holds the new value" "MAX_DELETE=10" "$(cat "$conf")"

run config-set MAX_DELETE banana
expect_status "32c non-numeric value rejected" 1
expect_contains "32d the file still holds 10" "MAX_DELETE=10" "$(cat "$conf")"

run config-set NONSENSE 1
expect_status "32e unknown key rejected" 1

run config-set NOTIFY 2
expect_status "32f NOTIFY must be 0 or 1" 1

run config-set ATTIC "$p1/attic-inside"
expect_status "32g attic inside path1 rejected at write time" 1
expect_contains "32h and explained" "would sync itself" "$err"

# replacing preserves the rest of the file
printf '# a comment worth keeping\n' >> "$conf"
run config-set MAX_DELETE 7
expect_contains "32i comment survives a rewrite" "a comment worth keeping" "$(cat "$conf")"
expect_eq "32j exactly one MAX_DELETE line" "1" "$(grep -c '^MAX_DELETE=' "$conf")"
teardown
}

# 33. activity: the feed comes from run logs, newest first, machine-readable
test_33_activity() {
setup
seed 3
establish
printf 'fresh cloud file\n' > "$p2/from-cloud.txt"
run sync
run activity --porcelain
expect_status "33a activity succeeds" 0
expect_contains "33b the copied file appears" "from-cloud.txt" "$out"
first_line=$(printf '%s\n' "$out" | head -1)
case "$first_line" in
    [0-9]*'	'*'	'*) ok "33c records are epoch<TAB>action<TAB>path" ;;
    *) no "33c records are epoch<TAB>action<TAB>path" "got: $first_line" ;;
esac

run activity --porcelain -n 1
expect_eq "33d -n limits the record count" "1" "$(printf '%s\n' "$out" | grep -c .)"

run activity -n 0
expect_status "33e -n 0 is fine and quiet" 0
teardown
}

# 34. attic list --porcelain: date and exact bytes, for the app's browser
test_34_attic_porcelain() {
setup
seed 20
establish
rm "$p2/f9.txt"
run sync
run attic list --porcelain
expect_status "34a attic list --porcelain succeeds" 0
expect_contains "34b today's snapshot is listed" "$(date +%Y-%m-%d)" "$out"
line=$(printf '%s\n' "$out" | head -1)
case "$line" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'	'[0-9]*) ok "34c records are date<TAB>bytes" ;;
    *) no "34c records are date<TAB>bytes" "got: $line" ;;
esac
teardown
}

# 35. doctor --porcelain: same checks, TSV records, exit still meaningful
test_35_doctor_porcelain() {
setup
seed 3
establish
run doctor --porcelain
expect_status "35a healthy pair exits 0" 0
expect_eq "35b nothing on stderr" "" "$err"
expect_contains "35c markers reported ok" "ok	marker" "$out"
expect_contains "35d attic reported ok" "ok	attic" "$out"
bad_lines=$(printf '%s\n' "$out" | grep -vcE '^(ok|bad|info)	[a-z]+	' || true)
expect_eq "35e every record is status<TAB>slug<TAB>detail" "0" "$bad_lines"

rm "$p2/RCLONE_TEST"
run doctor --porcelain
expect_status "35f a missing marker exits 1" 1
expect_contains "35g and is reported bad" "bad	marker" "$out"
teardown
}


# ------------------------------------------------------------------ runner --

all_tests=$(declare -F | awk '{print $3}' | grep '^test_[0-9]' | sort)

label() { printf '%s' "${1#test_}" | sed 's/^\([0-9]*\)_/\1 /; s/_/ /g'; }

if $LIST; then
    for t in $all_tests; do printf '  %s\n' "$(label "$t")"; done
    exit 0
fi

selected=""
for t in $all_tests; do
    keep=false
    if [[ -z $nums && -z $pattern ]]; then
        keep=true
    else
        for n in $nums; do
            [[ $t == test_$(printf '%02d' "$n")_* ]] && keep=true
        done
        if [[ -n $pattern ]]; then
            case $t in *"$pattern"*) keep=true ;; esac
        fi
    fi
    $keep && selected="$selected $t"
done

if [[ -z ${selected// /} ]]; then
    printf 'no groups matched. try: %s -l\n' "$0" >&2
    exit 2
fi

command -v rclone >/dev/null 2>&1 || { printf 'rclone is required to run these tests\n' >&2; exit 2; }

total=$(printf '%s' "$selected" | wc -w | tr -d ' ')
if [[ -z $nums && -z $pattern ]]; then
    printf 'running ferry tests\n\n'
else
    printf 'running %d of %d groups\n\n' "$total" "$(printf '%s' "$all_tests" | wc -w | tr -d ' ')"
fi

for t in $selected; do
    $VERBOSE && printf '%s· %s%s\n' "$D" "$(label "$t")" "$Z"
    "$t"
    teardown
done

printf '\n'
if [[ $fail -eq 0 ]]; then
    printf '%s%d passed, 0 failed%s\n' "$G" "$pass" "$Z"
    exit 0
else
    printf '%s%d passed, %d failed%s\n' "$R" "$pass" "$fail" "$Z"
    for n in "${failed_names[@]}"; do printf '  - %s\n' "$n"; done
    exit 1
fi
