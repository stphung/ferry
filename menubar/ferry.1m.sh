#!/bin/bash
#
# <xbar.title>ferry</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Steven Phung</xbar.author>
# <xbar.desc>Two-way mirror status between a NAS folder and OneDrive.</xbar.desc>
# <xbar.dependencies>ferry</xbar.dependencies>
#
# A SwiftBar/xbar plugin. Install it with `ferry menubar install` rather than by
# hand — that sets SwiftBar's plugin directory and refreshes it for you.
#
# This reads ONLY local state, via `ferry status --porcelain`. It never touches
# the network: at a one-minute refresh, polling the cloud would mean ~1,400 API
# calls a day to decorate a menu. Cloud headroom is recorded by `ferry sync`
# while it is already connected, and shown here as of that run.

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# FERRY_BIN lets the test suite point at a checkout instead of the installed
# copy; SwiftBar never sets it.
FERRY=${FERRY_BIN:-$(command -v ferry 2>/dev/null)}
if [ -z "$FERRY" ]; then
	echo "⇄ ?| color=red"
	echo "---"
	echo "ferry not found on PATH"
	echo "brew install stphung/tap/ferry | href=https://github.com/stphung/ferry"
	exit 0
fi

# key=value on stdout; the human report goes to stderr and is discarded here.
raw=$("$FERRY" status --porcelain 2>/dev/null) || {
	echo "⇄ !| color=red"
	echo "---"
	echo "ferry status failed"
	echo "Run ferry doctor | bash=$FERRY param1=doctor terminal=true"
	exit 0
}

get() { printf '%s\n' "$raw" | sed -n "s/^$1=//p" | head -1; }

state=$(get state)

# An older ferry ignores --porcelain and prints nothing to stdout. Say so
# plainly rather than showing an unexplained "?" forever.
if [ -z "$state" ]; then
	echo "⇄ ?| color=red"
	echo "---"
	echo "ferry status --porcelain returned nothing"
	echo "This plugin needs ferry 0.2.0 or newer. | size=11"
	echo "Installed: $($FERRY --version 2>/dev/null || echo unknown) | size=11"
	echo "---"
	echo "brew upgrade stphung/tap/ferry | bash=/usr/bin/open param1=-a param2=Terminal terminal=false"
	exit 0
fi

age=$(get age_seconds)
copied=$(get copied)
deleted=$(get deleted)
outcome=$(get outcome)
duration=$(get duration)
when=$(get when)
log=$(get log)
free_bytes=$(get free_bytes)
interval=$(get interval)
path1=$(get path1)
path2=$(get path2)
schedule=$(get schedule)
errors=$(get errors)

# --- formatting helpers ------------------------------------------------------

human_age() {
	[ -n "$1" ] || { echo "—"; return; }
	awk -v s="$1" 'BEGIN{
		if (s < 60)      printf "%ds", s;
		else if (s<3600) printf "%dm", s/60;
		else if (s<86400)printf "%dh", s/3600;
		else             printf "%dd", s/86400;
	}'
}

human_bytes() {
	[ -n "$1" ] || { echo "—"; return; }
	awk -v b="$1" 'BEGIN{
		u[1]="B";u[2]="KB";u[3]="MB";u[4]="GB";u[5]="TB";i=1;
		while (b>=1024 && i<5) { b/=1024; i++ }
		printf "%.1f %s", b, u[i];
	}'
}

# --- the always-visible title ------------------------------------------------
#
# Icon, age, and the counts from the last run. The icon carries the state so a
# glance is enough; `stale` is amber rather than red because nothing failed —
# runs simply stopped happening, which is the quiet rot worth surfacing.

counts=""
if [ -n "$copied" ] && [ -n "$deleted" ]; then
	counts=" ${copied}↑ ${deleted}↓"
fi

case "$state" in
	syncing)       echo "↻ syncing| color=#4a90d9" ;;
	blocked)       echo "⛔ blocked| color=red" ;;
	failed)        echo "⚠ failed| color=red" ;;
	stale)         echo "⇄ $(human_age "$age")$counts| color=orange" ;;
	unestablished) echo "⇄ setup| color=orange" ;;
	never)         echo "⇄ ready| color=orange" ;;
	ok)            echo "⇄ $(human_age "$age")$counts" ;;
	*)             echo "⇄ ?| color=red" ;;
esac

echo "---"

# --- the dropdown ------------------------------------------------------------

case "$state" in
	blocked)
		echo "BLOCKED — needs a decision | color=red"
		echo "A run stopped and will not retry. Read the log, then resync. | color=red size=11"
		;;
	stale)
		echo "No successful sync in $(human_age "$age") | color=orange"
		echo "That is over twice the $(human_age "$interval") interval. | color=orange size=11"
		;;
	unestablished)
		echo "Pair not established | color=orange"
		echo "Run ferry markers, then ferry resync. | size=11"
		;;
	never)
		echo "Never run | color=orange"
		;;
esac

echo "$path1 | size=11 color=gray"
echo "↕ $path2 | size=11 color=gray"
echo "---"

if [ -n "$when" ]; then
	echo "Last run: $when | size=12"
	echo "Outcome: ${outcome:-?}  ·  ${duration:-?}s | size=12"
	echo "Moved: ${copied:-0} up, ${deleted:-0} down, ${errors:-0} errors | size=12"
fi
if [ -n "$free_bytes" ]; then
	echo "Cloud free: $(human_bytes "$free_bytes")  (as of last sync) | size=12"
fi
echo "Schedule: $schedule, every $(human_age "$interval") | size=12"

echo "---"
echo "Sync now | bash=$FERRY param1=sync terminal=false refresh=true"
echo "Dry run (opens Terminal) | bash=$FERRY param1=sync param2=--dry-run terminal=true"
echo "Check both sides | bash=$FERRY param1=check terminal=true"
echo "Doctor | bash=$FERRY param1=doctor terminal=true"

echo "---"
[ -n "$log" ] && echo "Open latest log | bash=/usr/bin/open param1=-t param2=$log terminal=false"
echo "Open log folder | bash=/usr/bin/open param1=$HOME/.local/state/ferry/logs terminal=false"

echo "---"
# resync decides which side is truth. It must never be one click from a menu,
# so this opens a Terminal where ferry can ask for confirmation as designed.
echo "Resync… (opens Terminal) | bash=$FERRY param1=resync terminal=true"
echo "Refresh | refresh=true"
