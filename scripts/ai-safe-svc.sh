#!/bin/bash
# ============================================================
# AI Safe Service Controller - Production Server
# /usr/local/bin/ai-safe-svc
# ============================================================
# Purpose: Safe service management with pre/post checks & audit
# Usage:   sudo ai-safe-svc <action> <service-name>
# Actions: restart, reload, start, stop
# ============================================================

set -euo pipefail

# --- Configuration ---
LOG_DIR="/var/log/ai-agent"
LOG_FILE="${LOG_DIR}/actions.log"
SVC_LOG="${LOG_DIR}/svc-operations.log"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# --- Functions ---
log_action() {
    local msg="[${TIMESTAMP}] [SVC] $1"
    echo "$msg" >> "$LOG_FILE"
    echo "$msg" >> "$SVC_LOG"
    logger -t ai-agent -p local6.info "SVC: $1"
}

die() {
    echo "ERROR: $1" >&2
    log_action "ERROR: $1"
    exit 1
}

capture_service_state() {
    local svc="$1"
    local label="$2"
    echo "=== ${label} State: ${svc} ==="
    echo "Active: $(systemctl is-active "$svc" 2>&1 || true)"
    echo "Enabled: $(systemctl is-enabled "$svc" 2>&1 || true)"
    echo "MainPID: $(systemctl show -p MainPID --value "$svc" 2>/dev/null || echo N/A)"
    echo "Memory: $(systemctl show -p MemoryCurrent --value "$svc" 2>/dev/null || echo N/A)"
    echo "Uptime: $(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null || echo N/A)"
    echo "Last 5 log lines:"
    journalctl -u "$svc" -n 5 --no-pager 2>/dev/null || echo "  (no journal entries)"
    echo ""
}

show_usage() {
    echo "Usage: ai-safe-svc <action> <service-name>"
    echo "Actions:"
    echo "  restart  - Restart the service (captures before/after state)"
    echo "  reload   - Reload service config (graceful, no downtime)"
    echo "  start    - Start a stopped service"
    echo "  stop     - Stop a running service"
    echo "  status   - Show detailed service status"
    exit 1
}

# --- Argument Parsing ---
[ $# -lt 2 ] && show_usage

ACTION="$1"
SERVICE="$2"

# Validate action
case "$ACTION" in
    restart|reload|start|stop|status)
        ;;
    *)
        die "Invalid action: $ACTION. Allowed: restart, reload, start, stop, status"
        ;;
esac

# Validate service exists
if ! systemctl cat "$SERVICE" &>/dev/null; then
    die "Service not found: $SERVICE"
fi

echo "============================================"
echo "[AI-AGENT] Service Operation"
echo "Action:    $ACTION"
echo "Service:   $SERVICE"
echo "Timestamp: $TIMESTAMP"
echo "============================================"

# --- Capture BEFORE State ---
BEFORE_ACTIVE=$(systemctl is-active "$SERVICE" 2>&1 || true)
BEFORE_PID=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo "N/A")
echo ""
capture_service_state "$SERVICE" "BEFORE"

# --- Log ---
log_action "${ACTION} ${SERVICE} | before: active=${BEFORE_ACTIVE} pid=${BEFORE_PID}"

# --- Execute ---
if [ "$ACTION" = "status" ]; then
    systemctl status "$SERVICE" --no-pager 2>&1 || true
    exit 0
fi

echo ">>> Executing: systemctl $ACTION $SERVICE"
systemctl "$ACTION" "$SERVICE"
EXIT_CODE=$?

# --- Wait & Capture AFTER State ---
sleep 3

AFTER_ACTIVE=$(systemctl is-active "$SERVICE" 2>&1 || true)
AFTER_PID=$(systemctl show -p MainPID --value "$SERVICE" 2>/dev/null || echo "N/A")
echo ""
capture_service_state "$SERVICE" "AFTER"

# --- Log Result ---
log_action "${ACTION} ${SERVICE} COMPLETE | after: active=${AFTER_ACTIVE} pid=${AFTER_PID} | exit: ${EXIT_CODE}"

# --- Health Check ---
if [ "$ACTION" = "restart" ] || [ "$ACTION" = "start" ]; then
    if [ "$AFTER_ACTIVE" = "active" ]; then
        echo "HEALTH CHECK: Service is ACTIVE and RUNNING"
    else
        echo "WARNING: Service is NOT active after $ACTION!"
        echo "Status: $AFTER_ACTIVE"
        echo "Check logs: journalctl -u $SERVICE -n 50 --no-pager"
        log_action "WARNING: ${SERVICE} not active after ${ACTION}! Status: ${AFTER_ACTIVE}"
    fi
fi

echo "============================================"
echo "Operation complete. Exit code: $EXIT_CODE"
echo "Full log: $SVC_LOG"

exit $EXIT_CODE
