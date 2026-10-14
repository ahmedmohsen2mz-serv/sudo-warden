#!/bin/bash
# ============================================================
# AI Agent System - Uninstall Script
# ============================================================
# Run as root: sudo bash uninstall.sh
# This removes all AI agent components from the server.
# Log files and backups are PRESERVED for audit purposes.
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "[INFO] $1"; }
log_ok()    { echo -e "${GREEN}[  OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Must run as root"
    exit 1
fi

echo "============================================================"
echo "  AI Agent System - Uninstall"
echo "============================================================"
echo ""
echo -e "${YELLOW}WARNING: This will remove the AI agent system.${NC}"
echo "Log files and backups will be PRESERVED."
echo ""
read -p "Are you sure? (type 'yes' to confirm): " CONFIRM
[ "$CONFIRM" != "yes" ] && echo "Aborted." && exit 0

# Remove sudoers
if [ -f /etc/sudoers.d/ai-agent ]; then
    rm /etc/sudoers.d/ai-agent
    log_ok "Removed sudoers config"
fi

# Remove wrapper scripts
for script in ai-safe-edit ai-safe-pkg ai-safe-svc; do
    if [ -f "/usr/local/bin/${script}" ]; then
        rm "/usr/local/bin/${script}"
        log_ok "Removed /usr/local/bin/${script}"
    fi
done

# Remove rsyslog config
if [ -f /etc/rsyslog.d/50-ai-agent.conf ]; then
    rm /etc/rsyslog.d/50-ai-agent.conf
    systemctl restart rsyslog 2>/dev/null || true
    log_ok "Removed rsyslog config"
fi

# Remove logrotate config
if [ -f /etc/logrotate.d/ai-agent ]; then
    rm /etc/logrotate.d/ai-agent
    log_ok "Removed logrotate config"
fi

# Remove audit rules
if [ -f /etc/audit/rules.d/99-ai-agent.rules ]; then
    rm /etc/audit/rules.d/99-ai-agent.rules
    augenrules --load 2>/dev/null || true
    log_ok "Removed audit rules"
fi

# Optionally remove user
echo ""
read -p "Remove ai-agent user? (type 'yes' to confirm): " CONFIRM_USER
if [ "$CONFIRM_USER" = "yes" ]; then
    userdel -r ai-agent 2>/dev/null || true
    log_ok "Removed ai-agent user and home directory"
else
    log_warn "User ai-agent preserved"
fi

echo ""
echo "============================================================"
echo "  PRESERVED (for audit trail):"
echo "    Logs:    /var/log/ai-agent/"
echo "    Backups: /var/backups/ai-agent/"
echo "============================================================"
echo ""
echo "To remove logs and backups:"
echo "  sudo rm -rf /var/log/ai-agent /var/backups/ai-agent"
echo ""
log_ok "Uninstall complete"
