#!/usr/bin/env bash
# Quick Atlas connectivity diagnostic (macOS). Never hangs; 3s timeouts.
set -u
CLUSTER_HOST="cluster0.vlalwtx.mongodb.net"
SRV_NAME="_mongodb._tcp.${CLUSTER_HOST}"

bold=$'\033[1m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
ok()   { printf "  %s✓%s %s\n" "$green" "$reset" "$1"; }
bad()  { printf "  %s✗%s %s\n" "$red"   "$reset" "$1"; }
warn() { printf "  %s!%s %s\n" "$yellow" "$reset" "$1"; }

echo "${bold}1. Basic internet${reset}"
if curl -sI -m 3 https://www.google.com | head -1 | grep -q 200; then
  ok "Internet is reachable"
else
  bad "No internet — fix your network/WiFi first and retry"
  exit 1
fi

echo "${bold}2. DNS SRV lookup (mongodb+srv:// requires this)${reset}"
SRV_OUT="$(dig +short +time=3 +tries=1 SRV "$SRV_NAME" 2>&1)"
if [ -n "$SRV_OUT" ]; then
  ok "SRV resolves:"
  printf "%s\n" "$SRV_OUT" | sed 's/^/      /'
else
  bad "SRV lookup failed/empty. Your DNS resolver is the problem."
  warn "Try:  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder"
  warn "Or switch DNS to 8.8.8.8 / 1.1.1.1 in System Settings → Network"
fi

echo "${bold}3. DNS TXT (Atlas connection options)${reset}"
TXT_OUT="$(dig +short +time=3 +tries=1 TXT "$CLUSTER_HOST" 2>&1)"
if [ -n "$TXT_OUT" ]; then ok "TXT record present"; else warn "TXT empty (non-fatal)"; fi

echo "${bold}4. TCP reach to Atlas shards (port 27017)${reset}"
REACHED=0
for shard in ac-troto2o-shard-00-00 ac-troto2o-shard-00-01 ac-troto2o-shard-00-02; do
  host="${shard}.vlalwtx.mongodb.net"
  if nc -z -G 3 "$host" 27017 >/dev/null 2>&1; then
    ok "$host:27017 reachable"
    REACHED=$((REACHED+1))
  else
    bad "$host:27017 UNREACHABLE (IP blocked by Atlas allowlist, or cluster paused)"
  fi
done

echo ""
if [ "$REACHED" -ge 1 ] && [ -n "$SRV_OUT" ]; then
  echo "${green}${bold}All green — DB should connect. Restart the server.${reset}"
elif [ "$REACHED" -eq 0 ]; then
  echo "${yellow}${bold}Atlas is blocking your IP, or the cluster is paused.${reset}"
  echo "  → Go to https://cloud.mongodb.com → Network Access → Add Current IP"
  echo "  → And check if the cluster shows 'Resume' (free tier auto-pauses)"
elif [ -z "$SRV_OUT" ]; then
  echo "${yellow}${bold}DNS SRV is the problem. Use the non-SRV connection string as a workaround.${reset}"
fi
