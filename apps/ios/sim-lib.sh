#!/bin/bash
# Shared simulator lifecycle (#407). Source this after (optionally) setting
# SIM/BUNDLE. It resolves $SIM to a UDID once, boots only when needed, and
# a trap tears down what this run started: the launched app always, the
# device only if this run booted it. A pre-booted device is left alone.
#   KEEP=1     keep app + device running on exit (interactive debugging)
#   SIM_GUI=1  open the Simulator window — headless is the default; simctl
#              install/launch/io screenshot all work without the GUI.

SIM="${SIM:-iPhone 17 Pro}"
BUNDLE="${BUNDLE:-com.codegraff.graff}"

sim_udid="$(xcrun simctl list devices available | awk -v n="$SIM" -F '[()]' 'index($0, n" (") {print $2; exit}')"
[ -n "$sim_udid" ] || { echo "no available simulator named '$SIM'" >&2; exit 1; }

sim_booted_by_us=0
sim_cleanup() {
  [ "${KEEP:-0}" = 1 ] && return 0
  xcrun simctl terminate "$sim_udid" "$BUNDLE" 2>/dev/null || true
  [ "$sim_booted_by_us" = 1 ] && xcrun simctl shutdown "$sim_udid" 2>/dev/null || true
}
trap sim_cleanup EXIT INT TERM

sim_boot() {
  xcrun simctl list devices | grep "$sim_udid" | grep -q '(Booted)' && return 0
  xcrun simctl boot "$sim_udid"
  sim_booted_by_us=1
  [ "${SIM_GUI:-0}" = 1 ] && open -a Simulator >/dev/null 2>&1 || true
}
