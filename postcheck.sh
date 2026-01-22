#!/bin/bash
#===============================================================================
# Post-Check Script for Auditing Screenshots
# Usage: ./postcheck.sh [-artifactory] [-workato] [-sshd]
#===============================================================================

# Parse flags
CHECK_ARTIFACTORY=false
CHECK_WORKATO=false
CHECK_SSHD=false

for arg in "$@"; do
    case $arg in
        -artifactory) CHECK_ARTIFACTORY=true ;;
        -workato)     CHECK_WORKATO=true ;;
        -sshd)        CHECK_SSHD=true ;;
    esac
done

# Function to show command and execute it
run() {
    echo "\$ $*"
    eval "$*"
    echo ""
}

# Basic system info (always shown)
run hostname
run uname -r
run date
run uptime
run df -h

# Optional service checks
if $CHECK_SSHD; then
    run systemctl status sshd.service --no-pager
fi

if $CHECK_ARTIFACTORY; then
    run "systemctl status artifactory --no-pager 2>/dev/null || ps aux | grep -i [a]rtifactory"
fi

if $CHECK_WORKATO; then
    run "systemctl status workato --no-pager 2>/dev/null || ps aux | grep -i [w]orkato"
fi
