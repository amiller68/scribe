#!/bin/bash

# Test script for Scribe fixes

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing Scribe fixes..."
echo "========================"

# Test 1: Bash compatibility
echo -e "\n1. Testing bash compatibility..."
bash_version=$(bash --version | head -1)
echo "   Bash version: ${bash_version}"

# Create test PIDs array
test_pids=(1234 5678 9012)
test_count=3

# Test nameref assignment (this would fail on very old bash)
test_nameref() {
    local -n ref=$1
    echo "   Nameref test: ${ref[0]}"
}
test_nameref test_pids && echo "   ✓ Nameref support OK" || echo "   ✗ Nameref not supported"

# Test 2: Check Claude Code flags
echo -e "\n2. Testing Claude Code setup..."
if command -v claude >/dev/null 2>&1; then
    echo "   ✓ Claude Code found: $(which claude)"
    claude --version 2>/dev/null | head -1 | sed 's/^/   Version: /'
else
    echo "   ✗ Claude Code not found"
fi

# Test 3: Git worktree support
echo -e "\n3. Testing git worktree support..."
if git worktree list >/dev/null 2>&1; then
    echo "   ✓ Git worktree supported"
    git version | sed 's/^/   /'
else
    echo "   ✗ Git worktree not supported"
fi

# Test 4: Required tools
echo -e "\n4. Testing required tools..."
tools=("jq" "git" "timeout" "gh")
for tool in "${tools[@]}"; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "   ✓ $tool found"
    else
        echo "   ✗ $tool not found"
    fi
done

echo -e "\n========================"
echo "Test complete!"