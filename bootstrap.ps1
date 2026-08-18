# bootstrap.ps1 - Windows entry point for the Agent OS staged installer.
#
# Windows does not get a separate installer. It gets WSL2, which is Linux, and then
# runs exactly the same bash scripts as Mac. That keeps one codebase instead of two.
#
# Run in an ADMIN PowerShell:
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   .\bootstrap.ps1
#
# This script will never enter a password, card details, or log in on your behalf.

$ErrorActionPreference = "Stop"

function Say  ($m) { Write-Host $m }
function Ok   ($m) { Write-Host "  PASS  $m" -ForegroundColor Green }
function Bad  ($m) { Write-Host "  FAIL  $m" -ForegroundColor Red }
function Warn ($m) { Write-Host "  WARN  $m" -ForegroundColor Yellow }

Say "Agent OS bootstrap for Windows"
Say ""

# --- admin check ---
$admin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $admin) {
  Bad "Not running as Administrator. WSL2 install needs it."
  Say "Right-click PowerShell, Run as administrator, then re-run this script."
  exit 1
}

# --- WSL present? ---
$wslOk = $false
try { wsl.exe --status *> $null; if ($LASTEXITCODE -eq 0) { $wslOk = $true } } catch { }

if (-not $wslOk) {
  Warn "WSL2 not detected. Installing Ubuntu."
  Say "This needs a reboot. Re-run this script afterwards."
  wsl.exe --install -d Ubuntu
  Say ""
  Say "Reboot now, finish the Ubuntu first-run setup (it asks for a username and"
  Say "password of your choosing), then run this script again."
  exit 0
}
Ok "WSL2 available"

# --- default distro ---
$distro = (wsl.exe -l -q | Where-Object { $_.Trim() -ne "" } | Select-Object -First 1).Trim()
if (-not $distro) { Bad "No WSL distro installed. Run: wsl --install -d Ubuntu"; exit 1 }
Ok "Distro: $distro"

# --- locate the installer folder and translate the path ---
$here = $PSScriptRoot
$wslPath = & wsl.exe wslpath -a ($here -replace '\\','/')
if (-not $wslPath) { Bad "Could not translate $here into a WSL path"; exit 1 }
$wslPath = $wslPath.Trim()
Ok "Installer visible inside WSL at $wslPath"

Warn "Performance note: running the Agent OS app from /mnt/c is slow."
Say  "Copy the unzipped agent-os folder into the Linux filesystem (for example ~/agent-os)"
Say  "before you build it. The installer will still work either way, just slower on /mnt/c."
Say ""

# --- base packages inside WSL ---
Say "Installing base packages inside WSL (curl, git, python3, node 20, age, rsync)."
$bash = @'
set -e
sudo apt-get update -qq
sudo apt-get install -y -qq curl git python3 python3-venv python3-pip lsof age rsync
if ! command -v node >/dev/null 2>&1 || [ "$(node -v | tr -d v | cut -d. -f1)" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
node -v; python3 --version
'@
wsl.exe -d $distro -- bash -lc $bash
if ($LASTEXITCODE -ne 0) { Bad "Base package install failed inside WSL"; exit 1 }
Ok "Base packages ready"

# --- hand off ---
Say ""
Say "Handing off to the bash installer."
Say ""
wsl.exe -d $distro -- bash -lc "cd '$wslPath' && chmod +x *.sh && ./setup.sh"

Say ""
Say "When the dashboard is running inside WSL, open it from Windows Chrome at:"
Say "  http://localhost:3737"
Say ""
Say "WSL2 forwards localhost automatically. If it does not resolve, get the WSL IP with:"
Say "  wsl hostname -I"
