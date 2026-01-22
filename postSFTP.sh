#!/bin/bash
#===============================================================================
# Post-SFTP Patch Script
# Usage: ./postSFTP.sh -pre   (before reboot)
#        ./postSFTP.sh -post  (after manual reboot)
#===============================================================================

TODAY=$(date +%d%b%y | tr '[:lower:]' '[:upper:]')
BACKUP_DIR="/home/ec2-user"
IPT_BACKUP="ipt_${TODAY}"

# Function to show command and execute it
run() {
    echo "\$ $*"
    eval "$*"
    echo ""
}

case "$1" in
    -pre)
        cd "$BACKUP_DIR"
        run iptables -t nat -L
        run iptables-save \> "${IPT_BACKUP}"
        run ls -la ipt_*
        run cat "${IPT_BACKUP}"
        # If releasever prompt appears, use: run dnf update -y --releasever=latest
        run dnf update -y
        ;;
    -post)
        cd "$BACKUP_DIR"
        echo "=== Saved iptables (before reboot) ==="
        run cat "${IPT_BACKUP}"
        echo "=== Current iptables (after reboot) ==="
        run iptables -t nat -L
        
        # Compare before/after iptables
        echo "=== Comparing iptables (before vs after) ==="
        iptables-save > "/tmp/ipt_current_$$"
        if diff -q "${IPT_BACKUP}" "/tmp/ipt_current_$$" > /dev/null 2>&1; then
            echo "✓ iptables MATCH - rules are identical"
        else
            echo "✗ iptables DIFFER - review changes below:"
            diff "${IPT_BACKUP}" "/tmp/ipt_current_$$"
        fi
        rm -f "/tmp/ipt_current_$$"
        echo ""
        
        run systemctl status sshd.service --no-pager
        run uname -r
        run date
        run df -h
        run uptime
        ;;
    *)
        echo "Usage: $0 -pre | -post"
        ;;
esac
