#!/usr/bin/env bash
# Show the VM's state and whether Sunshine is reachable.
#   ./status.sh          one-shot
#   ./status.sh --wait   poll until Sunshine answers (first boot: ~20-30 min)
source "$(dirname "$0")/lib.sh"
st=$(instance_state)
echo "instance: ${INSTANCE_ID:-none} ($st)  type: $INSTANCE_TYPE  region: $REGION"
[ "$st" = running ] || { [ "$st" = stopped ] && echo "paused: ./deploy.sh resumes it"; exit 0; }
IP=$(public_ip)
echo "address:  $IP"

sunshine_up() { curl -sk --max-time 5 -o /dev/null "https://$IP:47990/"; }
if [ "${1:-}" = --wait ]; then
  start=$(date +%s)
  until sunshine_up; do
    printf '\r  waiting for Sunshine... %dm' $(( ($(date +%s) - start) / 60 )) >&2
    (( $(date +%s) - start > 3600 )) && { echo; die "Sunshine not up after 60 min; RDP in and read C:\\cloud-gaming\\setup.log"; }
    sleep 20
  done
  echo >&2
fi

if sunshine_up; then
  echo "sunshine: up (web UI https://$IP:47990, user 'sunshine', password in secrets/sunshine-password)"
  cat <<MSG

Next:
  1. Moonlight -> Add Host (+) -> $IP   (first time only; it shows a 4-digit PIN)
  2. ./pair.sh <PIN>
  3. Open 'Desktop', log in to Steam, install Deadlock; afterwards just launch 'Deadlock'.
MSG
else
  echo "sunshine: not reachable yet (setup still running, or your IP changed: re-run ./deploy.sh)"
fi
