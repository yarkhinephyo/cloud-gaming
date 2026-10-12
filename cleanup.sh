#!/usr/bin/env bash
# Delete everything deploy.sh created (instance + disk, Elastic IP, security group, key pair).
# Finds resources by the Project tag too, in case secrets/state.env was lost.  ./cleanup.sh -y skips the prompt.
source "$(dirname "$0")/lib.sh"

ids=$(aws ec2 describe-instances --filters Name=tag:Project,Values="$NAME" \
  Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
ids=$(echo "$INSTANCE_ID $ids" | tr ' \t' '\n\n' | grep . | sort -u | tr '\n' ' ' || true)
allocs=$(aws ec2 describe-addresses --filters Name=tag:Project,Values="$NAME" --query 'Addresses[].AllocationId' --output text)
allocs=$(echo "$ALLOC_ID $allocs" | tr ' \t' '\n\n' | grep . | sort -u | tr '\n' ' ' || true)
sgs=$(aws ec2 describe-security-groups --filters Name=tag:Project,Values="$NAME" --query 'SecurityGroups[].GroupId' --output text)
sgs=$(echo "$SG_ID $sgs" | tr ' \t' '\n\n' | grep . | sort -u | tr '\n' ' ' || true)

echo "Will permanently delete in $REGION:"
echo "  instances (and their disks, incl. the Steam library): ${ids:-none}"
echo "  elastic IPs: ${allocs:-none}"
echo "  security groups: ${sgs:-none}"
echo "  key pair: $NAME"
if [ "${1:-}" != -y ]; then read -r -p "Type 'delete' to confirm: " ans; [ "$ans" = delete ] || die "aborted"; fi

for id in $ids; do
  state=$(aws ec2 describe-instances --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo gone)
  [ "$state" = terminated ] || [ "$state" = gone ] && continue
  log "Terminating $id"; aws ec2 terminate-instances --instance-ids "$id" >/dev/null
done
[ -n "${ids// /}" ] && aws ec2 wait instance-terminated --instance-ids $ids 2>/dev/null || true
for a in $allocs; do log "Releasing $a"; aws ec2 release-address --allocation-id "$a" || true; done
for sg in $sgs; do log "Deleting $sg"; aws ec2 delete-security-group --group-id "$sg" || true; done
if aws ec2 describe-key-pairs --key-names "$NAME" >/dev/null 2>&1; then log "Deleting key pair $NAME"; aws ec2 delete-key-pair --key-name "$NAME"; fi
rm -f "$STATE" "$SECRETS/$NAME.pem" "$SECRETS/admin-password" "$SECRETS/sunshine-password"
log "Clean. Nothing from this project is left in AWS."
