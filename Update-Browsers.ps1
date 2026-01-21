<#
.SYNOPSIS
    Automatically updates Google Chrome and Microsoft Edge browsers.
.DESCRIPTION
    This script detects which browsers (Chrome, Edge) are installed and updates
    only those browsers using MSI installers from an Azure File Share.
    Designed for air-gapped/offline environments.
    
    Compatible with PowerShell 5.1 (built into Windows).
.NOTES
    - Only updates browsers that are already installed
    - Copies MSI from Azure File Share to Downloads, installs, then removes MSI
    - Optionally closes running browser processes before update
    - Shows clear before/after version comparison
.EXAMPLE
    .\Update-Browsers.ps1
    .\Update-Browsers.ps1 -Force  # Closes running browsers automatically
#>

[CmdletBinding()]
param(
    [switch]$Force  # If set, will close running browser processes without prompting
)

#Requires -RunAsAdministrator

# ============================================================================
# CONFIGURATION - MODIFY THESE VALUES FOR YOUR ENVIRONMENT
# ============================================================================

$Config = @{
    # Azure File Share credentials
    # NOTE: Keep this script secured - contains sensitive credentials
    StorageAccountName = "yourstorageaccount"
    StorageAccountKey  = "YourStorageAccountKeyHere=="
    FileShareName      = "browserinstallers"
    
    # MSI filenames in the Azure File Share (update these if your filenames differ)
    ChromeMsiFilename  = "GoogleChromeStandaloneEnterprise64.msi"
    EdgeMsiFilename    = "MicrosoftEdgeEnterpriseX64.msi"
    FirefoxMsiFilename = "Firefox Setup 134.0.msi"  # Update version number as needed
    
    # Downloads folder for MSI files (will be cleaned up after install)
    DownloadsFolder = Join-Path $env:USERPROFILE "Downloads"
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $colors = @{
        'Info'    = 'Cyan'
        'Success' = 'Green'
        'Warning' = 'Yellow'
        'Error'   = 'Red'
    }
    $prefix = @{
        'Info'    = '[i]'
        'Success' = '[+]'
        'Warning' = '[!]'
        'Error'   = '[X]'
    }
    
    Write-Host "$timestamp $($prefix[$Level]) $Message" -ForegroundColor $colors[$Level]
}

function Get-ChromeVersion {
    <#
    .SYNOPSIS
        Gets the installed Chrome version from multiple registry locations.
    #>
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Google Chrome",
        "HKLM:\SOFTWARE\Google\Chrome\BLBeacon"
    )
    
    foreach ($path in $paths) {
        try {
            if (Test-Path $path) {
                $item = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                if ($item.DisplayVersion) { return $item.DisplayVersion }
                if ($item.version) { return $item.version }
            }
        }
        catch { }
    }
    
    # Fallback: Check the Chrome executable directly
    $chromePath = "${env:ProgramFiles}\Google\Chrome\Application\chrome.exe"
    if (-not (Test-Path $chromePath)) {
        $chromePath = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    }
    
    if (Test-Path $chromePath) {
        try {
            return (Get-Item $chromePath).VersionInfo.ProductVersion
        }
        catch { }
    }
    
    return $null
}

function Get-EdgeVersion {
    <#
    .SYNOPSIS
        Gets the installed Edge version from multiple registry locations.
    #>
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-418B-B694-B130680B5DE0}",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-418B-B694-B130680B5DE0}",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
    )
    
    foreach ($path in $paths) {
        try {
            if (Test-Path $path) {
                $item = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue
                if ($item.pv) { return $item.pv }
                if ($item.DisplayVersion) { return $item.DisplayVersion }
            }
        }
        catch { }
    }
    
    # Fallback: Check the Edge executable directly
    $edgePath = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
    if (-not (Test-Path $edgePath)) {
        $edgePath = "${env:ProgramFiles}\Microsoft\Edge\Application\msedge.exe"
    }
    
    if (Test-Path $edgePath) {
        try {
            return (Get-Item $edgePath).VersionInfo.ProductVersion
        }
        catch { }
    }
    
    return $null
}

function Get-FirefoxVersion {
    <#
    .SYNOPSIS
        Gets the installed Firefox version from multiple registry locations.
    #>
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Mozilla Firefox*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Mozilla Firefox*"
    )
    
    foreach ($pattern in $paths) {
        try {
            $keys = Get-Item -Path $pattern -ErrorAction SilentlyContinue
            foreach ($key in $keys) {
                $item = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                if ($item.DisplayVersion) { return $item.DisplayVersion }
            }
        }
        catch { }
    }
    
    # Fallback: Check the Firefox executable directly
    $firefoxPath = "${env:ProgramFiles}\Mozilla Firefox\firefox.exe"
    if (-not (Test-Path $firefoxPath)) {
        $firefoxPath = "${env:ProgramFiles(x86)}\Mozilla Firefox\firefox.exe"
    }
    
    if (Test-Path $firefoxPath) {
        try {
            return (Get-Item $firefoxPath).VersionInfo.ProductVersion
        }
        catch { }
    }
    
    return $null
}

function Close-BrowserProcesses {
    param(
        [string]$BrowserName,
        [string[]]$ProcessNames
    )
    
    $running = Get-Process -Name $ProcessNames -ErrorAction SilentlyContinue
    
    if ($running) {
        Write-Log "$BrowserName is currently running." -Level Warning
        
        if ($Force) {
            Write-Log "Force flag set - closing $BrowserName processes..." -Level Warning
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            return $true
        }
        else {
            $response = Read-Host "Close $BrowserName to continue update? (Y/N)"
            if ($response -eq 'Y' -or $response -eq 'y') {
                $running | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                return $true
            }
            else {
                Write-Log "Skipping $BrowserName update (browser still running)." -Level Warning
                return $false
            }
        }
    }
    
    return $true
}

function Copy-FromFileShare {
    param(
        [string]$SourcePath,
        [string]$Destination,
        [string]$BrowserName
    )
    
    try {
        Write-Log "Copying $BrowserName installer from file share..."
        
        if (-not (Test-Path $SourcePath)) {
            Write-Log "MSI not found at: $SourcePath" -Level Error
            return $false
        }
        
        Copy-Item -Path $SourcePath -Destination $Destination -Force
        
        if (Test-Path $Destination) {
            $size = [math]::Round((Get-Item $Destination).Length / 1MB, 2)
            Write-Log "Copy complete ($size MB)" -Level Success
            return $true
        }
        
        return $false
    }
    catch {
        Write-Log "Copy failed: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Install-MSI {
    param(
        [string]$MsiPath,
        [string]$BrowserName
    )
    
    try {
        Write-Log "Installing $BrowserName update..."
        
        # Silent install, no logging, no restart
        $arguments = "/i `"$MsiPath`" /qn /norestart"
        
        $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            # 0 = Success, 3010 = Success but reboot required
            if ($process.ExitCode -eq 3010) {
                Write-Log "$BrowserName updated successfully (reboot recommended)" -Level Success
            }
            else {
                Write-Log "$BrowserName updated successfully" -Level Success
            }
            return $true
        }
        else {
            Write-Log "$BrowserName installation failed with exit code: $($process.ExitCode)" -Level Error
            return $false
        }
    }
    catch {
        Write-Log "Installation error: $($_.Exception.Message)" -Level Error
        return $false
    }
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Clear-Host
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           BROWSER UPDATE SCRIPT v2.0                         ║" -ForegroundColor Cyan
Write-Host "║           Chrome & Edge Automatic Updater                    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Initialize results tracking
$results = @{
    Chrome = @{
        Installed     = $false
        VersionBefore = $null
        VersionAfter  = $null
        Updated       = $false
        Status        = 'Not Installed'
    }
    Edge = @{
        Installed     = $false
        VersionBefore = $null
        VersionAfter  = $null
        Updated       = $false
        Status        = 'Not Installed'
    }
    Firefox = @{
        Installed     = $false
        VersionBefore = $null
        VersionAfter  = $null
        Updated       = $false
        Status        = 'Not Installed'
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Detect Installed Browsers
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── STEP 1: Detecting Installed Browsers ───" -ForegroundColor White
Write-Host ""

$chromeVersion = Get-ChromeVersion
$edgeVersion = Get-EdgeVersion

if ($chromeVersion) {
    $results.Chrome.Installed = $true
    $results.Chrome.VersionBefore = $chromeVersion
    Write-Log "Google Chrome detected: v$chromeVersion" -Level Success
}
else {
    Write-Log "Google Chrome: Not installed (will skip)" -Level Info
}

if ($edgeVersion) {
    $results.Edge.Installed = $true
    $results.Edge.VersionBefore = $edgeVersion
    Write-Log "Microsoft Edge detected: v$edgeVersion" -Level Success
}
else {
    Write-Log "Microsoft Edge: Not installed (will skip)" -Level Info
}

$firefoxVersion = Get-FirefoxVersion
if ($firefoxVersion) {
    $results.Firefox.Installed = $true
    $results.Firefox.VersionBefore = $firefoxVersion
    Write-Log "Mozilla Firefox detected: v$firefoxVersion" -Level Success
}
else {
    Write-Log "Mozilla Firefox: Not installed (will skip)" -Level Info
}

# Check if any browsers are installed
if (-not $results.Chrome.Installed -and -not $results.Edge.Installed -and -not $results.Firefox.Installed) {
    Write-Host ""
    Write-Log "No supported browsers found. Nothing to update." -Level Warning
    Write-Host ""
    exit 0
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Prepare for Updates & Connect to Azure File Share
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── STEP 2: Connecting to Azure File Share ───" -ForegroundColor White
Write-Host ""

# Verify Downloads folder exists (it should, but just in case)
if (-not (Test-Path $Config.DownloadsFolder)) {
    New-Item -ItemType Directory -Path $Config.DownloadsFolder -Force | Out-Null
}
Write-Log "Using folder: $($Config.DownloadsFolder)" -Level Info

# Build UNC path and connect
$uncPath = "\\$($Config.StorageAccountName).file.core.windows.net\$($Config.FileShareName)"
$fileShareConnected = $false

try {
    Write-Log "Connecting to: $uncPath"
    
    # Remove any existing connection first (in case of stale mount)
    net use $uncPath /delete /y 2>$null | Out-Null
    
    # Establish connection
    $netResult = net use $uncPath /user:$($Config.StorageAccountName) $($Config.StorageAccountKey) 2>&1
    
    if ($LASTEXITCODE -eq 0) {
        Write-Log "Connected to Azure File Share" -Level Success
        $fileShareConnected = $true
    }
    else {
        throw "net use failed: $netResult"
    }
}
catch {
    Write-Log "Failed to connect to Azure File Share: $($_.Exception.Message)" -Level Error
    Write-Log "Ensure storage account credentials are correct and network is accessible." -Level Warning
    
    # Mark all as failed and skip to report
    if ($results.Chrome.Installed) { $results.Chrome.Status = 'Connection Failed' }
    if ($results.Edge.Installed) { $results.Edge.Status = 'Connection Failed' }
    if ($results.Firefox.Installed) { $results.Firefox.Status = 'Connection Failed' }
}

if ($fileShareConnected) {
    # ─────────────────────────────────────────────────────────────────────────────
    # STEP 3: Update Chrome (if installed)
    # ─────────────────────────────────────────────────────────────────────────────
    if ($results.Chrome.Installed) {
        Write-Host ""
        Write-Host "─── STEP 3a: Updating Google Chrome ───" -ForegroundColor White
        Write-Host ""
        
        # Check/close running processes
        $canProceed = Close-BrowserProcesses -BrowserName "Chrome" -ProcessNames @("chrome", "GoogleUpdate")
        
        if ($canProceed) {
            $chromeSourcePath = Join-Path $uncPath $Config.ChromeMsiFilename
            $chromeMsiPath = Join-Path $Config.DownloadsFolder $Config.ChromeMsiFilename
            
            # Copy from file share
            $copied = Copy-FromFileShare -SourcePath $chromeSourcePath -Destination $chromeMsiPath -BrowserName "Chrome"
            
            if ($copied) {
                # Install
                $installed = Install-MSI -MsiPath $chromeMsiPath -BrowserName "Chrome"
                
                if ($installed) {
                    $results.Chrome.Updated = $true
                    $results.Chrome.Status = 'Updated'
                }
                else {
                    $results.Chrome.Status = 'Install Failed'
                }
            }
            else {
                $results.Chrome.Status = 'Copy Failed'
            }
        }
        else {
            $results.Chrome.Status = 'Skipped (Running)'
        }
    }

    # ─────────────────────────────────────────────────────────────────────────────
    # STEP 4: Update Edge (if installed)
    # ─────────────────────────────────────────────────────────────────────────────
    if ($results.Edge.Installed) {
        Write-Host ""
        Write-Host "─── STEP 3b: Updating Microsoft Edge ───" -ForegroundColor White
        Write-Host ""
        
        # Check/close running processes
        $canProceed = Close-BrowserProcesses -BrowserName "Edge" -ProcessNames @("msedge", "MicrosoftEdgeUpdate")
        
        if ($canProceed) {
            $edgeSourcePath = Join-Path $uncPath $Config.EdgeMsiFilename
            $edgeMsiPath = Join-Path $Config.DownloadsFolder $Config.EdgeMsiFilename
            
            # Copy from file share
            $copied = Copy-FromFileShare -SourcePath $edgeSourcePath -Destination $edgeMsiPath -BrowserName "Edge"
            
            if ($copied) {
                # Install
                $installed = Install-MSI -MsiPath $edgeMsiPath -BrowserName "Edge"
                
                if ($installed) {
                    $results.Edge.Updated = $true
                    $results.Edge.Status = 'Updated'
                }
                else {
                    $results.Edge.Status = 'Install Failed'
                }
            }
            else {
                $results.Edge.Status = 'Copy Failed'
            }
        }
        else {
            $results.Edge.Status = 'Skipped (Running)'
        }
    }

    # ─────────────────────────────────────────────────────────────────────────────
    # STEP 5: Update Firefox (if installed)
    # ─────────────────────────────────────────────────────────────────────────────
    if ($results.Firefox.Installed) {
        Write-Host ""
        Write-Host "─── STEP 3c: Updating Mozilla Firefox ───" -ForegroundColor White
        Write-Host ""
        
        # Check/close running processes
        $canProceed = Close-BrowserProcesses -BrowserName "Firefox" -ProcessNames @("firefox")
        
        if ($canProceed) {
            $firefoxSourcePath = Join-Path $uncPath $Config.FirefoxMsiFilename
            $firefoxMsiPath = Join-Path $Config.DownloadsFolder $Config.FirefoxMsiFilename
            
            # Copy from file share
            $copied = Copy-FromFileShare -SourcePath $firefoxSourcePath -Destination $firefoxMsiPath -BrowserName "Firefox"
            
            if ($copied) {
                # Install
                $installed = Install-MSI -MsiPath $firefoxMsiPath -BrowserName "Firefox"
                
                if ($installed) {
                    $results.Firefox.Updated = $true
                    $results.Firefox.Status = 'Updated'
                }
                else {
                    $results.Firefox.Status = 'Install Failed'
                }
            }
            else {
                $results.Firefox.Status = 'Copy Failed'
            }
        }
        else {
            $results.Firefox.Status = 'Skipped (Running)'
        }
    }
    
    # Disconnect from file share
    Write-Host ""
    Write-Log "Disconnecting from Azure File Share..." -Level Info
    net use $uncPath /delete /y 2>$null | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: Get Final Versions
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "─── STEP 4: Verifying Updates ───" -ForegroundColor White
Write-Host ""

Start-Sleep -Seconds 2  # Brief pause for registry to update

if ($results.Chrome.Installed) {
    $results.Chrome.VersionAfter = Get-ChromeVersion
}

if ($results.Edge.Installed) {
    $results.Edge.VersionAfter = Get-EdgeVersion
}

if ($results.Firefox.Installed) {
    $results.Firefox.VersionAfter = Get-FirefoxVersion
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6: Cleanup - Remove ONLY the browser MSI files, nothing else
# ─────────────────────────────────────────────────────────────────────────────
Write-Log "Cleaning up MSI installers..." -Level Info

# Delete ONLY the specific Chrome, Edge, and Firefox MSI files by exact name
$chromeMsiToDelete = Join-Path $Config.DownloadsFolder $Config.ChromeMsiFilename
$edgeMsiToDelete = Join-Path $Config.DownloadsFolder $Config.EdgeMsiFilename
$firefoxMsiToDelete = Join-Path $Config.DownloadsFolder $Config.FirefoxMsiFilename

if (Test-Path $chromeMsiToDelete) {
    Remove-Item -Path $chromeMsiToDelete -Force -ErrorAction SilentlyContinue
}
if (Test-Path $edgeMsiToDelete) {
    Remove-Item -Path $edgeMsiToDelete -Force -ErrorAction SilentlyContinue
}
if (Test-Path $firefoxMsiToDelete) {
    Remove-Item -Path $firefoxMsiToDelete -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# FINAL REPORT
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                    UPDATE SUMMARY                            ║" -ForegroundColor Green
Write-Host "╠══════════════════════════════════════════════════════════════╣" -ForegroundColor Green
Write-Host "║  Computer: $($env:COMPUTERNAME.PadRight(49))║" -ForegroundColor Green
Write-Host "║  Date:     $($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').PadRight(49))║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

# Chrome Summary
if ($results.Chrome.Installed) {
    $chromeStatusColor = if ($results.Chrome.Updated) { 'Green' } elseif ($results.Chrome.Status -like '*Failed*') { 'Red' } else { 'Yellow' }
    
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor $chromeStatusColor
    Write-Host "│  GOOGLE CHROME                                              │" -ForegroundColor $chromeStatusColor
    Write-Host "├─────────────────────────────────────────────────────────────┤" -ForegroundColor $chromeStatusColor
    
    $beforeStr = "│  Previous Version:  $($results.Chrome.VersionBefore)"
    Write-Host "$($beforeStr.PadRight(62))│" -ForegroundColor $chromeStatusColor
    
    $afterStr = "│  Current Version:   $($results.Chrome.VersionAfter)"
    Write-Host "$($afterStr.PadRight(62))│" -ForegroundColor $chromeStatusColor
    
    # Compare versions
    if ($results.Chrome.VersionBefore -eq $results.Chrome.VersionAfter) {
        $statusMsg = "│  Status:            Already up-to-date (no change)"
    }
    elseif ($results.Chrome.Updated) {
        $statusMsg = "│  Status:            ✓ UPGRADED SUCCESSFULLY"
    }
    else {
        $statusMsg = "│  Status:            $($results.Chrome.Status)"
    }
    Write-Host "$($statusMsg.PadRight(62))│" -ForegroundColor $chromeStatusColor
    
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor $chromeStatusColor
    Write-Host ""
}

# Edge Summary
if ($results.Edge.Installed) {
    $edgeStatusColor = if ($results.Edge.Updated) { 'Green' } elseif ($results.Edge.Status -like '*Failed*') { 'Red' } else { 'Yellow' }
    
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor $edgeStatusColor
    Write-Host "│  MICROSOFT EDGE                                             │" -ForegroundColor $edgeStatusColor
    Write-Host "├─────────────────────────────────────────────────────────────┤" -ForegroundColor $edgeStatusColor
    
    $beforeStr = "│  Previous Version:  $($results.Edge.VersionBefore)"
    Write-Host "$($beforeStr.PadRight(62))│" -ForegroundColor $edgeStatusColor
    
    $afterStr = "│  Current Version:   $($results.Edge.VersionAfter)"
    Write-Host "$($afterStr.PadRight(62))│" -ForegroundColor $edgeStatusColor
    
    # Compare versions
    if ($results.Edge.VersionBefore -eq $results.Edge.VersionAfter) {
        $statusMsg = "│  Status:            Already up-to-date (no change)"
    }
    elseif ($results.Edge.Updated) {
        $statusMsg = "│  Status:            ✓ UPGRADED SUCCESSFULLY"
    }
    else {
        $statusMsg = "│  Status:            $($results.Edge.Status)"
    }
    Write-Host "$($statusMsg.PadRight(62))│" -ForegroundColor $edgeStatusColor
    
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor $edgeStatusColor
    Write-Host ""
}

# Firefox Summary
if ($results.Firefox.Installed) {
    $firefoxStatusColor = if ($results.Firefox.Updated) { 'Green' } elseif ($results.Firefox.Status -like '*Failed*') { 'Red' } else { 'Yellow' }
    
    Write-Host "┌─────────────────────────────────────────────────────────────┐" -ForegroundColor $firefoxStatusColor
    Write-Host "│  MOZILLA FIREFOX                                            │" -ForegroundColor $firefoxStatusColor
    Write-Host "├─────────────────────────────────────────────────────────────┤" -ForegroundColor $firefoxStatusColor
    
    $beforeStr = "│  Previous Version:  $($results.Firefox.VersionBefore)"
    Write-Host "$($beforeStr.PadRight(62))│" -ForegroundColor $firefoxStatusColor
    
    $afterStr = "│  Current Version:   $($results.Firefox.VersionAfter)"
    Write-Host "$($afterStr.PadRight(62))│" -ForegroundColor $firefoxStatusColor
    
    # Compare versions
    if ($results.Firefox.VersionBefore -eq $results.Firefox.VersionAfter) {
        $statusMsg = "│  Status:            Already up-to-date (no change)"
    }
    elseif ($results.Firefox.Updated) {
        $statusMsg = "│  Status:            ✓ UPGRADED SUCCESSFULLY"
    }
    else {
        $statusMsg = "│  Status:            $($results.Firefox.Status)"
    }
    Write-Host "$($statusMsg.PadRight(62))│" -ForegroundColor $firefoxStatusColor
    
    Write-Host "└─────────────────────────────────────────────────────────────┘" -ForegroundColor $firefoxStatusColor
    Write-Host ""
}

# Overall Status
$overallSuccess = $true
if ($results.Chrome.Installed -and $results.Chrome.Status -like '*Failed*') { $overallSuccess = $false }
if ($results.Edge.Installed -and $results.Edge.Status -like '*Failed*') { $overallSuccess = $false }
if ($results.Firefox.Installed -and $results.Firefox.Status -like '*Failed*') { $overallSuccess = $false }

if ($overallSuccess) {
    Write-Host "Overall Status: " -NoNewline
    Write-Host "SUCCESS" -ForegroundColor Green
}
else {
    Write-Host "Overall Status: " -NoNewline
    Write-Host "COMPLETED WITH ERRORS" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Script completed at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Gray
Write-Host ""
