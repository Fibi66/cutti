#!/usr/bin/env bash
# Run the locally-built Cutti.app with full stdout/stderr captured to
# /tmp/cutti-logs/. Use this when you want to share a reproduction
# with someone debugging — paste the log file at the end of the run.
set -euo pipefail

# Defensively reset the terminal to a sane line-discipline mode. A
# previous invocation that used `script(1)` (an earlier version of
# this helper) could leave the tty in cbreak/raw mode if it died
# before restoring the saved termios. In that state every `\n`
# becomes a bare LF with no carriage return, and any text printed
# afterwards renders as a "staircase" (cursor drops a line but stays
# in the previous column). Calling `stty sane` here costs nothing
# when the tty is already healthy and silently fixes the broken case.
if [[ -t 1 ]]; then
  stty sane 2>/dev/null || true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="${CUTTI_APP:-$REPO_ROOT/build/Cutti.app}"
BIN="$APP/Contents/MacOS/Cutti"

if [[ ! -x "$BIN" ]]; then
  echo "❌ Cutti binary not found at $BIN" >&2
  echo "   Build it first:" >&2
  echo "   SPARKLE_PUBLIC_ED_KEY='...' scripts/package-macos.sh --version 0.1.4 --build 999" >&2
  exit 1
fi

LOG_DIR="/tmp/cutti-logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/cutti-run-$(date +%Y%m%d-%H%M%S).log"

echo "==> Launching Cutti"
echo "    binary: $BIN"
echo "    log:    $LOG_FILE"
echo
echo "    Cutti window will open. When you're done reproducing the issue,"
echo "    quit Cutti normally (⌘Q) and the log file above will contain"
echo "    everything for the debugger to read."
echo "    Tail it live with:   tail -F \"$LOG_FILE\""
echo

# We deliberately pipe through `tee` instead of `script(1)`. The macOS
# `script` command captures raw TTY output, where `\n` is just LF, so
# any embedded newlines render as a "staircase" (cursor drops a line
# but doesn't return to column 0) when the captured log is later
# replayed in a terminal. A plain pipe gives us clean line-based
# output that `cat`, `tail`, and editors all render correctly.
#
# Restore the tty on exit too so that if Cutti or tee ever leaves the
# terminal in a weird state, the next prompt the user sees is sane.
restore_tty() {
  if [[ -t 1 ]]; then
    stty sane 2>/dev/null || true
  fi
}
trap restore_tty EXIT

exec "$BIN" 2>&1 | tee "$LOG_FILE"
