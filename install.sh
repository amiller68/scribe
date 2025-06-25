#!/bin/bash

# Scribe installation script

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

echo -e "${BLUE}Installing Scribe...${RESET}"

# Get the directory where this script is located
SCRIBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect shell configuration file
SHELL_CONFIG=""
if [[ -f "$HOME/.zshrc" ]]; then
    SHELL_CONFIG="$HOME/.zshrc"
elif [[ -f "$HOME/.bashrc" ]]; then
    SHELL_CONFIG="$HOME/.bashrc"
elif [[ -f "$HOME/.bash_profile" ]]; then
    SHELL_CONFIG="$HOME/.bash_profile"
else
    echo -e "${RED}Could not detect shell configuration file${RESET}"
    echo "Please manually add the following to your shell config:"
    echo "export PATH=\"\$PATH:${SCRIBE_DIR}\""
    exit 1
fi

# Check if already in PATH
if grep -q "PATH.*${SCRIBE_DIR}" "$SHELL_CONFIG" 2>/dev/null; then
    echo -e "${GREEN}Scribe is already in your PATH${RESET}"
else
    # Add to PATH
    echo "" >> "$SHELL_CONFIG"
    echo "# Scribe - Multi-Agent Code Orchestration" >> "$SHELL_CONFIG"
    echo "export PATH=\"\$PATH:${SCRIBE_DIR}\"" >> "$SHELL_CONFIG"
    echo -e "${GREEN}Added Scribe to PATH in ${SHELL_CONFIG}${RESET}"
fi

# Make scripts executable
chmod +x "${SCRIBE_DIR}/scribe"
chmod +x "${SCRIBE_DIR}/scribe.sh"
chmod +x "${SCRIBE_DIR}/lib"/*.sh
chmod +x "${SCRIBE_DIR}/scribe-issue.sh"
chmod +x "${SCRIBE_DIR}/scribe-work.sh"

# Check dependencies
echo -e "\n${BLUE}Checking dependencies...${RESET}"
MISSING_DEPS=()

command -v git >/dev/null 2>&1 || MISSING_DEPS+=("git")
command -v jq >/dev/null 2>&1 || MISSING_DEPS+=("jq")
command -v gh >/dev/null 2>&1 || MISSING_DEPS+=("gh (GitHub CLI)")
command -v claude >/dev/null 2>&1 || MISSING_DEPS+=("claude (Claude Code CLI)")

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo -e "${RED}Missing dependencies:${RESET}"
    for dep in "${MISSING_DEPS[@]}"; do
        echo "  - $dep"
    done
    echo -e "\nPlease install missing dependencies before using Scribe."
else
    echo -e "${GREEN}All dependencies are installed!${RESET}"
fi

echo -e "\n${GREEN}Installation complete!${RESET}"
echo -e "\nTo start using Scribe:"
echo -e "1. Reload your shell: ${BLUE}source ${SHELL_CONFIG}${RESET}"
echo -e "2. Test installation: ${BLUE}scribe --version${RESET}"
echo -e "\n${BOLD}Available Commands:${RESET}"
echo -e "   ${BLUE}scribe${RESET}                    Show help and available commands"
echo -e "   ${BLUE}scribe run${RESET}               Execute orchestration"
echo -e "   ${BLUE}scribe issue${RESET}             Work on GitHub issues"
echo -e "   ${BLUE}scribe work${RESET}              Interactive workflow menu"
echo -e "   ${BLUE}scribe analyze${RESET}           Analyze repository structure"
echo -e "   ${BLUE}scribe list${RESET}              List recent sessions"
echo -e "   ${BLUE}scribe clean${RESET}             Clean up old sessions"
echo -e "\n${BOLD}Examples:${RESET}"
echo -e "   ${BLUE}scribe issue${RESET}                        # Select and work on an issue"
echo -e "   ${BLUE}scribe issue -n 123${RESET}                 # Work on specific issue"
echo -e "   ${BLUE}scribe issue list${RESET}                   # List open issues"
echo -e "   ${BLUE}scribe \"Add feature\" \"repo-url\"${RESET}     # Direct orchestration"
echo -e "   ${BLUE}scribe work${RESET}                         # Open interactive menu"
echo -e "   ${BLUE}scribe analyze .${RESET}                    # Analyze current repo"