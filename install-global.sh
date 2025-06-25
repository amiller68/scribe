#!/bin/bash

# Global installation script for Scribe
# Creates symlinks in /usr/local/bin

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
RESET='\033[0m'

# Get script directory
SCRIBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/bin"

echo -e "${BLUE}Installing Scribe globally...${RESET}"

# Check if running with appropriate permissions
if [[ ! -w "$INSTALL_DIR" ]]; then
    echo -e "${RED}Error: Cannot write to $INSTALL_DIR${RESET}"
    echo "Please run with sudo: sudo $0"
    exit 1
fi

# Create symlink
ln -sf "${SCRIBE_DIR}/scribe.sh" "${INSTALL_DIR}/scribe"

# Make scripts executable
chmod +x "${SCRIBE_DIR}/scribe.sh"
chmod +x "${SCRIBE_DIR}/lib"/*.sh

echo -e "${GREEN}Scribe installed globally!${RESET}"
echo -e "You can now run ${BLUE}scribe${RESET} from any directory"

# Create uninstall script
cat > "${SCRIBE_DIR}/uninstall-global.sh" << 'EOF'
#!/bin/bash
rm -f /usr/local/bin/scribe
echo "Scribe has been uninstalled from global PATH"
EOF
chmod +x "${SCRIBE_DIR}/uninstall-global.sh"

echo -e "\nTo uninstall: ${BLUE}${SCRIBE_DIR}/uninstall-global.sh${RESET}"