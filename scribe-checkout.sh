#!/bin/bash

# Scribe Checkout - Switch to branches from Scribe sessions
# Usage: scribe checkout [SESSION_ID]

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null

# Colors
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

# Default values
SESSION_ID=""
CREATE_WORKTREE=false
FORCE_CHECKOUT=false
LIST_ONLY=false
WORKSPACE_DIR="${SCRIPT_DIR}/workspace"

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [SESSION_ID]

Checkout branches created by Scribe sessions.

OPTIONS:
    -w, --worktree      Create new worktree instead of switching branches
    -f, --force         Force checkout even with uncommitted changes
    -l, --list          List all available branches without checking out
    -h, --help          Show this help message

ARGUMENTS:
    SESSION_ID          Specific session to checkout (optional)
                       If not provided, uses the latest session

EXAMPLES:
    $0                          # Checkout branch from latest session
    $0 20250625_131706          # Checkout branch from specific session
    $0 -w                       # Create worktree for latest session
    $0 -l                       # List branches without checkout

BEHAVIOR:
    - Single-PR strategy: Checks out the integration branch
    - Federated strategy: Shows interactive menu to select task branch
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -w|--worktree)
            CREATE_WORKTREE=true
            shift
            ;;
        -f|--force)
            FORCE_CHECKOUT=true
            shift
            ;;
        -l|--list)
            LIST_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "${SESSION_ID}" ]]; then
                SESSION_ID="$1"
            else
                log_error "Unknown option: $1"
                usage
            fi
            shift
            ;;
    esac
done

# Find session directory
find_session() {
    local sessions_dir="${WORKSPACE_DIR}/sessions"
    
    if [[ ! -d "${sessions_dir}" ]]; then
        log_error "No sessions directory found"
        exit 1
    fi
    
    if [[ -n "${SESSION_ID}" ]]; then
        # Use specified session
        local session_dir="${sessions_dir}/${SESSION_ID}"
        if [[ ! -d "${session_dir}" ]]; then
            # Try partial match
            local matches=($(ls -d "${sessions_dir}/${SESSION_ID}"* 2>/dev/null))
            if [[ ${#matches[@]} -eq 1 ]]; then
                session_dir="${matches[0]}"
            elif [[ ${#matches[@]} -gt 1 ]]; then
                log_error "Multiple sessions match '${SESSION_ID}'"
                echo "Matches:" >&2
                for match in "${matches[@]}"; do
                    echo "  $(basename "${match}")" >&2
                done
                exit 1
            else
                log_error "Session not found: ${SESSION_ID}"
                exit 1
            fi
        fi
        echo "${session_dir}"
    else
        # Find latest session
        local latest=""
        for session in $(ls -t "${sessions_dir}" 2>/dev/null); do
            local config_file="${sessions_dir}/${session}/config.json"
            if [[ -f "${config_file}" ]]; then
                latest="${session}"
                break
            fi
        done
        
        if [[ -z "${latest}" ]]; then
            log_error "No sessions found"
            exit 1
        fi
        
        echo "${sessions_dir}/${latest}"
    fi
}

# Get branch info
get_branch_info() {
    local branch="$1"
    local base_branch="${2:-main}"
    
    # Check if branch exists remotely
    local remote_exists=false
    if git ls-remote --heads origin "${branch}" >/dev/null 2>&1; then
        remote_exists=true
    fi
    
    # Check if branch exists locally
    local local_exists=false
    if git rev-parse --verify "${branch}" >/dev/null 2>&1; then
        local_exists=true
    fi
    
    if [[ "${local_exists}" == false && "${remote_exists}" == false ]]; then
        echo "not found"
        return
    fi
    
    if [[ "${local_exists}" == false && "${remote_exists}" == true ]]; then
        echo "remote only (use checkout to fetch)"
        return
    fi
    
    # Get commit count
    local commits=$(git rev-list --count "${base_branch}..${branch}" 2>/dev/null || echo "0")
    
    # Check tracking status
    local tracking=""
    if [[ "${remote_exists}" == true ]]; then
        local ahead=$(git rev-list --count "origin/${branch}..${branch}" 2>/dev/null || echo "0")
        local behind=$(git rev-list --count "${branch}..origin/${branch}" 2>/dev/null || echo "0")
        
        if [[ ${ahead} -eq 0 && ${behind} -eq 0 ]]; then
            tracking="synced with remote"
        elif [[ ${ahead} -gt 0 && ${behind} -eq 0 ]]; then
            tracking="${ahead} ahead of remote"
        elif [[ ${ahead} -eq 0 && ${behind} -gt 0 ]]; then
            tracking="${behind} behind remote"
        else
            tracking="${ahead} ahead, ${behind} behind"
        fi
    else
        tracking="local only"
    fi
    
    echo "${commits} commits, ${tracking}"
}

# List branches for session
list_session_branches() {
    local session_dir="$1"
    local merge_strategy="$2"
    local base_branch="${3:-main}"
    local session_name=$(basename "${session_dir}")
    
    echo -e "\n${BOLD}Branches for session: ${session_name}${RESET}"
    echo -e "Strategy: ${CYAN}${merge_strategy}${RESET}"
    echo ""
    
    if [[ "${merge_strategy}" == "single-pr" ]]; then
        # Single integration branch
        local integration_branch="scribe-integration-${session_name}"
        local info=$(get_branch_info "${integration_branch}" "${base_branch}")
        
        echo -e "  ${GREEN}→${RESET} ${integration_branch}"
        echo -e "    ${YELLOW}${info}${RESET}"
        echo -e "    ${CYAN}Combined PR with all tasks${RESET}"
        
        # Also list individual task branches for reference
        echo -e "\n  ${BOLD}Individual task branches:${RESET}"
        list_task_branches "${session_dir}" "${base_branch}" "    "
    else
        # Federated - list all task branches
        list_task_branches "${session_dir}" "${base_branch}" "  "
    fi
}

# List task branches
list_task_branches() {
    local session_dir="$1"
    local base_branch="$2"
    local prefix="${3:-}"
    
    local workers_dir="${session_dir}/workers"
    if [[ ! -d "${workers_dir}" ]]; then
        return
    fi
    
    local index=1
    for worker_dir in "${workers_dir}"/worker-*; do
        if [[ -d "${worker_dir}" ]]; then
            local status_file="${worker_dir}/status.json"
            local task_file="${worker_dir}/task.json"
            
            if [[ -f "${status_file}" && -f "${task_file}" ]]; then
                local status=$(jq -r '.status' "${status_file}" 2>/dev/null)
                if [[ "${status}" == "completed" ]]; then
                    local branch=$(jq -r '.branch' "${status_file}" 2>/dev/null)
                    local task_name=$(jq -r '.name' "${task_file}" 2>/dev/null)
                    local task_id=$(jq -r '.id' "${task_file}" 2>/dev/null)
                    
                    if [[ -n "${branch}" && "${branch}" != "null" ]]; then
                        local info=$(get_branch_info "${branch}" "${base_branch}")
                        echo -e "${prefix}${GREEN}${index})${RESET} ${branch}"
                        echo -e "${prefix}   ${YELLOW}${info}${RESET}"
                        echo -e "${prefix}   ${CYAN}${task_name}${RESET}"
                        ((index++))
                    fi
                fi
            fi
        fi
    done
}

# Checkout branch
checkout_branch() {
    local branch="$1"
    local worktree_name="${2:-}"
    
    # Check for uncommitted changes
    if [[ -n "$(git status --porcelain)" ]] && [[ "${FORCE_CHECKOUT}" != true ]]; then
        log_error "You have uncommitted changes"
        log_info "Use -f/--force to checkout anyway, or commit/stash your changes"
        exit 1
    fi
    
    # Check if branch exists remotely but not locally
    local needs_fetch=false
    if ! git rev-parse --verify "${branch}" >/dev/null 2>&1; then
        if git ls-remote --heads origin "${branch}" >/dev/null 2>&1; then
            needs_fetch=true
        else
            log_error "Branch not found: ${branch}"
            exit 1
        fi
    fi
    
    if [[ "${CREATE_WORKTREE}" == true ]]; then
        # Create worktree
        if [[ -z "${worktree_name}" ]]; then
            worktree_name="${branch}-worktree"
        fi
        
        local worktree_path="../${worktree_name}"
        log_info "Creating worktree: ${worktree_path}"
        
        # For remote branches, use origin/branch syntax
        local worktree_ref="${branch}"
        if [[ "${needs_fetch}" == true ]]; then
            worktree_ref="origin/${branch}"
            log_info "Fetching remote branch: ${branch}"
            git fetch origin "${branch}:${branch}"
        fi
        
        if git worktree add "${worktree_path}" "${branch}"; then
            log_success "Created worktree at: $(cd "${worktree_path}" && pwd)"
            echo -e "\n${YELLOW}To enter the worktree:${RESET}"
            echo "  cd ${worktree_path}"
        else
            log_error "Failed to create worktree"
            exit 1
        fi
    else
        # Regular checkout
        log_info "Checking out branch: ${branch}"
        
        if [[ "${needs_fetch}" == true ]]; then
            log_info "Fetching remote branch..."
            # Try to checkout with tracking (-t creates local branch from remote)
            if git checkout -t "origin/${branch}" 2>/dev/null; then
                log_success "Created and switched to branch: ${branch}"
            elif git checkout "${branch}" 2>/dev/null; then
                # Branch exists locally but wasn't tracking, set upstream
                git branch --set-upstream-to="origin/${branch}" "${branch}" 2>/dev/null || true
                log_success "Switched to branch: ${branch}"
            else
                log_error "Failed to checkout branch: ${branch}"
                exit 1
            fi
        else
            # Local branch exists, just checkout
            if git checkout "${branch}"; then
                log_success "Switched to branch: ${branch}"
            else
                log_error "Failed to checkout branch"
                exit 1
            fi
        fi
        
        # Show status
        echo -e "\n${BOLD}Branch status:${RESET}"
        git status -sb
    fi
}

# Interactive branch selection
select_branch() {
    local session_dir="$1"
    local base_branch="$2"
    
    local branches=()
    local branch_names=()
    
    # Collect branches
    local workers_dir="${session_dir}/workers"
    for worker_dir in "${workers_dir}"/worker-*; do
        if [[ -d "${worker_dir}" ]]; then
            local status_file="${worker_dir}/status.json"
            if [[ -f "${status_file}" ]]; then
                local status=$(jq -r '.status' "${status_file}" 2>/dev/null)
                if [[ "${status}" == "completed" ]]; then
                    local branch=$(jq -r '.branch' "${status_file}" 2>/dev/null)
                    if [[ -n "${branch}" && "${branch}" != "null" ]]; then
                        branches+=("${branch}")
                        local task_file="${worker_dir}/task.json"
                        local task_name=$(jq -r '.name' "${task_file}" 2>/dev/null || echo "Unknown")
                        branch_names+=("${task_name}")
                    fi
                fi
            fi
        fi
    done
    
    if [[ ${#branches[@]} -eq 0 ]]; then
        log_error "No branches found for session"
        exit 1
    fi
    
    # Show menu
    echo -e "\n${BOLD}Select a branch to checkout:${RESET}"
    for i in "${!branches[@]}"; do
        local index=$((i + 1))
        local info=$(get_branch_info "${branches[$i]}" "${base_branch}")
        echo -e "  ${GREEN}${index})${RESET} ${branches[$i]}"
        echo -e "     ${YELLOW}${info}${RESET}"
        echo -e "     ${CYAN}${branch_names[$i]}${RESET}"
    done
    
    # Get selection
    echo ""
    read -p "Enter selection (1-${#branches[@]}): " selection
    
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || [[ ${selection} -lt 1 ]] || [[ ${selection} -gt ${#branches[@]} ]]; then
        log_error "Invalid selection"
        exit 1
    fi
    
    local selected_branch="${branches[$((selection - 1))]}"
    checkout_branch "${selected_branch}"
}

# Main function
main() {
    print_banner "Scribe Checkout - Branch Management"
    
    # Check if in git repository
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        log_error "Not in a git repository"
        exit 1
    fi
    
    # Find session
    local session_dir=$(find_session)
    local session_name=$(basename "${session_dir}")
    log_info "Using session: ${session_name}"
    
    # Get session config
    local config_file="${session_dir}/config.json"
    if [[ ! -f "${config_file}" ]]; then
        log_error "Session config not found"
        exit 1
    fi
    
    local merge_strategy=$(jq -r '.merge_strategy' "${config_file}" 2>/dev/null || echo "single-pr")
    local base_branch=$(jq -r '.base_branch // "main"' "${config_file}" 2>/dev/null)
    
    # Fetch latest from origin
    log_info "Fetching latest from origin..."
    git fetch origin >/dev/null 2>&1 || true
    
    if [[ "${LIST_ONLY}" == true ]]; then
        # Just list branches
        list_session_branches "${session_dir}" "${merge_strategy}" "${base_branch}"
    else
        # Checkout based on strategy
        if [[ "${merge_strategy}" == "single-pr" ]]; then
            # Single PR - checkout integration branch
            local integration_branch="scribe-integration-${session_name}"
            
            # Try to checkout - will fetch if needed
            checkout_branch "${integration_branch}" "${session_name}"
        else
            # Federated - show selection menu
            select_branch "${session_dir}" "${base_branch}"
        fi
    fi
}

# Run main function
main "$@"