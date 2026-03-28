#!/usr/bin/env bash
# =============================================================================
# approve-device.sh -- Manually approve pending device pairing requests
#
# Interactive script:
#   1. Lists pending pairing requests
#   2. Lets user select a device
#   3. Asks approve or cancel
#   4. Executes the chosen action
#
# Usage:
#   ./scripts/approve-device.sh
# =============================================================================
set -euo pipefail

echo ""
echo "========================================"
echo "  OpenClaw Device Pairing Manager"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# Detect runtime
# ---------------------------------------------------------------------------
RT=""
if command -v docker >/dev/null 2>&1; then
    RT="docker"
elif command -v podman >/dev/null 2>&1; then
    RT="podman"
else
    echo "ERROR: No container runtime found." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Check OpenClaw container is running
# ---------------------------------------------------------------------------
if ! "${RT}" container inspect democlaw-openclaw >/dev/null 2>&1; then
    echo "ERROR: Container 'democlaw-openclaw' is not running."
    echo "Start it first with: ./scripts/start.sh"
    exit 1
fi

# ---------------------------------------------------------------------------
# Show paired devices summary
# ---------------------------------------------------------------------------
echo "--- Currently Paired Devices ---"
"${RT}" exec democlaw-openclaw sh -c \
    'openclaw devices list --json 2>/dev/null | jq -r ".paired[] | \"  [\(.platform)] \(.clientMode) - \(.deviceId[0:16])... (IP: \(.remoteIp // \"n/a\"))\"" 2>/dev/null' || true
echo ""

# ---------------------------------------------------------------------------
# Get pending devices
# ---------------------------------------------------------------------------
echo "--- Pending Pairing Requests ---"

PENDING_JSON=$("${RT}" exec democlaw-openclaw sh -c 'openclaw devices list --json 2>/dev/null | jq -c ".pending[]" 2>/dev/null' || true)

if [ -z "${PENDING_JSON}" ]; then
    echo "  No pending pairing requests found."
    echo ""
    echo "  If you just clicked \"Connect\" in the browser,"
    echo "  wait a moment and run this script again."
    exit 0
fi

# Parse pending devices into arrays
declare -a REQUEST_IDS=()
declare -a DEVICE_INFOS=()
IDX=0

while IFS= read -r line; do
    [ -z "${line}" ] && continue
    IDX=$((IDX + 1))

    REQ_ID=$(echo "${line}" | jq -r '.requestId // .deviceId')
    DEV_ID=$(echo "${line}" | jq -r '.deviceId[0:16]')
    PLATFORM=$(echo "${line}" | jq -r '.platform // "unknown"')
    MODE=$(echo "${line}" | jq -r '.clientMode // "unknown"')
    IP=$(echo "${line}" | jq -r '.remoteIp // "n/a"')

    REQUEST_IDS+=("${REQ_ID}")
    DEVICE_INFOS+=("${DEV_ID}")

    echo "  [${IDX}] ID: ${REQ_ID}"
    echo "      Device: ${DEV_ID}...  Platform: ${PLATFORM}  Mode: ${MODE}  IP: ${IP}"
done <<< "${PENDING_JSON}"

PCOUNT=${#REQUEST_IDS[@]}

echo ""
echo "----------------------------------------"

# ---------------------------------------------------------------------------
# User selection
# ---------------------------------------------------------------------------
SELECTION=""
if [ "${PCOUNT}" -eq 1 ]; then
    SELECTION="1"
    echo "Only one pending request found. Auto-selected [1]."
else
    echo "Enter device number to manage [1-${PCOUNT}], or 'a' for all, or 'q' to quit:"
    read -r SELECTION
fi

if [ "${SELECTION}" = "q" ]; then
    echo "Cancelled."
    exit 0
fi

# ---------------------------------------------------------------------------
# Approve or Cancel
# ---------------------------------------------------------------------------
echo ""
echo "Choose action:"
echo "  [1] Approve  - Allow this device to connect"
echo "  [2] Cancel   - Deny and quit"
echo ""
read -rp "Your choice [1/2]: " ACTION

if [ "${ACTION}" = "2" ]; then
    echo "Cancelled. No devices were approved."
    exit 0
fi

if [ "${ACTION}" != "1" ]; then
    echo "Invalid choice. Exiting."
    exit 1
fi

# ---------------------------------------------------------------------------
# Execute approval
# ---------------------------------------------------------------------------
if [ "${SELECTION}" = "a" ] || [ "${SELECTION}" = "A" ]; then
    echo "Approving ALL pending devices ..."
    for i in $(seq 0 $((PCOUNT - 1))); do
        REQ="${REQUEST_IDS[$i]}"
        echo "  Approving ${REQ} ..."
        if "${RT}" exec democlaw-openclaw openclaw devices approve "${REQ}" >/dev/null 2>&1; then
            echo "  Approved."
        else
            echo "  WARNING: Failed to approve ${REQ}"
        fi
    done
else
    SEL_IDX=$((SELECTION - 1))
    if [ "${SEL_IDX}" -lt 0 ] || [ "${SEL_IDX}" -ge "${PCOUNT}" ]; then
        echo "Invalid selection. Exiting."
        exit 1
    fi
    REQ="${REQUEST_IDS[$SEL_IDX]}"
    echo "Approving ${REQ} ..."
    if "${RT}" exec democlaw-openclaw openclaw devices approve "${REQ}" 2>&1; then
        echo "Device approved successfully!"
    else
        echo "WARNING: Failed to approve device."
    fi
fi

echo ""
echo "Done. Refresh the browser to connect."
