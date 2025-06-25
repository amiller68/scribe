#!/bin/bash

# Simplified wrapper for common Scribe workflows
# Provides quick access to issue-based development

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Main menu
show_menu() {
    print_banner "Scribe Work Menu"
    
    echo "What would you like to do?"
    echo ""
    echo "  1) Work on a GitHub issue"
    echo "  2) Implement a custom feature"
    echo "  3) List recent Scribe sessions"
    echo "  4) Resume a previous session"
    echo "  5) Clean up old sessions"
    echo "  q) Quit"
    echo ""
}

# List recent sessions
list_sessions() {
    local sessions_dir="${SCRIPT_DIR}/workspace/sessions"
    
    if [[ ! -d "${sessions_dir}" ]] || [[ -z "$(ls -A ${sessions_dir} 2>/dev/null)" ]]; then
        echo "No sessions found."
        return
    fi
    
    echo -e "${CYAN}${BOLD}Recent Scribe Sessions:${RESET}\n"
    
    local count=1
    for session in $(ls -t "${sessions_dir}" | head -10); do
        local config="${sessions_dir}/${session}/config.json"
        if [[ -f "${config}" ]]; then
            local ticket=$(jq -r '.ticket_description' "${config}" | head -1)
            local status=$(jq -r '.status' "${config}")
            local created=$(jq -r '.created_at' "${config}" | cut -d'T' -f1)
            
            echo -e "${count}. ${BOLD}${session}${RESET}"
            echo "   Ticket: ${ticket:0:60}..."
            echo "   Status: ${status}"
            echo "   Created: ${created}"
            echo ""
            ((count++))
        fi
    done
}

# Resume session
resume_session() {
    local sessions_dir="${SCRIPT_DIR}/workspace/sessions"
    
    echo "Enter session ID to resume: "
    read -r session_id
    
    local session_dir="${sessions_dir}/${session_id}"
    if [[ ! -d "${session_dir}" ]]; then
        log_error "Session not found: ${session_id}"
        return
    fi
    
    local config="${session_dir}/config.json"
    if [[ ! -f "${config}" ]]; then
        log_error "Session config not found"
        return
    fi
    
    # Show session details
    echo -e "\n${CYAN}${BOLD}Session Details:${RESET}"
    jq '.' "${config}"
    
    echo -e "\n${YELLOW}Note: Session resumption is not yet implemented.${RESET}"
    echo "You can view logs at: ${session_dir}/logs/"
}

# Clean up old sessions
cleanup_sessions() {
    local sessions_dir="${SCRIPT_DIR}/workspace/sessions"
    local retention_days=7
    
    echo "This will remove sessions older than ${retention_days} days."
    read -r -p "Continue? (y/n): " confirm
    
    if [[ "${confirm,,}" != "y" ]]; then
        return
    fi
    
    local count=0
    for session in "${sessions_dir}"/*; do
        if [[ -d "${session}" ]]; then
            local config="${session}/config.json"
            if [[ -f "${config}" ]]; then
                local created=$(jq -r '.created_at' "${config}")
                local created_timestamp=$(date -d "${created}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${created}" +%s)
                local current_timestamp=$(date +%s)
                local age_days=$(( (current_timestamp - created_timestamp) / 86400 ))
                
                if [[ ${age_days} -gt ${retention_days} ]]; then
                    echo "Removing session: $(basename "${session}") (${age_days} days old)"
                    rm -rf "${session}"
                    ((count++))
                fi
            fi
        fi
    done
    
    echo -e "\n${GREEN}Cleaned up ${count} old sessions.${RESET}"
}

# Custom feature implementation
custom_feature() {
    echo -e "${CYAN}${BOLD}Custom Feature Implementation${RESET}\n"
    
    # Get repository
    local repo_url=""
    if git remote get-url origin >/dev/null 2>&1; then
        repo_url=$(git remote get-url origin)
        echo "Current repository: ${repo_url}"
        read -r -p "Use this repository? (y/n): " use_current
        
        if [[ "${use_current,,}" != "y" ]]; then
            read -r -p "Enter repository URL: " repo_url
        fi
    else
        read -r -p "Enter repository URL: " repo_url
    fi
    
    # Get feature description
    echo -e "\n${BOLD}Describe the feature you want to implement:${RESET}"
    echo "(Be specific about what needs to be done)"
    read -r -p "> " feature_description
    
    # Configuration
    echo -e "\n${BOLD}Configuration:${RESET}"
    read -r -p "Number of parallel workers (default: 3): " workers
    workers=${workers:-3}
    
    echo "Merge strategy:"
    echo "  1) Single PR"
    echo "  2) Federated PRs"
    read -r -p "Select (default: 1): " strategy
    
    local strategy_opt=""
    if [[ "${strategy}" == "2" ]]; then
        strategy_opt="-s federated"
    fi
    
    # Execute
    echo -e "\n${GREEN}${BOLD}Launching Scribe...${RESET}\n"
    "${SCRIPT_DIR}/scribe.sh" -w "${workers}" ${strategy_opt} "${feature_description}" "${repo_url}"
}

# Main loop
main() {
    while true; do
        show_menu
        read -r -p "Select option: " choice
        
        case "${choice}" in
            1)
                "${SCRIPT_DIR}/scribe-issue.sh"
                ;;
            2)
                custom_feature
                ;;
            3)
                list_sessions
                ;;
            4)
                resume_session
                ;;
            5)
                cleanup_sessions
                ;;
            q|Q)
                echo "Goodbye!"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please try again.${RESET}"
                ;;
        esac
        
        echo -e "\nPress Enter to continue..."
        read -r
        clear
    done
}

# Check if running directly or with arguments
if [[ $# -gt 0 ]]; then
    # Pass through to scribe-issue.sh
    exec "${SCRIPT_DIR}/scribe-issue.sh" "$@"
else
    # Interactive menu
    main
fi