#!/usr/bin/env zsh
##############################################################################
# grafana-sciama.sh — one-click, no-sudo SOCKS tunnel to Grafana UI
#
# What it does
#   1. Creates (or reuses) a specific SSH ControlMaster SOCKS tunnel.
#   2. Launches a dedicated browser instance through that SOCKS proxy.
#   3. Cleans up the tunnel automatically when the browser exits.
#
# Notes
#   - Works on macOS and Linux.
#   - Does NOT rely on lsof for tunnel ownership.
#   - Uses a unique temporary Chromium profile per run.
#   - Firefox is supported only via a preconfigured Firefox profile.
#
# Examples
#   chmod +x grafana-sciama.sh
#   ./grafana-sciama.sh
#
# Optional env overrides
#   REMOTE=user@login.example.org SOCKS_PORT=8152 ./grafana-sciama.sh
#
# Firefox
#   Firefox CLI does not set SOCKS proxy settings directly. If you want Firefox:
#     1. Create a dedicated Firefox profile manually.
#     2. Configure SOCKS5 proxy 127.0.0.1:8151 in that profile.
#     3. Set network.proxy.socks_remote_dns=true in that profile.
#     4. Run with e.g.:
#          BROWSER_CMD_LINUX=firefox FIREFOX_PROFILE_NAME=SciamaSocks ./grafana-sciama.sh
##############################################################################

set -euo pipefail
umask 077

# ----- helpers -----
die() {
  print -u2 -- "Error: $*"
  exit 1
}

have_cmd() {
  command -v -- "$1" >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
Usage: ./grafana-sciama.sh [--help]

Open Grafana through an SSH SOCKS tunnel and launch a browser configured to use it.

Examples
  ./grafana-sciama.sh
  REMOTE=sciama-login ./grafana-sciama.sh
  REMOTE=username@login1.sciama.icg.port.ac.uk SOCKS_PORT=8152 ./grafana-sciama.sh

Environment overrides
  REMOTE                SSH host or alias to connect to
  CLUSTER_IP            Private IP or hostname of the Grafana target
  PORT                  Grafana port on the private network
  SOCKS_PORT            Local SOCKS5 listen port
  URL                   Full URL to open instead of CLUSTER_IP/PORT
  BROWSER_BIN_MAC       macOS browser binary path
  BROWSER_CMD_LINUX     Linux browser command in PATH
  FIREFOX_PROFILE_NAME  Preconfigured Firefox profile name
  AUTO_CLOSE_TERMINAL   Set to 1 to close the launching Terminal window on macOS
EOF
}

browser_kind_from_name() {
  local name="${1:l}"
  if [[ "$name" == *firefox* ]]; then
    print -- "firefox"
  else
    print -- "chromium"
  fi
}

control_master_alive() {
  ssh -S "$CONTROL_SOCK" -O check "$REMOTE" >/dev/null 2>&1
}

control_socket_path() {
  local remote="$1"
  local remote_cksum=""

  remote_cksum="$(print -rn -- "$remote" | cksum 2>/dev/null)" || return 1
  remote_cksum="${remote_cksum%% *}"

  print -- "/tmp/sciama_${USER}_${SOCKS_PORT}_${remote_cksum}.ctl"
}

if (( $# > 0 )); then
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unexpected argument: $1. Use --help for usage."
      ;;
  esac
fi

# ----- OS detection -----
OS="${OSTYPE:-unknown}"
IS_DARWIN=0
IS_LINUX=0
[[ "$OS" == darwin* ]] && IS_DARWIN=1
[[ "$OS" == linux*  ]] && IS_LINUX=1

(( IS_DARWIN || IS_LINUX )) || die "Unsupported OS: $OS"

# ----- config (overridable via environment) -----
REMOTE="${REMOTE:-username@login1.sciama.icg.port.ac.uk}"
CLUSTER_IP="${CLUSTER_IP:-10.50.0.6}"
PORT="${PORT:-3000}"
SOCKS_PORT="${SOCKS_PORT:-8151}"
URL="${URL:-http://${CLUSTER_IP}:${PORT}}"

# macOS: full path to browser binary
BROWSER_BIN_MAC="${BROWSER_BIN_MAC:-/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge}"

# Linux: executable in PATH
BROWSER_CMD_LINUX="${BROWSER_CMD_LINUX:-google-chrome}"

# Firefox only: preconfigured profile name
FIREFOX_PROFILE_NAME="${FIREFOX_PROFILE_NAME:-}"

# Optional nicety: set AUTO_CLOSE_TERMINAL=1 if you only use this as a .command
AUTO_CLOSE_TERMINAL="${AUTO_CLOSE_TERMINAL:-0}"

# SSH control socket: key it by remote and local port so reuse is target-specific
CONTROL_SOCK="$(control_socket_path "$REMOTE")" || die "Could not derive SSH control socket path"

# Unique temp browser profile for Chromium-like browsers
PROFILE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sciama-profile.XXXXXX")" || die "Could not create temp profile dir"

# ----- remember Terminal window if requested -----
TERM_ID=""
if (( IS_DARWIN )) && [[ "$AUTO_CLOSE_TERMINAL" == "1" ]] && have_cmd osascript; then
  TERM_ID="$(osascript -e 'tell application "Terminal" to id of front window' 2>/dev/null || true)"
fi

# ----- determine browser -----
if (( IS_DARWIN )); then
  [[ -x "$BROWSER_BIN_MAC" ]] || die "Browser binary not found or not executable: $BROWSER_BIN_MAC"
  BROWSER_CMD="$BROWSER_BIN_MAC"
  BROWSER_KIND="$(browser_kind_from_name "${BROWSER_BIN_MAC##*/}")"
else
  have_cmd "$BROWSER_CMD_LINUX" || die "Browser not found in PATH: $BROWSER_CMD_LINUX"
  BROWSER_CMD="$BROWSER_CMD_LINUX"
  BROWSER_KIND="$(browser_kind_from_name "$BROWSER_CMD_LINUX")"
fi

# ----- browser args -----
typeset -a BROWSER_ARGS
case "$BROWSER_KIND" in
  chromium)
    BROWSER_ARGS=(
      --user-data-dir="$PROFILE_DIR"
      --no-first-run
      --no-default-browser-check
      --proxy-server="socks5://127.0.0.1:${SOCKS_PORT}"
      --proxy-bypass-list="<-loopback>"
      --new-window
      "$URL"
    )
    ;;
  firefox)
    [[ -n "$FIREFOX_PROFILE_NAME" ]] || die \
      "Firefox selected, but FIREFOX_PROFILE_NAME is not set. Configure a dedicated Firefox profile with SOCKS settings first."
    BROWSER_ARGS=(
      -no-remote
      -P "$FIREFOX_PROFILE_NAME"
      "$URL"
    )
    ;;
  *)
    die "Unsupported browser kind: $BROWSER_KIND"
    ;;
esac

# ----- state -----
TUNNEL_CREATED_BY_SCRIPT=0
BROWSER_PID=""

# ----- cleanup -----
cleanup() {
  local rc="${1:-$?}"

  trap - EXIT INT TERM

  if (( TUNNEL_CREATED_BY_SCRIPT )); then
    ssh -S "$CONTROL_SOCK" -O exit "$REMOTE" >/dev/null 2>&1 || true
    [[ -e "$CONTROL_SOCK" ]] && rm -f -- "$CONTROL_SOCK" || true
  fi

  [[ -d "$PROFILE_DIR" ]] && rm -rf -- "$PROFILE_DIR" || true

  if (( IS_DARWIN )) && [[ "$AUTO_CLOSE_TERMINAL" == "1" ]] && [[ -n "$TERM_ID" ]]; then
    (
      sleep 0.3
      osascript -e "tell application \"Terminal\" to if exists (every window whose id is $TERM_ID) then close (every window whose id is $TERM_ID) saving no" >/dev/null 2>&1 || true
    ) &
  fi

  exit "$rc"
}

trap 'cleanup $?' EXIT
trap 'cleanup 130' INT
trap 'cleanup 143' TERM

# ----- start or reuse tunnel -----
if control_master_alive; then
  print -- "Reusing existing tunnel via control socket: $CONTROL_SOCK"
else
  [[ -e "$CONTROL_SOCK" ]] && rm -f -- "$CONTROL_SOCK"

  print -- "Starting SOCKS tunnel on 127.0.0.1:${SOCKS_PORT} via ${REMOTE} ..."
  if ! ssh \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=60 \
      -o ServerAliveCountMax=3 \
      -M \
      -S "$CONTROL_SOCK" \
      -fN \
      -D "127.0.0.1:${SOCKS_PORT}" \
      "$REMOTE"
  then
    die "Failed to start SOCKS tunnel. Check SSH connectivity, key auth, and whether port ${SOCKS_PORT} is already in use."
  fi

  control_master_alive || die "Tunnel start appeared to succeed, but ControlMaster is not responding."
  TUNNEL_CREATED_BY_SCRIPT=1
fi

# ----- launch and wait for browser -----
print -- "Opening ${URL} via ${BROWSER_KIND} over SOCKS5 127.0.0.1:${SOCKS_PORT}"

"$BROWSER_CMD" "${BROWSER_ARGS[@]}" &
BROWSER_PID=$!

wait "$BROWSER_PID"
