#!/bin/bash
# Compaction-arms benchmark driver v2: --yolo (unattended writes), wall-time
# tracking, full contents in history (spill defeated), one turn per run.
# Arms: server (context_management), client (classic summary), none (baseline).
set -u
B=/tmp/compact_bench
GRAFF=$HOME/.local/bin/graff
mkdir -p $B/runs

run_one() {
  local arm=$1 trial=$2
  local d=$B/runs/${arm}${trial}
  rm -rf "$d"; mkdir -p "$d"; cp -r $B/src "$d"/
  local envs
  case $arm in
    server) envs="GRAFF_SERVER_COMPACT=1 GRAFF_COMPACT_PCT=6";;
    client) envs="GRAFF_SERVER_COMPACT=0 GRAFF_COMPACT_PCT=6";;
    none)   envs="GRAFF_SERVER_COMPACT=0 GRAFF_COMPACT_PCT=100";;
  esac
  envs="$envs GRAFF_TOOL_HANDLE_BYTES=262144"
  echo "== ${arm}${trial} start $(date +%H:%M:%S)"
  local t0=$(date +%s)
  (cd "$d" && env $envs "$GRAFF" --yolo --new --model gpt-5.6-sol < $B/prompt.txt > out.log 2>&1)
  local rc=$?
  echo "$(( $(date +%s) - t0 ))" > "$d/wall_seconds"
  echo "== ${arm}${trial} exit=$rc wall=$(cat $d/wall_seconds)s"
}

if [ "${1:-}" = "wave" ]; then
  # one trial per arm in parallel (wave $2)
  run_one server "$2" & run_one client "$2" & run_one none "$2" & wait
else
  for trial in 1 2; do
    for arm in server client none; do
      run_one $arm $trial
    done
  done
fi
echo "ALL DONE"
