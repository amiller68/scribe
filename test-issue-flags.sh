#!/bin/bash

# Test script for issue workflow with flags

set -euo pipefail

echo "Testing scribe issue command with flags..."
echo "This will run without any prompts and show agent output in debug mode"
echo ""

# Test with all flags provided (should bypass all prompts)
./scribe issue -n 1 \
    --scope frontend \
    --priority low \
    --workers 3 \
    --strategy federated \
    --debug \
    --yes

echo ""
echo "Test completed!"
echo ""
echo "To run without debug output:"
echo "./scribe issue -n 1 --scope frontend --priority low --workers 3 --strategy federated --yes"