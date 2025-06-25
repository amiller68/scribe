#!/bin/bash

# Merge strategy implementation for Scribe orchestration system
# Handles integration of parallel worker changes

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Default values
DEFAULT_STRATEGY="single-pr"
DEFAULT_BASE_BRANCH="main"

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Execute merge strategy to integrate worker changes.

OPTIONS:
    --session-dir DIR      Session directory containing worker results
    --repo-dir DIR         Main repository directory
    --strategy TYPE        Merge strategy: single-pr or federated (default: ${DEFAULT_STRATEGY})
    --base-branch NAME     Base branch to merge into (default: ${DEFAULT_BASE_BRANCH})
    -h, --help            Show this help message

Example:
    $0 --session-dir /path/to/session --repo-dir /path/to/repo --strategy single-pr
EOF
    exit 1
}

# Parse arguments
SESSION_DIR=""
REPO_DIR=""
STRATEGY="${DEFAULT_STRATEGY}"
BASE_BRANCH="${DEFAULT_BASE_BRANCH}"

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
        --strategy)
            STRATEGY="$2"
            shift 2
            ;;
        --base-branch)
            BASE_BRANCH="$2"
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
if [[ -z "${SESSION_DIR}" ]] || [[ -z "${REPO_DIR}" ]]; then
    log_error "Missing required arguments"
    usage
fi

# Validate strategy
if [[ "${STRATEGY}" != "single-pr" ]] && [[ "${STRATEGY}" != "federated" ]]; then
    log_error "Invalid strategy: ${STRATEGY}"
    usage
fi

# Get session info
SESSION_CONFIG="${SESSION_DIR}/config.json"
TICKET_DESCRIPTION=$(read_json "${SESSION_CONFIG}" ".ticket_description")
SESSION_ID=$(read_json "${SESSION_CONFIG}" ".session_id")

# Collect worker results
collect_worker_results() {
    local workers_dir="${SESSION_DIR}/workers"
    local completed_workers=()
    local failed_workers=()
    
    log_info "Collecting worker results..."
    
    for worker_dir in "${workers_dir}"/worker-*; do
        if [[ -d "${worker_dir}" ]]; then
            local status_file="${worker_dir}/status.json"
            local task_file="${worker_dir}/task.json"
            
            if [[ -f "${status_file}" ]]; then
                local status=$(read_json "${status_file}" ".status")
                local task_id=$(basename "${worker_dir}" | sed 's/worker-//')
                
                case "${status}" in
                    completed)
                        completed_workers+=("${task_id}")
                        ;;
                    failed|timeout|interrupted)
                        failed_workers+=("${task_id}")
                        ;;
                esac
            fi
        fi
    done
    
    log_info "Completed workers: ${#completed_workers[@]}"
    log_info "Failed workers: ${#failed_workers[@]}"
    
    # Return arrays
    if [[ ${#completed_workers[@]} -gt 0 ]]; then
        echo "${completed_workers[@]}"
    fi
    if [[ ${#failed_workers[@]} -gt 0 ]]; then
        echo "${failed_workers[@]}"
    fi
}

# Execute single PR strategy
execute_single_pr_strategy() {
    local completed_workers=($1)
    
    log_info "Executing single PR strategy..."
    
    # Create integration branch
    local integration_branch="scribe-integration-${SESSION_ID}"
    cd "${REPO_DIR}"
    
    # Ensure we're on the base branch
    git checkout "${BASE_BRANCH}" >/dev/null 2>&1
    git pull origin "${BASE_BRANCH}" >/dev/null 2>&1 || true
    
    # Create integration branch
    git checkout -b "${integration_branch}" >/dev/null 2>&1
    
    # Merge each worker's changes
    local merge_conflicts=0
    local merged_tasks=()
    
    for task_id in "${completed_workers[@]}"; do
        local worker_dir="${SESSION_DIR}/workers/worker-${task_id}"
        local status_file="${worker_dir}/status.json"
        local task_file="${worker_dir}/task.json"
        
        # Get worker info
        local worktree_path=$(read_json "${status_file}" ".worktree_path")
        local branch_name=$(read_json "${status_file}" ".branch")
        local task_name=$(read_json "${task_file}" ".name")
        
        if [[ -z "${worktree_path}" ]] || [[ ! -d "${worktree_path}" ]]; then
            log_warning "Worktree not found for task ${task_id}, skipping"
            continue
        fi
        
        log_info "Merging task ${task_id}: ${task_name}"
        
        # Fetch the branch
        cd "${worktree_path}"
        local has_commits=$(git rev-list --count "HEAD...${BASE_BRANCH}" 2>/dev/null || echo "0")
        
        if [[ ${has_commits} -eq 0 ]]; then
            log_warning "No commits found for task ${task_id}, skipping"
            continue
        fi
        
        # Try to merge
        cd "${REPO_DIR}"
        if git merge --no-ff --no-edit "${branch_name}" >/dev/null 2>&1; then
            log_success "Successfully merged task ${task_id}"
            merged_tasks+=("${task_name}")
        else
            log_error "Merge conflict for task ${task_id}"
            ((merge_conflicts++))
            
            # Try to resolve automatically
            if ! resolve_merge_conflict "${task_id}" "${branch_name}"; then
                git merge --abort >/dev/null 2>&1
                log_error "Could not resolve conflict for task ${task_id}, skipping"
            else
                merged_tasks+=("${task_name}")
            fi
        fi
    done
    
    # Create PR if we have merged tasks
    if [[ ${#merged_tasks[@]} -gt 0 ]]; then
        log_info "Creating pull request..."
        create_single_pr "${integration_branch}" "${merged_tasks[@]}"
    else
        log_error "No tasks were successfully merged"
        return 1
    fi
}

# Execute federated PR strategy
execute_federated_pr_strategy() {
    local completed_workers=($1)
    
    log_info "Executing federated PR strategy..."
    
    local created_prs=()
    local tracking_issue_body="# Scribe Orchestration: ${TICKET_DESCRIPTION}\n\n"
    tracking_issue_body+="This issue tracks the parallel implementation of the feature ticket.\n\n"
    tracking_issue_body+="## Pull Requests\n\n"
    
    for task_id in "${completed_workers[@]}"; do
        local worker_dir="${SESSION_DIR}/workers/worker-${task_id}"
        local status_file="${worker_dir}/status.json"
        local task_file="${worker_dir}/task.json"
        
        # Get worker info
        local worktree_path=$(read_json "${status_file}" ".worktree_path")
        local branch_name=$(read_json "${status_file}" ".branch")
        local task_name=$(read_json "${task_file}" ".name")
        local task_description=$(read_json "${task_file}" ".description")
        
        if [[ -z "${worktree_path}" ]] || [[ ! -d "${worktree_path}" ]]; then
            log_warning "Worktree not found for task ${task_id}, skipping"
            continue
        fi
        
        # Push branch
        cd "${worktree_path}"
        if git push -u origin "${branch_name}" >/dev/null 2>&1; then
            log_success "Pushed branch for task ${task_id}"
            
            # Create PR
            local pr_url=$(create_task_pr "${branch_name}" "${task_name}" "${task_description}")
            if [[ -n "${pr_url}" ]]; then
                created_prs+=("${pr_url}")
                tracking_issue_body+="- [ ] ${task_name}: ${pr_url}\n"
            fi
        else
            log_error "Failed to push branch for task ${task_id}"
        fi
    done
    
    # Create tracking issue
    if [[ ${#created_prs[@]} -gt 0 ]]; then
        create_tracking_issue "${tracking_issue_body}"
    fi
}

# Resolve merge conflicts
resolve_merge_conflict() {
    local task_id="$1"
    local branch_name="$2"
    
    log_info "Attempting to resolve merge conflict for task ${task_id}..."
    
    # Get conflict files
    local conflict_files=($(git diff --name-only --diff-filter=U))
    
    if [[ ${#conflict_files[@]} -eq 0 ]]; then
        return 0
    fi
    
    # Simple resolution strategy: prefer changes from the branch
    for file in "${conflict_files[@]}"; do
        # Check if file exists in branch
        if git show "${branch_name}:${file}" >/dev/null 2>&1; then
            # Use version from branch
            git show "${branch_name}:${file}" > "${file}"
            git add "${file}"
        else
            # File was deleted in branch
            git rm "${file}"
        fi
    done
    
    # Complete the merge
    git commit --no-edit >/dev/null 2>&1
    return 0
}

# Create single PR
create_single_pr() {
    local branch_name="$1"
    shift
    local merged_tasks=("$@")
    
    # Push integration branch
    git push -u origin "${branch_name}" >/dev/null 2>&1
    
    # Generate PR body
    local pr_body="## Summary\n\n"
    pr_body+="This PR implements the following feature: **${TICKET_DESCRIPTION}**\n\n"
    pr_body+="### Implemented Tasks\n\n"
    
    for task in "${merged_tasks[@]}"; do
        pr_body+="- ✅ ${task}\n"
    done
    
    pr_body+="\n### Implementation Details\n\n"
    pr_body+="This PR was created by Scribe, which orchestrated ${#merged_tasks[@]} parallel Claude Code instances.\n"
    pr_body+="Each task was implemented in an isolated Git worktree and then integrated.\n\n"
    pr_body+="Session ID: \`${SESSION_ID}\`\n\n"
    pr_body+="---\n🤖 Generated by Scribe Multi-Agent Orchestration"
    
    # Create PR using gh CLI
    if command_exists "gh"; then
        local pr_url=$(gh pr create \
            --base "${BASE_BRANCH}" \
            --head "${branch_name}" \
            --title "Implement: ${TICKET_DESCRIPTION}" \
            --body "${pr_body}" \
            2>&1 | grep -o 'https://[^ ]*' | head -1)
        
        if [[ -n "${pr_url}" ]]; then
            log_success "Created PR: ${pr_url}"
            echo "${pr_url}" > "${SESSION_DIR}/pr_url.txt"
        else
            log_error "Failed to create PR"
            return 1
        fi
    else
        log_warning "GitHub CLI (gh) not found. Please create PR manually."
        log_info "Branch: ${branch_name}"
    fi
}

# Create individual task PR
create_task_pr() {
    local branch_name="$1"
    local task_name="$2"
    local task_description="$3"
    
    local pr_body="## Summary\n\n"
    pr_body+="${task_description}\n\n"
    pr_body+="This PR is part of the implementation for: **${TICKET_DESCRIPTION}**\n\n"
    pr_body+="### Task Details\n\n"
    pr_body+="- **Task**: ${task_name}\n"
    pr_body+="- **Branch**: ${branch_name}\n"
    pr_body+="- **Session**: ${SESSION_ID}\n\n"
    pr_body+="---\n🤖 Generated by Scribe Multi-Agent Orchestration"
    
    if command_exists "gh"; then
        local pr_url=$(gh pr create \
            --base "${BASE_BRANCH}" \
            --head "${branch_name}" \
            --title "${task_name}" \
            --body "${pr_body}" \
            2>&1 | grep -o 'https://[^ ]*' | head -1)
        
        echo "${pr_url}"
    fi
}

# Create tracking issue
create_tracking_issue() {
    local issue_body="$1"
    
    if command_exists "gh"; then
        local issue_url=$(gh issue create \
            --title "Tracking: ${TICKET_DESCRIPTION}" \
            --body "${issue_body}" \
            2>&1 | grep -o 'https://[^ ]*' | head -1)
        
        if [[ -n "${issue_url}" ]]; then
            log_success "Created tracking issue: ${issue_url}"
            echo "${issue_url}" > "${SESSION_DIR}/tracking_issue_url.txt"
        fi
    fi
}

# Main merge function
main() {
    log_info "Starting merge strategy: ${STRATEGY}"
    
    # Collect worker results
    local results=($(collect_worker_results))
    local num_results=${#results[@]}
    
    # Split results (first half completed, second half failed)
    local mid=$((num_results / 2))
    local completed_workers=("${results[@]:0:${mid}}")
    local failed_workers=("${results[@]:${mid}}")
    
    if [[ ${#completed_workers[@]} -eq 0 ]]; then
        log_error "No completed workers found"
        return 1
    fi
    
    # Execute strategy
    case "${STRATEGY}" in
        single-pr)
            execute_single_pr_strategy "${completed_workers[@]}"
            ;;
        federated)
            execute_federated_pr_strategy "${completed_workers[@]}"
            ;;
    esac
    
    log_success "Merge strategy completed"
}

# Run main function
main "$@"