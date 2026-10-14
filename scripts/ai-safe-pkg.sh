#!/bin/bash
# ============================================================
# AI Safe Package Manager - Production Server
# /usr/local/bin/ai-safe-pkg
# ============================================================
# Purpose: Safe package operations with full audit trail
# Usage:   sudo ai-safe-pkg install <package> [package2 ...]
#          sudo ai-safe-pkg update
#          sudo ai-safe-pkg search <package>
#          sudo ai-safe-pkg info <package>
# ============================================================

set -euo pipefail

# --- Configuration ---
LOG_DIR="/var/log/ai-agent"
LOG_FILE="${LOG_DIR}/actions.log"
PKG_LOG="${LOG_DIR}/pkg-operations.log"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# --- Functions ---
log_action() {
    local msg="[${TIMESTAMP}] [PKG] $1"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg" >> "$PKG_LOG"
    logger -t ai-agent -p local6.info "PKG: $1"
}

die() {
    echo "ERROR: $1" >&2
    log_action "ERROR: $1"
    exit 1
}

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        echo "apt-get"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v yum &>/dev/null; then
        echo "yum"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        die "No supported package manager found"
    fi
}

show_usage() {
    echo "Usage:"
    echo "  ai-safe-pkg install <package> [packages...]  - Install packages"
    echo "  ai-safe-pkg update                           - Update package index"
    echo "  ai-safe-pkg upgrade                          - Upgrade installed packages"
    echo "  ai-safe-pkg search <pattern>                 - Search for packages"
    echo "  ai-safe-pkg info <package>                   - Show package info"
    echo "  ai-safe-pkg history                          - Show AI package operation history"
    exit 1
}

# --- Argument Parsing ---
[ $# -lt 1 ] && show_usage

ACTION="$1"
shift
PACKAGES="${*:-}"
PKG_MGR=$(detect_pkg_manager)

case "$ACTION" in
    install)
        [ -z "$PACKAGES" ] && die "No packages specified"
        log_action "INSTALL START: ${PKG_MGR} install ${PACKAGES}"
        echo "[AI-AGENT] Installing: $PACKAGES"
        echo "[AI-AGENT] Package Manager: $PKG_MGR"
        echo "[AI-AGENT] Timestamp: $TIMESTAMP"
        echo "============================================"

        # Snapshot installed packages before
        if [ "$PKG_MGR" = "apt-get" ]; then
            dpkg -l > "${LOG_DIR}/pkg-snapshot-before-${TIMESTAMP}.txt" 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive $PKG_MGR install -y $PACKAGES 2>&1 | tee -a "$PKG_LOG"
        elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
            rpm -qa > "${LOG_DIR}/pkg-snapshot-before-${TIMESTAMP}.txt" 2>/dev/null || true
            $PKG_MGR install -y $PACKAGES 2>&1 | tee -a "$PKG_LOG"
        fi

        EXIT_CODE=${PIPESTATUS[0]}
        log_action "INSTALL COMPLETE: ${PACKAGES} | exit: ${EXIT_CODE}"
        echo "============================================"
        [ $EXIT_CODE -eq 0 ] && echo "SUCCESS" || echo "FAILED (exit: $EXIT_CODE)"
        exit $EXIT_CODE
        ;;

    update)
        log_action "UPDATE START: ${PKG_MGR} update"
        echo "[AI-AGENT] Updating package index..."

        if [ "$PKG_MGR" = "apt-get" ]; then
            $PKG_MGR update 2>&1 | tee -a "$PKG_LOG"
        elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
            $PKG_MGR check-update 2>&1 | tee -a "$PKG_LOG" || true
        fi

        log_action "UPDATE COMPLETE"
        echo "Package index updated."
        ;;

    upgrade)
        log_action "UPGRADE START: ${PKG_MGR} upgrade"
        echo "[AI-AGENT] Upgrading packages..."
        echo "WARNING: This will upgrade all installed packages."

        # Take snapshot
        if [ "$PKG_MGR" = "apt-get" ]; then
            dpkg -l > "${LOG_DIR}/pkg-snapshot-before-upgrade-${TIMESTAMP}.txt" 2>/dev/null || true
            DEBIAN_FRONTEND=noninteractive $PKG_MGR upgrade -y 2>&1 | tee -a "$PKG_LOG"
        elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
            rpm -qa > "${LOG_DIR}/pkg-snapshot-before-upgrade-${TIMESTAMP}.txt" 2>/dev/null || true
            $PKG_MGR upgrade -y 2>&1 | tee -a "$PKG_LOG"
        fi

        EXIT_CODE=${PIPESTATUS[0]}
        log_action "UPGRADE COMPLETE: exit ${EXIT_CODE}"
        exit $EXIT_CODE
        ;;

    search)
        [ -z "$PACKAGES" ] && die "No search pattern specified"
        if [ "$PKG_MGR" = "apt-get" ]; then
            apt-cache search $PACKAGES
        elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
            $PKG_MGR search $PACKAGES
        fi
        ;;

    info)
        [ -z "$PACKAGES" ] && die "No package specified"
        if [ "$PKG_MGR" = "apt-get" ]; then
            apt-cache show $PACKAGES
        elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
            $PKG_MGR info $PACKAGES
        fi
        ;;

    history)
        echo "=== AI Package Operation History ==="
        grep '\[PKG\]' "$LOG_FILE" 2>/dev/null || echo "No package operations recorded."
        ;;

    *)
        die "Unknown action: $ACTION"
        ;;
esac

exit 0
