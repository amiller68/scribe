#!/bin/bash

# Common utilities and functions for Scribe orchestration system

set -euo pipefail

# Color codes for output
readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_RESET='\033[0m'

# Logging functions
log_info() {
    echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_warning() {
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $(date '+%Y-%m-%d %H:%M:%S') - $*" >&2
}

# Print banner
print_banner() {
    local title="$1"
    local width=60
    local padding=$(( (width - ${#title}) / 2 ))
    
    echo -e "\n${COLOR_BLUE}$(printf '=%.0s' {1..60})${COLOR_RESET}" >&2
    printf "%*s%s%*s\n" $padding "" "$title" $padding "" >&2
    echo -e "${COLOR_BLUE}$(printf '=%.0s' {1..60})${COLOR_RESET}\n" >&2
}

# Generate unique ID
generate_id() {
    # Generate a short unique ID
    echo "$(date +%s)$(shuf -i 1000-9999 -n 1)"
}

# Update session status
update_session_status() {
    local session_dir="$1"
    local status="$2"
    local config_file="${session_dir}/config.json"
    
    if [[ -f "${config_file}" ]]; then
        # Update status in config file
        local tmp_file="${config_file}.tmp"
        jq --arg status "${status}" '.status = $status' "${config_file}" > "${tmp_file}"
        mv "${tmp_file}" "${config_file}"
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Validate dependencies
validate_dependencies() {
    local deps=("git" "jq" "gh")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command_exists "${dep}"; then
            missing+=("${dep}")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Please install them before running Scribe"
        exit 1
    fi
}

# Create worktree
create_worktree() {
    local repo_dir="$1"
    local worktree_name="$2"
    local branch_name="$3"
    local worktree_base="${repo_dir}/../worktrees"
    
    mkdir -p "${worktree_base}"
    local worktree_path="${worktree_base}/${worktree_name}"
    
    cd "${repo_dir}"
    
    # Create new branch and worktree
    if git show-ref --verify --quiet "refs/heads/${branch_name}"; then
        # Branch exists, create worktree with existing branch
        git worktree add "${worktree_path}" "${branch_name}" >/dev/null 2>&1
    else
        # Create new branch with worktree
        git worktree add -b "${branch_name}" "${worktree_path}" >/dev/null 2>&1
    fi
    
    echo "${worktree_path}"
}

# Remove worktree
remove_worktree() {
    local repo_dir="$1"
    local worktree_path="$2"
    
    cd "${repo_dir}"
    
    # Remove worktree
    if git worktree list | grep -q "${worktree_path}"; then
        git worktree remove --force "${worktree_path}" >/dev/null 2>&1 || true
    fi
    
    # Clean up directory if it still exists
    if [[ -d "${worktree_path}" ]]; then
        rm -rf "${worktree_path}"
    fi
}

# Read JSON file safely
read_json() {
    local file="$1"
    local query="${2:-.}"
    
    if [[ -f "${file}" ]]; then
        jq -r "${query}" "${file}" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Write JSON file atomically
write_json() {
    local file="$1"
    local content="$2"
    local tmp_file="${file}.tmp"
    
    echo "${content}" | jq . > "${tmp_file}"
    mv "${tmp_file}" "${file}"
}

# Get current timestamp
get_timestamp() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Calculate duration
calculate_duration() {
    local start_time="$1"
    local end_time="$2"
    
    local start_seconds=$(date -d "${start_time}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${start_time}" +%s)
    local end_seconds=$(date -d "${end_time}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "${end_time}" +%s)
    
    local duration=$((end_seconds - start_seconds))
    
    # Format duration
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    printf "%02d:%02d:%02d" ${hours} ${minutes} ${seconds}
}

# Lock file management
acquire_lock() {
    local lock_file="$1"
    local timeout="${2:-30}"
    local elapsed=0
    
    while ! mkdir "${lock_file}" 2>/dev/null; do
        if [[ ${elapsed} -ge ${timeout} ]]; then
            log_error "Failed to acquire lock: ${lock_file}"
            return 1
        fi
        sleep 1
        ((elapsed++))
    done
    
    # Store PID in lock
    echo $$ > "${lock_file}/pid"
}

release_lock() {
    local lock_file="$1"
    
    if [[ -d "${lock_file}" ]]; then
        rm -rf "${lock_file}"
    fi
}

# Cleanup on exit
cleanup_on_exit() {
    local lock_file="$1"
    release_lock "${lock_file}"
}

# Check if process is running
is_process_running() {
    local pid="$1"
    kill -0 "${pid}" 2>/dev/null
}

# Wait for file with timeout
wait_for_file() {
    local file="$1"
    local timeout="${2:-60}"
    local elapsed=0
    
    while [[ ! -f "${file}" ]]; do
        if [[ ${elapsed} -ge ${timeout} ]]; then
            return 1
        fi
        sleep 1
        ((elapsed++))
    done
    
    return 0
}

# Retry command with exponential backoff
retry_with_backoff() {
    local max_attempts="${1}"
    shift
    local command=("$@")
    local attempt=1
    local delay=1
    
    while [[ ${attempt} -le ${max_attempts} ]]; do
        if "${command[@]}"; then
            return 0
        fi
        
        if [[ ${attempt} -lt ${max_attempts} ]]; then
            log_warning "Command failed, retrying in ${delay}s... (attempt ${attempt}/${max_attempts})"
            sleep "${delay}"
            delay=$((delay * 2))
        fi
        
        ((attempt++))
    done
    
    return 1
}

# Export functions
export -f log_info log_success log_warning log_error
export -f generate_id update_session_status
export -f create_worktree remove_worktree
export -f read_json write_json
export -f get_timestamp calculate_duration
export -f acquire_lock release_lock
export -f is_process_running wait_for_file
export -f retry_with_backoff