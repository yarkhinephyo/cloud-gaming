# First-boot setup for the gaming VM. EC2Launch v2 runs this on every boot (frequency: always), so it works through
# stages, marks each one done in C:\cloud-gaming, reboots where drivers need it, and exits early once finished.
# deploy.sh fills in the __PLACEHOLDERS__. Log: C:\cloud-gaming\setup.log
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = 'C:\cloud-gaming'
New-Item -ItemType Directory -Force -Path $Root | Out-Null
if (Test-Path "$Root\all.done") { exit 0 }
Start-Transcript -Append -Path "$Root\setup.log"

$AdminPassword    = '__ADMIN_PASSWORD__'
$SunshineUser     = 'sunshine'
$SunshinePassword = '__SUNSHINE_PASSWORD__'
$DriverUrl        = '__DRIVER_URL__'
$DriverFile       = '__DRIVER_FILE__'
$SunshineUrl      = '__SUNSHINE_URL__'
$SshPubKey        = '__SSH_PUBKEY__'
$OpenSshMsiUrl    = 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64-v10.0.0.0.msi'
$VddUrl           = 'https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip'
$NefconUrl        = 'https://github.com/nefarius/nefcon/releases/download/v1.21.0/nefcon_v1.21.0.zip'
$VbCableUrl       = 'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip'
$SteamUrl         ='https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe'
$GridCertUrl      = 'https://nvidia-gaming.s3.amazonaws.com/GridSwCert-Archive/GridSwCertWindows_2024_02_22.cert'
$DeadlockAppId    = 1422450

function Done($s) { Test-Path "$Root\$s.done" }
# Progress also goes to the serial console, readable from the Mac: aws ec2 get-console-output --latest
function Say($msg) {
  Write-Output $msg
  try { $c = New-Object IO.Ports.SerialPort COM1, 115200; $c.Open(); $c.WriteLine("cloud-gaming: $msg"); $c.Close() } catch {}
}
function Mark($s) { New-Item -ItemType File -Force -Path "$Root\$s.done" | Out-Null; Say "stage $s done" }
function Fetch($url, $out) {
  for ($i = 1; $i -le 5; $i++) {
    try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out; return } catch { Write-Output "download retry $i ($url): $_"; Start-Sleep 15 }
  }
  Say "download failed: $url"; throw "download failed: $url"
}
function Reboot { Say 'rebooting'; Stop-Transcript; Restart-Computer -Force; exit 0 }
Say "setup script started; done so far: $((Get-ChildItem $Root -Filter *.done).BaseName -join ', ')"

# ---- 1. Windows basics -------------------------------------------------------------------------------------------
if (-not (Done 'base')) {
  Say 'stage base starting'
  net user Administrator $AdminPassword

  # Auto-logon: Sunshine streams the console session, so a user must be logged in at boot.
  $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
  Set-ItemProperty $wl AutoAdminLogon '1'
  Set-ItemProperty $wl DefaultUserName 'Administrator'
  Set-ItemProperty $wl DefaultPassword $AdminPassword
  Set-ItemProperty $wl DefaultDomainName $env:COMPUTERNAME
  Remove-ItemProperty $wl AutoLogonCount -ErrorAction SilentlyContinue

  # Desktop-friendly server: no Ctrl+Alt+Del, Server Manager, shutdown tracker, IE ESC, sleep or screen blanking.
  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' DisableCAD 1
  New-Item -Force 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' | Out-Null
  Set-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Reliability' ShutdownReasonOn 0
  Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null
  foreach ($k in '{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}', '{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}') {
    Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$k" IsInstalled 0 -ErrorAction SilentlyContinue
  }
  powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c   # High performance
  powercfg /change monitor-timeout-ac 0
  powercfg /change standby-timeout-ac 0
  Set-TimeZone -Id 'Singapore Standard Time'

  # Audio is off by default on Windows Server.
  Set-Service AudioEndpointBuilder -StartupType Automatic; Start-Service AudioEndpointBuilder
  Set-Service Audiosrv -StartupType Automatic; Start-Service Audiosrv

  # Games and video playback need Media Foundation, which Server doesn't ship by default.
  Install-WindowsFeature Server-Media-Foundation | Out-Null

  New-NetFirewallRule -DisplayName 'Sunshine TCP' -Direction Inbound -Protocol TCP -LocalPort 47984,47989,47990,48010 -Action Allow | Out-Null
  New-NetFirewallRule -DisplayName 'Sunshine UDP' -Direction Inbound -Protocol UDP -LocalPort 47998,47999,48000,48002,48010 -Action Allow | Out-Null
  Mark 'base'
}

# ---- 1b. SSH (admin access with secrets/cloud-gaming.pem; ./ssh.sh) --------------------------------------------
if (-not (Done 'ssh')) {
  Say 'stage ssh starting'
  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
  if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    Fetch $OpenSshMsiUrl "$Root\openssh.msi"
    Start-Process msiexec.exe -ArgumentList '/i', "`"$Root\openssh.msi`"", '/qn', '/norestart' -Wait
  }
  $ak = 'C:\ProgramData\ssh\administrators_authorized_keys'
  New-Item -ItemType Directory -Force 'C:\ProgramData\ssh' | Out-Null
  Set-Content $ak $SshPubKey -Encoding ASCII
  icacls $ak /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
  New-Item -Force 'HKLM:\SOFTWARE\OpenSSH' | Out-Null
  New-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' DefaultShell -Value "$PSHOME\powershell.exe" -PropertyType String -Force | Out-Null
  Set-Service sshd -StartupType Automatic; Start-Service sshd
  New-NetFirewallRule -DisplayName 'SSH' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow | Out-Null
  Mark 'ssh'
}

# ---- 2. NVIDIA gaming driver (T4 in graphics mode + NVENC) ------------------------------------------------------
if (-not (Done 'nvidia')) {
  Say 'stage nvidia starting'
  $dl = "$Root\$DriverFile"
  Fetch $DriverUrl $dl
  if ($dl -like '*.zip') {
    Expand-Archive $dl "$Root\nvidia" -Force
    $exe = Get-ChildItem "$Root\nvidia" -Recurse -Filter *.exe | Sort-Object Length -Descending | Select-Object -First 1
  } else { $exe = Get-Item $dl }
  Write-Output "installing $($exe.FullName)"
  $p = Start-Process $exe.FullName -ArgumentList '-s', '-noreboot', '-clean' -PassThru
  if (-not $p.WaitForExit(20 * 60 * 1000)) {
    Say 'nvidia installer still running after 20 min; killing it'
    Get-Process | Where-Object { $_.Path -like "$Root\*" -or $_.Name -match '^setup$' } | Stop-Process -Force
  }
  Say "nvidia installer exit code $($p.ExitCode)"

  # Unlock the gaming (non-GRID) license, per the AWS docs for the nvidia-gaming driver.
  New-Item -Force 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global' | Out-Null
  New-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global' vGamingMarketplace -PropertyType DWord -Value 2 -Force | Out-Null
  Fetch $GridCertUrl 'C:\Users\Public\Documents\GridSwCert.txt'
  Mark 'nvidia'
  Reboot
}

# ---- 3. Virtual monitor (the GPU has no physical display for Sunshine to capture) -------------------------------
if (-not (Done 'vdd')) {
  Say 'stage vdd starting'
  Fetch $VddUrl "$Root\vdd.zip";       Expand-Archive "$Root\vdd.zip" "$Root\vdd" -Force
  Fetch $NefconUrl "$Root\nefcon.zip"; Expand-Archive "$Root\nefcon.zip" "$Root\nefcon" -Force
  $inf = (Get-ChildItem "$Root\vdd" -Recurse -Filter MttVDD.inf | Select-Object -First 1).FullName
  $cat = Join-Path (Split-Path $inf) 'mttvdd.cat'
  $nefcon = "$Root\nefcon\x64\nefconw.exe"

  # The first mode is the default. Sunshine doesn't switch modes here (see sunshine.conf), so 1920x1200 (16:10, like
  # a MacBook) is what gets streamed; the rest are there to pick by hand in Windows display settings.
  $modes = '1920x1200','1280x800','1440x900','1470x956','1512x982','1680x1050','1728x1117','1920x1080',
           '2560x1440','2560x1600','2880x1864','3024x1964','3456x2234'
  $res = ($modes | ForEach-Object { $w, $h = $_ -split 'x'; "<resolution><width>$w</width><height>$h</height><refresh_rate>60</refresh_rate></resolution>" }) -join ''
  New-Item -ItemType Directory -Force 'C:\VirtualDisplayDriver' | Out-Null
  $xml = Get-Content (Join-Path (Split-Path $inf) 'vdd_settings.xml') -Raw
  $xml = $xml -replace '(?s)<resolutions>.*</resolutions>', "<resolutions>$res</resolutions>"
  Set-Content 'C:\VirtualDisplayDriver\vdd_settings.xml' $xml -Encoding UTF8

  # Trust the driver's publisher (SignPath Foundation) so the install doesn't stop at a prompt nobody can click.
  Add-Type -AssemblyName System.Security
  $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
  $cms.Decode([IO.File]::ReadAllBytes($cat))
  $certFile = "$Root\vdd-signer.cer"
  [IO.File]::WriteAllBytes($certFile, $cms.SignerInfos[0].Certificate.Export('Cert'))
  Import-Certificate -FilePath $certFile -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

  Start-Process $nefcon -Wait -ArgumentList '--create-device-node', '--hardware-id', 'Root\MttVDD', '--class-name', 'Display', '--class-guid', '4D36E968-E325-11CE-BFC1-08002BE10318'
  Start-Process $nefcon -Wait -ArgumentList '--install-driver', '--inf-path', "`"$inf`""

  # Make the virtual monitor the only display, so games and Sunshine use it (and the NVIDIA GPU).
  Get-PnpDevice -Class Display | Where-Object FriendlyName -like '*Basic Display*' | Disable-PnpDevice -Confirm:$false
  Get-PnpDevice -Class Display | Format-Table -AutoSize FriendlyName, Status | Out-String | Write-Output

  # Virtual sound card for Sunshine to capture: the VM has none, and Steam only adds its streaming speakers when
  # its own Remote Play is used. VB-Cable's driver is Microsoft-signed, so this needs no trust prompt.
  Fetch $VbCableUrl "$Root\vbcable.zip"; Expand-Archive "$Root\vbcable.zip" "$Root\vbcable" -Force
  Start-Process $nefcon -Wait -ArgumentList '--create-device-node', '--hardware-id', 'VBAudioVACWDM', '--class-name', 'MEDIA', '--class-guid', '4d36e96c-e325-11ce-bfc1-08002be10318'
  Start-Process $nefcon -Wait -ArgumentList '--install-driver', '--inf-path', "`"$Root\vbcable\vbMmeCable64_win10.inf`""
  Mark 'vdd'
}

# ---- 4. Steam + Sunshine ---------------------------------------------------------------------------------------
if (-not (Done 'apps')) {
  Say 'stage apps starting'
  Fetch $SteamUrl "$Root\SteamSetup.exe"
  Start-Process "$Root\SteamSetup.exe" -ArgumentList '/S' -Wait

  Fetch $SunshineUrl "$Root\sunshine.msi"
  $p = Start-Process msiexec.exe -ArgumentList '/i', "`"$Root\sunshine.msi`"", '/qn', '/norestart', '/l*v', "`"$Root\sunshine-msi.log`"" -Wait -PassThru
  Say "sunshine msi exit code $($p.ExitCode)"
  $sun = 'C:\Program Files\Sunshine'
  Get-Service -Name *sunshine* -ErrorAction SilentlyContinue | Stop-Service -Force

  # dd_configuration_option = disabled: with the VDD, the NVIDIA and the EC2 default display all present, Sunshine's
  # "only this display" switch hung the launch request. Streaming the VDD as-is works.
  Set-Content "$sun\config\sunshine.conf" -Encoding ASCII -Value @"
sunshine_name = aws-deadlock
origin_web_ui_allowed = wan
encoder = nvenc
dd_configuration_option = disabled
dd_resolution_option = auto
dd_refresh_rate_option = auto
"@
  Set-Content "$sun\config\apps.json" -Encoding ASCII -Value @"
{
  "env": {},
  "apps": [
    { "name": "Desktop", "image-path": "desktop.png" },
    { "name": "Deadlock", "detached": ["steam://rungameid/$DeadlockAppId"], "image-path": "steam.png" },
    { "name": "Steam Big Picture", "detached": ["steam://open/bigpicture"],
      "prep-cmd": [{ "do": "", "undo": "steam://close/bigpicture" }], "image-path": "steam.png" }
  ]
}
"@
  Push-Location $sun
  & "$sun\sunshine.exe" --creds $SunshineUser $SunshinePassword
  Pop-Location
  Get-Service -Name *sunshine* | Set-Service -StartupType Automatic

  # If you ever RDP in, run this before disconnecting, or Sunshine loses the console session.
  Set-Content 'C:\Users\Public\Desktop\RDP - return session to console.bat' -Encoding ASCII -Value @'
@echo off
for /f "skip=1 tokens=3" %%s in ('query user %USERNAME%') do tscon %%s /dest:console
'@
  Mark 'apps'
  Mark 'all'
  Reboot
}
Stop-Transcript
