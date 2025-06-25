#!/bin/bash

# Test script for single-pr merge strategy

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing Single-PR Merge Strategy"
echo "================================"

# Find a completed session
SESSION_DIR=$(find "${SCRIPT_DIR}/workspace/sessions" -type d -name "20250625_*" | sort -r | head -1)

if [[ -z "${SESSION_DIR}" ]]; then
    echo "No sessions found to test"
    exit 1
fi

echo "Using session: $(basename "${SESSION_DIR}")"

# Check if it has completed tasks
if [[ ! -d "${SESSION_DIR}/workers" ]]; then
    echo "No workers directory found"
    exit 1
fi

# Count completed tasks
COMPLETED=0
for worker in "${SESSION_DIR}"/workers/worker-*/status.json; do
    if [[ -f "${worker}" ]]; then
        STATUS=$(jq -r '.status' "${worker}" 2>/dev/null || echo "unknown")
        if [[ "${STATUS}" == "completed" ]]; then
            ((COMPLETED++))
        fi
    fi
done

echo "Found ${COMPLETED} completed tasks"

if [[ ${COMPLETED} -eq 0 ]]; then
    echo "No completed tasks to merge"
    exit 1
fi

# Test the publish command with single-pr strategy
echo -e "\nTesting scribe publish with single-pr strategy..."
echo "Command: ./scribe publish $(basename "${SESSION_DIR}")"
echo ""
echo "This will:"
echo "1. Create an integration branch"
echo "2. Cherry-pick commits from each task"
echo "3. Push the integration branch"
echo "4. Create a single combined PR"
echo ""
echo "Ready to test? (Ctrl+C to cancel)"
read -p "Press Enter to continue..."

# Run the publish command
"${SCRIPT_DIR}/scribe" publish "$(basename "${SESSION_DIR}")"