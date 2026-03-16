#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Injects a 4K-capable EDID into the vGPU display adapter on EC2 Gaming instances.

.DESCRIPTION
    After switching to the NVIDIA Gaming driver on EC2, the virtual display adapter
    reports no EDID, causing Windows to fall back to 1366x768. This script injects
    a 256-byte EDID (base block + CTA-861 extension) that advertises all standard
    resolutions from 640x480 up to 3840x2160 @ 60Hz, then sets the resolution to
    4K immediately via Set-DisplayResolution.

.NOTES
    Effective after the next RDP reconnect or session start.
    Run once after every Gaming driver install.
#>

# ── Logging helper (writes to console + optional log file) ─────────────────
$LogFile = "$env:ProgramData\airgpu\edid_fix.log"
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    try {
        $dir = Split-Path $LogFile
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $LogFile -Value $line -Encoding UTF8
    } catch {}
    if ($Level -eq "WARN")  { Write-Host "  [!] $Message" -ForegroundColor Yellow }
    if ($Level -eq "ERROR") { Write-Host "  [!] $Message" -ForegroundColor Red }
}

# ── Main ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  airgpu -- Gaming Display Fix" -ForegroundColor DarkCyan
Write-Host "  Injecting 4K EDID..." -ForegroundColor DarkGray
Write-Host ""

Write-Log "Starting EDID injection (4K, all modes up to 3840x2160@60Hz)."

try {
    # ── 128-byte EDID 1.4 base block ─────────────────────────────────────
    # Preferred timing: 3840x2160@60Hz (DTD1)
    # Also includes: 1920x1080@60Hz (DTD2), monitor name "NVIDIA 4K"
    # Monitor range: 24-75Hz / 30-255kHz / max 600MHz pixel clock
    $base = [byte[]](
        0x00,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0x00,0x36,0x93,0x01,0x00,0x00,0x00,0x00,0x00,
        0x00,0x1E,0x01,0x04,0xA5,0x3D,0x22,0x78,0x3E,0xEE,0xEE,0x91,0xA3,0x54,0x4C,0x99,
        0x26,0x0F,0x50,0x21,0x08,0x00,0xD1,0xC0,0x81,0xC0,0x81,0x80,0x61,0x40,0x45,0x40,
        0x01,0x01,0x01,0x01,0x01,0x01,0x4D,0xD0,0x00,0xB0,0xF0,0x70,0x3E,0x80,0x58,0x2C,
        0x85,0x00,0x3D,0x22,0x00,0x00,0x00,0x18,0x02,0x3A,0x80,0x18,0x71,0x38,0x2D,0x40,
        0x58,0x2C,0x45,0x00,0x34,0x1D,0x00,0x00,0x00,0x18,0x00,0x00,0x00,0xFC,0x00,0x4E,
        0x56,0x49,0x44,0x49,0x41,0x20,0x34,0x4B,0x0A,0x20,0x20,0x20,0x00,0x00,0x00,0xFD,
        0x00,0x18,0x4B,0x1E,0xFF,0x3C,0x00,0x0A,0x20,0x20,0x20,0x20,0x20,0x20,0x01,0x00
    )
    # Recompute base checksum at runtime
    $s = 0; for ($i = 0; $i -lt 127; $i++) { $s += $base[$i] }
    $base[127] = [byte]((256 - ($s % 256)) % 256)

    # ── 128-byte CTA-861 extension block ─────────────────────────────────
    # Video Data Block: VIC 95 (3840x2160@60, native), 97, 96, 16, 4, 3, 1
    # DTDs: 2560x1440@60, 1280x720@60, 1600x900@60
    $ext = [byte[]](
        0x02,0x03,0x2C,0x09,0x47,0xDF,0x61,0x60,0x10,0x04,0x03,0x01,0x23,0x09,0x07,0x07,
        0x83,0x01,0x00,0x00,0x65,0x03,0x0C,0x00,0x10,0x00,0xE2,0x00,0xFB,0x06,0x0F,0x01,
        0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x56,0x5E,0x00,0xA0,
        0xA0,0xA0,0x2D,0x50,0x30,0x20,0x35,0x00,0x35,0x1E,0x00,0x00,0x00,0x18,0x01,0x1D,
        0x00,0x72,0x51,0xD0,0x1E,0x20,0x6E,0x28,0x55,0x00,0x23,0x14,0x00,0x00,0x00,0x18,
        0x30,0x2A,0x40,0xC8,0x60,0x84,0x19,0x30,0x18,0x50,0x13,0x00,0x2C,0x19,0x00,0x00,
        0x00,0x18,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
        0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
    )
    # Recompute extension checksum at runtime
    $s2 = 0; for ($i = 0; $i -lt 127; $i++) { $s2 += $ext[$i] }
    $ext[127] = [byte]((256 - ($s2 % 256)) % 256)

    # Combine into final 256-byte EDID
    $edid = New-Object byte[] 256
    [System.Array]::Copy($base, 0, $edid, 0,   128)
    [System.Array]::Copy($ext,  0, $edid, 128, 128)

    # Inject into all DISPLAY enum nodes
    $vidPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY'
    $n = 0
    if (Test-Path $vidPath) {
        Get-ChildItem $vidPath -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
                $devParams = Join-Path $_.PSPath 'Device Parameters'
                if (Test-Path $devParams) {
                    try {
                        Set-ItemProperty -Path $devParams -Name 'EDID' -Value $edid -Type Binary -Force
                        $n++
                    } catch {
                        Write-Log "EDID inject failed at ${devParams}: $_"
                    }
                }
            }
        }
    }

    Write-Host "  EDID injected into $n display device(s)." -ForegroundColor DarkCyan
    Write-Log "4K EDID injected into $n display device(s)."

} catch {
    Write-Log "EDID injection error: $_" -Level "ERROR"
}

# ── Set resolution immediately ────────────────────────────────────────────
try {
    if (Get-Command Set-DisplayResolution -ErrorAction SilentlyContinue) {
        Set-DisplayResolution -Width 3840 -Height 2160 -Force
        Write-Host "  Resolution set to 3840x2160." -ForegroundColor DarkCyan
        Write-Log "Set-DisplayResolution 3840x2160 OK."
    } else {
        Write-Host "  Set-DisplayResolution not available -- reboot to apply." -ForegroundColor DarkGray
        Write-Log "Set-DisplayResolution not available on this OS."
    }
} catch {
    Write-Log "Set-DisplayResolution failed: $_" -Level "WARN"
}

Write-Host ""
Write-Host "  Done. All resolutions up to 4K available after next RDP reconnect." -ForegroundColor DarkCyan
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ""
