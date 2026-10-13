#!/usr/bin/env bash
# SSH into the VM as Administrator (PowerShell). Extra args run as a command: ./ssh.sh 'Get-Content C:\cloud-gaming\setup.log -Tail 30'
source "$(dirname "$0")/lib.sh"
exec ssh -i "$SECRETS/$KEY_NAME.pem" -o UserKnownHostsFile="$SECRETS/known_hosts" -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=10 "Administrator@$(public_ip)" "$@"
