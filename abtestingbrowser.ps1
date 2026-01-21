<#
.SYNOPSIS
    Updates Google Chrome and Microsoft Edge on the local machine with resilient offline handling.
.DESCRIPTION
    This script is designed to be run directly on a target VM. It uses a lean
    registry detection method suitable for controlled 64-bit environments. It attempts
    to check for the latest versions online; if it cannot, it assumes an update is
    needed and falls back to installing from a reliable MSI source.
#>

# --- 1. HARDCODED CONFIGURATION - MODIFY VALUES HERE ---

# DANGER: Hardcoding secrets is a security risk. Ensure this script is protected.
# These are the credentials for the Azure File Share where MSIs are stored.
$StorageAccountName = "yourstorageaccount"
$StorageAccountKey  = "yourreallylongstorageaccountaccesskey=="
$FileShareName      = "browserinstallers"

# --- End of Configuration ---


# --- 2. SCRIPT EXECUTION (No changes needed below) ---

# This report object will be filled out and displayed at the end.
$report = [PSCustomObject]@{
    ComputerName         = $env:COMPUTERNAME
    Status               = 'Failure' # Default to Failure
    Message              = ''
    ChromeVersionInitial = 'Not Installed'
    ChromeVersionFinal   = 'Not Installed'
    EdgeVersionInitial   = 'Not Installed'
    EdgeVersionFinal     = 'Not Installed'
}

try {
    # --- Step A: Get Latest Version Info (Resilient Method) ---
    $latestChromeVersion = $null
    $latestEdgeVersion = $null
    $internetOK = $true
    
    Write-Host "Checking for latest browser versions..." -ForegroundColor Cyan
    try {
        $chromeApiUrl = "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"
        $chromeData = Invoke-RestMethod -Uri $chromeApiUrl -TimeoutSec 15
        $latestChromeVersion = $chromeData.channels.Stable.version
    
        $edgeReleaseNotesUrl = "https://learn.microsoft.com/en-us/deployedge/microsoft-edge-relnote-stable-channel"
        $edgePage = Invoke-WebRequest -Uri $edgeReleaseNotesUrl -UseBasicParsing -TimeoutSec 15
        $edgeMatch = ($edgePage.Content -split '\r?\n' |
                      Select-String -Pattern 'Version\s+([\d\.]+)\s+to\s+the\s+Stable\s+Channel' -AllMatches).Matches
        if ($edgeMatch.Count -gt 0) {
            $latestEdgeVersion = $edgeMatch[0].Groups[1].Value
        }
    
        Write-Host "  [+] Latest Chrome Target: $latestChromeVersion"
        Write-Host "  [+] Latest Edge Target:   $latestEdgeVersion"
    }
    catch {
        $internetOK = $false
        Write-Warning "Could not fetch latest version info — proceeding with MSI update for installed browsers."
    }

    # --- Step B: Get Currently Installed Versions ---
    # Simplified function for a controlled 64-bit environment.
    function Get-InstalledVersions {
        $versions = @{ Chrome = $null; Edge = $null }
        try { $versions.Chrome = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome").DisplayVersion } catch {}
        # For 64-bit Edge on 64-bit Windows, the primary key is in the native hive.
        try { $versions.Edge = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-418B-B694-B130680B5DE0}").pv } catch {}
        return $versions
    }
    
    # Safe comparison function
    function Safe-VersionCompare {
        param([string]$Current, [string]$Latest)
        # Explicitly handle "no latest version" (offline or parse fail)
        if ([string]::IsNullOrWhiteSpace($Latest)) {
            return $true  # Assume update needed if we don't know
        }
        try {
            return ([version]$Current -lt [version]$Latest)
        }
        catch {
            # Only hit this if the string was malformed
            return $true
        }
    }

    $initialVersions = Get-InstalledVersions
    $report.ChromeVersionInitial = $initialVersions.Chrome ?? 'Not Installed'
    $report.EdgeVersionInitial = $initialVersions.Edge ?? 'Not Installed'
    Write-Host "Initial versions found: Chrome `($($report.ChromeVersionInitial)`), Edge `($($report.EdgeVersionInitial)`)"

    # --- Step C: Decide if an update is needed ---
    if ($initialVersions.Chrome -eq $null -and $initialVersions.Edge -eq $null) {
        $report.Status = 'Skipped'
        $report.Message = 'No browsers installed — nothing to do.'
    }
    else {
        $chromeUpdateNeeded = $false
        $edgeUpdateNeeded = $false
        
        if ($internetOK) {
            # Online: Compare versions
            if ($initialVersions.Chrome -ne $null) { $chromeUpdateNeeded = Safe-VersionCompare $initialVersions.Chrome $latestChromeVersion }
            if ($initialVersions.Edge -ne $null) { $edgeUpdateNeeded = Safe-VersionCompare $initialVersions.Edge $latestEdgeVersion }
        } else {
            # Offline: Assume update is needed for any installed browser
            if ($initialVersions.Chrome -ne $null) { $chromeUpdateNeeded = $true }
            if ($initialVersions.Edge -ne $null) { $edgeUpdateNeeded = $true }
        }

        if (-not $chromeUpdateNeeded -and -not $edgeUpdateNeeded) {
            $report.Status = 'Success'
            $report.Message = 'All installed browsers already up-to-date.'
        }
        else {
            # --- Step D: Perform Update using MSI from Azure File Share ---
            Write-Host "`nUpdate required. Using MSI installers from Azure File Share..." -ForegroundColor Yellow
            $uncPath = "\\$StorageAccountName.file.core.windows.net\$FileShareName"
            try {
                Write-Host "  -> Establishing temporary connection..."
                net use $uncPath /user:$StorageAccountName $StorageAccountKey | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Failed to authenticate to Azure File Share." }

                if ($chromeUpdateNeeded) {
                    Write-Host "  -> Installing/Updating Chrome from MSI..."
                    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$uncPath\GoogleChromeStandaloneEnterprise64.msi`" /qn /norestart" -Wait -PassThru
                    if ($proc.ExitCode -ne 0) { throw "Chrome MSI installer failed with exit code $($proc.ExitCode)." }
                }
                if ($edgeUpdateNeeded) {
                    Write-Host "  -> Installing/Updating Edge from MSI..."
                    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$uncPath\MicrosoftEdgeEnterpriseX64.msi`" /qn /norestart" -Wait -PassThru
                    if ($proc.ExitCode -ne 0) { throw "Edge MSI installer failed with exit code $($proc.ExitCode)." }
                }
                
                $report.Status = 'Success'
                $report.Message = if ($internetOK) { 'Update completed based on version check.' } else { 'Update completed (offline mode).' }
            }
            finally {
                # This cleanup ALWAYS runs to ensure the connection is removed.
                Write-Host "  -> Cleaning up connection..."
                net use $uncPath /delete /y | Out-Null
            }
        }
    }
}
catch {
    # If any part of the main 'try' block fails, this catch block will run.
    $report.Status = 'Failure'
    $report.Message = "ERROR: $($_.Exception.Message.Trim())"
}
finally {
    # This block ALWAYS runs, ensuring a final report is generated.
    Write-Host "`n--- UPDATE SUMMARY FOR $($env:COMPUTERNAME) ---`n" -ForegroundColor Green
    
    # Get the absolute final versions and update the report card.
    $finalVersions = Get-InstalledVersions
    $report.ChromeVersionFinal = $finalVersions.Chrome ?? 'Not Installed'
    $report.EdgeVersionFinal = $finalVersions.Edge ?? 'Not Installed'

    # Display the final report object in the console.
    $report | Format-List
}