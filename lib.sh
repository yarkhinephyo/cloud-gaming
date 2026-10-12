# Shared helpers, sourced by the other scripts.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SECRETS=$ROOT/secrets
STATE=$SECRETS/state.env
# shellcheck source=config.env
source "$ROOT/config.env"

# AWS creds: env/profile if set, else secrets/aws-ai-agent-credentials.txt (line 1 key id, line 3 secret).
if [ -z "${AWS_ACCESS_KEY_ID:-}" ] && [ -z "${AWS_PROFILE:-}" ]; then
  CREDS=$SECRETS/aws-ai-agent-credentials.txt
  [ -f "$CREDS" ] || { echo "missing $CREDS" >&2; exit 1; }
  AWS_ACCESS_KEY_ID=$(sed -n 1p "$CREDS" | tr -d '[:space:]')
  AWS_SECRET_ACCESS_KEY=$(sed -n 3p "$CREDS" | tr -d '[:space:]')
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
fi
export AWS_DEFAULT_REGION=$REGION AWS_PAGER=""

INSTANCE_ID="" SG_ID="" ALLOC_ID="" KEY_NAME=""
[ -f "$STATE" ] && source "$STATE"

log() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

save_state() {
  umask 077
  cat > "$STATE" <<EOF
INSTANCE_ID=$INSTANCE_ID
SG_ID=$SG_ID
ALLOC_ID=$ALLOC_ID
KEY_NAME=$KEY_NAME
EOF
}

# Alphanumeric only: these get embedded in PowerShell single-quoted strings.
secret() {
  local f=$SECRETS/$1
  if [ ! -s "$f" ]; then (umask 077; LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 > "$f"); fi
  cat "$f"
}

my_ip() { curl -fsS --max-time 5 https://checkip.amazonaws.com | tr -d '[:space:]'; }

instance_state() {
  [ -n "$INSTANCE_ID" ] || { echo none; return; }
  aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo none
}

public_ip() {
  aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

# Moonlight/Sunshine ports + RDP, open only to this Mac's current public IP.
SG_RULES_TCP="47984 47989 47990 48010 3389"
SG_RULES_UDP="47998 47999 48000 48002 48010"

sg_permissions() {
  local cidr=$1 p perms=""
  for p in $SG_RULES_TCP; do perms+="{\"IpProtocol\":\"tcp\",\"FromPort\":$p,\"ToPort\":$p,\"IpRanges\":[{\"CidrIp\":\"$cidr\"}]},"; done
  for p in $SG_RULES_UDP; do perms+="{\"IpProtocol\":\"udp\",\"FromPort\":$p,\"ToPort\":$p,\"IpRanges\":[{\"CidrIp\":\"$cidr\"}]},"; done
  echo "[${perms%,}]"
}

# Re-point the security group at the current public IP (home IPs change).
sync_sg_ip() {
  local cidr current
  cidr="$(my_ip)/32"
  current=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | tr '\t' '\n' | sort -u | tr -d '\n')
  if [ "$current" = "$cidr" ]; then return; fi
  log "Allowing $cidr in security group $SG_ID"
  local old
  old=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissions' --output json)
  [ "$old" != "[]" ] && aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --ip-permissions "$old" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions "$(sg_permissions "$cidr")" >/dev/null
}
