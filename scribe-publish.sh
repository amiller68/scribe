#!/bin/bash

# Scribe Publish - Create PRs and publish work from completed sessions
# Usage: scribe publish [SESSION_ID]

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
FORCE_PUSH=false
DRAFT_PRS=false
WORKSPACE_DIR="${SCRIPT_DIR}/workspace"

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [SESSION_ID]

Publish completed Scribe sessions by creating branches and pull requests.

OPTIONS:
    --force              Force push even if branches/PRs exist
    --draft              Create draft pull requests
    -h, --help          Show this help message

ARGUMENTS:
    SESSION_ID          Specific session to publish (optional)
                       If not provided, uses the latest completed session

EXAMPLES:
    $0                          # Publish latest completed session
    $0 20250625_131706          # Publish specific session
    $0 --draft                  # Create draft PRs
    $0 --force                  # Force push and recreate PRs

WORKFLOW:
    1. Analyzes session merge strategy (federated vs single-pr)
    2. Creates branches for each completed task
    3. Pushes branches to remote repository
    4. Creates pull requests with detailed descriptions
    5. Links PRs to original GitHub issue
    6. Updates session metadata with PR URLs
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE_PUSH=true
            shift
            ;;
        --draft)
            DRAFT_PRS=true
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
            log_error "Session not found: ${SESSION_ID}"
            exit 1
        fi
        echo "${session_dir}"
    else
        # Find latest completed session
        local latest=""
        for session in $(ls -t "${sessions_dir}" 2>/dev/null); do
            local config_file="${sessions_dir}/${session}/config.json"
            if [[ -f "${config_file}" ]]; then
                local status=$(jq -r '.status' "${config_file}" 2>/dev/null)
                if [[ "${status}" == "completed" ]]; then
                    latest="${session}"
                    break
                fi
            fi
        done
        
        if [[ -z "${latest}" ]]; then
            log_error "No completed sessions found"
            exit 1
        fi
        
        echo "${sessions_dir}/${latest}"
    fi
}

# Get session info
get_session_info() {
    local session_dir="$1"
    local config_file="${session_dir}/config.json"
    
    if [[ ! -f "${config_file}" ]]; then
        log_error "Session config not found: ${config_file}"
        exit 1
    fi
    
    # Extract session details
    SESSION_CONFIG=$(cat "${config_file}")
    MERGE_STRATEGY=$(echo "${SESSION_CONFIG}" | jq -r '.merge_strategy')
    REPO_URL=$(echo "${SESSION_CONFIG}" | jq -r '.repo_url')
    TICKET_DESCRIPTION=$(echo "${SESSION_CONFIG}" | jq -r '.ticket_description')
    BASE_BRANCH=$(echo "${SESSION_CONFIG}" | jq -r '.base_branch // "main"')
    
    log_info "Session: $(basename "${session_dir}")"
    log_info "Repository: ${REPO_URL}"
    log_info "Merge strategy: ${MERGE_STRATEGY}"
    log_info "Base branch: ${BASE_BRANCH}"
}

# Extract repository info
extract_repo_info() {
    local url="$1"
    echo "${url}" | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?.*|\1|'
}

# Get completed tasks
get_completed_tasks() {
    local session_dir="$1"
    local workers_dir="${session_dir}/workers"
    local completed_tasks=()
    
    if [[ ! -d "${workers_dir}" ]]; then
        log_warning "No workers directory found"
        return
    fi
    
    for worker_dir in "${workers_dir}"/worker-*; do
        if [[ -d "${worker_dir}" ]]; then
            local status_file="${worker_dir}/status.json"
            local task_file="${worker_dir}/task.json"
            
            if [[ -f "${status_file}" && -f "${task_file}" ]]; then
                local status=$(jq -r '.status' "${status_file}")
                if [[ "${status}" == "completed" ]]; then
                    local task_id=$(jq -r '.id' "${task_file}")
                    completed_tasks+=("${task_id}")
                fi
            fi
        fi
    done
    
    echo "${completed_tasks[@]}"
}

# Check if worktree has commits
worktree_has_commits() {
    local worktree_path="$1"
    local base_branch="$2"
    
    cd "${worktree_path}"
    
    # Check if there are commits ahead of base branch
    local current_branch=$(git branch --show-current)
    local commit_count=$(git rev-list --count "${base_branch}..${current_branch}" 2>/dev/null || echo "0")
    
    [[ ${commit_count} -gt 0 ]]
}

# Create and push branch for task
push_task_branch() {
    local session_dir="$1"
    local task_id="$2"
    local base_branch="$3"
    
    # Find worktree path
    local worktree_pattern="${session_dir}/repo/../worktrees/*${task_id}*"
    local worktree_path=$(ls -d ${worktree_pattern} 2>/dev/null | head -1)
    
    if [[ ! -d "${worktree_path}" ]]; then
        log_error "Worktree not found for task: ${task_id}"
        return 1
    fi
    
    cd "${worktree_path}"
    
    # Check if worktree has commits
    if ! worktree_has_commits "${worktree_path}" "${base_branch}"; then
        log_warning "No commits found in worktree for task: ${task_id}"
        return 1
    fi
    
    local current_branch=$(git branch --show-current)
    log_info "Pushing branch: ${current_branch}"
    
    # Push branch to remote
    if [[ "${FORCE_PUSH}" == true ]]; then
        git push origin "${current_branch}" --force
    else
        git push origin "${current_branch}"
    fi
    
    echo "${current_branch}"
}

# Create pull request
create_pull_request() {
    local repo_info="$1"
    local branch_name="$2"
    local task_id="$3"
    local session_dir="$4"
    local base_branch="$5"
    
    # Get task details
    local task_file="${session_dir}/workers/worker-${task_id}/task.json"
    local task_name=$(jq -r '.name' "${task_file}" 2>/dev/null || echo "Task ${task_id}")
    local task_description=$(jq -r '.description' "${task_file}" 2>/dev/null || echo "")
    
    # Create PR title and body
    local pr_title="${task_name}"
    local pr_body="$(cat << EOF
## ${task_name}

${task_description}

**Original Issue:**
${TICKET_DESCRIPTION}

**Implementation Details:**
- Task ID: ${task_id}
- Base Branch: ${base_branch}
- Merge Strategy: ${MERGE_STRATEGY}

**Generated by Scribe Multi-Agent System**
- Session: $(basename "${session_dir}")
- Worker: ${task_id}

---
🤖 This pull request was created automatically by [Scribe](https://github.com/your-org/scribe)
EOF
)"
    
    # Create PR using GitHub CLI
    local pr_flags=""
    if [[ "${DRAFT_PRS}" == true ]]; then
        pr_flags="--draft"
    fi
    
    log_info "Creating pull request for ${task_name}..."
    
    local pr_url=$(gh pr create \
        --repo "${repo_info}" \
        --base "${base_branch}" \
        --head "${branch_name}" \
        --title "${pr_title}" \
        --body "${pr_body}" \
        ${pr_flags} 2>/dev/null || echo "")
    
    if [[ -n "${pr_url}" ]]; then
        log_success "Created PR: ${pr_url}"
        echo "${pr_url}"
    else
        log_error "Failed to create PR for ${task_name}"
        return 1
    fi
}

# Link PR to original issue
link_pr_to_issue() {
    local repo_info="$1"
    local pr_url="$2"
    local issue_number="$3"
    
    if [[ -n "${issue_number}" && "${issue_number}" != "null" ]]; then
        log_info "Linking PR to issue #${issue_number}..."
        
        local comment_body="🤖 **Scribe Implementation**

I've created a pull request to address this issue: ${pr_url}

The implementation was generated using the Scribe multi-agent system based on the requirements in this issue."
        
        gh issue comment "${issue_number}" \
            --repo "${repo_info}" \
            --body "${comment_body}" 2>/dev/null || {
            log_warning "Could not link PR to issue #${issue_number}"
        }
    fi
}

# Resolve merge conflicts automatically
resolve_merge_conflicts() {
    # Get files with conflicts
    local conflict_files=($(git diff --name-only --diff-filter=U))
    
    if [[ ${#conflict_files[@]} -eq 0 ]]; then
        return 0
    fi
    
    log_info "Attempting to auto-resolve ${#conflict_files[@]} conflicts..."
    
    # Simple strategy: accept incoming changes
    for file in "${conflict_files[@]}"; do
        # Try to use theirs strategy
        if git checkout --theirs "${file}" 2>/dev/null; then
            git add "${file}"
        else
            # File might be deleted, try to remove it
            git rm "${file}" 2>/dev/null || return 1
        fi
    done
    
    # Continue cherry-pick
    git cherry-pick --continue --no-edit >/dev/null 2>&1
    return $?
}

# Create PR body for single-pr strategy
create_single_pr_body() {
    local session_dir="$1"
    shift
    local merged_tasks=("$@")
    
    cat << EOF
## Summary

This pull request implements the following feature:
**${TICKET_DESCRIPTION}**

### Implemented Tasks

$(for task in "${merged_tasks[@]}"; do echo "- ✅ ${task}"; done)

### Implementation Details

This PR was created by the Scribe multi-agent orchestration system, which:
- Analyzed the codebase and decomposed the feature into ${#merged_tasks[@]} parallel tasks
- Spawned ${#merged_tasks[@]} Claude Code instances to implement each task independently
- Merged all implementations into this single PR

Each task was implemented in an isolated Git worktree to enable true parallel development.

### Session Information
- **Session ID**: $(basename "${session_dir}")
- **Strategy**: Single PR (all changes combined)
- **Base Branch**: ${BASE_BRANCH}

### Testing

Please review and test all changes thoroughly, as they were implemented by AI agents.

---
🤖 Generated by [Scribe Multi-Agent System](https://github.com/your-org/scribe)
EOF
}

# Save PR URLs to session
save_pr_urls() {
    local session_dir="$1"
    shift
    local pr_urls=("$@")
    
    local pr_file="${session_dir}/pull_requests.json"
    
    # Create PR metadata
    local pr_data="[]"
    for pr_url in "${pr_urls[@]}"; do
        pr_data=$(echo "${pr_data}" | jq ". + [\"${pr_url}\"]")
    done
    
    echo "${pr_data}" > "${pr_file}"
    log_info "Saved PR URLs to: ${pr_file}"
}

# Main publish function
main() {
    print_banner "Scribe Publish - Create Pull Requests"
    
    # Check dependencies
    if ! command_exists "gh"; then
        log_error "GitHub CLI (gh) is required. Please install it first."
        exit 1
    fi
    
    # Check gh auth
    if ! gh auth status >/dev/null 2>&1; then
        log_error "Please authenticate with GitHub CLI first: gh auth login"
        exit 1
    fi
    
    # Find and validate session
    local session_dir=$(find_session)
    log_info "Publishing session: $(basename "${session_dir}")"
    
    # Get session information
    get_session_info "${session_dir}"
    
    # Extract repository info
    local repo_info=$(extract_repo_info "${REPO_URL}")
    
    # Get completed tasks
    local completed_tasks=($(get_completed_tasks "${session_dir}"))
    
    if [[ ${#completed_tasks[@]} -eq 0 ]]; then
        log_error "No completed tasks found in session"
        exit 1
    fi
    
    log_info "Found ${#completed_tasks[@]} completed tasks: ${completed_tasks[*]}"
    
    # Create branches and PRs based on merge strategy
    local pr_urls=()
    
    if [[ "${MERGE_STRATEGY}" == "federated" ]]; then
        log_info "Using federated strategy - creating separate PRs for each task"
        
        for task_id in "${completed_tasks[@]}"; do
            log_info "Processing task: ${task_id}"
            
            # Push branch for task
            if branch_name=$(push_task_branch "${session_dir}" "${task_id}" "${BASE_BRANCH}"); then
                # Create PR for task
                if pr_url=$(create_pull_request "${repo_info}" "${branch_name}" "${task_id}" "${session_dir}" "${BASE_BRANCH}"); then
                    pr_urls+=("${pr_url}")
                    
                    # Extract issue number from ticket description if available
                    local issue_number=$(echo "${TICKET_DESCRIPTION}" | grep -oE "Issue #([0-9]+)" | grep -oE "[0-9]+" | head -1)
                    if [[ -n "${issue_number}" ]]; then
                        link_pr_to_issue "${repo_info}" "${pr_url}" "${issue_number}"
                    fi
                fi
            fi
        done
        
    else
        log_info "Using single-pr strategy - creating one combined PR"
        
        # Create integration branch
        local integration_branch="scribe-integration-$(basename "${session_dir}")"
        local repo_path="${session_dir}/repo"
        
        cd "${repo_path}"
        
        # Fetch all remote branches first
        git fetch origin >/dev/null 2>&1 || true
        
        # Ensure we're on the latest base branch
        git checkout "${BASE_BRANCH}" >/dev/null 2>&1
        git pull origin "${BASE_BRANCH}" >/dev/null 2>&1 || true
        
        # Check if integration branch exists and has same content
        local branch_exists=false
        local needs_update=false
        
        if git rev-parse --verify "${integration_branch}" >/dev/null 2>&1; then
            branch_exists=true
            
            # Check if branch is already up-to-date
            git checkout "${integration_branch}" >/dev/null 2>&1
            
            # Check current state first before deciding what to do
            local new_commits=0
            
            # See if our branch already has all the task commits
            local has_all_changes=true
            for task_id in "${completed_tasks[@]}"; do
                local task_file="${session_dir}/workers/worker-${task_id}/task.json"
                local task_name=$(jq -r '.name' "${task_file}" 2>/dev/null || echo "Task ${task_id}")
                
                # Check if a commit with this task name exists in the branch
                if ! git log --oneline --grep="Fix: ${task_name}" | grep -q "Fix: ${task_name}"; then
                    has_all_changes=false
                    new_commits=$((new_commits + 1))
                fi
            done
            
            if [[ "${has_all_changes}" == true ]]; then
                log_info "Integration branch already contains all task commits"
                new_commits=0
                
                # Make sure we're in sync with remote
                if git fetch origin "${integration_branch}" >/dev/null 2>&1; then
                    git pull origin "${integration_branch}" --ff-only >/dev/null 2>&1 || true
                fi
            else
                log_info "Found ${new_commits} new commits to merge"
            fi
            
            if [[ ${new_commits} -eq 0 ]]; then
                log_info "Integration branch is already up-to-date"
                
                # Check if PR exists
                local existing_pr=$(gh pr list --repo "${repo_info}" --head "${integration_branch}" --json url --jq '.[0].url' 2>/dev/null || echo "")
                if [[ -n "${existing_pr}" ]]; then
                    log_info "Pull request already exists: ${existing_pr}"
                    echo -e "\n${GREEN}Session already published!${RESET}"
                    echo -e "PR: ${CYAN}${existing_pr}${RESET}"
                    exit 0
                else
                    log_info "No PR exists yet, continuing to create one..."
                fi
            else
                needs_update=true
                log_info "Found ${new_commits} new commits to merge"
            fi
        fi
        
        # Handle branch creation/recreation
        if [[ "${branch_exists}" == true ]]; then
            if [[ "${needs_update}" == true ]] || [[ "${FORCE_PUSH}" == true ]]; then
                if [[ "${FORCE_PUSH}" == true ]]; then
                    log_info "Recreating integration branch due to --force flag"
                else
                    log_info "Updating integration branch with new commits"
                fi
                git checkout "${BASE_BRANCH}" >/dev/null 2>&1
                git branch -D "${integration_branch}" >/dev/null 2>&1
                git checkout -b "${integration_branch}" >/dev/null 2>&1
            else
                # Already on integration branch and it's up-to-date
                log_info "Using existing integration branch"
            fi
        else
            git checkout -b "${integration_branch}" >/dev/null 2>&1
        fi
        
        # Only merge if we need updates
        local merged_tasks=()
        local failed_merges=()
        local total_commits=0
        
        if [[ "${needs_update}" == true ]] || [[ "${branch_exists}" == false ]] || [[ "${FORCE_PUSH}" == true ]]; then
            # Merge each completed task
            for task_id in "${completed_tasks[@]}"; do
            log_info "Processing task: ${task_id}"
            
            # Find task worktree
            local worktree_pattern="${session_dir}/repo/../worktrees/*${task_id}*"
            local worktree_path=$(ls -d ${worktree_pattern} 2>/dev/null | head -1)
            
            if [[ ! -d "${worktree_path}" ]]; then
                log_warning "Worktree not found for task: ${task_id}"
                failed_merges+=("${task_id}")
                continue
            fi
            
            # Get task details
            local task_file="${session_dir}/workers/worker-${task_id}/task.json"
            local task_name=$(jq -r '.name' "${task_file}" 2>/dev/null || echo "Task ${task_id}")
            
            # Get branch name from worktree
            cd "${worktree_path}"
            local task_branch=$(git branch --show-current)
            local task_commits=$(git rev-list --count "${BASE_BRANCH}..HEAD" 2>/dev/null || echo "0")
            
            if [[ ${task_commits} -eq 0 ]]; then
                log_warning "No commits found for task: ${task_id}"
                failed_merges+=("${task_id}")
                continue
            fi
            
            # Go back to main repo and try to merge
            cd "${repo_path}"
            log_info "Merging ${task_commits} commits from ${task_branch}..."
            
            # Try to cherry-pick commits to avoid merge conflicts
            local merge_success=false
            local commits_to_merge=$(cd "${worktree_path}" && git rev-list --reverse "${BASE_BRANCH}..HEAD")
            
            for commit in ${commits_to_merge}; do
                if git cherry-pick "${commit}" >/dev/null 2>&1; then
                    merge_success=true
                else
                    # Try to resolve conflicts automatically
                    if ! resolve_merge_conflicts; then
                        log_warning "Could not cherry-pick commit ${commit}"
                        git cherry-pick --abort >/dev/null 2>&1
                        break
                    fi
                fi
            done
            
            if [[ "${merge_success}" == true ]]; then
                merged_tasks+=("${task_name}")
                total_commits=$((total_commits + task_commits))
                log_success "Successfully integrated task: ${task_id}"
            else
                failed_merges+=("${task_id}")
                log_error "Failed to integrate task: ${task_id}"
            fi
            done
            
            # Check if we have any successful merges
            if [[ ${#merged_tasks[@]} -eq 0 ]]; then
                log_error "No tasks were successfully merged"
                git checkout "${BASE_BRANCH}" >/dev/null 2>&1
                git branch -D "${integration_branch}" >/dev/null 2>&1
                exit 1
            fi
        else
            # Branch is up-to-date, just get task names for PR body
            for task_id in "${completed_tasks[@]}"; do
                local task_file="${session_dir}/workers/worker-${task_id}/task.json"
                local task_name=$(jq -r '.name' "${task_file}" 2>/dev/null || echo "Task ${task_id}")
                merged_tasks+=("${task_name}")
            done
        fi
        
        # Push the integration branch if needed
        if [[ "${needs_update}" == true ]] || [[ "${branch_exists}" == false ]] || [[ "${FORCE_PUSH}" == true ]]; then
            log_info "Pushing integration branch..."
            
            # Check if we need to force push
            local push_flags=""
            if git ls-remote --heads origin "${integration_branch}" >/dev/null 2>&1; then
                # Remote branch exists, check if content is the same
                git fetch origin "${integration_branch}" 2>/dev/null || true
                
                # Compare tree objects (actual content) rather than commits
                local local_tree=$(git rev-parse HEAD^{tree})
                local remote_tree=$(git rev-parse "origin/${integration_branch}^{tree}" 2>/dev/null || echo "")
                
                if [[ "${local_tree}" == "${remote_tree}" ]]; then
                    log_info "Integration branch content matches remote, no push needed"
                    # Skip the push entirely
                    needs_update=false
                elif ! git merge-base --is-ancestor "origin/${integration_branch}" HEAD 2>/dev/null; then
                    # Content differs and history diverged
                    push_flags="--force-with-lease"
                    log_info "Branch has diverged, will force push with lease"
                fi
            fi
            
            if [[ "${needs_update}" == true ]]; then
                if git push origin "${integration_branch}" ${push_flags} 2>&1; then
                    log_success "Pushed integration branch"
                else
                    log_error "Failed to push integration branch"
                    exit 1
                fi
            fi
        else
            log_info "Integration branch already up-to-date on remote"
        fi
        
        # Create the combined PR
        local pr_body="$(create_single_pr_body "${session_dir}" "${merged_tasks[@]}")"
        
        log_info "Creating combined pull request..."
        local pr_flags=""
        if [[ "${DRAFT_PRS}" == true ]]; then
            pr_flags="--draft"
        fi
        
        # Check if PR already exists
        local existing_pr=$(gh pr list --repo "${repo_info}" --head "${integration_branch}" --json url --jq '.[0].url' 2>/dev/null || echo "")
        
        if [[ -n "${existing_pr}" ]]; then
            log_info "Pull request already exists: ${existing_pr}"
            pr_url="${existing_pr}"
            
            # Update PR body if forced or if there were changes
            if [[ "${FORCE_PUSH}" == true ]] || [[ "${needs_update}" == true ]]; then
                log_info "Updating PR description..."
                gh pr edit "${existing_pr}" --repo "${repo_info}" --body "${pr_body}" >/dev/null 2>&1 || true
            fi
        else
            # Create new PR
            local pr_url=$(gh pr create \
                --repo "${repo_info}" \
                --base "${BASE_BRANCH}" \
                --head "${integration_branch}" \
                --title "Implement: ${TICKET_DESCRIPTION%%$'\n'*}" \
                --body "${pr_body}" \
                ${pr_flags} 2>&1)
            
            # Extract URL from output
            pr_url=$(echo "${pr_url}" | grep -o 'https://[^ ]*' | head -1 || echo "")
        fi
        
        if [[ -n "${pr_url}" ]]; then
            pr_urls+=("${pr_url}")
            if [[ -n "${existing_pr}" ]]; then
                log_success "Using existing PR: ${pr_url}"
            else
                log_success "Created combined PR: ${pr_url}"
            fi
            
            # Link to issue if available
            local issue_number=$(echo "${TICKET_DESCRIPTION}" | grep -oE "Issue #([0-9]+)" | grep -oE "[0-9]+" | head -1)
            if [[ -n "${issue_number}" ]]; then
                link_pr_to_issue "${repo_info}" "${pr_url}" "${issue_number}"
            fi
            
            # Log summary
            log_info "Summary:"
            log_info "- Merged ${#merged_tasks[@]} tasks"
            log_info "- Total commits: ${total_commits}"
            if [[ ${#failed_merges[@]} -gt 0 ]]; then
                log_warning "- Failed to merge ${#failed_merges[@]} tasks: ${failed_merges[*]}"
            fi
        else
            log_error "Failed to create combined PR"
            exit 1
        fi
    fi
    
    # Save PR URLs
    if [[ ${#pr_urls[@]} -gt 0 ]]; then
        save_pr_urls "${session_dir}" "${pr_urls[@]}"
        
        echo -e "\n${GREEN}${BOLD}Successfully published session!${RESET}"
        echo -e "${BOLD}Created ${#pr_urls[@]} pull request(s):${RESET}"
        for pr_url in "${pr_urls[@]}"; do
            echo -e "  ${CYAN}${pr_url}${RESET}"
        done
        
        echo -e "\n${YELLOW}Next steps:${RESET}"
        echo "1. Review the pull requests"
        echo "2. Address any feedback using: scribe review [PR_URL]"
        echo "3. Merge when approved"
    else
        log_error "No pull requests were created"
        exit 1
    fi
}

# Run main function
main "$@"