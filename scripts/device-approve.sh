#!/usr/bin/env bash
# =============================================================================
# device-approve.sh -- List and approve pending devices on the OpenClaw gateway
#
# Queries the OpenClaw container for pending device pairing requests
# and lets you approve them interactively from the host.
#
# Usage:
#   ./scripts/device-approve.sh          # Interactive: list + select
#   ./scripts/device-approve.sh --list   # List pending devices only
#   ./scripts/device-approve.sh <id>     # Approve a specific device by ID
# =============================================================================
set -euo pipefail

OPENCLAW_CONTAINER="${OPENCLAW_CONTAINER:-democlaw-openclaw}"

# ---------------------------------------------------------------------------
# Detect container runtime
# ---------------------------------------------------------------------------
RUNTIME=""
if [ -n "${CONTAINER_RUNTIME:-}" ] && command -v "${CONTAINER_RUNTIME}" >/dev/null 2>&1; then
    RUNTIME="${CONTAINER_RUNTIME}"
elif command -v docker >/dev/null 2>&1; then
    RUNTIME="docker"
elif command -v podman >/dev/null 2>&1; then
    RUNTIME="podman"
else
    echo "ERROR: No container runtime found (docker / podman)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify OpenClaw container is running
# ---------------------------------------------------------------------------
if ! "${RUNTIME}" container inspect "${OPENCLAW_CONTAINER}" >/dev/null 2>&1; then
    echo "ERROR: Container '${OPENCLAW_CONTAINER}' is not running." >&2
    echo "Start the stack first: ./scripts/start.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Fetch pending devices
# ---------------------------------------------------------------------------
list_pending() {
    "${RUNTIME}" exec "${OPENCLAW_CONTAINER}" openclaw devices list 2>/dev/null
}

# ---------------------------------------------------------------------------
# Approve a device by ID
# ---------------------------------------------------------------------------
approve_device() {
    local device_id="$1"
    "${RUNTIME}" exec "${OPENCLAW_CONTAINER}" openclaw devices approve "${device_id}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
    --list|-l)
        echo "Pending devices on ${OPENCLAW_CONTAINER}:"
        echo ""
        list_pending
        ;;
    --help|-h)
        echo "Usage: $0 [--list | --help | <device-id>]"
        echo ""
        echo "  (no args)     Interactive: list pending devices and select one to approve"
        echo "  --list, -l    List pending devices only"
        echo "  <device-id>   Approve a specific device by ID"
        echo "  --help, -h    Show this help"
        ;;
    "")
        # Interactive mode
        echo "Fetching pending devices from ${OPENCLAW_CONTAINER} ..."
        echo ""
        raw=$(list_pending)
        echo "${raw}"
        echo ""

        # Extract UUIDs
        mapfile -t ids < <(echo "${raw}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')

        if [ ${#ids[@]} -eq 0 ]; then
            echo "No pending devices found."
            exit 0
        fi

        echo "Found ${#ids[@]} device(s):"
        for i in "${!ids[@]}"; do
            echo "  [$((i+1))] ${ids[$i]}"
        done
        echo "  [a] Approve all"
        echo "  [q] Quit"
        echo ""

        read -rp "Select device to approve (number/a/q): " choice

        case "${choice}" in
            q|Q) echo "Cancelled."; exit 0 ;;
            a|A)
                for id in "${ids[@]}"; do
                    echo "Approving ${id} ..."
                    approve_device "${id}" && echo "  Approved." || echo "  Failed."
                done
                ;;
            *)
                if ! [[ "${choice}" =~ ^[0-9]+$ ]]; then
                    echo "Invalid selection." >&2
                    exit 1
                fi
                idx=$((choice - 1))
                if [ "${idx}" -ge 0 ] && [ "${idx}" -lt "${#ids[@]}" ]; then
                    echo "Approving ${ids[$idx]} ..."
                    approve_device "${ids[$idx]}" && echo "Approved." || echo "Failed."
                else
                    echo "Invalid selection." >&2
                    exit 1
                fi
                ;;
        esac
        ;;
    *)
        # Direct approve by ID
        echo "Approving device $1 ..."
        approve_device "$1" && echo "Approved." || echo "Failed."
        ;;
esac
