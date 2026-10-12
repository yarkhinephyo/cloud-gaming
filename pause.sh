#!/usr/bin/env bash
# Stop the VM: no GPU/compute charges while paused. Disk (Steam library) and Elastic IP are kept (~$18/month).
source "$(dirname "$0")/lib.sh"
st=$(instance_state)
case $st in
  running|pending) log "Stopping $INSTANCE_ID"; aws ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null ;;
  stopping|stopped) ;;
  *) die "no instance to pause ($st)" ;;
esac
aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
log "Paused. ./deploy.sh resumes it; ./cleanup.sh deletes everything."
