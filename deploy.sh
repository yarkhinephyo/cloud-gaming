#!/usr/bin/env bash
# Create the gaming VM, or resume it if it's paused. Safe to re-run.
#   ./deploy.sh          create or start, then wait until Sunshine answers
#   ./deploy.sh --dry    only check AWS permissions and inputs
source "$(dirname "$0")/lib.sh"
DRY=${1:-}

start_existing() {
  local st; st=$(instance_state)
  sync_sg_ip
  case $st in
    running) log "Already running" ;;
    stopping) log "Waiting for stop to finish"; aws ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"; start_existing; return ;;
    stopped) log "Starting $INSTANCE_ID"; aws ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null ;;
    pending) ;;
    *) die "instance $INSTANCE_ID is $st; run ./cleanup.sh and deploy again" ;;
  esac
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  exec "$ROOT/status.sh" --wait
}

case $(instance_state) in
  none|terminated|shutting-down) ;;
  *) [ -n "$DRY" ] && { log "Instance exists ($(instance_state)); nothing to dry-run"; exit 0; }; start_existing ;;
esac

# ---- inputs --------------------------------------------------------------------------------------------------------
AMI=$(aws ec2 describe-images --owners amazon --filters "Name=name,Values=$AMI_NAME" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
[ "$AMI" != None ] || die "no AMI matches $AMI_NAME"
log "AMI $AMI"

setup_inputs

VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC" != None ] || die "no default VPC in $REGION"

if [ -n "$DRY" ]; then
  out=$(aws ec2 run-instances --dry-run --image-id "$AMI" --instance-type "$INSTANCE_TYPE" 2>&1 || true)
  grep -q DryRunOperation <<<"$out" \
    && log "Dry run OK: launch permitted (the G-instance vCPU quota is only checked on a real launch)" \
    || die "run-instances dry run failed"
  exit 0
fi

# ---- resources ------------------------------------------------------------------------------------------------------
TAGS="{Key=Name,Value=$NAME},{Key=Project,Value=$NAME}"

KEY_NAME=$NAME
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  log "Creating key pair $KEY_NAME"
  (umask 077; aws ec2 create-key-pair --key-name "$KEY_NAME" --tag-specifications "ResourceType=key-pair,Tags=[$TAGS]" \
    --query KeyMaterial --output text > "$SECRETS/$KEY_NAME.pem")
fi

if [ -z "$SG_ID" ] || ! aws ec2 describe-security-groups --group-ids "$SG_ID" >/dev/null 2>&1; then
  SG_ID=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$NAME" Name=vpc-id,Values="$VPC" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$SG_ID" = None ]; then
    log "Creating security group"
    SG_ID=$(aws ec2 create-security-group --group-name "$NAME" --vpc-id "$VPC" \
      --description "Moonlight/Sunshine + RDP from home IP only" \
      --tag-specifications "ResourceType=security-group,Tags=[$TAGS]" --query GroupId --output text)
  fi
fi
save_state
sync_sg_ip

USERDATA=$(mktemp); trap 'rm -f "$USERDATA"' EXIT
render_userdata "$USERDATA"

log "Launching $INSTANCE_TYPE"
INSTANCE_ID=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" \
  --security-group-ids "$SG_ID" --user-data "file://$USERDATA" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_GB,\"VolumeType\":\"gp3\",\"Iops\":3000,\"Throughput\":250,\"DeleteOnTermination\":true}}]" \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --tag-specifications "ResourceType=instance,Tags=[$TAGS]" "ResourceType=volume,Tags=[$TAGS]" \
  --query 'Instances[0].InstanceId' --output text 2>&1) || {
    echo "$INSTANCE_ID" >&2
    grep -q VcpuLimitExceeded <<<"$INSTANCE_ID" && die "vCPU quota for G instances in $REGION is too low.
  Request >= 8 for 'Running On-Demand G and VT instances' (L-DB2E81BA) in Service Quotas, then re-run."
    die "launch failed"; }
save_state
log "Instance $INSTANCE_ID"

# Elastic IP so Moonlight's saved host address survives pause/resume.
if [ -z "$ALLOC_ID" ]; then
  ALLOC_ID=$(aws ec2 allocate-address --domain vpc --tag-specifications "ResourceType=elastic-ip,Tags=[$TAGS]" \
    --query AllocationId --output text)
  save_state
fi
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
aws ec2 associate-address --allocation-id "$ALLOC_ID" --instance-id "$INSTANCE_ID" >/dev/null
log "Running at $(public_ip). First-boot setup takes ~20-30 min (driver install + 2 reboots)."
exec "$ROOT/status.sh" --wait
