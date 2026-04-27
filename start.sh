#!/usr/bin/env bash
# Trust Layer — one-command dev launcher for macOS.
# Starts the web UI, AI service (+ worker) and user-service in parallel,
# streams color-prefixed logs to your terminal, and shuts them all down
# cleanly on Ctrl+C.
#
# Usage:
#   ./start.sh                  # run ui + ai (api) + ai-worker + server
#   NO_WORKER=1 ./start.sh      # skip the BullMQ worker (no Redis needed)
#   ONLY=ui,server ./start.sh   # run only selected services (comma list)
#
# Service → port map:
#   ui      web/            http://localhost:3000
#   server  user-service/   http://localhost:4000
#   ai      neucleas-ai/    http://localhost:5000   (PORT=5000 override)
#   worker  neucleas-ai/    (BullMQ worker — needs Redis on :6379)
#   store   poc-store/      http://localhost:6001   (POC e-commerce demo)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# ── ANSI colors ──────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  CYAN=$'\033[36m'
  MAGENTA=$'\033[35m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  BLUE=$'\033[34m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
else
  CYAN=''; MAGENTA=''; GREEN=''; YELLOW=''; RED=''; BLUE=''; BOLD=''; DIM=''; RESET=''
fi

log()  { printf "%s%s%s\n" "$BOLD" "$*" "$RESET"; }
warn() { printf "%s%s%s\n" "$YELLOW" "$*" "$RESET"; }
err()  { printf "%s%s%s\n" "$RED" "$*" "$RESET" >&2; }

# ── Preflight ────────────────────────────────────────────────────────────────
command -v node >/dev/null 2>&1 || { err "node is not installed. Install Node 18+ and retry."; exit 1; }
command -v npm  >/dev/null 2>&1 || { err "npm is not installed."; exit 1; }

# ── Service selection ────────────────────────────────────────────────────────
DEFAULT_SERVICES=("server" "ai" "worker" "ui" "store")
if [ "${NO_WORKER:-0}" = "1" ]; then
  DEFAULT_SERVICES=("server" "ai" "ui" "store")
fi

if [ -n "${ONLY:-}" ]; then
  IFS=',' read -ra SELECTED <<< "$ONLY"
else
  SELECTED=("${DEFAULT_SERVICES[@]}")
fi

has_service() {
  local s
  for s in "${SELECTED[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# ── Dependency install (only when node_modules is missing) ───────────────────
ensure_deps() {
  local name="$1" dir="$2"
  if [ ! -d "$dir/node_modules" ] && [ -f "$dir/package.json" ]; then
    warn "Installing dependencies for $name..."
    ( cd "$dir" && npm install --silent ) || { err "npm install failed for $name"; exit 1; }
  fi
}

log "Preparing dependencies..."
has_service ui     && ensure_deps "ui (web)"            "$ROOT/web"
has_service server && ensure_deps "server (user-service)" "$ROOT/user-service"
has_service store  && ensure_deps "store (poc-store)"   "$ROOT/poc-store"
if has_service ai || has_service worker; then
  if [ -f "$ROOT/neucleas-ai/package.json" ]; then
    ensure_deps "ai (neucleas-ai)" "$ROOT/neucleas-ai"
  elif [ ! -d "$ROOT/neucleas-ai/node_modules" ]; then
    warn "neucleas-ai has no package.json; if it fails to start, run \`npm install\` there manually."
  fi
fi

# ── Child tracking + graceful shutdown ───────────────────────────────────────
PIDS=()

kill_tree() {
  local parent=$1 child
  for child in $(pgrep -P "$parent" 2>/dev/null); do
    kill_tree "$child"
  done
  kill -TERM "$parent" 2>/dev/null || true
}

cleanup() {
  trap - INT TERM EXIT
  printf "\n%sShutting down all services...%s\n" "$YELLOW" "$RESET"
  for pid in "${PIDS[@]}"; do kill_tree "$pid"; done
  sleep 0.5
  for pid in "${PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  printf "%sAll services stopped.%s\n" "$GREEN" "$RESET"
}
trap cleanup INT TERM EXIT

# ── Spawn helper: tags every line with [service] in color ────────────────────
spawn() {
  local name="$1" color="$2" dir="$3"
  shift 3
  local tag="${color}[${name}]${RESET}"
  (
    cd "$dir" || exit 1
    exec "$@"
  ) 2>&1 | awk -v tag="$tag" '{ print tag, $0; fflush(); }' &
  PIDS+=($!)
}

# ── Banner ───────────────────────────────────────────────────────────────────
printf "\n%s Trust Layer · dev launcher %s\n" "$BOLD" "$RESET"
printf "%s%s%s\n" "$DIM" "Ctrl+C to stop everything." "$RESET"
printf "\n"
has_service server && printf "  %s[server]%s  user-service  → http://localhost:4000\n" "$CYAN"    "$RESET"
has_service ai     && printf "  %s[ai]    %s  neucleas-ai   → http://localhost:5000\n" "$MAGENTA" "$RESET"
has_service worker && printf "  %s[worker]%s  neucleas-ai   → BullMQ queue (needs Redis)\n" "$MAGENTA" "$RESET"
has_service ui     && printf "  %s[ui]    %s  web (Vite)    → http://localhost:3000\n" "$GREEN"   "$RESET"
has_service store  && printf "  %s[store] %s  poc-store     → http://localhost:6001\n" "$YELLOW"  "$RESET"
printf "\n"

# ── Start services ───────────────────────────────────────────────────────────
has_service server && spawn "server" "$CYAN"    "$ROOT/user-service" npm run dev
has_service ai     && spawn "ai"     "$MAGENTA" "$ROOT/neucleas-ai"  env PORT=5000 node index.js
has_service worker && spawn "worker" "$BLUE"    "$ROOT/neucleas-ai"  node worker.js
has_service ui     && spawn "ui"     "$GREEN"   "$ROOT/web"          npm run dev
has_service store  && spawn "store"  "$YELLOW"  "$ROOT/poc-store"    node server.js

if [ "${#PIDS[@]}" -eq 0 ]; then
  err "No services selected. Check ONLY=... value."
  exit 1
fi

wait
