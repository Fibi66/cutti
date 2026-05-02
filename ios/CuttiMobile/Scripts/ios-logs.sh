#!/bin/bash
# Stream CuttiMobile logs from the simulator *or* a connected iPhone.
#
# Usage:
#   ./ios-logs.sh                    # sim, live stream (Ctrl-C to stop)
#   ./ios-logs.sh last 10m           # sim, print last 10m and exit
#   ./ios-logs.sh device             # iPhone, live stream
#   ./ios-logs.sh device last        # iPhone, hint for past-log path
#
# Simulator path uses `xcrun simctl spawn booted log stream` with a
# predicate scoped to our os.Logger subsystem. Device path uses
# `idevicesyslog` from libimobiledevice (install with
# `brew install libimobiledevice`) filtered to our process name, with
# a clear fallback message if the tool isn't present — Apple doesn't
# ship a first-party CLI that streams a connected device's unified
# log, so Console.app remains the no-install option.

set -euo pipefail

SIM_PREDICATE='subsystem == "app.cutti.ios" OR process == "CuttiMobile"'

stream_simulator() {
    if ! xcrun simctl list devices booted 2>/dev/null | grep -q Booted; then
        echo "No booted simulator. Start one from Xcode → Window → Devices,"
        echo "or run:  xcrun simctl boot 'iPhone 17 Pro'"
        exit 1
    fi
    if [[ "${1:-}" == "last" ]]; then
        local range="${2:-10m}"
        exec xcrun simctl spawn booted log show \
            --last "$range" --style compact --predicate "$SIM_PREDICATE"
    fi
    echo "Streaming CuttiMobile simulator logs (Ctrl-C to stop)…"
    exec xcrun simctl spawn booted log stream \
        --style compact --predicate "$SIM_PREDICATE"
}

stream_device() {
    if ! command -v idevicesyslog >/dev/null 2>&1; then
        cat <<'EOF'
Real-device log streaming needs libimobiledevice. Install it once:

    brew install libimobiledevice

Then re-run:  ./ios-logs.sh device

Alternatively, no-install options:
  • Console.app → left sidebar → select your iPhone →
    search "subsystem:app.cutti.ios"
  • Xcode → Window → Devices and Simulators → select iPhone →
    "Open Console"
EOF
        exit 1
    fi
    if [[ "${1:-}" == "last" ]]; then
        cat <<'EOF'
idevicesyslog can only stream live — it has no past-log mode.
For historical device logs, open Console.app, select your iPhone in
the sidebar, and scroll back, or grab a sysdiagnose via
Settings → Privacy & Security → Analytics & Improvements.
EOF
        exit 1
    fi
    echo "Streaming CuttiMobile device logs (Ctrl-C to stop)…"
    # -p filters by sender process name (exact). -m would match any
    # line containing 'CuttiMobile' — including every audiomxd /
    # symptomsd / mediaplaybackd entry that mentions our app in its
    # session description, drowning out the signal. -p restricts to
    # lines actually emitted by our binary, which is what our
    # os.Logger subsystem lands under.
    exec idevicesyslog -p CuttiMobile
}

case "${1:-}" in
    device) shift; stream_device "$@" ;;
    *)      stream_simulator "$@" ;;
esac

