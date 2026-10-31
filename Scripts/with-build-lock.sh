#!/bin/bash
# Runs one heavy build at a time on this machine, across every agent session and worktree.
# Parallel cold xcodebuilds, each with its own simulator, push a Mac into swap and make
# every build slower than running them in turn.
# Usage: Scripts/with-build-lock.sh xcodebuild test -scheme Bighelp ...
# BIGHELP_BUILD_LOCK changes the lock path (default /tmp/bighelp-build.lock, the same for
# every session: per-session TMPDIRs would give each one its own lock).
# BIGHELP_BUILD_LABEL names the holder in waiting messages (default: this folder's name).
set -euo pipefail

if (( $# == 0 )); then
  echo "Usage: $0 <command> [arguments...]" >&2
  exit 2
fi

lock=${BIGHELP_BUILD_LOCK:-/tmp/bighelp-build.lock}
label=${BIGHELP_BUILD_LABEL:-$(basename "$PWD")}
# A lock with no owner file is either being taken right now or was left by a holder that
# died before writing it. Only call it stale after longer than any archive takes.
ownerless_stale_minutes=90
waited=0

while ! mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/owner" 2>/dev/null || true)
  pid=${holder%% *}
  if [[ -n $pid ]] && ! ps -p "$pid" >/dev/null 2>&1; then
    echo "with-build-lock: clearing a lock left by a finished build ($holder)" >&2
    rm -rf "$lock"
    continue
  fi
  if [[ -z $holder ]] && [[ -n $(find "$lock" -maxdepth 0 -mmin +$ownerless_stale_minutes 2>/dev/null) ]]; then
    echo "with-build-lock: clearing an ownerless lock older than $ownerless_stale_minutes minutes" >&2
    rm -rf "$lock"
    continue
  fi
  if (( waited % 60 == 0 )); then
    echo "with-build-lock: waiting for ${holder:-another build} (${waited}s so far)" >&2
  fi
  sleep 5
  waited=$((waited + 5))
done

trap 'rm -rf "$lock"' EXIT
echo "$$ $label $(date '+%H:%M:%S')" > "$lock/owner"
# Run the command as a child and wait for it: bash runs a trap only after a foreground
# child ends, so a stopped session would otherwise hold the lock until its build finished.
# A background child ignores SIGINT, so both signals stop it with SIGTERM, and the lock
# goes only once it has exited.
"$@" &
child=$!
stop() { kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; exit "$1"; }
trap 'stop 130' INT
trap 'stop 143' TERM
set +e
wait "$child"
status=$?
set -e
exit "$status"
