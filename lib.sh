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

# Moonlight/Sunshine ports + RDP + SSH, open only to this Mac's current public IP.
SG_RULES_TCP="47984 47989 47990 48010 3389 22"
SG_RULES_UDP="47998 47999 48000 48002 48010"

sg_permissions() {
  local cidr=$1 p perms=""
  for p in $SG_RULES_TCP; do perms+="{\"IpProtocol\":\"tcp\",\"FromPort\":$p,\"ToPort\":$p,\"IpRanges\":[{\"CidrIp\":\"$cidr\"}]},"; done
  for p in $SG_RULES_UDP; do perms+="{\"IpProtocol\":\"udp\",\"FromPort\":$p,\"ToPort\":$p,\"IpRanges\":[{\"CidrIp\":\"$cidr\"}]},"; done
  echo "[${perms%,}]"
}

# Re-point the security group at the current public IP (home IPs change) and the port list above.
sync_sg_ip() {
  local cidr current want p
  cidr="$(my_ip)/32"
  current=$(aws ec2 describe-security-groups --group-ids "$SG_ID" \
    --query 'SecurityGroups[0].IpPermissions[].[IpProtocol,FromPort,IpRanges[0].CidrIp]' --output text | sort)
  want=$( { for p in $SG_RULES_TCP; do printf 'tcp\t%s\t%s\n' "$p" "$cidr"; done
            for p in $SG_RULES_UDP; do printf 'udp\t%s\t%s\n' "$p" "$cidr"; done; } | sort)
  if [ "$current" = "$want" ]; then return; fi
  log "Allowing $cidr in security group $SG_ID"
  local old
  old=$(aws ec2 describe-security-groups --group-ids "$SG_ID" --query 'SecurityGroups[0].IpPermissions' --output json)
  [ "$old" != "[]" ] && aws ec2 revoke-security-group-ingress --group-id "$SG_ID" --ip-permissions "$old" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions "$(sg_permissions "$cidr")" >/dev/null
}

# Download links windows/setup.ps1 needs. The NVIDIA gaming driver sits in an AWS bucket that needs signed requests,
# so the VM gets a 7-day presigned URL.
setup_inputs() {
  DRIVER_KEY=$(aws s3api list-objects-v2 --bucket nvidia-gaming --prefix windows/latest/ \
    --query 'sort_by(Contents,&LastModified)[?ends_with(Key,`.zip`) || ends_with(Key,`.exe`)] | [-1].Key' --output text 2>&1) \
    || die "can't list s3://nvidia-gaming ($DRIVER_KEY). The ai-agent user (and its permissions boundary) needs
  s3:ListBucket + s3:GetObject on arn:aws:s3:::nvidia-gaming and arn:aws:s3:::nvidia-gaming/*"
  [ -n "$DRIVER_KEY" ] && [ "$DRIVER_KEY" != None ] || die "no driver found under s3://nvidia-gaming/windows/latest/"
  log "NVIDIA driver s3://nvidia-gaming/$DRIVER_KEY"
  # The bucket is in us-east-1: a link signed for another region gets a 301 redirect that breaks the signature.
  DRIVER_URL=$(aws s3 presign "s3://nvidia-gaming/$DRIVER_KEY" --region us-east-1 --expires-in 604800)
  [ "$(curl -sS -r 0-0 -o /dev/null -w '%{http_code}' "$DRIVER_URL")" = 206 ] \
    || die "presigned driver URL doesn't work (s3:GetObject denied?)"

  SUNSHINE_URL=$(curl -fsS https://api.github.com/repos/LizardByte/Sunshine/releases/latest |
    python3 -c 'import json,sys; print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if a["name"]=="Sunshine-Windows-AMD64-installer.msi"))')
  log "Sunshine $SUNSHINE_URL"
}

# Fill windows/setup.ps1's placeholders and write the result to $1.
render_userdata() {
  ADMIN_PASSWORD=$(secret admin-password) SUNSHINE_PASSWORD=$(secret sunshine-password) \
  DRIVER_URL=$DRIVER_URL DRIVER_FILE=$(basename "$DRIVER_KEY") SUNSHINE_URL=$SUNSHINE_URL \
  SSH_PUBKEY=$(ssh-keygen -y -f "$SECRETS/$KEY_NAME.pem") \
  python3 - "$ROOT/windows/setup.ps1" > "$1" <<'PY'
import os, sys
s = open(sys.argv[1]).read()
for k in ("ADMIN_PASSWORD", "SUNSHINE_PASSWORD", "DRIVER_URL", "DRIVER_FILE", "SUNSHINE_URL", "SSH_PUBKEY"):
    s = s.replace(f"__{k}__", os.environ[k].replace("'", "''"))
# EC2Launch v2 YAML user data: run the script as SYSTEM on every boot.
body = "\n".join(("      " + l) if l.strip() else "" for l in s.splitlines())
sys.stdout.write("version: 1.0\ntasks:\n- task: executeScript\n  inputs:\n  - frequency: always\n"
                 "    type: powershell\n    runAs: localSystem\n    content: |-\n" + body + "\n")
PY
  [ "$(wc -c < "$1")" -lt 16384 ] || die "user data is over EC2's 16 KB limit"
}
