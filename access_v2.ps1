<#
.SYNOPSIS
    SSH Pre-check Script for RHEL VMs using PuTTY's plink.
.DESCRIPTION
    Connects to servers, auto-accepts host fingerprints, runs precheck script, and outputs results.
.NOTES
    Output files are one-value-per-line for direct Excel column paste.
#>

# ============================================================================
# CONFIGURATION
# ============================================================================
$plinkPath       = "C:\Program Files\PuTTY\plink.exe"
$serverListFile  = ".\server_list.txt"
$username        = "your_username"
$password        = "your_password"
$remoteScript    = "/etc/precheck.sh"
$delayInSeconds  = 2
$varDiskThreshold = 90
$timeoutSeconds  = 10

# Keywords indicating issues in precheck output
$issueKeywords = @(
    "error", "warning", "failed", "critical", "unhealthy", "permission denied",
    "no space left", "read-only", "i/o error", "corruption",
    "password expired", "account locked", "has been locked",
    "unknown device", "inactive", "down", "offline"
)

# Output files (one value per line - paste directly into Excel columns)
$accessFile   = ".\Access_list.txt"
$precheckFile = ".\Precheck_list.txt"
$logFile      = ".\precheck_results.log"

# ============================================================================
# FUNCTIONS
# ============================================================================

function Invoke-PlinkCommand {
    <#
    .SYNOPSIS
        Execute SSH command with timeout and auto-accept host fingerprint.
    #>
    param(
        [string]$Server,
        [string]$Command
    )
    
    # Build plink arguments
    # -ssh: SSH protocol
    # -hostkey *: Auto-accept ANY new host fingerprint (handles first-time connections)
    # -pw: Password authentication
    # -batch: Non-interactive mode (won't hang waiting for input)
    $plinkArgs = "-ssh -hostkey * -batch -pw `"$password`" `"$username@$Server`" `"$Command`""
    
    $result = @{
        Output  = ""
        Success = $false
        TimedOut = $false
    }
    
    try {
        # Use Process class for timeout control
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $plinkPath
        $psi.Arguments = $plinkArgs
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        
        $process = [System.Diagnostics.Process]::Start($psi)
        
        # Read output asynchronously to prevent deadlock with large outputs
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        
        $completed = $process.WaitForExit($timeoutSeconds * 1000)
        
        if (-not $completed) {
            $process.Kill()
            $result.TimedOut = $true
            $result.Output = "Connection timed out after $timeoutSeconds seconds"
            return $result
        }
        
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $result.Output = ($stdout + "`n" + $stderr).Trim()
        $result.Success = ($process.ExitCode -eq 0)
        
    } catch {
        $result.Output = "Exception: $($_.Exception.Message)"
    }
    
    return $result
}

function Test-ConnectionFailed {
    param([string]$Output)
    
    $errorPatterns = @(
        "Access denied", "Authentication failed", "Host does not exist",
        "Connection refused", "Network error", "Connection timed out",
        "Connection reset", "No route to host", "FATAL ERROR", "Unable to open connection"
    )
    
    foreach ($pattern in $errorPatterns) {
        if ($Output -match [regex]::Escape($pattern)) {
            return $true
        }
    }
    return $false
}

function Test-SudoOrScriptFailed {
    param([string]$Output)
    
    $patterns = @(
        "sudo: a password is required",
        "sudo: incorrect password",
        "command not found",
        "No such file or directory",
        "Permission denied"
    )
    
    foreach ($pattern in $patterns) {
        if ($Output -match [regex]::Escape($pattern)) {
            return $true
        }
    }
    return $false
}

function Find-IssueKeywords {
    param([string]$Output)
    
    foreach ($keyword in $issueKeywords) {
        if ($Output -match "\b$([regex]::Escape($keyword))\b") {
            return $true
        }
    }
    return $false
}

function Get-VarDiskUsage {
    param([string]$Output)
    
    # Look for /var line and extract percentage
    $lines = $Output -split "`n" | Where-Object { $_ -match "/var" }
    foreach ($line in $lines) {
        if ($line -match "(\d+)%") {
            return [int]$Matches[1]
        }
    }
    return -1
}

# ============================================================================
# MAIN SCRIPT
# ============================================================================

Write-Host ""
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "  SSH Pre-check Script for RHEL VMs" -ForegroundColor Cyan
Write-Host "===============================================================================" -ForegroundColor Cyan

# --- Prerequisites Check ---
if (-not (Test-Path $plinkPath)) {
    Write-Host "ERROR: plink.exe not found at '$plinkPath'" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $serverListFile)) {
    Write-Host "ERROR: Server list not found at '$serverListFile'" -ForegroundColor Red
    exit 1
}

# Load servers (skip empty lines and comments)
$servers = Get-Content -Path $serverListFile | Where-Object { 
    -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch "^\s*#" 
}

if ($servers.Count -eq 0) {
    Write-Host "ERROR: Server list is empty." -ForegroundColor Yellow
    exit 1
}

Write-Host "Loaded $($servers.Count) server(s) from list." -ForegroundColor Green
Write-Host ""

# --- Initialize Output Files ---
@($accessFile, $precheckFile, $logFile) | ForEach-Object {
    if (Test-Path $_) { Remove-Item $_ -Force }
}

Add-Content -Path $logFile -Value "Pre-check started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Content -Path $logFile -Value ("=" * 80)

# --- Build Remote Command ---
# Run precheck script with sudo, then check /var disk usage
# Escape single quotes in password for safe shell embedding
$escapedPassword = $password -replace "'", "'\"'\"'"
$remoteCommand = "echo '$escapedPassword' | sudo -S -p '' bash -c '$remoteScript 2>&1; echo ___VAR_SEPARATOR___; df -h /var 2>&1'"

# --- Process Each Server ---
$totalServers = $servers.Count
$currentIndex = 0

foreach ($server in $servers) {
    $currentIndex++
    $remaining = $totalServers - $currentIndex
    
    Write-Host "[$currentIndex/$totalServers] $server ($remaining remaining)" -ForegroundColor White
    
    # Execute command
    $result = Invoke-PlinkCommand -Server $server -Command $remoteCommand
    
    # Clean output (remove sudo password prompt echo)
    $cleanedOutput = $result.Output -replace "\[sudo\] password for ${username}:", ""
    
    # Log full output
    Add-Content -Path $logFile -Value "`nSERVER: $server"
    Add-Content -Path $logFile -Value ("-" * 40)
    Add-Content -Path $logFile -Value $cleanedOutput
    Add-Content -Path $logFile -Value ("=" * 80)
    
    # --- Determine Access Status ---
    if ($result.TimedOut -or (Test-ConnectionFailed -Output $result.Output)) {
        $accessStatus = "No"
        $precheckStatus = "Not Done"
    }
    else {
        $accessStatus = "Yes"
        
        # --- Determine Precheck Status ---
        if (Test-SudoOrScriptFailed -Output $cleanedOutput) {
            $precheckStatus = "Not Done"
        }
        else {
            # Split output: precheck results vs /var disk check
            $parts = $cleanedOutput -split "___VAR_SEPARATOR___", 2
            $precheckOutput = $parts[0]
            $varOutput = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            
            # Check for issue keywords
            $hasIssueKeyword = Find-IssueKeywords -Output $precheckOutput
            
            # Check /var disk usage
            $varUsage = Get-VarDiskUsage -Output $varOutput
            $varDiskIssue = ($varUsage -ge $varDiskThreshold)
            
            if ($hasIssueKeyword -or $varDiskIssue) {
                $precheckStatus = "Review Needed"
            }
            else {
                $precheckStatus = "Done"
            }
        }
    }
    
    # --- Write to Output Files (one per line for Excel paste) ---
    Add-Content -Path $accessFile -Value $accessStatus
    Add-Content -Path $precheckFile -Value $precheckStatus
    
    # Display result
    $statusColor = switch ($precheckStatus) {
        "Done"          { "Green" }
        "Review Needed" { "Yellow" }
        "Not Done"      { "Red" }
    }
    Write-Host "    Access: $accessStatus | Precheck: " -NoNewline
    Write-Host $precheckStatus -ForegroundColor $statusColor
    
    # Delay between servers (except last one)
    if ($accessStatus -eq "Yes" -and $currentIndex -lt $totalServers -and $delayInSeconds -gt 0) {
        Start-Sleep -Seconds $delayInSeconds
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "===============================================================================" -ForegroundColor Cyan

# Read results for counting
$accessResults = Get-Content $accessFile
$precheckResults = Get-Content $precheckFile

# Sanity check
if ($accessResults.Count -ne $totalServers -or $precheckResults.Count -ne $totalServers) {
    Write-Host "WARNING: Output row count mismatch!" -ForegroundColor Red
} else {
    Write-Host "Sanity check passed - $totalServers rows in each output file." -ForegroundColor Green
}

# Counts
$accessYes = ($accessResults | Where-Object { $_ -eq "Yes" }).Count
$accessNo  = ($accessResults | Where-Object { $_ -eq "No" }).Count
$done      = ($precheckResults | Where-Object { $_ -eq "Done" }).Count
$review    = ($precheckResults | Where-Object { $_ -eq "Review Needed" }).Count
$notDone   = ($precheckResults | Where-Object { $_ -eq "Not Done" }).Count

Write-Host ""
Write-Host "  Total Servers:      $totalServers"
Write-Host "  Access OK:          $accessYes" -ForegroundColor Green
Write-Host "  Access Failed:      $accessNo" -ForegroundColor Red
Write-Host ""
Write-Host "  Precheck Done:      $done" -ForegroundColor Green
Write-Host "  Review Needed:      $review" -ForegroundColor Yellow
Write-Host "  Not Done:           $notDone" -ForegroundColor Red
Write-Host ""
Write-Host "  Output files (copy & paste directly into Excel columns):"
Write-Host "    $accessFile"
Write-Host "    $precheckFile"
Write-Host "    $logFile (detailed log)"
Write-Host ""
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "  Completed: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "===============================================================================" -ForegroundColor Cyan
