<#
.SYNOPSIS
    Richtet Odoo 20 (Community) mit Docker Desktop auf Windows 11 ein.

.DESCRIPTION
    Version 2.1 (29.09.2026) - teilbare Version fuer beliebige Windows-11-Rechner.
    Neu in 2.1: nutzt eine bereits laufende Docker-Engine, erkennt Rancher Desktop /
    Podman und Docker in WSL-Distributionen, schaltet Windows-Container auf Linux um.

    Das Skript arbeitet schrittweise und kann jederzeit erneut gestartet werden;
    bereits erledigte Schritte werden erkannt und uebersprungen.

      1. Voraussetzungen pruefen (Windows 11, x64 oder ARM64, Virtualisierung, Speicher)
      2. WSL 2 aktivieren (bei Bedarf Neustart, danach automatische Fortsetzung)
      3. Docker pruefen: laufende Engine nutzen, sonst Docker Desktop laden,
         Signatur pruefen und still installieren
      4. Docker Desktop starten und auf die Engine warten
      5. Projektordner mit compose.yaml und odoo.conf anlegen (zufaellige Passwoerter)
      6. Images laden, Container starten, warten bis Odoo antwortet

    Sicherheit:
      - Odoo ist standardmaessig NUR auf diesem Rechner erreichbar (127.0.0.1).
      - Das Docker-Installationsprogramm wird nur ausgefuehrt, wenn es gueltig
        von Docker Inc. signiert ist.
      - Datenbank- und Master-Passwort werden bei jeder Installation neu erzeugt.

    Lizenz: Das Skript akzeptiert die Lizenz von Docker Desktop. Docker Desktop ist
    kostenlos fuer Privatnutzung, Ausbildung und Unternehmen mit weniger als 250
    Mitarbeitenden UND weniger als 10 Mio. USD Jahresumsatz, sonst ist ein Abo noetig.

    Nicht automatisierbar: die Virtualisierung im BIOS/UEFI einschalten (falls aus)
    und das Anlegen der ersten Datenbank im Browser.

.PARAMETER InstallDir          Projektordner (Standard: C:\odoo20)
.PARAMETER OdooVersion         Image-Tag von odoo (Standard: 20.0)
.PARAMETER PostgresVersion     Image-Tag von postgres (Standard: 16)
.PARAMETER Port                Port auf dem Rechner (Standard: 8069)
.PARAMETER WslMemoryGB         RAM-Obergrenze fuer WSL in GB; 0 = .wslconfig nicht anlegen (Standard: 8)
.PARAMETER AllowNetworkAccess  Odoo auch fuer andere Geraete im Netzwerk erreichbar machen (nicht empfohlen)
.PARAMETER Force               compose.yaml und odoo.conf neu schreiben, auch wenn sie existieren
.PARAMETER Yes                 Bestaetigungsabfragen ueberspringen (Standardantwort: fortfahren)
.PARAMETER IgnoreOtherEngines  Docker Desktop auch installieren, wenn Rancher Desktop oder Podman vorhanden ist

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
$ProgressPreference    = 'SilentlyContinue'   # beschleunigt Downloads in PowerShell 5.1
$env:WSL_UTF8          = '1'                  # wsl.exe gibt sonst UTF-16 aus

$ScriptVersion  = '2.1 (29.09.2026)'
$ResumeTaskName = 'Odoo20-Setup-Fortsetzen'
$RunOnceName    = 'Odoo20SetupFortsetzen'
$LicenseUrl     = 'https://www.docker.com/legal/docker-subscription-service-agreement/'

# Docker Desktop kann systemweit oder (neuere Versionen) pro Benutzer installiert sein
$DockerInstallRoots = @(
    (Join-Path $env:ProgramFiles 'Docker\Docker'),
    (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop')
)

# ---------------------------------------------------------------- Hilfsfunktionen

function Write-Step([string]$Text) { Write-Host "`n==> $Text" -ForegroundColor Cyan }
function Write-Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Warn([string]$Text) { Write-Host "    [!] $Text" -ForegroundColor Yellow }
function Stop-WithError([string]$Text) {
    Write-Host "`n[FEHLER] $Text" -ForegroundColor Red
    exit 1
}

function Get-DockerRoot {
    foreach ($root in $DockerInstallRoots) {
        if (Test-Path (Join-Path $root 'Docker Desktop.exe')) { return $root }
    }
    return $null
}

# Native Programme aufrufen, ohne dass Ausgaben auf stderr in PowerShell 5.1 zum Abbruch fuehren
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

# Argumente fuer einen Neustart des Skripts (Selbst-Erhoehung, Fortsetzung nach Neustart)
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
    # nur Buchstaben und Ziffern: keine Probleme mit YAML- oder INI-Sonderzeichen
    $chars = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    # odoo.conf darf kein BOM haben, sonst findet Odoo den Abschnitt [options] nicht
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
        # Fallback fuer aeltere .NET-Versionen
        if ($env:PROCESSOR_ARCHITEW6432) { return $env:PROCESSOR_ARCHITEW6432 }
        return $env:PROCESSOR_ARCHITECTURE
    }
}

# Nach einem Neustart automatisch weitermachen: zuerst geplante Aufgabe (ohne UAC-Abfrage),
# sonst RunOnce-Eintrag (mit UAC-Abfrage), sonst Hinweis zum manuellen Neustart.
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

# ---------------------------------------------------------------- 0. Adminrechte und Bestaetigung

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Das Skript braucht Administratorrechte und startet sich jetzt erhoeht neu ...' -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList (Get-ScriptArguments)
    } catch {
        Stop-WithError 'Die Administrator-Abfrage wurde abgelehnt. Ohne Adminrechte ist die Installation nicht moeglich.'
    }
    exit 0
}

# Fortsetzung nach Neustart: Aufgabe bzw. RunOnce-Eintrag wieder entfernen
if (Get-ScheduledTask -TaskName $ResumeTaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $ResumeTaskName -Confirm:$false
    Write-Host 'Setup wird nach dem Neustart fortgesetzt.' -ForegroundColor Cyan
}
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' `
                    -Name $RunOnceName -ErrorAction SilentlyContinue

$bindAddress = if ($AllowNetworkAccess) { '0.0.0.0' } else { '127.0.0.1' }

Write-Host ''
Write-Host "  Odoo mit Docker Desktop einrichten  (Skript-Version $ScriptVersion)" -ForegroundColor White
Write-Host "  Odoo $OdooVersion  |  PostgreSQL $PostgresVersion  |  Ordner $InstallDir  |  Port $Port"

if (-not $Yes) {
    $accessText = if ($AllowNetworkAccess) {
        "Odoo wird auch fuer ANDERE GERAETE IM NETZWERK erreichbar sein (Port $Port)."
    } else {
        "Odoo wird nur auf diesem Rechner erreichbar sein (http://localhost:$Port)."
    }
    Write-Host @"

  Dieses Skript wird mit Administratorrechten:
    - WSL 2 aktivieren und aktualisieren (eventuell ist ein Neustart noetig; danach geht es
      automatisch weiter). Das Update betrifft auch bereits vorhandene Linux-Distributionen.
    - eine laufende Docker-Engine verwenden, sonst Docker Desktop von docker.com installieren
    - den Ordner $InstallDir anlegen und ca. 1,5 GB Images herunterladen
    - $accessText

  Docker-Desktop-Lizenz (wird mit der Installation akzeptiert):
    Kostenlos fuer Privatnutzung, Ausbildung und Unternehmen mit weniger als
    250 Mitarbeitenden UND weniger als 10 Mio. USD Jahresumsatz.
    Sonst ist ein kostenpflichtiges Docker-Abo erforderlich.
    Details: $LicenseUrl

"@
    $answer = Read-Host '  Fortfahren? (J/N)'
    if ($answer -notmatch '^[JjYy]') { Write-Host '  Abgebrochen, es wurde nichts veraendert.'; exit 0 }
}

# ---------------------------------------------------------------- 1. Voraussetzungen

Write-Step 'Schritt 1/6: Voraussetzungen pruefen'

$build = [Environment]::OSVersion.Version.Build
if ($build -lt 22000) {
    Stop-WithError "Dieses Skript unterstuetzt nur Windows 11 (gefunden: Build $build).
Windows 10 wird von Microsoft nicht mehr regulaer unterstuetzt und daher auch von Docker Desktop nicht."
}
if ($build -lt 22631) { Write-Warn "Windows-Build $build ist alt. Bitte Windows Update ausfuehren (23H2 oder neuer empfohlen)." }
else { Write-Ok "Windows 11, Build $build" }

$osArch = Get-OsArchitecture
switch -Regex ($osArch) {
    '^(X64|AMD64)$' { $dockerArch = 'amd64'; Write-Ok 'Prozessor: x64 (Intel/AMD)' }
    '^(Arm64|ARM64)$' {
        $dockerArch = 'arm64'
        Write-Ok 'Prozessor: ARM64'
        Write-Warn 'Docker Desktop fuer Windows auf ARM ist noch nicht final (Early Access). Es sollte funktionieren, kann aber Eigenheiten haben.'
    }
    default { Stop-WithError "Nicht unterstuetzte Prozessorarchitektur: $osArch" }
}
$DockerInstallerUrl = "https://desktop.docker.com/win/main/$dockerArch/Docker%20Desktop%20Installer.exe"

# Laeuft das Skript unter einem anderen Konto als dem angemeldeten Benutzer?
$sessionUser = (Get-CimInstance Win32_ComputerSystem).UserName
if ($sessionUser -and ($sessionUser -ne $identity.Name)) {
    Write-Warn "Angemeldet ist '$sessionUser', das Skript laeuft aber als '$($identity.Name)'."
    Write-Warn 'Docker Desktop und die WSL-Einstellungen werden dann fuer das Admin-Konto eingerichtet.'
    Write-Warn 'Besser: sich mit einem Konto anmelden, das selbst Administratorrechte hat.'
    if (-not $Yes) {
        $answer = Read-Host '    Trotzdem fortfahren? (J/N)'
        if ($answer -notmatch '^[JjYy]') { exit 0 }
    }
}

$hypervisor = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
$vtFirmware = (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled
if ($hypervisor -or $vtFirmware) {
    Write-Ok 'Hardware-Virtualisierung ist aktiv'
} else {
    Stop-WithError @"
Die Hardware-Virtualisierung ist im BIOS/UEFI ausgeschaltet. Das kann kein Skript aendern.

So kommst du ins BIOS/UEFI (herstellerunabhaengig):
  Einstellungen -> System -> Wiederherstellung -> Erweiterter Start: 'Jetzt neu starten'
  -> Problembehandlung -> Erweiterte Optionen -> UEFI-Firmwareeinstellungen -> Neu starten

Oder beim Einschalten die Taste des Herstellers druecken, z. B.:
  Lenovo: F1 oder F2 (bei ThinkPads Enter, dann F1)   Dell: F2   HP: Esc, dann F10
  ASUS: F2 oder Entf   Acer: F2   MSI: Entf   Microsoft Surface: Lauter-Taste halten

Dort die Option einschalten. Sie heisst je nach Hersteller z. B.
  'Intel Virtualization Technology', 'Intel VT-x', 'SVM Mode' (AMD) oder 'AMD-V'.
Speichern, neu starten und dieses Skript erneut ausfuehren.
"@
}

$drive = Get-PSDrive -Name ($InstallDir.Substring(0, 1)) -ErrorAction SilentlyContinue
if (-not $drive) { Stop-WithError "Laufwerk fuer '$InstallDir' nicht gefunden." }
$freeGB = [math]::Round($drive.Free / 1GB)
if ($freeGB -lt 30) { Write-Warn "Nur $freeGB GB frei. Empfohlen sind mindestens 30 GB." }
else { Write-Ok "$freeGB GB freier Speicherplatz" }

$ramGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
if ($ramGB -lt 8) { Write-Warn "$ramGB GB Arbeitsspeicher. Funktioniert, empfohlen sind 8 GB oder mehr." }
else { Write-Ok "$ramGB GB Arbeitsspeicher" }

# ---------------------------------------------------------------- 2. WSL 2

Write-Step 'Schritt 2/6: WSL 2 einrichten'

$restartNeeded = $false
foreach ($feature in 'VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux') {
    $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
    if ($state -eq 'Enabled') {
        Write-Ok "Windows-Feature $feature ist aktiv"
    } else {
        Write-Info "Aktiviere Windows-Feature $feature ..."
        $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
        if ($result.RestartNeeded) { $restartNeeded = $true }
    }
}

if ($restartNeeded) {
    Write-Warn 'Fuer WSL 2 ist ein Neustart noetig.'
    switch (Register-Resume) {
        'task'    { Write-Info 'Nach der Anmeldung laeuft das Skript automatisch weiter.' }
        'runonce' { Write-Info 'Nach der Anmeldung startet das Skript automatisch; bitte die Administrator-Abfrage bestaetigen.' }
        default   { Write-Warn "Automatische Fortsetzung nicht moeglich. Nach dem Neustart das Skript bitte erneut starten:`n    $PSCommandPath" }
    }
    $answer = Read-Host '    Jetzt neu starten? (J/N)'
    if ($answer -match '^[JjYy]') { Restart-Computer -Force }
    Write-Info 'Bitte spaeter manuell neu starten.'
    exit 0
}

Write-Info 'Aktualisiere WSL (wsl --update) ...'
$update = Invoke-Native 'wsl.exe' @('--update')
if ($update.ExitCode -ne 0) { Write-Warn "wsl --update meldete: $($update.Output)" }
Invoke-Native 'wsl.exe' @('--set-default-version', '2') | Out-Null

$wslVersion = Invoke-Native 'wsl.exe' @('--version')
if ($wslVersion.Output -match '(\d+)\.(\d+)\.(\d+)') {
    $v = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    if ($v -lt [version]'2.1.5') { Stop-WithError "WSL $v ist zu alt (mindestens 2.1.5). Bitte 'wsl --update' manuell ausfuehren." }
    Write-Ok "WSL $v"
} else {
    Stop-WithError "WSL-Version nicht ermittelbar. Ausgabe: $($wslVersion.Output)"
}

if ($WslMemoryGB -gt 0) {
    $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
    if (Test-Path $wslConfig) {
        Write-Ok '.wslconfig existiert bereits, wird nicht veraendert'
    } else {
        $memGB = [math]::Min($WslMemoryGB, [math]::Max(2, [math]::Floor($ramGB / 2)))
        $cpu   = [math]::Max(2, [math]::Floor([Environment]::ProcessorCount / 2))
        Write-Utf8NoBom $wslConfig "[wsl2]`r`nmemory=${memGB}GB`r`nprocessors=$cpu`r`n"
        Write-Ok ".wslconfig angelegt (max. $memGB GB RAM, $cpu Prozessoren; gilt fuer alle WSL-Distributionen)"
    }
}

# ---------------------------------------------------------------- 3. Docker-Engine pruefen / Docker Desktop installieren

Write-Step 'Schritt 3/6: Docker pruefen und bei Bedarf installieren'

Update-SessionPath
$useExistingEngine = $false

if (Test-DockerEngine) {
    # Irgendeine Docker-Engine laeuft bereits (Docker Desktop, Rancher Desktop, ...) -> nichts installieren
    $engineName = (Invoke-Native 'docker' @('info', '--format', '{{.OperatingSystem}}')).Output.Trim()
    Write-Ok "Eine Docker-Engine laeuft bereits ($engineName) - es wird nichts installiert"
    $useExistingEngine = $true
} elseif (Get-DockerRoot) {
    Write-Ok "Docker Desktop ist bereits installiert ($(Get-DockerRoot))"
} else {
    # Andere Container-Programme erkennen, die sich mit Docker Desktop nicht vertragen
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
Auf diesem Rechner ist bereits $($otherTools -join ' / ') installiert.
Docker Desktop zusaetzlich zu installieren fuehrt oft zu Konflikten.

Moeglichkeiten:
  a) $($otherTools[0]) starten (bei Rancher Desktop die Engine 'dockerd (moby)' waehlen)
     und dieses Skript erneut ausfuehren - es nutzt dann die laufende Engine.
  b) $($otherTools -join ' / ') deinstallieren und das Skript erneut ausfuehren.
  c) Docker Desktop trotzdem installieren:  -IgnoreOtherEngines
"@
    }

    # Docker direkt in einer WSL-Distribution (z. B. docker-ce in Ubuntu)?
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
        Write-Warn "In der WSL-Distribution $($wslDocker -join ', ') ist Docker direkt installiert."
        Write-Warn 'Docker empfiehlt, es dort vor der Installation von Docker Desktop zu entfernen,'
        Write-Warn "sonst koennen sich beide in dieser Distribution in die Quere kommen."
        Write-Warn "(In der Distribution z. B.: sudo apt remove docker-ce docker-ce-cli containerd.io)"
        if (-not $Yes) {
            $answer = Read-Host '    Trotzdem mit der Installation von Docker Desktop fortfahren? (J/N)'
            if ($answer -notmatch '^[JjYy]') { exit 0 }
        }
    }

    $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
    Write-Info "Lade Docker Desktop ($dockerArch) von docker.com herunter (ca. 500 MB) ..."
    try {
        Start-BitsTransfer -Source $DockerInstallerUrl -Destination $installer
    } catch {
        Invoke-WebRequest -Uri $DockerInstallerUrl -OutFile $installer -UseBasicParsing
    }

    # Nur ausfuehren, wenn das Installationsprogramm gueltig von Docker Inc. signiert ist
    $sig = Get-AuthenticodeSignature -FilePath $installer
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O="?Docker') {
        Remove-Item $installer -ErrorAction SilentlyContinue
        Stop-WithError "Die Signatur des Docker-Installationsprogramms ist ungueltig ($($sig.Status)). Installation abgebrochen."
    }
    Write-Ok 'Signatur von Docker Inc. geprueft'

    Write-Info 'Installiere Docker Desktop (still, WSL-2-Backend, Lizenz akzeptiert) ...'
    $p = Start-Process -FilePath $installer -Wait -PassThru `
         -ArgumentList 'install', '--quiet', '--accept-license', '--backend=wsl-2'
    Remove-Item $installer -ErrorAction SilentlyContinue
    if ($p.ExitCode -notin 0, 3010) { Stop-WithError "Docker-Installer beendet mit Code $($p.ExitCode)." }
    if (-not (Get-DockerRoot)) { Stop-WithError 'Docker Desktop wurde nach der Installation nicht gefunden.' }
    Write-Ok 'Docker Desktop installiert'
}

if (Get-DockerRoot) {
    # Benutzer in die Gruppe docker-users aufnehmen (wirkt ab der naechsten Anmeldung)
    try {
        $member = Get-LocalGroupMember -Group 'docker-users' -ErrorAction Stop |
                  Where-Object { $_.Name -eq $identity.Name }
        if (-not $member) {
            Add-LocalGroupMember -Group 'docker-users' -Member $identity.Name -ErrorAction Stop
            Write-Ok "$($identity.Name) zur Gruppe docker-users hinzugefuegt"
        }
    } catch { }
}

Update-SessionPath

# ---------------------------------------------------------------- 4. Docker-Engine starten

Write-Step 'Schritt 4/6: Docker-Engine starten'

function Wait-DockerEngine([int]$Minutes = 5) {
    $deadline = (Get-Date).AddMinutes($Minutes)
    while (-not (Test-DockerEngine)) {
        if ((Get-Date) -gt $deadline) {
            Stop-WithError @"
Die Docker-Engine ist nach $Minutes Minuten nicht bereit.
Docker Desktop oeffnen und pruefen, ob unten links 'Engine running' steht.
Falls nicht: Docker Desktop beenden, 'wsl --shutdown' ausfuehren, neu starten.
Danach dieses Skript erneut ausfuehren.
"@
        }
        Start-Sleep -Seconds 5
        Write-Host '.' -NoNewline
    }
    Write-Host ''
}

if (Test-DockerEngine) {
    if (-not $useExistingEngine) { Write-Ok 'Docker-Engine laeuft bereits' }
} else {
    # ueber explorer.exe starten, damit Docker Desktop NICHT mit Adminrechten laeuft
    $dockerExe = Join-Path (Get-DockerRoot) 'Docker Desktop.exe'
    Start-Process explorer.exe -ArgumentList "`"$dockerExe`""
    Write-Info 'Warte auf die Docker-Engine (beim ersten Start bis zu 5 Minuten) ...'
    Write-Info "Zeigt Docker Desktop 'Welcome to Docker' oder eine Umfrage: einfach 'Skip' klicken."
    Wait-DockerEngine
    Write-Ok 'Docker-Engine laeuft'
}

# Odoo und PostgreSQL sind Linux-Images: die Engine muss im Linux-Modus laufen
$osType = (Invoke-Native 'docker' @('info', '--format', '{{.OSType}}')).Output.Trim()
if ($osType -eq 'windows') {
    $dockerCli = if (Get-DockerRoot) { Join-Path (Get-DockerRoot) 'DockerCli.exe' } else { $null }
    Write-Warn 'Docker Desktop laeuft im Modus "Windows-Container". Odoo braucht Linux-Container.'
    $switch = $false
    if ($dockerCli -and (Test-Path $dockerCli)) {
        if ($Yes) { $switch = $true }
        else {
            $answer = Read-Host '    Jetzt auf Linux-Container umschalten? (J/N)'
            $switch = ($answer -match '^[JjYy]')
        }
    }
    if (-not $switch) {
        Stop-WithError "Bitte auf Linux-Container umschalten: Rechtsklick auf den Docker-Wal im Infobereich
-> 'Switch to Linux containers...'. Danach dieses Skript erneut ausfuehren."
    }
    Write-Info 'Schalte auf Linux-Container um ...'
    & $dockerCli -SwitchLinuxEngine
    Start-Sleep -Seconds 10
    Wait-DockerEngine -Minutes 3
    $osType = (Invoke-Native 'docker' @('info', '--format', '{{.OSType}}')).Output.Trim()
    if ($osType -ne 'linux') { Stop-WithError "Umschalten fehlgeschlagen (Modus: $osType). Bitte manuell auf Linux-Container umschalten." }
}
Write-Ok 'Linux-Container-Modus aktiv'

$composeVersion = Invoke-Native 'docker' @('compose', 'version', '--short')
if ($composeVersion.ExitCode -ne 0) {
    Stop-WithError "'docker compose' ist nicht verfuegbar. Bitte Docker Desktop aktualisieren bzw. bei anderen
Container-Programmen das Compose-Plugin installieren."
}
Write-Ok "Docker Compose $($composeVersion.Output.Trim())"

# ---------------------------------------------------------------- 5. Projektordner

Write-Step "Schritt 5/6: Projektordner $InstallDir anlegen"

New-Item -ItemType Directory -Force -Path $InstallDir, "$InstallDir\config", "$InstallDir\addons" | Out-Null

$composeFile = Join-Path $InstallDir 'compose.yaml'
$confFile    = Join-Path $InstallDir 'config\odoo.conf'
$masterPwd   = $null

if ((Test-Path $composeFile) -and -not $Force) {
    Write-Ok 'compose.yaml existiert bereits, wird nicht ueberschrieben (-Force zum Neuschreiben)'
    $existingCompose = Get-Content $composeFile -Raw
    if (-not $AllowNetworkAccess -and $existingCompose -match '(?m)^\s*-\s*"\d+:8069"') {
        Write-Warn 'Die bestehende compose.yaml macht Odoo im ganzen Netzwerk erreichbar.'
        Write-Warn "Nur lokal: in compose.yaml die Zeile unter 'ports:' auf `"127.0.0.1:${Port}:8069`" aendern,"
        Write-Warn "dann im Ordner $InstallDir 'docker compose up -d' ausfuehren."
    }
} else {
    $dbPwd = New-RandomPassword
    $compose = @"
# Erzeugt von install-odoo20.ps1 (Version $ScriptVersion)
# Das Datenbank-Passwort gilt ab dem ersten Start. Wer es aendert,
# muss vorher mit 'docker compose down -v' alle Daten loeschen.
# Port-Freigabe: 127.0.0.1 = nur dieser Rechner, 0.0.0.0 = ganzes Netzwerk
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
    Write-Ok "compose.yaml geschrieben (Odoo erreichbar ueber $bindAddress)"
}

if ((Test-Path $confFile) -and -not $Force) {
    Write-Ok 'odoo.conf existiert bereits, wird nicht ueberschrieben'
    # Odoo 20 lauscht ohne diese Zeile nur auf 127.0.0.1 IM CONTAINER -> Port nicht erreichbar
    $existing = Get-Content $confFile -Raw
    if ($existing -notmatch '(?m)^\s*http_interface\s*=') {
        Write-Utf8NoBom $confFile ($existing.TrimEnd() + "`r`nhttp_interface = 0.0.0.0`r`n")
        Write-Ok 'http_interface = 0.0.0.0 in odoo.conf ergaenzt'
        $script:ConfChanged = $true
    }
} else {
    $masterPwd = New-RandomPassword
    # http_interface = 0.0.0.0 gilt nur INNERHALB des Containers und ist noetig,
    # weil Odoo 20 dort sonst nur auf 127.0.0.1 lauscht. Wer von aussen zugreifen darf,
    # regelt die Port-Freigabe in compose.yaml.
    $conf = @"
[options]
addons_path = /mnt/extra-addons
data_dir = /var/lib/odoo
admin_passwd = $masterPwd
list_db = True
http_interface = 0.0.0.0
"@
    Write-Utf8NoBom $confFile $conf
    Write-Ok 'odoo.conf geschrieben (neues Master-Passwort erzeugt)'
}

# ---------------------------------------------------------------- 6. Starten

Write-Step "Schritt 6/6: Odoo $OdooVersion laden und starten"

Push-Location $InstallDir
try {
    Write-Info 'Lade Images (ca. 1,2 GB) ...'
    & docker compose pull
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError @"
Die Images konnten nicht geladen werden.
Meldet Docker 'manifest ... not found', ist odoo:$OdooVersion auf Docker Hub nicht verfuegbar.
Dann spaeter erneut versuchen oder zum Testen mit Odoo 19 starten:
  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -OdooVersion 19.0 -Force
"@
    }
    & docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        Stop-WithError "Start fehlgeschlagen. Ist Port $Port belegt? Dann mit -Port 8070 -Force erneut starten.
Details: cd $InstallDir ; docker compose logs web"
    }
    if ($script:ConfChanged) { & docker compose restart web | Out-Null }
} finally {
    Pop-Location
}

Write-Info 'Warte, bis Odoo antwortet ...'
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
    Write-Warn 'Odoo antwortet noch nicht. Letzte Log-Zeilen:'
    Push-Location $InstallDir; & docker compose logs --tail 8 web; Pop-Location
    Write-Warn "Mehr Log (beenden mit Strg + C):  cd $InstallDir ; docker compose logs -f web"
    if ($masterPwd) { Write-Host "    Master-Passwort: $masterPwd (steht auch in config\odoo.conf)" -ForegroundColor Yellow }
    exit 1
}

# ---------------------------------------------------------------- Zusammenfassung

Write-Host ''
Write-Host '  Odoo laeuft!' -ForegroundColor Green
Write-Host "  Adresse:          $url"
if ($AllowNetworkAccess) {
    Write-Host "  Netzwerkzugriff:  AKTIV - andere Geraete erreichen Odoo ueber die IP dieses Rechners, Port $Port" -ForegroundColor Yellow
} else {
    Write-Host '  Netzwerkzugriff:  aus - Odoo ist nur auf diesem Rechner erreichbar'
}
Write-Host "  Projektordner:    $InstallDir"
if ($masterPwd) {
    Write-Host "  Master-Passwort:  $masterPwd" -ForegroundColor Yellow
    Write-Host '                    (steht auch in config\odoo.conf unter admin_passwd)'
} else {
    Write-Host '  Master-Passwort:  siehe config\odoo.conf (admin_passwd)'
}
Write-Host ''
Write-Host '  Hinweis: Die Log-Warnung "invalid addons directory /mnt/extra-addons" ist harmlos,'
Write-Host "  solange $InstallDir\addons leer ist."
Write-Host ''
Write-Host '  Naechster Schritt: im Browser die erste Datenbank anlegen'
Write-Host '  (Master-Passwort, Datenbankname, Login (keine echte E-Mail noetig), Passwort,'
Write-Host '   Sprache und Land waehlen).'
Write-Host ''
Write-Host '  Nach einem Neustart des Rechners startet Odoo automatisch mit Docker Desktop.'
Write-Host ''

Start-Process $url
