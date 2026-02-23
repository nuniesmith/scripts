# map-network-drives.ps1
# Run as Administrator on your Windows machine
# Maps Sullivan and Freddy SMB shares as persistent network drives
#
# Usage: Right-click > Run with PowerShell (as Admin)
#   or:  powershell -ExecutionPolicy Bypass -File .\map-network-drives.ps1

#Requires -RunAsAdministrator

# ─────────────────────────────────────────────
# Configuration - update IPs/hostnames as needed
# ─────────────────────────────────────────────
# Use Tailscale IPs for reliable access, or hostnames if DNS resolves them
$SullivanHost = "sullivan"     # or Tailscale IP like "100.87.125.19"
$FreddyHost   = "freddy"       # or Tailscale IP

$SmbUser = "jordan"

# Drive letter mappings
$Drives = @(
    @{ Letter = "S"; Host = $SullivanHost; Share = "media";       Label = "Sullivan Media" }
    @{ Letter = "T"; Host = $SullivanHost; Share = "local-media"; Label = "Sullivan Local" }
    @{ Letter = "F"; Host = $FreddyHost;   Share = "storage";     Label = "Freddy Storage" }
    @{ Letter = "H"; Host = $FreddyHost;   Share = "local-media"; Label = "Freddy Local" }
)

# ─────────────────────────────────────────────
# Prompt for credentials once
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "=== Network Drive Mapper ===" -ForegroundColor Cyan
Write-Host "SMB User: $SmbUser"
Write-Host ""

$Credential = Get-Credential -UserName $SmbUser -Message "Enter your Samba password for $SmbUser"

if (-not $Credential) {
    Write-Host "No credentials provided. Exiting." -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────
# Map each drive
# ─────────────────────────────────────────────
foreach ($Drive in $Drives) {
    $DriveLetter = "$($Drive.Letter):"
    $UncPath     = "\\$($Drive.Host)\$($Drive.Share)"
    $Label       = $Drive.Label

    Write-Host ""
    Write-Host "--- Mapping $DriveLetter -> $UncPath ($Label) ---" -ForegroundColor Yellow

    # Remove existing mapping if present
    if (Test-Path $DriveLetter) {
        Write-Host "  Removing existing mapping on $DriveLetter..."
        try {
            net use $DriveLetter /delete /y 2>$null | Out-Null
        } catch {
            Remove-PSDrive -Name $Drive.Letter -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 500
    }

    # Test connectivity first
    $HostToTest = $Drive.Host
    Write-Host "  Testing connectivity to $HostToTest..."
    if (-not (Test-Connection -ComputerName $HostToTest -Count 1 -Quiet -TimeoutSeconds 3)) {
        Write-Host "  SKIPPED: Cannot reach $HostToTest" -ForegroundColor Red
        continue
    }

    # Map the drive persistently
    try {
        $Password = $Credential.GetNetworkCredential().Password
        net use $DriveLetter $UncPath /user:$SmbUser $Password /persistent:yes 2>&1 | Out-Null

        if (Test-Path $DriveLetter) {
            # Set friendly label
            $Shell = New-Object -ComObject Shell.Application
            $Shell.NameSpace($DriveLetter).Self.Name = $Label

            Write-Host "  OK: $DriveLetter -> $UncPath" -ForegroundColor Green
        } else {
            Write-Host "  FAILED: Drive mapped but not accessible" -ForegroundColor Red
        }
    } catch {
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
Write-Host ""
Write-Host "=== Current Network Drives ===" -ForegroundColor Cyan
net use | Select-String "\\\\$SullivanHost|\\\\$FreddyHost|OK|Unavailable"

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Green
Write-Host "Drives are persistent and will reconnect on login."
Write-Host "If drives show as disconnected after reboot, run:" -ForegroundColor Gray
Write-Host "  net use <drive>: /delete /y && net use <drive>: \\server\share /user:jordan <password> /persistent:yes" -ForegroundColor Gray
Write-Host ""
