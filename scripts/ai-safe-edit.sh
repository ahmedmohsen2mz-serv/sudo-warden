#!/bin/bash
# ============================================================
# AI Safe File Editor - Production Server
# /usr/local/bin/ai-safe-edit
# ============================================================
# Purpose: Safely edit files with mandatory backup & audit trail
# Usage:   sudo ai-safe-edit <target-file> <new-content-file>
#          sudo ai-safe-edit --restore <backup-file> <target-file>
#          sudo ai-safe-edit --diff <target-file>
#          sudo ai-safe-edit --list-backups <target-file>
#          sudo ai-safe-edit --append <target-file> <content-file>
# ============================================================

set -euo pipefail

# --- Configuration ---
LOG_DIR="/var/log/ai-agent"
BACKUP_DIR="/var/backups/ai-agent"
LOG_FILE="${LOG_DIR}/actions.log"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
CALLER=$(who am i 2>/dev/null | awk '{print $1}' || echo "ai-agent")

# --- Functions ---
log_action() {
    local action="$1"
    local detail="$2"
    echo "[${TIMESTAMP}] [EDIT] [${CALLER}] ${action}: ${detail}" >> "$LOG_FILE"
    logger -t ai-agent -p local6.info "EDIT ${action}: ${detail}"
}

die() {
    echo "ERROR: $1" >&2
    log_action "ERROR" "$1"
    exit 1
}

create_backup() {
    local target="$1"
    local backup_path="${BACKUP_DIR}$(dirname "$target")"
    mkdir -p "$backup_path"
    local backup_file="${backup_path}/$(basename "$target").${TIMESTAMP}.bak"
    cp -a "$target" "$backup_file"
    echo "$backup_file"
}

show_usage() {
    echo "Usage:"
    echo "  ai-safe-edit <target-file> <new-content-file>   - Apply changes (creates backup first)"
    echo "  ai-safe-edit --restore <backup-file> <target>   - Restore from backup"
    echo "  ai-safe-edit --diff <target-file>               - Show diff with latest backup"
    echo "  ai-safe-edit --list-backups <target-file>        - List all backups for a file"
    echo "  ai-safe-edit --append <target-file> <content-file> - Append content (creates backup first)"
    exit 1
}

# --- Argument Parsing ---
[ $# -lt 1 ] && show_usage

case "$1" in
    --restore)
        [ $# -ne 3 ] && die "Usage: ai-safe-edit --restore <backup-file> <target-file>"
        BACKUP_SRC="$2"
        RESTORE_TARGET="$3"
        [ ! -f "$BACKUP_SRC" ] && die "Backup file not found: $BACKUP_SRC"
        # Backup current state before restore
        if [ -f "$RESTORE_TARGET" ]; then
            PRE_RESTORE_BACKUP=$(create_backup "$RESTORE_TARGET")
            echo "Pre-restore backup: $PRE_RESTORE_BACKUP"
        fi
        cp -a "$BACKUP_SRC" "$RESTORE_TARGET"
        log_action "RESTORE" "${RESTORE_TARGET} <- ${BACKUP_SRC}"
        echo "RESTORED: $RESTORE_TARGET from $BACKUP_SRC"
        ;;

    --diff)
        [ $# -ne 2 ] && die "Usage: ai-safe-edit --diff <target-file>"
        TARGET="$2"
        [ ! -f "$TARGET" ] && die "File not found: $TARGET"
        BASENAME=$(basename "$TARGET")
        BACKUP_PATH="${BACKUP_DIR}$(dirname "$TARGET")"
        LATEST_BACKUP=$(ls -t "${BACKUP_PATH}/${BASENAME}".*.bak 2>/dev/null | head -1)
        if [ -z "$LATEST_BACKUP" ]; then
            echo "No backups found for: $TARGET"
            exit 0
        fi
        echo "Comparing: $LATEST_BACKUP -> $TARGET"
        echo "============================================"
        diff --color=auto -u "$LATEST_BACKUP" "$TARGET" || true
        ;;

    --list-backups)
        [ $# -ne 2 ] && die "Usage: ai-safe-edit --list-backups <target-file>"
        TARGET="$2"
        BASENAME=$(basename "$TARGET")
        BACKUP_PATH="${BACKUP_DIR}$(dirname "$TARGET")"
        echo "Backups for: $TARGET"
        echo "Location: $BACKUP_PATH"
        echo "============================================"
        ls -lh "${BACKUP_PATH}/${BASENAME}".*.bak 2>/dev/null || echo "No backups found."
        ;;

    --append)
        [ $# -ne 3 ] && die "Usage: ai-safe-edit --append <target-file> <content-file>"
        TARGET="$2"
        CONTENT="$3"
        [ ! -f "$CONTENT" ] && die "Content file not found: $CONTENT"
        # Create backup if file exists
        if [ -f "$TARGET" ]; then
            BACKUP_FILE=$(create_backup "$TARGET")
            echo "Backup created: $BACKUP_FILE"
        fi
        cat "$CONTENT" >> "$TARGET"
        log_action "APPEND" "${TARGET} += ${CONTENT} ($(wc -l < "$CONTENT") lines)"
        echo "APPENDED to: $TARGET"
        ;;

    --*)
        die "Unknown option: $1"
        ;;

    *)
        # Standard edit: ai-safe-edit <target> <new-content>
        [ $# -ne 2 ] && show_usage
        TARGET="$1"
        NEW_CONTENT="$2"
        [ ! -f "$NEW_CONTENT" ] && die "New content file not found: $NEW_CONTENT"

        # If target exists, backup first (MANDATORY)
        if [ -f "$TARGET" ]; then
            BACKUP_FILE=$(create_backup "$TARGET")
            echo "Backup created: $BACKUP_FILE"
            log_action "BACKUP" "${TARGET} -> ${BACKUP_FILE}"
        else
            echo "New file will be created: $TARGET"
            mkdir -p "$(dirname "$TARGET")"
        fi

        # Apply changes
        cp "$NEW_CONTENT" "$TARGET"
        # Preserve original ownership if backup exists
        if [ -n "${BACKUP_FILE:-}" ]; then
            chown --reference="$BACKUP_FILE" "$TARGET" 2>/dev/null || true
            chmod --reference="$BACKUP_FILE" "$TARGET" 2>/dev/null || true
        fi

        log_action "APPLY" "${TARGET} <- ${NEW_CONTENT} ($(wc -c < "$TARGET") bytes)"

        # Show diff
        if [ -n "${BACKUP_FILE:-}" ]; then
            echo ""
            echo "--- Changes Applied ---"
            diff --color=auto -u "$BACKUP_FILE" "$TARGET" || true
        fi

        echo ""
        echo "SUCCESS: $TARGET updated"
        echo "Rollback: sudo ai-safe-edit --restore ${BACKUP_FILE:-N/A} $TARGET"
        ;;
esac

exit 0
