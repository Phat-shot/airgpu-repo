#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Compiles airgpu-driver-manager.exe using csc.exe (built into Windows .NET Framework).
    No Visual Studio or additional tools required.
#>

$OutDir   = "C:\Program Files\airgpu"
$OutExe   = "$OutDir\airgpu-driver-manager.exe"
$IconPath = "$OutDir\airgpu.ico"

# Find csc.exe from .NET Framework
$csc = Get-ChildItem "C:\Windows\Microsoft.NET\Framework64" -Filter "csc.exe" -Recurse -ErrorAction SilentlyContinue |
       Sort-Object FullName -Descending | Select-Object -First 1

if (-not $csc) {
    Write-Host "  ERROR: csc.exe not found. Is .NET Framework installed?" -ForegroundColor Red
    exit 1
}
Write-Host "  Using: $($csc.FullName)" -ForegroundColor DarkGray

# Write manifest
$tempManifest = "$env:TEMP\airgpu.manifest"
@'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <assemblyIdentity version="1.0.0.0" processorArchitecture="X86"
      name="airgpu.DriverManager" type="win32"/>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="requireAdministrator" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
</assembly>
'@ | Set-Content $tempManifest -Encoding UTF8

# Write C# source
$tempCs = "$env:TEMP\airgpu_launcher.cs"
@'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

class Program {
    static int Main(string[] args) {
        string exeDir  = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string ps1Path = Path.Combine(exeDir, "Driver Manager", "Launch-NvidiaDriverManager.ps1");

        if (!File.Exists(ps1Path)) {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.WriteLine("  ERROR: Launcher script not found:");
            Console.WriteLine("  " + ps1Path);
            Console.ResetColor();
            Console.WriteLine("\n  Press any key to exit...");
            Console.ReadKey();
            return 1;
        }

        string passArgs = args.Length > 0 ? string.Join(" ", args) : "";
        string psArgs   = string.Format(
            "-NoProfile -ExecutionPolicy Bypass -File \"{0}\" {1}",
            ps1Path, passArgs).Trim();

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName         = "powershell.exe";
        psi.Arguments        = psArgs;
        psi.UseShellExecute  = false;

        Process proc = Process.Start(psi);
        proc.WaitForExit();
        return proc.ExitCode;
    }
}
'@ | Set-Content $tempCs -Encoding UTF8

# Build compile args
$iconArg = if (Test-Path $IconPath) { "/win32icon:`"$IconPath`"" } else { "" }
$args = "/target:exe /platform:x64 /out:`"$OutExe`" /win32manifest:`"$tempManifest`" $iconArg `"$tempCs`""

Write-Host "  Compiling airgpu-driver-manager.exe..." -ForegroundColor Cyan
$result = & $csc.FullName $args.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) 2>&1

Remove-Item $tempManifest, $tempCs -Force -ErrorAction SilentlyContinue

if ($LASTEXITCODE -ne 0) {
    Write-Host "  Compilation failed:" -ForegroundColor Red
    $result | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    exit 1
}

Write-Host "  Done: $OutExe" -ForegroundColor Green
