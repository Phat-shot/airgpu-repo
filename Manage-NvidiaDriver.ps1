#Requires -RunAsAdministrator
<#
.SYNOPSIS
    airgpu Driver Manager -- NVIDIA driver management for Amazon EC2 Windows 11 instances.

.DESCRIPTION
    - Detects installed NVIDIA driver (version, variant, GPU model)
    - Checks online for newer driver versions
    - Supports in-place update and variant switching (Gaming <-> GRID)
    - Full clean uninstall + registry cleanup before reinstall
    - Sets NVIDIA Virtual Display as Primary Display after installation
    - State persistence across reboots for seamless resume

.NOTES
    Must be run as Administrator on EC2 Windows 11 with NVIDIA GPU.
    Working dir : C:\Program Files\airgpu\Driver Manager\
    State file  : C:\Program Files\airgpu\Driver Manager\state.json
    Log file    : C:\Program Files\airgpu\Driver Manager\driver_manager.log
#>

# ─────────────────────────────────────────────────────────────
#  PARAMETERS
# ─────────────────────────────────────────────────────────────
param([switch]$Resume)

# ─────────────────────────────────────────────────────────────
#  CONFIGURATION
# ─────────────────────────────────────────────────────────────
$WorkDir    = "C:\Program Files\airgpu\Driver Manager"
$StateFile  = "$WorkDir\state.json"
$LogFile    = "$WorkDir\driver_manager.log"
$TempDir    = "C:\Temp\airgpuDriverManager"
$RunKey     = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunName    = "airgpuDriverManagerResume"
$ScriptPath = $MyInvocation.MyCommand.Path

# ─────────────────────────────────────────────────────────────
#  LOGGING
# ─────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

# ─────────────────────────────────────────────────────────────
#  STATE MANAGEMENT
# ─────────────────────────────────────────────────────────────
function Save-State {
    param([hashtable]$State)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8
    Write-Log "State saved: $($State.Step)"
}

function Load-State {
    if (Test-Path $StateFile) {
        try { return (Get-Content $StateFile -Raw -Encoding UTF8) | ConvertFrom-Json -AsHashtable }
        catch { Write-Log "Could not load state file: $_" -Level "WARN" }
    }
    return $null
}

function Clear-State {
    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    Remove-ItemProperty -Path $RunKey -Name $RunName -Force -ErrorAction SilentlyContinue
    Write-Log "State cleared."
}

function Register-ResumeOnBoot {
    param([string]$NextStep)
    $state = Load-State
    if ($null -eq $state) { $state = @{} }
    $state.Step = $NextStep
    Save-State $state
    Set-ItemProperty -Path $RunKey -Name $RunName `
        -Value "powershell.exe -ExecutionPolicy Bypass -File `"$ScriptPath`" -Resume"
    Write-Log "Registered resume on next boot for step: $NextStep"
}

# ─────────────────────────────────────────────────────────────
#  UI HELPERS
# ─────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    # airgpu logo: rocket icon (left) + wordmark (right)
    # The rocket body mirrors the shield/rocket shape from the actual airgpu logo
    Write-Host ""
    Write-Host "      *    .         .    *       .    *   .    .  *  " -ForegroundColor DarkGray
    Write-Host "   .     *    .  *       .    .       .       *      " -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "        /\        " -NoNewline -ForegroundColor Cyan
    Write-Host "        _                   " -ForegroundColor White
    Write-Host "       /  \       " -NoNewline -ForegroundColor Cyan
    Write-Host "   __ (_) _ __  __ _  _ __  _   _  " -ForegroundColor White
    Write-Host "      ||        " -NoNewline -ForegroundColor Cyan
    Write-Host "  / _` || || '__|/ _` || '_ \| | | | " -ForegroundColor White
    Write-Host "   |    |       " -NoNewline -ForegroundColor Cyan
    Write-Host " | (_| || || |  | (_| || |_) | |_| | " -ForegroundColor White
    Write-Host "   | () |       " -NoNewline -ForegroundColor Cyan
    Write-Host "  \__,_||_||_|   \__, || .__/ \__,_| " -ForegroundColor White
    Write-Host "   |    |        " -NoNewline -ForegroundColor Cyan
    Write-Host "                 |___/ |_|            " -ForegroundColor White
    Write-Host "  /|    |\      " -ForegroundColor Cyan
    Write-Host " / |    | \     " -NoNewline -ForegroundColor Cyan
    Write-Host "   D R I V E R   M A N A G E R       " -ForegroundColor DarkCyan
    Write-Host "   \  /\  /     " -NoNewline -ForegroundColor Cyan
    Write-Host "   NVIDIA  *  Amazon EC2  *  Windows 11" -ForegroundColor DarkGray
    Write-Host "    \/  \/      " -ForegroundColor Cyan
    Write-Host "    |    |      " -ForegroundColor DarkCyan
    Write-Host "   /      \     " -ForegroundColor DarkCyan
    Write-Host "  / ' '' ' \    " -ForegroundColor DarkCyan
    Write-Host ""
}

function Show-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  -- $Title " -ForegroundColor DarkGray
    Write-Host ""
}

function Prompt-YesNo {
    param([string]$Question)
    do {
        Write-Host "  $Question [Y/N]: " -ForegroundColor Yellow -NoNewline
        $answer = Read-Host
    } while ($answer -notmatch '^[YyNn]$')
    return ($answer -match '^[Yy]$')
}

function Prompt-Menu {
    param([string]$Title, [string[]]$Options)
    Write-Host ""
    Write-Host "  $Title" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "    [$($i+1)] $($Options[$i])"
    }
    Write-Host "    [0] Cancel / Exit"
    Write-Host ""
    do {
        Write-Host "  Selection: " -ForegroundColor Yellow -NoNewline
        $sel = Read-Host
        $num = -1
        [int]::TryParse($sel, [ref]$num) | Out-Null
    } while ($num -lt 0 -or $num -gt $Options.Count)
    return $num
}

# ─────────────────────────────────────────────────────────────
#  GPU DETECTION
# ─────────────────────────────────────────────────────────────
function Get-InstalledNvidiaInfo {
    $info = @{
        Installed     = $false
        Version       = ""
        VersionParsed = $null
        Variant       = "Unknown"    # Gaming | GRID | Unknown
        GpuName       = ""
        DriverDate    = ""
    }

    $gpus = Get-WmiObject Win32_VideoController |
        Where-Object { $_.Name -like "*NVIDIA*" -or $_.AdapterCompatibility -like "*NVIDIA*" }

    if (-not $gpus) {
        Write-Log "No NVIDIA GPU found via WMI." -Level "WARN"
        return $info
    }

    $gpu             = $gpus | Select-Object -First 1
    $info.GpuName    = $gpu.Name
    $info.DriverDate = $gpu.DriverDate

    # Parse NVIDIA version from WMI string -- last 5 digits become xxx.xx
    if ($gpu.DriverVersion -match '(\d{3})(\d{2})$') {
        $info.Version       = "$($Matches[1]).$($Matches[2])"
        $info.VersionParsed = try { [Version]$info.Version } catch { $null }
    } else {
        $info.Version = $gpu.DriverVersion
    }

    # Prefer nvidia-smi for accuracy
    $smiPath = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
    if (-not (Test-Path $smiPath)) { $smiPath = "nvidia-smi" }
    try {
        $smiOut = & $smiPath --query-gpu=name,driver_version --format=csv,noheader 2>&1
        if ($LASTEXITCODE -eq 0 -and $smiOut) {
            $parts = $smiOut -split ","
            if ($parts.Count -ge 2) {
                $info.GpuName       = $parts[0].Trim()
                $info.Version       = $parts[1].Trim()
                $info.VersionParsed = try { [Version]$info.Version } catch { $null }
            }
        }
    } catch { }

    $info.Installed = $true

    # Determine variant from installed programs
    $nvidiaApps = Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*NVIDIA*" }

    $allNames = ($nvidiaApps | ForEach-Object { $_.DisplayName }) -join " "

    if ($allNames -match "GRID|vGPU|Virtual GPU|Tesla|Enterprise") {
        $info.Variant = "GRID"
    } elseif ($allNames -match "GeForce|Game Ready|Gaming|Studio") {
        $info.Variant = "Gaming"
    } elseif ($info.GpuName -match "Tesla|A10|A100|T4|V100|K80|A10G|L4|L40") {
        $info.Variant = "GRID"
    } else {
        $gridDirs = Get-ChildItem "$env:SystemRoot\System32\DriverStore\FileRepository" `
            -Filter "nvgridsw*" -ErrorAction SilentlyContinue
        $info.Variant = if ($gridDirs) { "GRID" } else { "Gaming" }
    }

    return $info
}

# ─────────────────────────────────────────────────────────────
#  ONLINE VERSION CHECK
# ─────────────────────────────────────────────────────────────
function Get-LatestGamingVersion {
    param([string]$GpuName)
    try {
        $psID = 120
        if ($GpuName -match "A10G") { $psID = 933 }
        if ($GpuName -match "M60")  { $psID = 864 }
        $resp = Invoke-WebRequest `
            -Uri "https://www.nvidia.com/Download/processDriver.aspx?psid=$psID&pfid=783&osid=135&lid=1&whql=1&lang=en-us&ctk=0&qnf=0" `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.Content -match '(\d{3}\.\d{2})') { return @{ Version = $Matches[1]; Url = "" } }
    } catch {
        Write-Log "Gaming driver online check failed: $_" -Level "WARN"
    }
    return @{ Version = "Unknown"; Url = "" }
}

function Get-LatestGridVersion {
    param([string]$GpuName)
    try {
        $resp    = Invoke-WebRequest -Uri "https://griddownloads.nvidia.com/flex/NVIDIAGridLatestDriverVersion" `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        $json    = $resp.Content | ConvertFrom-Json -ErrorAction Stop
        $version = $json.latestDriverVersion ?? $json.version ?? ""
        if ($version) { return @{ Version = $version; Url = "" } }
    } catch { }
    try {
        $s3Base = "https://ec2-windows-nvidia-drivers.s3.amazonaws.com"
        $resp   = Invoke-WebRequest -Uri $s3Base -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
        if ($resp.Content -match '(\d+\.\d+).*?\.exe') {
            return @{ Version = $Matches[1]; Url = "$s3Base/$($Matches[0])" }
        }
    } catch {
        Write-Log "GRID driver online check failed: $_" -Level "WARN"
    }
    return @{ Version = "Unknown"; Url = "" }
}

function Get-DownloadUrl {
    param([string]$Variant, [string]$Version, [string]$GpuName)
    if ($Variant -eq "GRID") {
        $base = "https://ec2-windows-nvidia-drivers.s3.amazonaws.com"
        try {
            $list  = Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            $found = [regex]::Matches($list.Content, '(?<=<Key>)[^<]*' + [regex]::Escape($Version) + '[^<]*\.exe(?=</Key>)')
            if ($found.Count -gt 0) { return "$base/$($found[0].Value)" }
            $allExe = [regex]::Matches($list.Content, '(?<=<Key>)[^<]*\.exe(?=</Key>)')
            if ($allExe.Count -gt 0) { return "$base/$($allExe[$allExe.Count-1].Value)" }
        } catch { }
        return ""
    } else {
        return "https://international.download.nvidia.com/Windows/$Version/$Version-desktop-win10-win11-64bit-international-dch-whql.exe"
    }
}

# ─────────────────────────────────────────────────────────────
#  UNINSTALL
# ─────────────────────────────────────────────────────────────
function Invoke-NvidiaUninstall {
    Show-Section "Uninstalling NVIDIA Drivers"
    Write-Log "Starting NVIDIA uninstall..."

    $apps = Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*NVIDIA*" -and $_.UninstallString }

    if (-not $apps) {
        Write-Host "  No registered NVIDIA programs found -- continuing with cleanup." -ForegroundColor DarkGray
        Write-Log "No registered NVIDIA programs found for uninstall." -Level "WARN"
    } else {
        foreach ($app in $apps) {
            Write-Host "  Uninstalling: $($app.DisplayName)" -ForegroundColor Yellow
            try {
                if ($app.UninstallString -match "MsiExec") {
                    $guid = [regex]::Match($app.UninstallString, '\{[^}]+\}').Value
                    if ($guid) { Start-Process msiexec.exe -ArgumentList "/x $guid /quiet /norestart" -Wait -NoNewWindow }
                } elseif ($app.UninstallString -match "\.exe") {
                    $exe = [regex]::Match($app.UninstallString, '"?([^"]+\.exe)"?').Groups[1].Value
                    if (Test-Path $exe) { Start-Process $exe -ArgumentList "-s -noreboot" -Wait -NoNewWindow }
                }
                Write-Log "Uninstalled: $($app.DisplayName)" -Level "OK"
            } catch {
                Write-Log "Failed to uninstall '$($app.DisplayName)': $_" -Level "WARN"
            }
        }
    }

    Write-Host "  Stopping NVIDIA services..." -ForegroundColor Yellow
    Get-Service | Where-Object { $_.Name -like "nv*" -or $_.DisplayName -like "*NVIDIA*" } | ForEach-Object {
        Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
        sc.exe delete $_.Name 2>&1 | Out-Null
    }

    Write-Host "  Removing NVIDIA files..." -ForegroundColor Yellow
    @(
        "$env:ProgramFiles\NVIDIA Corporation",
        "$env:ProgramFiles\NVIDIA",
        "${env:ProgramFiles(x86)}\NVIDIA Corporation"
    ) | ForEach-Object { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }

    Get-Item "$env:SystemRoot\System32\DriverStore\FileRepository\nv*" -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "  Uninstall complete." -ForegroundColor Green
    Write-Log "Uninstall complete."
}

# ─────────────────────────────────────────────────────────────
#  REGISTRY CLEANUP
# ─────────────────────────────────────────────────────────────
function Invoke-RegistryCleanup {
    Show-Section "Registry Cleanup"
    Write-Log "Cleaning NVIDIA registry entries..."

    @(
        "HKLM:\SOFTWARE\NVIDIA Corporation",
        "HKLM:\SOFTWARE\WOW6432Node\NVIDIA Corporation",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvpciflt",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvstor",
        "HKLM:\SYSTEM\CurrentControlSet\Services\NvStreamKms",
        "HKLM:\SYSTEM\CurrentControlSet\Services\NVSvc",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvvhci",
        "HKLM:\SYSTEM\CurrentControlSet\Services\nvvad_WaveExtensible",
        "HKLM:\SYSTEM\CurrentControlSet\Services\NvTelemetryContainer",
        "HKCU:\SOFTWARE\NVIDIA Corporation"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  Removed: $_" -ForegroundColor DarkGray
            Write-Log "Removed: $_" -Level "OK"
        }
    }

    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ) | ForEach-Object {
        Get-ChildItem $_ -ErrorAction SilentlyContinue |
            Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).DisplayName -like "*NVIDIA*" } |
            ForEach-Object {
                Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Removed uninstall key: $($_.PSChildName)" -Level "OK"
            }
    }

    Write-Host "  Registry cleanup complete." -ForegroundColor Green
    Write-Log "Registry cleanup complete."
}

# ─────────────────────────────────────────────────────────────
#  DOWNLOAD
# ─────────────────────────────────────────────────────────────
function Get-DriverPackage {
    param([string]$Url, [string]$Variant)

    if (-not $Url) {
        Write-Host ""
        Write-Host "  No download URL could be determined automatically." -ForegroundColor Red
        Write-Host "  Please download the driver manually:" -ForegroundColor Yellow
        if ($Variant -eq "GRID") {
            Write-Host "  -> https://ec2-windows-nvidia-drivers.s3.amazonaws.com"
            Write-Host "  -> https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/install-nvidia-driver.html"
        } else {
            Write-Host "  -> https://www.nvidia.com/Download/index.aspx"
        }
        Write-Host ""
        Write-Host "  Enter installer path (leave empty to cancel): " -ForegroundColor Yellow -NoNewline
        return (Read-Host).Trim('"').Trim()
    }

    if (-not (Test-Path $TempDir)) { New-Item -ItemType Directory -Path $TempDir -Force | Out-Null }
    $dest = "$TempDir\$(Split-Path $Url -Leaf)"

    if (Test-Path $dest) {
        Write-Host "  Installer already cached: $dest" -ForegroundColor Green
        return $dest
    }

    Write-Host ""
    Write-Host "  Downloading : $Url" -ForegroundColor Cyan
    Write-Host "  Destination : $dest" -ForegroundColor Cyan
    Write-Host ""

    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadProgressChanged += {
            param($s, $e)
            Write-Progress -Activity "Downloading NVIDIA Driver" `
                -Status "$($e.ProgressPercentage)%  ($([math]::Round($e.BytesReceived/1MB,1)) MB)" `
                -PercentComplete $e.ProgressPercentage
        }
        $wc.DownloadFileAsync([Uri]$Url, $dest)
        while ($wc.IsBusy) { Start-Sleep -Milliseconds 500 }
        Write-Progress -Activity "Downloading NVIDIA Driver" -Completed
        Write-Log "Download complete: $dest" -Level "OK"
        return $dest
    } catch {
        Write-Log "Download failed: $_" -Level "ERROR"
        return ""
    }
}

# ─────────────────────────────────────────────────────────────
#  INSTALL
# ─────────────────────────────────────────────────────────────
function Install-NvidiaDriver {
    param([string]$InstallerPath, [string]$Variant)

    Show-Section "Installing NVIDIA Driver"

    if (-not $InstallerPath -or -not (Test-Path $InstallerPath)) {
        Write-Host "  Installer not found: $InstallerPath" -ForegroundColor Red
        Write-Log "Installer not found: $InstallerPath" -Level "ERROR"
        return $false
    }

    Write-Host "  Installer : $InstallerPath" -ForegroundColor Cyan
    Write-Host "  Variant   : $Variant" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Running silent installation (this may take several minutes)..." -ForegroundColor Yellow

    $argList = @("-s", "-noreboot", "-clean")
    if ($Variant -eq "GRID") { $argList += "-noeula" }

    try {
        $proc = Start-Process -FilePath $InstallerPath -ArgumentList $argList -Wait -PassThru -NoNewWindow
        # Exit code 14 = reboot required but install succeeded
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 14) {
            Write-Host "  Installation complete!" -ForegroundColor Green
            Write-Log "Driver installation succeeded (ExitCode: $($proc.ExitCode))" -Level "OK"
            return $true
        } else {
            Write-Host "  Installation finished with exit code: $($proc.ExitCode)" -ForegroundColor Yellow
            Write-Log "Driver installation ExitCode: $($proc.ExitCode)" -Level "WARN"
            return $true
        }
    } catch {
        Write-Host "  Installation error: $_" -ForegroundColor Red
        Write-Log "Installation exception: $_" -Level "ERROR"
        return $false
    }
}

# ─────────────────────────────────────────────────────────────
#  SET VIRTUAL DISPLAY AS PRIMARY
# ─────────────────────────────────────────────────────────────
function Set-NvidiaVirtualDisplayAsPrimary {
    Show-Section "Setting NVIDIA Virtual Display as Primary"

    $vDisp = Get-WmiObject Win32_PnPEntity |
        Where-Object { $_.Name -like "*NVIDIA Virtual*" -or $_.Name -like "*Virtual Display*" }

    if ($vDisp) {
        foreach ($d in $vDisp) {
            Write-Host "  Found: $($d.Name)" -ForegroundColor Green
            Write-Log "Virtual display found: $($d.Name)" -Level "OK"
        }
    } else {
        Write-Host "  No NVIDIA Virtual Display found via PnP." -ForegroundColor Yellow
        Write-Log "No NVIDIA Virtual Display found via PnP." -Level "WARN"
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        $screens = [System.Windows.Forms.Screen]::AllScreens
        Write-Host ""
        Write-Host "  Detected displays:" -ForegroundColor Cyan
        foreach ($s in $screens) {
            $tag = if ($s.Primary) { "  [PRIMARY]" } else { "" }
            Write-Host "    $($s.DeviceName)  $($s.Bounds.Width)x$($s.Bounds.Height)$tag"
        }
    } catch { }

    Write-Host ""
    Write-Host "  Opening Display Settings..." -ForegroundColor Yellow
    Start-Process "ms-settings:display" -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "  If the NVIDIA Virtual Display was not set as primary automatically:" -ForegroundColor DarkYellow
    Write-Host "  Settings -> System -> Display -> Select display -> 'Make this my main display'" -ForegroundColor DarkYellow
    Write-Log "Display settings opened for user review."
}

# ─────────────────────────────────────────────────────────────
#  REBOOT HELPER
# ─────────────────────────────────────────────────────────────
function Request-Reboot {
    param([string]$Reason, [string]$NextStep)
    Write-Host ""
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  A reboot is recommended.                         |" -ForegroundColor Yellow
    Write-Host "  |  Reason  : $Reason" -ForegroundColor Yellow
    Write-Host "  |  Resumes : Step '$NextStep'" -ForegroundColor Yellow
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""

    Register-ResumeOnBoot -NextStep $NextStep

    if (Prompt-YesNo "Reboot now? (Script will resume automatically after restart)") {
        Write-Log "User confirmed reboot. Resume step: $NextStep"
        Write-Host "  Rebooting in 10 seconds..." -ForegroundColor Red
        Start-Sleep -Seconds 10
        Restart-Computer -Force
    } else {
        Write-Log "User declined reboot. Resume step saved: $NextStep"
        Write-Host ""
        Write-Host "  Reboot skipped. The script will resume at step '$NextStep' on next login." -ForegroundColor Yellow
        Write-Host "  Or run manually: .\Manage-NvidiaDriver.ps1 -Resume" -ForegroundColor DarkGray
    }
}

# ─────────────────────────────────────────────────────────────
#  STATUS DISPLAY
# ─────────────────────────────────────────────────────────────
function Step-ShowStatus {
    Show-Section "Current GPU Status"
    $info = Get-InstalledNvidiaInfo

    if (-not $info.Installed) {
        Write-Host "  [!] No NVIDIA driver detected." -ForegroundColor Red
        Write-Host ""
        return $info
    }

    $varColor = switch ($info.Variant) {
        "Gaming" { "Magenta" }
        "GRID"   { "Blue" }
        default  { "Gray" }
    }

    Write-Host "  GPU Model   : " -NoNewline; Write-Host $info.GpuName -ForegroundColor Cyan
    Write-Host "  Driver Ver  : " -NoNewline; Write-Host $info.Version -ForegroundColor Cyan
    Write-Host "  Variant     : " -NoNewline; Write-Host $info.Variant -ForegroundColor $varColor
    if ($info.DriverDate) {
        Write-Host "  Driver Date : " -NoNewline; Write-Host $info.DriverDate -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Log "Installed driver: $($info.Version) [$($info.Variant)] on $($info.GpuName)"
    return $info
}

# ─────────────────────────────────────────────────────────────
#  ONLINE CHECK
# ─────────────────────────────────────────────────────────────
function Step-CheckOnline {
    param($info)
    Show-Section "Online Version Check"
    Write-Host "  Checking for newer drivers..." -ForegroundColor Yellow

    $latestGaming = Get-LatestGamingVersion -GpuName $info.GpuName
    $latestGrid   = Get-LatestGridVersion   -GpuName $info.GpuName

    Write-Host "  Installed     : $($info.Version)  [$($info.Variant)]" -ForegroundColor White
    Write-Host "  Latest Gaming : $($latestGaming.Version)" -ForegroundColor Magenta
    Write-Host "  Latest GRID   : $($latestGrid.Version)"   -ForegroundColor Blue
    Write-Host ""

    $updateAvailable = $false
    try {
        $current       = [Version]$info.Version
        $latestVariant = if ($info.Variant -eq "GRID") { $latestGrid.Version } else { $latestGaming.Version }
        if ([Version]$latestVariant -gt $current) {
            $updateAvailable = $true
            Write-Host "  [+] Update available: $latestVariant" -ForegroundColor Green
        } else {
            Write-Host "  [=] Driver is up to date." -ForegroundColor Green
        }
    } catch {
        Write-Host "  [?] Version comparison unavailable (unexpected format)." -ForegroundColor DarkGray
    }

    return @{ UpdateAvailable = $updateAvailable; LatestGaming = $latestGaming; LatestGrid = $latestGrid }
}

# ─────────────────────────────────────────────────────────────
#  ACTION MENU
# ─────────────────────────────────────────────────────────────
function Step-ActionMenu {
    param($info, $online)
    Show-Section "Available Actions"

    $opts = @()
    if ($online.UpdateAvailable)      { $opts += "Update driver  ($($info.Variant) -> latest version)" }
    if ($info.Variant -eq "Gaming")   { $opts += "Switch to GRID / Enterprise driver" }
    if ($info.Variant -eq "GRID")     { $opts += "Switch to Gaming / GeForce driver" }
    if (-not $online.UpdateAvailable) { $opts += "Reinstall current driver  ($($info.Version))" }
    $opts += "Set Virtual Display as primary display"
    $opts += "Show status only  (no changes)"

    $sel = Prompt-Menu "What would you like to do?" $opts
    if ($sel -eq 0) { Write-Host "  Cancelled." -ForegroundColor DarkGray; return $null }
    return $opts[$sel - 1]
}

# ─────────────────────────────────────────────────────────────
#  FULL INSTALL FLOW  (reboot-safe state machine)
# ─────────────────────────────────────────────────────────────
function Invoke-FullInstall {
    param([string]$TargetVariant, [string]$Version, [string]$Url)

    $state = Load-State
    if ($null -eq $state) { $state = @{} }
    $state.TargetVariant = $TargetVariant
    $state.TargetVersion = $Version
    $state.TargetUrl     = $Url

    # ── STEP 1: UNINSTALL ────────────────────────────────────
    if ($state.Step -notin @("AFTER_UNINSTALL", "AFTER_REGISTRY")) {
        Write-Host ""
        Write-Host "  Step 1 / 3  --  Uninstall" -ForegroundColor White
        $state.Step = "UNINSTALLING"
        Save-State $state

        Invoke-NvidiaUninstall

        $state.Step = "AFTER_UNINSTALL"
        Save-State $state

        Request-Reboot -Reason "Clean uninstall completed" -NextStep "AFTER_UNINSTALL"
        # Restart-Computer -Force exits the process if user says yes
    }

    # ── STEP 2: REGISTRY CLEANUP ─────────────────────────────
    if ($state.Step -eq "AFTER_UNINSTALL") {
        Write-Host ""
        Write-Host "  Step 2 / 3  --  Registry Cleanup" -ForegroundColor White

        Write-Host "  Rescanning installed drivers..." -ForegroundColor Cyan
        $rescan = Get-InstalledNvidiaInfo
        if ($rescan.Installed) {
            Write-Host "  Still detected: $($rescan.Version) [$($rescan.Variant)]" -ForegroundColor Yellow
        } else {
            Write-Host "  No driver detected -- ready for cleanup." -ForegroundColor Green
        }

        Invoke-RegistryCleanup

        $state.Step = "AFTER_REGISTRY"
        Save-State $state

        Request-Reboot -Reason "Registry cleanup completed" -NextStep "AFTER_REGISTRY"
    }

    # ── STEP 3: INSTALL ──────────────────────────────────────
    if ($state.Step -eq "AFTER_REGISTRY") {
        Write-Host ""
        Write-Host "  Step 3 / 3  --  Install $($state.TargetVariant) Driver  ($($state.TargetVersion))" -ForegroundColor White

        Write-Host "  Rescanning installed drivers..." -ForegroundColor Cyan
        $rescan = Get-InstalledNvidiaInfo
        if ($rescan.Installed) {
            Write-Host "  Still detected: $($rescan.Version) [$($rescan.Variant)]" -ForegroundColor Yellow
        } else {
            Write-Host "  No driver detected -- clean slate confirmed." -ForegroundColor Green
        }
        Write-Host ""

        $installerPath = Get-DriverPackage -Url $state.TargetUrl -Variant $state.TargetVariant
        if (-not $installerPath) {
            Write-Host "  No installer available. Aborting." -ForegroundColor Red
            Clear-State
            return
        }

        $ok = Install-NvidiaDriver -InstallerPath $installerPath -Variant $state.TargetVariant

        if ($ok) {
            $state.Step = "AFTER_INSTALL"
            Save-State $state

            Set-NvidiaVirtualDisplayAsPrimary
            Clear-State

            Write-Host ""
            Write-Host "  +----------------------------------------------+" -ForegroundColor Green
            Write-Host "  |  Installation completed successfully.          |" -ForegroundColor Green
            Write-Host "  +----------------------------------------------+" -ForegroundColor Green
            Write-Host ""

            if (Prompt-YesNo "A reboot is recommended to finalize the driver. Reboot now?") {
                Write-Host "  Rebooting in 10 seconds..." -ForegroundColor Red
                Start-Sleep 10
                Restart-Computer -Force
            }
        } else {
            Write-Host ""
            Write-Host "  Installation failed. State preserved -- re-run the script to retry." -ForegroundColor Red
            Write-Log "Installation failed. State preserved at AFTER_REGISTRY." -Level "ERROR"
        }
    }
}

# ─────────────────────────────────────────────────────────────
#  ENTRY POINT
# ─────────────────────────────────────────────────────────────
foreach ($dir in @($WorkDir, $TempDir)) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

Show-Banner

# ── Resume from saved state (post-reboot or manual -Resume) ──
$existingState = Load-State
if ($existingState -and ($Resume -or ($existingState.Step -in @("AFTER_UNINSTALL", "AFTER_REGISTRY")))) {
    Write-Host "  Resuming from saved step: " -NoNewline -ForegroundColor Yellow
    Write-Host $existingState.Step -ForegroundColor White
    Write-Log "Resuming from step: $($existingState.Step)"
    Write-Host ""
    Write-Host "  Rescanning current GPU driver state..." -ForegroundColor Cyan
    $cur = Get-InstalledNvidiaInfo
    if ($cur.Installed) {
        Write-Host "  Found: $($cur.Version) [$($cur.Variant)]  --  $($cur.GpuName)" -ForegroundColor Cyan
    } else {
        Write-Host "  No driver currently detected." -ForegroundColor DarkGray
    }
    Write-Host ""
    Invoke-FullInstall `
        -TargetVariant $existingState.TargetVariant `
        -Version       $existingState.TargetVersion `
        -Url           $existingState.TargetUrl
    exit 0
}

# ── Fresh run ─────────────────────────────────────────────────
$info = Step-ShowStatus

if (-not $info.Installed) {
    Write-Host "  No NVIDIA driver installed." -ForegroundColor Yellow
    $variant    = if (Prompt-YesNo "Install GRID / Enterprise driver? (No = Gaming)") { "GRID" } else { "Gaming" }
    $latestInfo = if ($variant -eq "GRID") { Get-LatestGridVersion -GpuName "" } else { Get-LatestGamingVersion -GpuName "" }
    $url        = Get-DownloadUrl -Variant $variant -Version $latestInfo.Version -GpuName ""
    Save-State @{ Step="AFTER_REGISTRY"; TargetVariant=$variant; TargetVersion=$latestInfo.Version; TargetUrl=$url }
    Invoke-FullInstall -TargetVariant $variant -Version $latestInfo.Version -Url $url
    exit 0
}

$online = Step-CheckOnline -info $info
$action = Step-ActionMenu  -info $info -online $online
if ($null -eq $action) { exit 0 }

switch -Wildcard ($action) {
    "*Update driver*" {
        $v   = if ($info.Variant -eq "GRID") { $online.LatestGrid.Version } else { $online.LatestGaming.Version }
        $url = Get-DownloadUrl -Variant $info.Variant -Version $v -GpuName $info.GpuName
        Save-State @{ Step="AFTER_REGISTRY"; TargetVariant=$info.Variant; TargetVersion=$v; TargetUrl=$url }
        Invoke-FullInstall -TargetVariant $info.Variant -Version $v -Url $url
    }
    "*GRID*" {
        $v   = $online.LatestGrid.Version
        $url = Get-DownloadUrl -Variant "GRID" -Version $v -GpuName $info.GpuName
        Save-State @{ Step="AFTER_REGISTRY"; TargetVariant="GRID"; TargetVersion=$v; TargetUrl=$url }
        Invoke-FullInstall -TargetVariant "GRID" -Version $v -Url $url
    }
    "*Gaming*" {
        $v   = $online.LatestGaming.Version
        $url = Get-DownloadUrl -Variant "Gaming" -Version $v -GpuName $info.GpuName
        Save-State @{ Step="AFTER_REGISTRY"; TargetVariant="Gaming"; TargetVersion=$v; TargetUrl=$url }
        Invoke-FullInstall -TargetVariant "Gaming" -Version $v -Url $url
    }
    "*Reinstall*" {
        $url = Get-DownloadUrl -Variant $info.Variant -Version $info.Version -GpuName $info.GpuName
        Save-State @{ Step="AFTER_REGISTRY"; TargetVariant=$info.Variant; TargetVersion=$info.Version; TargetUrl=$url }
        Invoke-FullInstall -TargetVariant $info.Variant -Version $info.Version -Url $url
    }
    "*Virtual Display*" {
        Set-NvidiaVirtualDisplayAsPrimary
    }
    default {
        Write-Host "  No action taken." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ""
