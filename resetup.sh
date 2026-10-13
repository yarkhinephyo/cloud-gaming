#!/usr/bin/env bash
# Re-run first-boot setup on the existing VM with the current windows/setup.ps1: stops the VM, replaces its user data,
# starts it again. Stages already marked done on the VM are skipped. Use after fixing a stage that failed or hung.
source "$(dirname "$0")/lib.sh"
[ "$(instance_state)" != none ] || die "no instance; run ./deploy.sh"

setup_inputs
USERDATA=$(mktemp); trap 'rm -f "$USERDATA"' EXIT
render_userdata "$USERDATA"

if [ "$(instance_state)" != stopped ]; then
  log "Stopping $INSTANCE_ID"
  aws ec2 stop-instances --instance-ids "$INSTANCE_ID" --force >/dev/null
  aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
fi
aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --user-data "Value=$(base64 -i "$USERDATA")"
log "User data updated"
exec "$ROOT/deploy.sh"
