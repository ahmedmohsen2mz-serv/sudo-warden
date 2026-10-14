#!/bin/bash
# ============================================================
# AI Agent System - Production Deployment Script
# ============================================================
# Run as root: sudo bash deploy.sh
# This script sets up a secure, audited AI agent user on
# a production Linux server with read-only diagnostic access
# and controlled write capabilities.
# ============================================================

set -euo pipefail

# --- Color Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[  OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[FAIL]${NC} $1"; }

# --- Pre-flight Checks ---
echo "============================================================"
echo "  AI Agent System - Production Deployment"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================================"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_USER="ai-agent"
AI_HOME="/home/${AI_USER}"
LOG_DIR="/var/log/ai-agent"
BACKUP_DIR="/var/backups/ai-agent"

# --- Verify source files exist ---
log_info "Verifying source files..."
REQUIRED_FILES=(
    "sudoers/ai-agent"
    "scripts/ai-safe-edit.sh"
    "scripts/ai-safe-pkg.sh"
    "scripts/ai-safe-svc.sh"
    "logging/ai-agent-rsyslog.conf"
    "logging/ai-agent-logrotate.conf"
    "audit/ai-agent-audit.rules"
    "SKILL.md"
)

for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${SCRIPT_DIR}/${f}" ]; then
        log_error "Missing required file: ${f}"
        exit 1
    fi
done
log_ok "All source files present"

# ============================================================
# STEP 1: Create AI Agent User
# ============================================================
echo ""
log_info "=== Step 1: Creating AI Agent User ==="

if id "$AI_USER" &>/dev/null; then
    log_warn "User '$AI_USER' already exists - skipping creation"
else
    useradd \
        --system \
        --create-home \
        --home-dir "$AI_HOME" \
        --shell /bin/bash \
        --comment "AI Diagnostic Agent - Restricted Access" \
        "$AI_USER"
    log_ok "User '$AI_USER' created"
fi

# Lock password (no direct login with password)
passwd -l "$AI_USER" &>/dev/null || true
log_ok "Password locked (SSH key auth only)"

# Create working directories
mkdir -p "${AI_HOME}/scripts"
mkdir -p "${AI_HOME}/tmp"
mkdir -p "${AI_HOME}/reports"
chown -R "${AI_USER}:${AI_USER}" "$AI_HOME"
chmod 750 "$AI_HOME"
log_ok "Home directory structure created"

# ============================================================
# STEP 2: Create Log & Backup Directories
# ============================================================
echo ""
log_info "=== Step 2: Setting Up Logging Infrastructure ==="

mkdir -p "$LOG_DIR"
mkdir -p "${LOG_DIR}/sudo-io"
mkdir -p "$BACKUP_DIR"

chown root:root "$LOG_DIR"
chmod 750 "$LOG_DIR"
chown root:root "$BACKUP_DIR"
chmod 750 "$BACKUP_DIR"

# Create initial log files
touch "${LOG_DIR}/actions.log"
touch "${LOG_DIR}/sudo.log"
touch "${LOG_DIR}/svc-operations.log"
touch "${LOG_DIR}/pkg-operations.log"
chmod 640 "${LOG_DIR}"/*.log

log_ok "Log directories created: $LOG_DIR"
log_ok "Backup directory created: $BACKUP_DIR"

# ============================================================
# STEP 3: Install Sudoers Configuration
# ============================================================
echo ""
log_info "=== Step 3: Installing Sudoers Configuration ==="

# Validate sudoers file BEFORE installing
cp "${SCRIPT_DIR}/sudoers/ai-agent" /tmp/ai-agent-sudoers.tmp

if visudo -cf /tmp/ai-agent-sudoers.tmp; then
    cp /tmp/ai-agent-sudoers.tmp /etc/sudoers.d/ai-agent
    chmod 0440 /etc/sudoers.d/ai-agent
    chown root:root /etc/sudoers.d/ai-agent
    rm /tmp/ai-agent-sudoers.tmp
    log_ok "Sudoers config installed and validated"
else
    rm /tmp/ai-agent-sudoers.tmp
    log_error "Sudoers validation FAILED! File NOT installed."
    log_error "Fix the sudoers file and re-run deployment."
    exit 1
fi

# ============================================================
# STEP 4: Install Wrapper Scripts
# ============================================================
echo ""
log_info "=== Step 4: Installing Wrapper Scripts ==="

for script in ai-safe-edit ai-safe-pkg ai-safe-svc; do
    src="${SCRIPT_DIR}/scripts/${script}.sh"
    dst="/usr/local/bin/${script}"
    cp "$src" "$dst"
    chmod 0755 "$dst"
    chown root:root "$dst"
    log_ok "Installed: $dst"
done

# ============================================================
# STEP 5: Install Logging Configuration
# ============================================================
echo ""
log_info "=== Step 5: Configuring Logging ==="

# Rsyslog
if [ -d /etc/rsyslog.d ]; then
    cp "${SCRIPT_DIR}/logging/ai-agent-rsyslog.conf" /etc/rsyslog.d/50-ai-agent.conf
    chmod 644 /etc/rsyslog.d/50-ai-agent.conf
    log_ok "Rsyslog config installed"

    # Restart rsyslog
    if systemctl is-active rsyslog &>/dev/null; then
        systemctl restart rsyslog
        log_ok "Rsyslog restarted"
    fi
else
    log_warn "rsyslog.d not found - skipping rsyslog config"
fi

# Logrotate
if [ -d /etc/logrotate.d ]; then
    cp "${SCRIPT_DIR}/logging/ai-agent-logrotate.conf" /etc/logrotate.d/ai-agent
    chmod 644 /etc/logrotate.d/ai-agent
    log_ok "Logrotate config installed"
else
    log_warn "logrotate.d not found - skipping logrotate config"
fi

# ============================================================
# STEP 6: Install Audit Rules
# ============================================================
echo ""
log_info "=== Step 6: Configuring Audit Rules ==="

if command -v auditctl &>/dev/null; then
    # Get AI agent UID for audit rules
    AI_UID=$(id -u "$AI_USER")
    
    # Replace placeholder uid with actual UID
    sed "s/uid=ai-agent/uid=${AI_UID}/g" \
        "${SCRIPT_DIR}/audit/ai-agent-audit.rules" \
        > /etc/audit/rules.d/99-ai-agent.rules
    
    chmod 640 /etc/audit/rules.d/99-ai-agent.rules
    
    # Load rules
    augenrules --load 2>/dev/null || auditctl -R /etc/audit/rules.d/99-ai-agent.rules 2>/dev/null || true
    log_ok "Audit rules installed (UID: $AI_UID)"
else
    log_warn "auditd not installed - skipping audit rules"
    log_warn "RECOMMENDED: apt install auditd audispd-plugins"
fi

# ============================================================
# STEP 7: Install SKILL.md
# ============================================================
echo ""
log_info "=== Step 7: Installing SKILL.md ==="

cp "${SCRIPT_DIR}/SKILL.md" "${AI_HOME}/SKILL.md"
chown "${AI_USER}:${AI_USER}" "${AI_HOME}/SKILL.md"
chmod 444 "${AI_HOME}/SKILL.md"
log_ok "SKILL.md installed to ${AI_HOME}/SKILL.md (read-only)"

# ============================================================
# STEP 8: SSH Configuration (optional)
# ============================================================
echo ""
log_info "=== Step 8: SSH Key Setup ==="

SSH_DIR="${AI_HOME}/.ssh"
if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    touch "${SSH_DIR}/authorized_keys"
    chmod 600 "${SSH_DIR}/authorized_keys"
    chown -R "${AI_USER}:${AI_USER}" "$SSH_DIR"
    log_ok "SSH directory created"
    log_warn "Add the AI model's SSH public key to: ${SSH_DIR}/authorized_keys"
else
    log_ok "SSH directory already exists"
fi

# ============================================================
# STEP 9: Verification
# ============================================================
echo ""
log_info "=== Step 9: Running Verification Checks ==="

CHECKS_PASSED=0
CHECKS_FAILED=0

# Check user exists
if id "$AI_USER" &>/dev/null; then
    log_ok "User '$AI_USER' exists"
    ((CHECKS_PASSED++))
else
    log_error "User '$AI_USER' not found"
    ((CHECKS_FAILED++))
fi

# Check sudoers
if visudo -cf /etc/sudoers.d/ai-agent &>/dev/null; then
    log_ok "Sudoers config valid"
    ((CHECKS_PASSED++))
else
    log_error "Sudoers config INVALID"
    ((CHECKS_FAILED++))
fi

# Check wrapper scripts
for script in ai-safe-edit ai-safe-pkg ai-safe-svc; do
    if [ -x "/usr/local/bin/${script}" ]; then
        log_ok "Script executable: /usr/local/bin/${script}"
        ((CHECKS_PASSED++))
    else
        log_error "Script missing or not executable: /usr/local/bin/${script}"
        ((CHECKS_FAILED++))
    fi
done

# Check log directory
if [ -d "$LOG_DIR" ]; then
    log_ok "Log directory exists: $LOG_DIR"
    ((CHECKS_PASSED++))
else
    log_error "Log directory missing: $LOG_DIR"
    ((CHECKS_FAILED++))
fi

# Check backup directory
if [ -d "$BACKUP_DIR" ]; then
    log_ok "Backup directory exists: $BACKUP_DIR"
    ((CHECKS_PASSED++))
else
    log_error "Backup directory missing: $BACKUP_DIR"
    ((CHECKS_FAILED++))
fi

# Test sudo as ai-agent (basic command)
if su -s /bin/bash -c "sudo uptime" "$AI_USER" &>/dev/null; then
    log_ok "Sudo test passed (ai-agent can run 'uptime')"
    ((CHECKS_PASSED++))
else
    log_warn "Sudo test inconclusive (may need interactive test)"
fi

# Check SKILL.md
if [ -f "${AI_HOME}/SKILL.md" ] && [ "$(stat -c '%a' "${AI_HOME}/SKILL.md")" = "444" ]; then
    log_ok "SKILL.md installed (read-only)"
    ((CHECKS_PASSED++))
else
    log_error "SKILL.md not properly installed"
    ((CHECKS_FAILED++))
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================================"
echo "  DEPLOYMENT SUMMARY"
echo "============================================================"
echo ""
echo "  User:        ${AI_USER} (UID: $(id -u "$AI_USER" 2>/dev/null || echo 'N/A'))"
echo "  Home:        ${AI_HOME}"
echo "  Logs:        ${LOG_DIR}"
echo "  Backups:     ${BACKUP_DIR}"
echo "  Sudoers:     /etc/sudoers.d/ai-agent"
echo "  SKILL:       ${AI_HOME}/SKILL.md"
echo ""
echo "  Wrappers:"
echo "    /usr/local/bin/ai-safe-edit   (file editing with backup)"
echo "    /usr/local/bin/ai-safe-pkg    (package management)"
echo "    /usr/local/bin/ai-safe-svc    (service control)"
echo ""
echo -e "  Checks: ${GREEN}${CHECKS_PASSED} passed${NC}, ${RED}${CHECKS_FAILED} failed${NC}"
echo ""

if [ $CHECKS_FAILED -gt 0 ]; then
    log_error "Some checks failed. Review the output above."
    exit 1
fi

echo "============================================================"
echo -e "  ${GREEN}DEPLOYMENT COMPLETE${NC}"
echo "============================================================"
echo ""
echo "  Next Steps:"
echo "  1. Add SSH key:    echo '<public-key>' >> ${SSH_DIR}/authorized_keys"
echo "  2. Test access:    su - ${AI_USER} -c 'sudo uptime'"
echo "  3. View logs:      tail -f ${LOG_DIR}/actions.log"
echo "  4. View sudo I/O:  ls ${LOG_DIR}/sudo-io/"
echo "  5. Search audits:  ausearch -k ai-agent-exec"
echo ""
echo "  Review Logs Cheatsheet:"
echo "    All actions:      cat ${LOG_DIR}/actions.log"
echo "    Package ops:      cat ${LOG_DIR}/pkg-operations.log"
echo "    Service ops:      cat ${LOG_DIR}/svc-operations.log"
echo "    Sudo commands:    cat ${LOG_DIR}/sudo.log"
echo "    Syslog:           cat ${LOG_DIR}/syslog.log"
echo "    Audit trail:      ausearch -k ai-agent-exec --format text"
echo "    File backups:     find ${BACKUP_DIR} -name '*.bak' -ls"
echo ""
