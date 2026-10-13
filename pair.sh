#!/usr/bin/env bash
# Approve a Moonlight pairing request: ./pair.sh <PIN shown by Moonlight>
source "$(dirname "$0")/lib.sh"
PIN=${1:?usage: ./pair.sh <PIN>}
IP=$(public_ip)
# Origin: Sunshine's CSRF check only lets localhost origins call the API without a token.
api() {
  curl -sk --max-time 10 -u "sunshine:$(cat "$SECRETS/sunshine-password")" \
    -H 'Content-Type: application/json' -H 'Origin: https://localhost:47990' "$@"
}
fail() { die "$1; or enter the PIN at https://$IP:47990/pin (user 'sunshine', password in secrets/sunshine-password)"; }

# Sunshine wants the id of the pending request (Moonlight must be showing the PIN).
ID=$(api "https://$IP:47990/api/pin" | python3 -c 'import json,sys; p=json.load(sys.stdin).get("pairings") or []; print(p[-1]["id"] if p else "")')
[ -n "$ID" ] || fail "no pending pairing request: click the host in Moonlight first so it shows a PIN"

out=$(api -d "{\"pairing_id\":\"$ID\",\"pin\":\"$PIN\",\"name\":\"$(scutil --get ComputerName 2>/dev/null || hostname)\"}" \
  "https://$IP:47990/api/pin")
echo "$out"
grep -Eq '"status": *(true|"true")' <<<"$out" && log "Paired" || fail "pairing failed"
