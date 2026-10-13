# Cloud gaming: Deadlock on AWS via Sunshine + Moonlight

Windows Server 2022 on a `g4dn.8xlarge` (NVIDIA T4, 32 vCPU; set in `config.env`) in Singapore (`ap-southeast-1`, ~10 ms from home), with the
NVIDIA gaming driver, a virtual monitor, Sunshine (host) and Steam. Moonlight on the Mac is the client.
Settings: `config.env`. Secrets, passwords and resource ids: `secrets/` (gitignored, mode 600).

| Command | What it does |
|---|---|
| `./deploy.sh` | First run: creates everything and waits ~20-30 min for setup. Later: resumes a paused VM. Always re-points the firewall at your current IP. |
| `./pause.sh` | Stops the VM. No GPU charges; disk + Elastic IP kept (~$24/month). |
| `./cleanup.sh` | Deletes everything (instance, disk incl. Steam library, Elastic IP, security group, key pair). |
| `./status.sh` | State, address, whether Sunshine answers. |
| `./pair.sh <PIN>` | Approves Moonlight's pairing PIN (once per Mac). |

## First time
1. `brew install --cask moonlight`
2. `./deploy.sh`, and wait until it reports that Sunshine is up.
3. In Moonlight, click **+** and enter the IP. Moonlight shows a PIN; run `./pair.sh <PIN>`.
4. Open **Desktop**, sign in to Steam (Steam Guard), and install Deadlock.
5. After that, launch **Deadlock** straight from Moonlight.

Moonlight settings: resolution 1920x1080 or 1728x1117 (14" MBP native/2), 60 FPS, 30-50 Mbps, H.265 (HEVC),
"Optimize mouse for remote desktop" off. Press Ctrl+Option+Shift+M to capture the mouse, and Ctrl+Option+Shift+Q to quit the stream.

## Costs (approximate)
- Running: about $4.40/hour on g4dn.8xlarge ($1.35 on 2xlarge, ~$2.10 on 4xlarge; Windows on-demand in Singapore, est.) plus data out (~$0.12/GB, ~15-20 GB per hour at 40 Mbps).
- Paused: 150 GB gp3 (~$14/mo) + Elastic IP (~$3.6/mo).
- **Pause when you're done.** A forgotten running VM costs about $1,000/month.

## Troubleshooting
- Setup log on the VM: `C:\cloud-gaming\setup.log` (stages: base, nvidia, vdd, apps). RDP as `Administrator`,
  password in `secrets/admin-password`. **Before you disconnect RDP**, run the desktop shortcut
  "RDP - return session to console". Otherwise Sunshine has no session to stream until the next reboot.
- Black screen or no NVENC: in RDP, `nvidia-smi` should show the T4. Device Manager > Display should show
  "Virtual Display Driver" with "Microsoft Basic Display Adapter" disabled.
- If your home IP changed, re-run `./deploy.sh`.
- Launch fails with `VcpuLimitExceeded`: request at least 8 vCPUs of quota `L-DB2E81BA` (Running On-Demand G and VT
  instances) for ap-southeast-1 in Service Quotas.

## Change size

Set `INSTANCE_TYPE` in `config.env`, then `./pause.sh && ./deploy.sh`: the stopped VM is switched over in place
(same disk, IP and setup). Needs enough G-instance vCPU quota; if AWS refuses, it goes back to the old size.

## Admin access

- `./ssh.sh` opens a PowerShell session on the VM as Administrator; `./ssh.sh '<command>'` runs one command.
- Setup progress is written to the serial console: `aws ec2 get-console-output --instance-id <id> --latest`
  (lines start with `cloud-gaming:`); the full log is `C:\cloud-gaming\setup.log` on the VM.
- `./resetup.sh` re-runs first-boot setup with the current `windows/setup.ps1` (stops, swaps user data, starts).
  Stages already done are skipped; delete `C:\cloud-gaming\<stage>.done` on the VM to redo one.
