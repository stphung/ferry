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
    mkdir -p "$p1" "$p2" "$attic" "$state"
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
teardown() { [[ -n $work ]] && rm -rf "$work"; work=""; }

# seed N numbered files on path1
seed() {
    local n=$1 i
    for ((i = 1; i <= n; i++)); do printf 'v1 file %d\n' "$i" > "$p1/f$i.txt"; done
}

# run ferry with the test config, capturing stdout, stderr and status
run() {
    out=$(FERRY_CONFIG="$conf" FERRY_STATE_DIR="$state" FERRY_PLIST="$work/ferry.plist" \
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
