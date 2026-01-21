# --- Configuration ---
# Ensure plink.exe is at this path or update the path accordingly.
$plinkPath = "C:\Program Files\PuTTY\plink.exe"
$serverListFile = ".\server_list.txt"
$username = "your_username"
$password = "your_password"
# $sshKeyPath = "C:\path\to\your\private_key.ppk"
$remoteScript = "/etc/precheck.sh"
$delayInSeconds = 2
$varDiskThreshold = 90

$issueKeywords = @(
    "error", "warning", "failed", "critical", "unhealthy", "permission denied",
    "no space left", "read-only", "i/o error", "corruption",
    "password expired", "account locked", "has been locked",
    "unknown device", "inactive", "down", "offline"
)

# --- Static Output Filenames ---
$accessFile = ".\Access_list.txt"
$precheckFile = ".\Precheck_list.txt"
$logFile = ".\precheck_results.log"

# --- Main Script ---
if (-not (Test-Path $plinkPath)) { Write-Host "Error: plink.exe not found at '$plinkPath'" -ForegroundColor Red; exit }
if (-not (Test-Path $serverListFile)) { Write-Host "Error: Server list file not found at '$serverListFile'" -ForegroundColor Red; exit }
$servers = Get-Content -Path $serverListFile
if ($servers.Count -eq 0) { Write-Host "Warning: The server list file is empty." -ForegroundColor Yellow; exit }

$keywordPatterns = $issueKeywords | ForEach-Object { "\b$([regex]::Escape($_))\b" }
$regexPattern = $keywordPatterns -join '|'

if (Test-Path $accessFile) { Remove-Item $accessFile }
if (Test-Path $precheckFile) { Remove-Item $precheckFile }
if (Test-Path $logFile) { Remove-Item $logFile }

# --- ✅ PHASE 1: FINGERPRINT ACCEPTANCE PASS ---
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "Phase 1: Caching SSH Host Key Fingerprints..." -ForegroundColor Cyan
Write-Host "==============================================================================="
foreach ($server in $servers) {
    Write-Host "Connecting to $server to cache key..."
    $plinkArgs = @("-ssh", "$username@$server")
    if ($sshKeyPath) { $plinkArgs += @("-i", $sshKeyPath) } else { $plinkArgs += @("-pw", $password) }
    
    # ✅ CHANGED: 'exit' command logs in and immediately closes the session. 
    # This is the fastest way to trigger the fingerprint prompt and then leave.
    $plinkArgs += "exit" 
    
    # Pipe "y" to handle the fingerprint dialog. We discard the output.
    (echo "y" | & $plinkPath $plinkArgs 2>&1) | Out-Null
}
Write-Host "Fingerprint caching complete." -ForegroundColor Green

# --- ✅ PHASE 2: INTELLIGENT PRE-CHECK PASS ---
Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "Phase 2: Starting Intelligent Pre-check..." -ForegroundColor Cyan
Write-Host "==============================================================================="
$totalServers = $servers.Count
$i = 0

Add-Content -Path $logFile -Value "Pre-check process started at: $(Get-Date)"
Add-Content -Path $logFile -Value "==============================================================================="

foreach ($server in $servers) {
    $i++
    $left = $totalServers - $i
    Write-Host "($i/$totalServers) Processing server: $server ($left remaining)"

    # Now we use -batch, which prevents hanging. It will fail if a key is not cached from Phase 1.
    $plinkArgs = @("-batch", "-ssh", "$username@$server")
    if ($sshKeyPath) { $plinkArgs += @("-i", $sshKeyPath) } else { $plinkArgs += @("-pw", $password) }
    
    $fullCheckCommand = "$remoteScript; echo ---VAR_CHECK_SEPARATOR---; df -h /var"
    $remoteCommand = "printf '%s\n' '$password' | sudo -S -p '' bash -c '$fullCheckCommand'"
    $plinkArgs += $remoteCommand

    # Use Out-String to reliably capture all output
    $output = (& $plinkPath $plinkArgs 2>&1) | Out-String

    Add-Content -Path $logFile -Value "SERVER: $server"
    Add-Content -Path $logFile -Value "-------------------------------------------------------------------------------"
    $cleanedOutput = $output -replace "\[sudo\] password for $username`:", ""
    Add-Content -Path $logFile -Value $cleanedOutput
    Add-Content -Path $logFile -Value "==============================================================================="
    
    $connectionFailed = $output -match "Access denied|Authentication failed|Host does not exist|Connection refused|fatal error|Network error|Connection timed out|timed out|Connection reset|No route to host"
    
    if ($connectionFailed) {
        $accessStatus = "No"
        $precheckStatus = "Not Done"
        $accessSucceeded = $false
    } else {
        $accessStatus = "Yes"
        $accessSucceeded = $true
        
        if ($output -match "sudo: a password is required|sudo: incorrect password attempts|command not found|No such file or directory") {
            $precheckStatus = "Not Done"
        } else {
            $mainOutput, $varOutput = $cleanedOutput -split '---VAR_CHECK_SEPARATOR---', 2
            
            $genericIssueFound = $mainOutput -match $regexPattern
            $varDiskIssue = $false
            if ($varOutput) {
                $varLine = ($varOutput -split '(\r\n|\n|\r)') | Where-Object { $_ -match '/var$' }
                if ($varLine) {
                    $match = [System.Text.RegularExpressions.Regex]::Match($varLine, '(\d+)\s?%')
                    if ($match.Success -and ([int]$match.Groups[1].Value -ge $varDiskThreshold)) {
                        $varDiskIssue = $true
                    }
                }
            }
            
            if ($genericIssueFound -or $varDiskIssue) {
                $precheckStatus = "Review Needed"
            } else {
                $precheckStatus = "Done"
            }
        }
    }

    Add-Content -Path $accessFile -Value $accessStatus
    Add-Content -Path $precheckFile -Value $precheckStatus
    Write-Host "  -> Access: $accessStatus, Precheck: $precheckStatus"

    if ($delayInSeconds -gt 0 -and $accessSucceeded) {
        Write-Host "Pausing for $delayInSeconds seconds..."
        Start-Sleep -Seconds $delayInSeconds
    }
}

# --- Final Sanity Check and Summary ---
Write-Host "Performing final sanity check on output files..."
$accessCount = (Get-Content $accessFile).Count; $precheckCount = (Get-Content $precheckFile).Count
if ($accessCount -ne $servers.Count -or $precheckCount -ne $servers.Count) { Write-Warning "Output row count mismatch."; } else { Write-Host "Sanity check passed." -ForegroundColor Green; }

Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "Pre-check Run Summary:" -ForegroundColor Cyan
$precheckResults = Get-Content $precheckFile
$doneCount = ($precheckResults | Where-Object { $_ -eq "Done" }).Count; $reviewCount = ($precheckResults | Where-Object { $_ -eq "Review Needed" }).Count; $notDoneCount = ($precheckResults | Where-Object { $_ -eq "Not Done" }).Count
Write-Host "  Servers Done (OK): $doneCount" -ForegroundColor Green; Write-Host "  Servers to Review: $reviewCount" -ForegroundColor Red; Write-Host "  Servers Not Done (Failed): $notDoneCount" -ForegroundColor Yellow

Write-Host "===============================================================================" -ForegroundColor Cyan
Write-Host "Process complete."
Write-Host "Output files for Excel created: $accessFile, $precheckFile"
Write-Host "Detailed audit log is available at: $logFile"
Write-Host "===============================================================================" -ForegroundColor Cyan