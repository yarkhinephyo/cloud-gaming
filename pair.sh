#!/usr/bin/env bash
# Approve a Moonlight pairing request: ./pair.sh <PIN shown by Moonlight>
source "$(dirname "$0")/lib.sh"
PIN=${1:?usage: ./pair.sh <PIN>}
IP=$(public_ip)
# Origin: Sunshine's CSRF check only lets localhost origins call the API without a token.
out=$(curl -sk --max-time 10 -u "sunshine:$(cat "$SECRETS/sunshine-password")" \
  -H 'Content-Type: application/json' -H 'Origin: https://localhost:47990' \
  -d "{\"pin\":\"$PIN\",\"name\":\"$(scutil --get ComputerName 2>/dev/null || hostname)\"}" "https://$IP:47990/api/pin")
echo "$out"
grep -Eq '"status": *(true|"true")' <<<"$out" && log "Paired" || \
  die "pairing failed; enter the PIN at https://$IP:47990/pin instead (user 'sunshine', password in secrets/sunshine-password)"
