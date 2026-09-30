<#
.SYNOPSIS
    Sets up Odoo 20 (Community) with Docker Desktop on Windows 11.

.DESCRIPTION
    Version 2.1 (2026-09-29) - shareable version for any Windows 11 computer.
    New in 2.1: uses an already running Docker engine, detects Rancher Desktop /
    Podman and Docker inside WSL distributions, switches Windows containers to Linux.

    The script works step by step and can be re-run at any time;
    steps that are already done are detected and skipped.

      1. Check requirements (Windows 11, x64 or ARM64, virtualization, disk space)
      2. Enable WSL 2 (restart if needed, then continue automatically)
      3. Check Docker: use a running engine, otherwise download Docker Desktop,
         verify its signature and install it silently
      4. Start Docker Desktop and wait for the engine
      5. Create the project folder with compose.yaml and odoo.conf (random passwords)
      6. Pull images, start containers, wait until Odoo responds

    Security:
      - By default Odoo is ONLY reachable from this computer (127.0.0.1).
      - The Docker installer is only run if it carries a valid
        signature from Docker Inc.
      - Database and master passwords are newly generated for each installation.

    License: The script accepts the Docker Desktop license. Docker Desktop is free
    for personal use, education and businesses with fewer than 250 employees
    AND less than USD 10 million annual revenue; otherwise a paid subscription is required.

    Not automatable: enabling virtualization in the BIOS/UEFI (if disabled)
    and creating the first database in the browser.

.PARAMETER InstallDir          Project folder (default: C:\odoo20)
.PARAMETER OdooVersion         Image tag of odoo (default: 20.0)
.PARAMETER PostgresVersion     Image tag of postgres (default: 16)
.PARAMETER Port                Port on this computer (default: 8069)
.PARAMETER WslMemoryGB         RAM limit for WSL in GB; 0 = do not create .wslconfig (default: 8)
.PARAMETER AllowNetworkAccess  Make Odoo reachable from other devices on the network (not recommended)
.PARAMETER Force               Rewrite compose.yaml and odoo.conf even if they exist
.PARAMETER Yes                 Skip confirmation prompts (default answer: continue)
.PARAMETER IgnoreOtherEngines  Install Docker Desktop even if Rancher Desktop or Podman is present

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-odoo20.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-odoo20.ps1 -OdooVersion 19.0 -Port 8070
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallDir      = 'C:\odoo20',
    [string]$OdooVersion     = '20.0',
    [string]$PostgresVersion = '16',
    [ValidateRange(1, 65535)]
    [int]   $Port            = 8069,
    [ValidateRange(0, 256)]
    [int]   $WslMemoryGB     = 8,
    [switch]$AllowNetworkAccess,
    [switch]$Force,
    [switch]$Yes,
    [switch]$IgnoreOtherEngines
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # speeds up downloads in PowerShell 5.1
$env:WSL_UTF8          = '1'                  # otherwise wsl.exe prints UTF-16

$ScriptVersion  = '2.1 (2026-09-29)'
$ResumeTaskName = 'Odoo20-Setup-Resume'
$RunOnceName    = 'Odoo20SetupResume'
$LicenseUrl     = 'https://www.docker.com/legal/docker-subscription-service-agreement/'

# Docker Desktop may be installed system-wide or (newer versions) per user
$DockerInstallRoots = @(
    (Join-Path $env:ProgramFiles 'Docker\Docker'),
    (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop')
)

# ---------------------------------------------------------------- Helper functions

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Warn([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }
function Stop-WithError([string]$Text) {
    Write-Host "`n[ERROR] $Text" -ForegroundColor Red
    exit 1
}

function Get-DockerRoot {
    foreach ($root in $DockerInstallRoots) {
        if (Test-Path (Join-Path $root 'Docker Desktop.exe')) { return $root }
    }
    return $null
}

# Run native programs without stderr output aborting the script in PowerShell 5.1
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $File @Arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    } finally {
        $ErrorActionPreference = $old
    }
}

# Arguments for restarting the script (self-elevation, resume after reboot)
function Get-ScriptArguments([switch]$AddYes) {
    $list = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($entry in $script:BoundParams.GetEnumerator()) {
        if ($entry.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($entry.Value.IsPresent) { $list += "-$($entry.Key)" }
        } else {
            $list += "-$($entry.Key)"; $list += "`"$($entry.Value)`""
        }
    }
    if ($AddYes -and -not $script:BoundParams.ContainsKey('Yes')) { $list += '-Yes' }
    return ($list -join ' ')
}

function New-RandomPassword([int]$Length = 24) {
    # letters and digits only: no trouble with YAML or INI special characters
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    # odoo.conf must not have a BOM, otherwise Odoo cannot find the [options] section
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
}

function Update-SessionPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
    $root = Get-DockerRoot
    if ($root) {
        $bin = Join-Path $root 'resources\bin'
        if ((Test-Path $bin) -and ($env:Path -notlike "*$bin*")) { $env:Path += ";$bin" }
    }
}

function Test-DockerEngine {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    return ((Invoke-Native 'docker' @('info')).ExitCode -eq 0)
}

function Get-OsArchitecture {
    try {
        return [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    } catch {
        # Fallback for older .NET versions
        if ($env:PROCESSOR_ARCHITEW6432) { return $env:PROCESSOR_ARCHITEW6432 }
        return $env:PROCESSOR_ARCHITECTURE
    }
}

function Test-YesAnswer([string]$Answer) { return ($Answer -match '^[YyJj]') }

# Continue automatically after a reboot: scheduled task first (no UAC prompt),
# otherwise a RunOnce entry (with UAC prompt), otherwise ask the user to re-run manually.
function Register-Resume {
    $arguments = Get-ScriptArguments -AddYes
    try {
        $userId  = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
        $princ   = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
        Register-ScheduledTask -TaskName $ResumeTaskName -Action $action -Trigger $trigger `
                               -Principal $princ -Force | Out-Null
        return 'task'
    } catch {
        try {
            $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
            Set-ItemProperty -Path $key -Name $RunOnceName -Value "powershell.exe $arguments"
            return 'runonce'
        } catch {
            return 'manual'
        }
    }
}

$script:BoundParams = $PSBoundParameters
$script:ConfChanged = $false

# ---------------------------------------------------------------- 0. Admin rights and confirmation

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'This script needs administrator rights and will now restart elevated ...' -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (Get-ScriptArguments)
    } catch {
        Stop-WithError 'The administrator prompt was declined. The installation is not possible without admin rights.'
    }
    exit 0
}

# Resuming after reboot: remove the scheduled task / RunOnce entry again
if (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false
    Write-Host 'Resuming setup after the reboot.' -ForegroundColor Cyan
}
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
                    -Name $RunOnceName -ErrorAction SilentlyContinue

$bindAddress = if ($AllowNetworkAccess) { '0.0.0.0' } else { '127.0.0.1' }

Write-Host ''
Write-Host "  Set up Odoo with Docker Desktop  (script version $ScriptVersion)" -ForegroundColor White
Write-Host "  Odoo $OdooVersion  |  PostgreSQL $PostgresVersion  |  Folder $InstallDir  |  Port $Port"

if (-not $Yes) {
    $accessText = if ($AllowNetworkAccess) {
        "Odoo will also be reachable from OTHER DEVICES ON THE NETWORK (port $Port)."
    } else {
        "Odoo will only be reachable from this computer (http://localhost:$Port)."
    }
    Write-Host @"

  With administrator rights, this script will:
    - enable and update WSL 2 (a reboot may be needed; the script then continues
      automatically). The update also affects existing Linux distributions.
    - use a running Docker engine, otherwise install Docker Desktop from docker.com
    - create the folder $InstallDir and download about 1.5 GB of images
    - $accessText

  Docker Desktop license (accepted as part of the installation):
    Free for personal use, education and businesses with fewer than
    250 employees AND less than USD 10 million annual revenue.
    Otherwise a paid Docker subscription is required.
    Details: $LicenseUrl

"@
    $answer = Read-Host '  Continue? (Y/N)'
    if (-not (Test-YesAnswer $answer)) { Write-Host '  Cancelled, nothing was changed.'; exit 0 }
}

# ---------------------------------------------------------------- 1. Requirements

Write-Step 'Step 1/6: Checking requirements'

$build = [Environment]::OSVersion.Version.Build
if ($build -lt 22000) {
    Stop-WithError "This script only supports Windows 11 (found: build $build).
Windows 10 is no longer regularly supported by Microsoft and therefore not by Docker Desktop either."
}
if ($build -lt 22631) { Write-Warn "Windows build $build is old. Please run Windows Update (23H2 or newer recommended)." }
else { Write-Ok "Windows 11, build $build" }

$osArch = Get-OsArchitecture
switch -Regex ($osArch) {
    '^(X64|AMD64)$' { $dockerArch = 'amd64'; Write-Ok 'Processor: x64 (Intel/AMD)' }
    '^(Arm64|ARM64)$' {
        $dockerArch = 'arm64'
        Write-Ok 'Processor: ARM64'
        Write-Warn 'Docker Desktop for Windows on ARM is not final yet (Early Access). It should work but may have quirks.'
    }
    default { Stop-WithError "Unsupported processor architecture: $osArch" }
}
$DockerInstallerUrl = "https://desktop.docker.com/win/main/$dockerArch/Docker%20Desktop%20Installer.exe"

# Is the script running under a different account than the signed-in user?
$sessionUser = (Get-CimInstance Win32_ComputerSystem).UserName
if ($sessionUser -and ($sessionUser -ne $identity.Name)) {
    Write-Warn "Signed in is '$sessionUser', but the script runs as '$($identity.Name)'."
    Write-Warn 'Docker Desktop and the WSL settings will then be set up for the admin account.'
    Write-Warn 'Better: sign in with an account that has administrator rights itself.'
    if (-not $Yes) {
        $answer = Read-Host '    Continue anyway? (Y/N)'
        if (-not (Test-YesAnswer $answer)) { exit 0 }
    }
}

$hypervisor = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
$vtFirmware = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
if ($hypervisor -or $vtFirmware) {
    Write-Ok 'Hardware virtualization is enabled'
} else {
    Stop-WithError @"
Hardware virtualization is disabled in the BIOS/UEFI. No script can change that.

How to open the BIOS/UEFI (any manufacturer):
  Settings -> System -> Recovery -> Advanced startup: 'Restart now'
  -> Troubleshoot -> Advanced options -> UEFI Firmware Settings -> Restart

Or press the manufacturer's key while the computer starts, e.g.:
  Lenovo: F1 or F2 (ThinkPads: Enter, then F1)   Dell: F2   HP: Esc, then F10
  ASUS: F2 or Del   Acer: F2   MSI: Del   Microsoft Surface: hold Volume Up

Enable the option there. Depending on the manufacturer it is called e.g.
  'Intel Virtualization Technology', 'Intel VT-x', 'SVM Mode' (AMD) or 'AMD-V'.
Save, restart and run this script again.
"@
}

$drive = Get-PSDrive -Name ($InstallDir.Substring(0, 1)) -ErrorAction SilentlyContinue
if (-not $drive) { Stop-WithError "Drive for '$InstallDir' not found." }
$freeGB = [math]::Round($drive.Free / 1GB)
if ($freeGB -lt 30) { Write-Warn "Only $freeGB GB free. At least 30 GB are recommended." }
else { Write-Ok "$freeGB GB free disk space" }

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramGB -lt 8) { Write-Warn "$ramGB GB of RAM. Works, but 8 GB or more are recommended." }
else { Write-Ok "$ramGB GB of RAM" }

# ---------------------------------------------------------------- 2. WSL 2

Write-Step 'Step 2/6: Setting up WSL 2'

$restartNeeded = $false
foreach ($feature in 'VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux') {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
    if ($state -eq 'Enabled') {
        Write-Ok "Windows feature $feature is enabled"
    } else {
        Write-Info "Enabling Windows feature $feature ..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
        if ($result.RestartNeeded) { $restartNeeded = $true }
    }
}

if ($restartNeeded) {
    Write-Warn 'WSL 2 requires a reboot.'
    switch (Register-Resume) {
        'task'    { Write-Info 'After signing in, the script continues automatically.' }
        'runonce' { Write-Info 'After signing in, the script starts automatically; please confirm the administrator prompt.' }
        default   { Write-Warn "Automatic resume is not possible. After the reboot please run the script again:`n    $PSCommandPath" }
    }
    $answer = Read-Host '    Reboot now? (Y/N)'
    if (Test-YesAnswer $answer) { Restart-Computer -Force }
    Write-Info 'Please reboot manually later.'
    exit 0
}

Write-Info 'Updating WSL (wsl --update) ...'
$update = Invoke-Native 'wsl.exe' @('--update')
if ($update.ExitCode -ne 0) { Write-Warn "wsl --update reported: $($update.Output)" }
Invoke-Native 'wsl.exe' @('--set-default-version', '2') | Out-Null

$wslVersion = Invoke-Native 'wsl.exe' @('--version')
if ($wslVersion.Output -match '(\d+)\.(\d+)\.(\d+)') {
    $v = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    if ($v -lt [version]'2.1.5') { Stop-WithError "WSL $v is too old (at least 2.1.5 required). Please run 'wsl --update' manually." }
    Write-Ok "WSL $v"
} else {
    Stop-WithError "Could not determine the WSL version. Output: $($wslVersion.Output)"
}

if ($WslMemoryGB -gt 0) {
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $wslConfig) {
        Write-Ok '.wslconfig already exists and is left unchanged'
    } else {
        $memGB = [math]::Min($WslMemoryGB, [math]::Max(2, [math]::Floor($ramGB / 2)))
        $cpu   = [math]::Max(2, [math]::Floor([Environment]::ProcessorCount / 2))
        Write-Utf8NoBom $wslConfig "[wsl2]`r`nmemory=${memGB}GB`r`nprocessors=$cpu`r`n"
        Write-Ok ".wslconfig created (max. $memGB GB RAM, $cpu processors; applies to all WSL distributions)"
    }
}

# ---------------------------------------------------------------- 3. Check Docker engine / install Docker Desktop

Write-Step 'Step 3/6: Checking Docker and installing it if needed'

Update-SessionPath
$useExistingEngine = $false

if (Test-DockerEngine) {
    # Some Docker engine is already running (Docker Desktop, Rancher Desktop, ...) -> install nothing
    $engineName = (Invoke-Native 'docker' @('info', '--format', '{{.OperatingSystem}}')).Output.Trim()
    Write-Ok "A Docker engine is already running ($engineName) - nothing will be installed"
    $useExistingEngine = $true
} elseif (Get-DockerRoot) {
    Write-Ok "Docker Desktop is already installed ($(Get-DockerRoot))"
} else {
    # Detect other container tools that do not get along with Docker Desktop
    $otherTools = @()
    foreach ($candidate in @(
            @{ Name = 'Rancher Desktop'; Paths = @((Join-Path $env:ProgramFiles 'Rancher Desktop'), (Join-Path $env:LOCALAPPDATA 'Programs\Rancher Desktop')) },
            @{ Name = 'Podman Desktop';  Paths = @((Join-Path $env:LOCALAPPDATA 'Programs\Podman Desktop'), (Join-Path $env:ProgramFiles 'Podman Desktop')) })) {
        if ($candidate.Paths | Where-Object { Test-Path $_ }) { $otherTools += $candidate.Name }
    }
    if (Get-Command podman -ErrorAction SilentlyContinue) { $otherTools += 'Podman' }
    $otherTools = $otherTools | Select-Object -Unique
    if ($otherTools -and -not $IgnoreOtherEngines) {
        Stop-WithError @"
$($otherTools -join ' / ') is already installed on this computer.
Installing Docker Desktop in addition often leads to conflicts.

Options:
  a) Start $($otherTools[0]) (for Rancher Desktop choose the engine 'dockerd (moby)')
     and run this script again - it will then use the running engine.
  b) Uninstall $($otherTools -join ' / ') and run the script again.
  c) Install Docker Desktop anyway:  -IgnoreOtherEngines
"@
    }

    # Docker installed directly inside a WSL distribution (e.g. docker-ce in Ubuntu)?
    $distroList = Invoke-Native 'wsl.exe' @('--list', '--quiet')
    $distros = @()
    if ($distroList.ExitCode -eq 0) {
        $distros = $distroList.Output -split "`n" |
                   ForEach-Object { $_.Trim([char]0, ' ', "`r") } |
                   Where-Object { $_ -and $_ -notmatch '^docker-desktop' }
    }
    $wslDocker = @()
    foreach ($d in $distros) {
        $check = Invoke-Native 'wsl.exe' @('-d', $d, '--', 'sh', '-c', 'command -v dockerd')
        if ($check.ExitCode -eq 0 -and $check.Output.Trim()) { $wslDocker += $d }
    }
    if ($wslDocker) {
        Write-Warn "Docker is installed directly in the WSL distribution $($wslDocker -join ', ')."
        Write-Warn 'Docker recommends removing it there before installing Docker Desktop,'
        Write-Warn 'otherwise both may get in each other''s way inside that distribution.'
        Write-Warn '(Inside the distribution e.g.: sudo apt remove docker-ce docker-ce-cli containerd.io)'
        if (-not $Yes) {
            $answer = Read-Host '    Continue installing Docker Desktop anyway? (Y/N)'
            if (-not (Test-YesAnswer $answer)) { exit 0 }
        }
    }

    $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
    Write-Info "Downloading Docker Desktop ($dockerArch) from docker.com (about 500 MB) ..."
    try {
        Start-BitsTransfer -Source $DockerInstallerUrl -Destination $installer
    } catch {
        Invoke-WebRequest -Uri $DockerInstallerUrl -OutFile $installer -UseBasicParsing
    }

    # Only run the installer if it carries a valid signature from Docker Inc.
    $sig = Get-AuthenticodeSignature -FilePath $installer
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O="?Docker') {
        Remove-Item $installer -ErrorAction SilentlyContinue
        Stop-WithError "The signature of the Docker installer is invalid ($($sig.Status)). Installation aborted."
    }
    Write-Ok 'Docker Inc. signature verified'

    Write-Info 'Installing Docker Desktop (silent, WSL 2 backend, license accepted) ...'
    $p = Start-Process -FilePath $installer -Wait -PassThru `
         -ArgumentList 'install', '--quiet', '--accept-license', '--backend=wsl-2'
    Remove-Item $installer -ErrorAction SilentlyContinue
    if ($p.ExitCode -notin 0, 3010) { Stop-WithError "Docker installer exited with code $($p.ExitCode)." }
    if (-not (Get-DockerRoot)) { Stop-WithError 'Docker Desktop was not found after the installation.' }
    Write-Ok 'Docker Desktop installed'
}

if (Get-DockerRoot) {
    # Add the user to the docker-users group (takes effect at the next sign-in)
    try {
        $member = Get-LocalGroupMember -Group 'docker-users' -ErrorAction Stop |
                  Where-Object { $_.Name -eq $identity.Name }
        if (-not $member) {
            Add-LocalGroupMember -Group 'docker-users' -Member $identity.Name -ErrorAction Stop
            Write-Ok "$($identity.Name) added to the docker-users group"
        }
    } catch { }
}

Update-SessionPath

# ---------------------------------------------------------------- 4. Start Docker engine

Write-Step 'Step 4/6: Starting the Docker engine'

function Wait-DockerEngine([int]$Minutes = 5) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while (-not (Test-DockerEngine)) {
        if ((Get-Date) -gt $deadline) {
            Stop-WithError @"
The Docker engine is not ready after $Minutes minutes.
Open Docker Desktop and check that 'Engine running' is shown at the bottom left.
If not: quit Docker Desktop, run 'wsl --shutdown', start it again.
Then run this script again.
"@
        }
        Start-Sleep -Seconds 5
        Write-Host '.' -NoNewline
    }
    Write-Host ''
}

if (Test-DockerEngine) {
    if (-not $useExistingEngine) { Write-Ok 'Docker engine is already running' }
} else {
    # start via explorer.exe so that Docker Desktop does NOT run with admin rights
    $dockerExe = Join-Path (Get-DockerRoot) 'Docker Desktop.exe'
    Start-Process explorer.exe -ArgumentList "`"$dockerExe`""
    Write-Info 'Waiting for the Docker engine (up to 5 minutes on first start) ...'
    Write-Info "If Docker Desktop shows 'Welcome to Docker' or a survey: just click 'Skip'."
    Wait-DockerEngine
    Write-Ok 'Docker engine is running'
}

# Odoo and PostgreSQL are Linux images: the engine must run in Linux mode
$osType = (Invoke-Native 'docker' @('info', '--format', '{{.OSType}}')).Output.Trim()
if ($osType -eq 'windows') {
    $dockerCli = if (Get-DockerRoot) { Join-Path (Get-DockerRoot) 'DockerCli.exe' } else { $null }
    Write-Warn 'Docker Desktop is running in "Windows containers" mode. Odoo needs Linux containers.'
    $switch = $false
    if ($dockerCli -and (Test-Path $dockerCli)) {
        if ($Yes) { $switch = $true }
        else {
            $answer = Read-Host '    Switch to Linux containers now? (Y/N)'
            $switch = (Test-YesAnswer $answer)
        }
    }
    if (-not $switch) {
        Stop-WithError "Please switch to Linux containers: right-click the Docker whale in the notification area
-> 'Switch to Linux containers...'. Then run this script again."
    }
    Write-Info 'Switching to Linux containers ...'
    & $dockerCli -SwitchLinuxEngine
    Start-Sleep -Seconds 10
    Wait-DockerEngine -Minutes 3
    $osType = (Invoke-Native 'docker' @('info', '--format', '{{.OSType}}')).Output.Trim()
    if ($osType -ne 'linux') { Stop-WithError "Switching failed (mode: $osType). Please switch to Linux containers manually." }
}
Write-Ok 'Linux container mode active'

$composeVersion = Invoke-Native 'docker' @('compose', 'version', '--short')
if ($composeVersion.ExitCode -ne 0) {
    Stop-WithError "'docker compose' is not available. Please update Docker Desktop or, for other
container tools, install the Compose plugin."
}
Write-Ok "Docker Compose $($composeVersion.Output.Trim())"

# ---------------------------------------------------------------- 5. Project folder

Write-Step "Step 5/6: Creating project folder $InstallDir"

New-Item -ItemType Directory -Force -Path $InstallDir, "$InstallDir\config", "$InstallDir\addons" | Out-Null

$composeFile = Join-Path $InstallDir 'compose.yaml'
$confFile    = Join-Path $InstallDir 'config\odoo.conf'
$masterPwd   = $null

if ((Test-Path $composeFile) -and -not $Force) {
    Write-Ok 'compose.yaml already exists and is not overwritten (use -Force to rewrite)'
    $existingCompose = Get-Content $composeFile -Raw
    if (-not $AllowNetworkAccess -and $existingCompose -match '(?m)^\s*-\s*"\d+:8069"') {
        Write-Warn 'The existing compose.yaml makes Odoo reachable from the whole network.'
        Write-Warn "Local only: in compose.yaml change the line under 'ports:' to `"127.0.0.1:${Port}:8069`","
        Write-Warn "then run 'docker compose up -d' in the folder $InstallDir."
    }
} else {
    $dbPwd = New-RandomPassword
    $compose = @"
# Generated by install-odoo20.ps1 (version $ScriptVersion)
# The database password is fixed from the first start. To change it,
# first delete all data with 'docker compose down -v'.
# Port binding: 127.0.0.1 = this computer only, 0.0.0.0 = whole network
services:
  db:
    image: postgres:$PostgresVersion
    container_name: odoo20-db
    environment:
      POSTGRES_DB: postgres
      POSTGRES_USER: odoo
      POSTGRES_PASSWORD: $dbPwd
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - odoo20-db-data:/var/lib/postgresql/data/pgdata
    restart: unless-stopped

  web:
    image: odoo:$OdooVersion
    container_name: odoo20-web
    depends_on:
      - db
    ports:
      - "${bindAddress}:${Port}:8069"
    environment:
      HOST: db
      USER: odoo
      PASSWORD: $dbPwd
    volumes:
      - odoo20-web-data:/var/lib/odoo
      - ./config:/etc/odoo
      - ./addons:/mnt/extra-addons
    restart: unless-stopped

volumes:
  odoo20-web-data:
  odoo20-db-data:
"@
    Write-Utf8NoBom $composeFile $compose
    Write-Ok "compose.yaml written (Odoo reachable via $bindAddress)"
}

if ((Test-Path $confFile) -and -not $Force) {
    Write-Ok 'odoo.conf already exists and is not overwritten'
    # Without this line Odoo 20 listens only on 127.0.0.1 INSIDE the container -> port unreachable
    $existing = Get-Content $confFile -Raw
    if ($existing -notmatch '(?m)^\s*http_interface\s*=') {
        Write-Utf8NoBom $confFile ($existing.TrimEnd() + "`r`nhttp_interface = 0.0.0.0`r`n")
        Write-Ok 'http_interface = 0.0.0.0 added to odoo.conf'
        $script:ConfChanged = $true
    }
} else {
    $masterPwd = New-RandomPassword
    # http_interface = 0.0.0.0 applies only INSIDE the container and is required,
    # because Odoo 20 otherwise listens only on 127.0.0.1 there. Who may connect
    # from outside is controlled by the port binding in compose.yaml.
    $conf = @"
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
admin_passwd = $masterPwd
list_db = True
http_interface = 0.0.0.0
"@
    Write-Utf8NoBom $confFile $conf
    Write-Ok 'odoo.conf written (new master password generated)'
}

# ---------------------------------------------------------------- 6. Start

Write-Step "Step 6/6: Pulling and starting Odoo $OdooVersion"

Push-Location $InstallDir
try {
    Write-Info 'Pulling images (about 1.2 GB) ...'
    & docker compose pull
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError @"
The images could not be pulled.
If Docker reports 'manifest ... not found', odoo:$OdooVersion is not available on Docker Hub.
Then try again later or test with Odoo 19:
  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -OdooVersion 19.0 -Force
"@
    }
    & docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Start failed. Is port $Port in use? Then run again with -Port 8070 -Force.
Details: cd $InstallDir ; docker compose logs web"
    }
    if ($script:ConfChanged) { & docker compose restart web | Out-Null }
} finally {
    Pop-Location
}

Write-Info 'Waiting for Odoo to respond ...'
$url = "http://localhost:$Port"
$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "$url/web/database/selector" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 5
    Write-Host '.' -NoNewline
}
Write-Host ''

if (-not $ready) {
    Write-Warn 'Odoo is not responding yet. Last log lines:'
    Push-Location $InstallDir; & docker compose logs --tail 8 web; Pop-Location
    Write-Warn "More log (stop with Ctrl + C):  cd $InstallDir ; docker compose logs -f web"
    if ($masterPwd) { Write-Host "    Master password: $masterPwd (also in config\odoo.conf)" -ForegroundColor Yellow }
    exit 1
}

# ---------------------------------------------------------------- Summary

Write-Host ''
Write-Host '  Odoo is running!' -ForegroundColor Green
Write-Host "  Address:          $url"
if ($AllowNetworkAccess) {
    Write-Host "  Network access:   ON - other devices reach Odoo via this computer's IP, port $Port" -ForegroundColor Yellow
} else {
    Write-Host '  Network access:   off - Odoo is only reachable from this computer'
}
Write-Host "  Project folder:   $InstallDir"
if ($masterPwd) {
    Write-Host "  Master password:  $masterPwd" -ForegroundColor Yellow
    Write-Host '                    (also in config\odoo.conf as admin_passwd)'
} else {
    Write-Host '  Master password:  see config\odoo.conf (admin_passwd)'
}
Write-Host ''
Write-Host '  Note: The log warning "invalid addons directory /mnt/extra-addons" is harmless'
Write-Host "  as long as $InstallDir\addons is empty."
Write-Host ''
Write-Host '  Next step: create the first database in the browser'
Write-Host '  (master password, database name, login (no real email needed), password,'
Write-Host '   language and country).'
Write-Host ''
Write-Host '  After a reboot, Odoo starts automatically together with Docker Desktop.'
Write-Host ''

Start-Process $url
