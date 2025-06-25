#!/bin/bash

# Worker spawning and management script for Scribe orchestration system
# Spawns Claude Code instances with specific tasks

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Default values
DEFAULT_TIMEOUT=3600

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Spawn a Claude Code worker for a specific task.

OPTIONS:
    --session-dir DIR      Session directory containing task info
    --repo-dir DIR         Repository directory
    --task-id ID          Task ID to execute
    --timeout SECONDS     Worker timeout (default: ${DEFAULT_TIMEOUT})
    -h, --help           Show this help message

Example:
    $0 --session-dir /path/to/session --repo-dir /path/to/repo --task-id task-001
EOF
    exit 1
}

# Parse arguments
SESSION_DIR=""
REPO_DIR=""
TASK_ID=""
TIMEOUT="${DEFAULT_TIMEOUT}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --session-dir)
            SESSION_DIR="$2"
            shift 2
            ;;
        --repo-dir)
            REPO_DIR="$2"
            shift 2
            ;;
        --task-id)
            TASK_ID="$2"
            shift 2
            ;;
        --timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "${SESSION_DIR}" ]] || [[ -z "${REPO_DIR}" ]] || [[ -z "${TASK_ID}" ]]; then
    log_error "Missing required arguments"
    usage
fi

# Worker directory
WORKER_DIR="${SESSION_DIR}/workers/worker-${TASK_ID}"
TASK_FILE="${WORKER_DIR}/task.json"
STATUS_FILE="${WORKER_DIR}/status.json"
LOG_FILE="${WORKER_DIR}/output.log"
PROMPT_FILE="${WORKER_DIR}/prompt.txt"

# Validate task file exists
if [[ ! -f "${TASK_FILE}" ]]; then
    log_error "Task file not found: ${TASK_FILE}"
    exit 1
fi

# Initialize worker status
init_worker_status() {
    local status_content=$(cat << EOF
{
    "task_id": "${TASK_ID}",
    "status": "initializing",
    "started_at": "$(get_timestamp)",
    "pid": $$,
    "timeout": ${TIMEOUT}
}
EOF
)
    write_json "${STATUS_FILE}" "${status_content}"
}

# Update worker status
update_worker_status() {
    local status="$1"
    local additional_fields="${2:-}"
    
    local current_status=$(read_json "${STATUS_FILE}")
    local updated_status=$(echo "${current_status}" | jq --arg status "${status}" '.status = $status')
    
    # Add additional fields if provided
    if [[ -n "${additional_fields}" ]]; then
        updated_status=$(echo "${updated_status}" | jq ". + ${additional_fields}")
    fi
    
    write_json "${STATUS_FILE}" "${updated_status}"
}

# Create worktree for task
create_task_worktree() {
    local task_name=$(read_json "${TASK_FILE}" ".name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
    local branch_name="scribe-${TASK_ID}-${task_name}"
    local worktree_name="${TASK_ID}-${task_name}"
    
    log_info "Creating worktree: ${worktree_name}"
    
    local worktree_path=$(create_worktree "${REPO_DIR}" "${worktree_name}" "${branch_name}")
    
    # Save worktree info
    update_worker_status "worktree_created" "{\"worktree_path\": \"${worktree_path}\", \"branch\": \"${branch_name}\"}"
    
    echo "${worktree_path}"
}

# Generate worker prompt
generate_worker_prompt() {
    local worktree_path="$1"
    local task=$(cat "${TASK_FILE}")
    local repo_analysis=$(cat "${SESSION_DIR}/repo_analysis.json")
    
    # Extract task details
    local task_name=$(echo "${task}" | jq -r '.name')
    local task_description=$(echo "${task}" | jq -r '.description')
    local task_scope=$(echo "${task}" | jq -r '.scope[]' | paste -sd ',' -)
    local task_boundaries=$(echo "${task}" | jq -r '.boundaries[]' | paste -sd ',' -)
    
    # Get other tasks for context
    local other_tasks=$(jq -r '.tasks[] | select(.id != "'"${TASK_ID}"'") | "- \(.name): \(.description)"' "${SESSION_DIR}/tasks.json")
    
    # Get the full feature description from config
    local feature_description=$(jq -r '.ticket_description' "${SESSION_DIR}/config.json")
    
    # Generate prompt
    cat > "${PROMPT_FILE}" << EOF
You are implementing a specific task as part of a larger feature implementation.

OVERALL FEATURE REQUEST:
${feature_description}

TASK DETAILS:
Task ID: ${TASK_ID}
Task Name: ${task_name}
Description: ${task_description}

YOUR SCOPE:
Focus on these directories/files: ${task_scope}
DO NOT modify these areas: ${task_boundaries}

REPOSITORY CONTEXT:
$(echo "${repo_analysis}" | jq -r '
"Project Type: \(.project.type)
Frameworks: \(.project.frameworks | join(", "))
Test Framework: \(.project.test_framework)"
')

OTHER PARALLEL TASKS:
${other_tasks}

WORKING DIRECTORY:
${worktree_path}

CRITICAL: You are running in automation mode. You MUST make actual file changes.

YOU ARE REQUIRED TO:
1. Change to the working directory: cd ${worktree_path}
2. Use tools to find and read files in the ${task_scope} directory
3. Use Edit or Write tools to ACTUALLY MODIFY files
4. Stage changes with: git add -A
5. Commit changes with: git commit -m "Fix: ${task_name}"

AUTOMATION REQUIREMENTS:
- You have pre-approved access to: bash, read, edit, write, grep, find, ls
- You MUST use these tools to make changes
- Do NOT ask for permission - all tools are pre-approved
- Do NOT provide recommendations - MAKE the changes
- The workflow FAILS if you don't create commits

START NOW with: cd ${worktree_path} && ls -la
EOF

    echo "${PROMPT_FILE}"
}

# Execute Claude Code with task
execute_claude_code() {
    local worktree_path="$1"
    local prompt_file="$2"
    
    log_info "Spawning Claude Code for task: ${TASK_ID}"
    update_worker_status "running"
    
    # Prepare Claude Code command
    local claude_command="claude"
    
    # Check if claude command exists
    if ! command_exists "${claude_command}"; then
        log_error "Claude Code CLI not found. Please ensure 'claude' is installed and in PATH"
        update_worker_status "failed" "{\"error\": \"Claude Code CLI not found\"}"
        return 1
    fi
    
    # Execute Claude Code with timeout
    local start_time=$(date +%s)
    
    # Run in background mode (headless)
    log_info "Running Claude Code in background mode"
    
    # Add debug information
    echo "=== CLAUDE CODE EXECUTION START ===" >> "${LOG_FILE}"
    echo "Working directory: ${worktree_path}" >> "${LOG_FILE}"
    echo "Prompt file: ${prompt_file}" >> "${LOG_FILE}"
    echo "Command: ${claude_command} --print" >> "${LOG_FILE}"
    echo "Timeout: ${TIMEOUT}" >> "${LOG_FILE}"
    echo "=== CLAUDE CODE OUTPUT ===" >> "${LOG_FILE}"
    
    # Change to working directory first
    cd "${worktree_path}"
    
    # Run Claude Code with automation flags for headless execution
    local success
    # Pre-approve all necessary tools for file operations
    # Note: Claude Code uses specific tool names
    local allowed_tools="Bash,Read,Edit,Write,Grep,Glob,LS,MultiEdit"
    local claude_flags="--print --dangerously-skip-permissions --max-turns 30 --allowedTools ${allowed_tools}"
    
    log_info "Running: ${claude_command} ${claude_flags}"
    echo "Command: ${claude_command} ${claude_flags}" >> "${LOG_FILE}"
    
    if timeout "${TIMEOUT}" "${claude_command}" ${claude_flags} < "${prompt_file}" >> "${LOG_FILE}" 2>&1; then
        success=0
        echo "=== CLAUDE CODE COMPLETED SUCCESSFULLY ===" >> "${LOG_FILE}"
    else
        local exit_code=$?
        success=${exit_code}
        echo "=== CLAUDE CODE FAILED WITH EXIT CODE ${exit_code} ===" >> "${LOG_FILE}"
    fi
    
    if [[ ${success} -eq 0 ]]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log_success "Claude Code completed successfully for task: ${TASK_ID} (duration: ${duration}s)"
        update_worker_status "completed" "{\"completed_at\": \"$(get_timestamp)\", \"duration\": ${duration}}"
        return 0
    else
        local exit_code=${success}
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        if [[ ${exit_code} -eq 124 ]]; then
            log_error "Claude Code timed out for task: ${TASK_ID}"
            update_worker_status "timeout" "{\"error\": \"Execution timed out after ${TIMEOUT} seconds\", \"duration\": ${duration}}"
        else
            log_error "Claude Code failed for task: ${TASK_ID} (exit code: ${exit_code})"
            update_worker_status "failed" "{\"error\": \"Claude Code exited with code ${exit_code}\", \"duration\": ${duration}}"
        fi
        return 1
    fi
}


# Verify task completion
verify_task_completion() {
    local worktree_path="$1"
    
    cd "${worktree_path}"
    
    # First check if any files were modified
    local modified_files=$(git status --porcelain | wc -l | tr -d ' ')
    # Count commits on this branch that aren't on main
    local branch_commits=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
    
    log_info "Checking task completion: ${modified_files} modified files, ${branch_commits} branch commits"
    
    # Check for uncommitted changes
    if [[ ${modified_files} -gt 0 ]]; then
        log_info "Found ${modified_files} uncommitted changes"
        
        # Try to commit them
        git add -A
        git commit -m "Fix: $(read_json "${TASK_FILE}" ".name")" || true
        
        # Recount after potential commit
        branch_commits=$(git rev-list --count main..HEAD 2>/dev/null || echo "0")
    fi
    
    if [[ ${branch_commits} -gt 0 ]]; then
        log_success "Task produced ${branch_commits} commits"
        update_worker_status "completed" "{\"commit_count\": ${branch_commits}, \"modified_files\": ${modified_files}}"
        return 0
    else
        log_error "No changes made by Claude Code - task failed"
        
        # Check if Claude only provided recommendations
        if grep -q "solution\|recommend\|should\|would\|could" "${LOG_FILE}" 2>/dev/null; then
            log_error "Claude Code only provided recommendations instead of making changes"
            update_worker_status "failed" "{\"error\": \"Claude only provided recommendations, no actual changes made\"}"
        else
            update_worker_status "failed" "{\"error\": \"No commits or file changes detected\"}"
        fi
        
        return 1
    fi
}

# Main worker function
main() {
    log_info "Starting worker for task: ${TASK_ID}"
    
    # Initialize status
    init_worker_status
    
    # Set up signal handlers
    trap 'update_worker_status "interrupted" "{\"error\": \"Worker interrupted\"}"; exit 130' INT TERM
    
    # Create worktree
    local worktree_path=$(create_task_worktree)
    
    # Generate prompt
    local prompt_file=$(generate_worker_prompt "${worktree_path}")
    
    # Execute Claude Code
    if execute_claude_code "${worktree_path}" "${prompt_file}"; then
        # Verify completion
        verify_task_completion "${worktree_path}"
    fi
    
    # Final status update
    local final_status=$(read_json "${STATUS_FILE}" ".status")
    log_info "Worker completed with status: ${final_status}"
}

# Run main function
main "$@"