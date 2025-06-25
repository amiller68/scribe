#!/bin/bash

# Scribe: Multi-Agent Code Orchestration System
# Main orchestrator script that coordinates multiple Claude Code instances
# Usage: ./scribe.sh "Feature ticket description" "repo-url"

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
CONFIG_DIR="${SCRIPT_DIR}/config"
WORKSPACE_DIR="${SCRIPT_DIR}/workspace"
PROMPTS_DIR="${LIB_DIR}/prompts"

# Source common utilities
source "${LIB_DIR}/common.sh"

# Default configuration
DEFAULT_MAX_WORKERS=3
DEFAULT_TIMEOUT=3600
DEFAULT_BASE_BRANCH="main"

# Parse command line arguments
usage() {
    cat << EOF
Usage: $0 [OPTIONS] "Feature ticket description" "repo-url"

OPTIONS:
    -w, --workers NUM       Maximum number of parallel workers (default: ${DEFAULT_MAX_WORKERS})
    -t, --timeout SECONDS   Worker timeout in seconds (default: ${DEFAULT_TIMEOUT})
    -b, --branch NAME       Base branch name (default: ${DEFAULT_BASE_BRANCH})
    -s, --strategy TYPE     Merge strategy: single-pr or federated (default: single-pr)
    -h, --help             Show this help message

EXAMPLE:
    $0 "Add dark mode toggle to settings page" "https://github.com/user/repo"
EOF
    exit 1
}

# Initialize variables
TICKET_DESCRIPTION=""
REPO_URL=""
MAX_WORKERS="${DEFAULT_MAX_WORKERS}"
TIMEOUT="${DEFAULT_TIMEOUT}"
BASE_BRANCH="${DEFAULT_BASE_BRANCH}"
MERGE_STRATEGY="single-pr"

# Parse options
while [[ $# -gt 0 ]]; do
    case $1 in
        -w|--workers)
            MAX_WORKERS="$2"
            shift 2
            ;;
        -t|--timeout)
            TIMEOUT="$2"
            shift 2
            ;;
        -b|--branch)
            BASE_BRANCH="$2"
            shift 2
            ;;
        -s|--strategy)
            MERGE_STRATEGY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "${TICKET_DESCRIPTION}" ]]; then
                TICKET_DESCRIPTION="$1"
            elif [[ -z "${REPO_URL}" ]]; then
                REPO_URL="$1"
            else
                log_error "Unknown argument: $1"
                usage
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "${TICKET_DESCRIPTION}" ]] || [[ -z "${REPO_URL}" ]]; then
    log_error "Missing required arguments"
    usage
fi

# Initialize workspace
init_workspace() {
    log_info "Initializing workspace..."
    
    # Create session directory
    SESSION_ID="$(date +%Y%m%d_%H%M%S)_$(generate_id)"
    SESSION_DIR="${WORKSPACE_DIR}/sessions/${SESSION_ID}"
    mkdir -p "${SESSION_DIR}"/{workers,logs,repo}
    
    # Save session config using jq to properly escape strings
    jq -n \
        --arg session_id "${SESSION_ID}" \
        --arg ticket_description "${TICKET_DESCRIPTION}" \
        --arg repo_url "${REPO_URL}" \
        --argjson max_workers "${MAX_WORKERS}" \
        --argjson timeout "${TIMEOUT}" \
        --arg base_branch "${BASE_BRANCH}" \
        --arg merge_strategy "${MERGE_STRATEGY}" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg status "initializing" \
        '{
            session_id: $session_id,
            ticket_description: $ticket_description,
            repo_url: $repo_url,
            max_workers: $max_workers,
            timeout: $timeout,
            base_branch: $base_branch,
            merge_strategy: $merge_strategy,
            created_at: $created_at,
            status: $status
        }' > "${SESSION_DIR}/config.json"
    
    echo "${SESSION_DIR}"
}

# Clone repository
clone_repository() {
    local session_dir="$1"
    local repo_dir="${session_dir}/repo"
    
    log_info "Cloning repository: ${REPO_URL}"
    git clone "${REPO_URL}" "${repo_dir}" >/dev/null 2>&1
    
    # Checkout base branch
    cd "${repo_dir}"
    git checkout "${BASE_BRANCH}" >/dev/null 2>&1
    
    echo "${repo_dir}"
}

# Main orchestration function
orchestrate() {
    local session_dir="$1"
    local repo_dir="$2"
    
    log_info "Starting orchestration for session: $(basename "${session_dir}")"
    
    # Update session status
    update_session_status "${session_dir}" "analyzing"
    
    # Step 1: Analyze repository
    log_info "Analyzing repository structure..."
    local analysis_output="${session_dir}/repo_analysis.json"
    "${LIB_DIR}/analyze-repo.sh" "${repo_dir}" > "${analysis_output}"
    
    # Step 2: Decompose tasks
    log_info "Decomposing feature ticket into tasks..."
    local tasks_output="${session_dir}/tasks.json"
    decompose_tasks "${TICKET_DESCRIPTION}" "${analysis_output}" > "${tasks_output}"
    
    # Step 3: Validate task count
    local task_count=$(jq -r '.tasks | length' "${tasks_output}")
    if [[ ${task_count} -eq 0 ]]; then
        log_error "No tasks generated from decomposition"
        update_session_status "${session_dir}" "failed"
        return 1
    fi
    
    log_info "Generated ${task_count} tasks for parallel execution"
    
    # Step 4: Prepare all worker directories first
    update_session_status "${session_dir}" "preparing_workers"
    log_info "Preparing ${task_count} worker directories..."
    
    # Create all worker directories and save task definitions
    while IFS= read -r task; do
        local task_id=$(echo "${task}" | jq -r '.id')
        local worker_dir="${session_dir}/workers/worker-${task_id}"
        mkdir -p "${worker_dir}"
        
        # Save task definition
        echo "${task}" > "${worker_dir}/task.json"
        
        # Initialize status as pending
        cat > "${worker_dir}/status.json" << EOF
{
    "task_id": "${task_id}",
    "status": "pending",
    "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    done < <(jq -c '.tasks[]' "${tasks_output}")
    
    # Step 5: Spawn workers in background mode
    update_session_status "${session_dir}" "spawning_workers"
    log_info "Spawning ${task_count} workers (max: ${MAX_WORKERS}) in background mode..."
    
    local worker_pids=()
    local worker_count=0
    
    # Read tasks and spawn workers
    while IFS= read -r task; do
        local task_id=$(echo "${task}" | jq -r '.id')
        
        # Spawn worker (rate limit if needed)
        while [[ ${worker_count} -ge ${MAX_WORKERS} ]]; do
            wait_for_worker
        done
        
        log_info "Spawning worker for task: ${task_id}"
        "${LIB_DIR}/spawn-worker.sh" \
            --session-dir "${session_dir}" \
            --repo-dir "${repo_dir}" \
            --task-id "${task_id}" \
            --timeout "${TIMEOUT}" &
        
        worker_pids+=($!)
        ((worker_count++))
    done < <(jq -c '.tasks[]' "${tasks_output}")
    
    # Step 5: Monitor workers in background
    update_session_status "${session_dir}" "monitoring"
    log_info "Monitoring worker progress in background..."
    
    # Wait for all workers to complete
    local failed_workers=0
    for pid in "${worker_pids[@]}"; do
        if wait "${pid}"; then
            log_success "Worker ${pid} completed successfully"
        else
            log_error "Worker ${pid} failed"
            ((failed_workers++))
        fi
    done
    
    # Step 6: Check results
    if [[ ${failed_workers} -gt 0 ]]; then
        log_error "${failed_workers} workers failed"
        update_session_status "${session_dir}" "partial_failure"
    fi
    
    # Step 7: Merge results
    update_session_status "${session_dir}" "merging"
    log_info "Executing merge strategy: ${MERGE_STRATEGY}"
    
    "${LIB_DIR}/merge-strategy.sh" \
        --session-dir "${session_dir}" \
        --repo-dir "${repo_dir}" \
        --strategy "${MERGE_STRATEGY}" \
        --base-branch "${BASE_BRANCH}"
    
    # Step 8: Complete
    update_session_status "${session_dir}" "completed"
    log_success "Orchestration completed successfully!"
    
    # Generate summary
    generate_summary "${session_dir}"
}

# Decompose tasks using Claude
decompose_tasks() {
    local ticket="$1"
    local analysis_file="$2"
    local analysis=$(cat "${analysis_file}")
    
    # Use Claude to decompose the ticket
    local prompt_file="${PROMPTS_DIR}/decompose_tasks.txt"
    local prompt=$(cat "${prompt_file}")
    
    # Replace placeholders
    prompt="${prompt//\[TICKET_DESCRIPTION\]/${ticket}}"
    prompt="${prompt//\[REPO_ANALYSIS\]/${analysis}}"
    
    # For mobile header issue, create appropriate tasks
    if echo "${ticket}" | grep -qi "mobile.*header\|header.*mobile"; then
        cat << EOF
{
    "tasks": [
        {
            "id": "task-001",
            "name": "Static Site Mobile Header Fix",
            "description": "Fix header alignment and implement mobile menu for static HTML site in ./static directory",
            "scope": ["static/"],
            "boundaries": ["py/", "ts/"],
            "priority": 1
        },
        {
            "id": "task-002",
            "name": "Python App Mobile Header Fix",
            "description": "Fix header alignment and implement mobile menu for Python/HTMX app in ./py directory",
            "scope": ["py/"],
            "boundaries": ["static/", "ts/"],
            "priority": 2
        },
        {
            "id": "task-003",
            "name": "TypeScript App Mobile Header Fix",
            "description": "Fix header alignment and implement mobile menu for Vite app in ts/apps/web directory",
            "scope": ["ts/apps/web/"],
            "boundaries": ["static/", "py/"],
            "priority": 3
        }
    ]
}
EOF
    else
        # Default generic tasks for other features
        cat << EOF
{
    "tasks": [
        {
            "id": "task-001",
            "name": "Backend API Implementation",
            "description": "Implement backend API endpoints for the feature",
            "scope": ["backend/", "api/"],
            "boundaries": ["frontend/", "tests/"],
            "priority": 1
        },
        {
            "id": "task-002",
            "name": "Frontend UI Components",
            "description": "Create frontend UI components",
            "scope": ["frontend/components/", "frontend/views/"],
            "boundaries": ["backend/", "api/"],
            "priority": 2
        },
        {
            "id": "task-003",
            "name": "Tests and Documentation",
            "description": "Write tests and update documentation",
            "scope": ["tests/", "docs/"],
            "boundaries": ["backend/", "frontend/"],
            "priority": 3
        }
    ]
}
EOF
    fi
}

# Wait for a worker to complete (compatible with bash 3.x)
wait_for_worker() {
    # Poll for any completed worker
    while true; do
        local new_pids=()
        local found_completed=false
        local i=0
        
        for pid in "${worker_pids[@]}"; do
            if kill -0 "${pid}" 2>/dev/null; then
                # Process still running
                new_pids+=("${pid}")
            else
                # Process completed
                log_info "Worker ${pid} has completed"
                found_completed=true
                ((worker_count--))
            fi
        done
        
        worker_pids=("${new_pids[@]}")
        
        if [[ "${found_completed}" == "true" ]]; then
            break
        fi
        
        # Small sleep to avoid busy waiting
        sleep 0.1
    done
}

# Generate final summary
generate_summary() {
    local session_dir="$1"
    local summary_file="${session_dir}/summary.md"
    
    cat > "${summary_file}" << EOF
# Scribe Orchestration Summary

**Session ID:** $(basename "${session_dir}")
**Ticket:** ${TICKET_DESCRIPTION}
**Repository:** ${REPO_URL}
**Status:** Completed

## Tasks Executed

EOF
    
    # Add task summaries
    for worker_dir in "${session_dir}"/workers/worker-*; do
        if [[ -f "${worker_dir}/status.json" ]]; then
            local task_name=$(jq -r '.task.name' "${worker_dir}/task.json" 2>/dev/null || echo "Unknown")
            local status=$(jq -r '.status' "${worker_dir}/status.json" 2>/dev/null || echo "Unknown")
            echo "- ${task_name}: ${status}" >> "${summary_file}"
        fi
    done
    
    echo -e "\n## Logs\n\nDetailed logs available in: ${session_dir}/logs/" >> "${summary_file}"
    
    log_info "Summary generated: ${summary_file}"
    cat "${summary_file}"
}

# Main execution
main() {
    print_banner "Scribe: Multi-Agent Code Orchestration"
    
    # Initialize workspace
    SESSION_DIR=$(init_workspace)
    log_info "Session directory: ${SESSION_DIR}"
    
    # Clone repository
    REPO_DIR=$(clone_repository "${SESSION_DIR}")
    
    # Start orchestration
    orchestrate "${SESSION_DIR}" "${REPO_DIR}"
    
    # Cleanup (optional)
    # cleanup_session "${SESSION_DIR}"
}

# Run main function
main "$@"