#!/bin/bash

# Scribe Review - Address PR feedback and iterate on implementations
# Usage: scribe review [PR_URL|SESSION_ID]

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
TARGET=""
AUTO_FIX=false
WORKSPACE_DIR="${SCRIPT_DIR}/workspace"

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [PR_URL|SESSION_ID]

Address review feedback and iterate on pull request implementations.

OPTIONS:
    --auto              Automatically address simple feedback
    -h, --help         Show this help message

ARGUMENTS:
    PR_URL             GitHub PR URL to review and iterate on
    SESSION_ID         Session ID to review all PRs from that session
                      If not provided, uses the latest session with PRs

EXAMPLES:
    $0                                    # Review latest session PRs
    $0 https://github.com/org/repo/pull/123  # Review specific PR
    $0 20250625_131706                    # Review all PRs from session
    $0 --auto                            # Auto-fix simple issues

WORKFLOW:
    1. Fetches PR comments and review feedback from GitHub
    2. Analyzes feedback and categorizes by complexity
    3. Creates tasks for addressing each piece of feedback
    4. Spawns workers to implement changes
    5. Updates PRs with new commits
    6. Responds to reviewers with status updates

FEEDBACK TYPES:
    - Simple: Typos, formatting, small changes (auto-fixable)
    - Complex: Logic changes, new features (requires worker session)
    - Questions: Requests for clarification (prompts for response)
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto)
            AUTO_FIX=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "${TARGET}" ]]; then
                TARGET="$1"
            else
                log_error "Unknown option: $1"
                usage
            fi
            shift
            ;;
    esac
done

# Check if target is a PR URL
is_pr_url() {
    [[ "$1" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]
}

# Extract PR info from URL
extract_pr_info() {
    local pr_url="$1"
    local repo=$(echo "${pr_url}" | sed -E 's|https://github\.com/([^/]+/[^/]+)/pull/[0-9]+|\1|')
    local pr_number=$(echo "${pr_url}" | sed -E 's|.*pull/([0-9]+)|\1|')
    
    echo "${repo}:${pr_number}"
}

# Find session with PRs
find_session_with_prs() {
    local sessions_dir="${WORKSPACE_DIR}/sessions"
    
    if [[ ! -d "${sessions_dir}" ]]; then
        log_error "No sessions directory found"
        exit 1
    fi
    
    # Find latest session with PRs
    for session in $(ls -t "${sessions_dir}" 2>/dev/null); do
        local pr_file="${sessions_dir}/${session}/pull_requests.json"
        if [[ -f "${pr_file}" ]]; then
            # Check if PR actually exists
            local pr_count=$(jq 'length' "${pr_file}" 2>/dev/null || echo "0")
            if [[ ${pr_count} -gt 0 ]]; then
                echo "${sessions_dir}/${session}"
                return
            fi
        fi
    done
    
    log_error "No sessions with pull requests found"
    exit 1
}

# Get PR comments and reviews
fetch_pr_feedback() {
    local repo="$1"
    local pr_number="$2"
    local output_file="$3"
    
    log_info "Fetching feedback for PR #${pr_number} in ${repo}..."
    
    # Create feedback structure
    local feedback_json=$(cat << EOF
{
    "pr_url": "https://github.com/${repo}/pull/${pr_number}",
    "repo": "${repo}",
    "pr_number": ${pr_number},
    "comments": [],
    "reviews": [],
    "tasks": []
}
EOF
)
    
    # Get PR comments
    local pr_comments=$(gh api "repos/${repo}/issues/${pr_number}/comments" 2>/dev/null || echo "[]")
    
    # Get review comments (comments on specific code lines)
    local review_comments=$(gh api "repos/${repo}/pulls/${pr_number}/comments" 2>/dev/null || echo "[]")
    
    # Get reviews
    local reviews=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" 2>/dev/null || echo "[]")
    
    # Combine all feedback
    feedback_json=$(echo "${feedback_json}" | jq \
        --argjson pr_comments "${pr_comments}" \
        --argjson review_comments "${review_comments}" \
        --argjson reviews "${reviews}" \
        '.comments = ($pr_comments + $review_comments) | .reviews = $reviews')
    
    # Save to file
    echo "${feedback_json}" > "${output_file}"
    
    # Display summary
    local comment_count=$(echo "${feedback_json}" | jq '.comments | length')
    local review_count=$(echo "${feedback_json}" | jq '.reviews | length')
    
    log_info "Found ${comment_count} comments and ${review_count} reviews"
    
    # Show recent feedback
    if [[ ${comment_count} -gt 0 ]]; then
        echo -e "\n${BOLD}Recent Comments:${RESET}"
        echo "${feedback_json}" | jq -r '.comments[-3:] | reverse | .[] | "- \(.user.login): \(.body | split("\n")[0])"'
    fi
    
    if [[ ${review_count} -gt 0 ]]; then
        echo -e "\n${BOLD}Review Status:${RESET}"
        echo "${feedback_json}" | jq -r '.reviews | group_by(.state) | .[] | "- \(.[0].state): \(length) review(s)"'
    fi
}

# Categorize feedback
categorize_feedback() {
    local feedback="$1"
    
    # Simple heuristics for categorization
    if echo "${feedback}" | grep -qiE "(typo|spelling|format|whitespace|indent)"; then
        echo "simple"
    elif echo "${feedback}" | grep -qiE "(why|how|what|explain|clarify)"; then
        echo "question"
    else
        echo "complex"
    fi
}

# Spawn workers for review tasks
spawn_review_workers() {
    local review_dir="$1"
    local repo="$2"
    local branch="$3"
    local pr_number="$4"
    local pr_files="$5"
    
    log_info "Spawning workers to address feedback..."
    
    # Clone or fetch the repository
    local repo_dir="${review_dir}/repo"
    if [[ -d "${repo_dir}" ]]; then
        cd "${repo_dir}"
        git fetch origin
    else
        # Use gh to clone which handles authentication properly
        gh repo clone "${repo}" "${repo_dir}"
        cd "${repo_dir}"
    fi
    
    # Checkout the PR branch
    git checkout "${branch}"
    git pull origin "${branch}"
    
    # Read tasks
    local tasks_file="${review_dir}/tasks.json"
    local task_count=$(jq 'length' "${tasks_file}")
    
    if [[ ${task_count} -eq 0 ]]; then
        log_warning "No tasks to process"
        return
    fi
    
    # Process each task
    local task_index=0
    while IFS= read -r task; do
        if [[ -z "${task}" ]]; then continue; fi
        
        local task_id=$(echo "${task}" | jq -r '.id')
        local description=$(echo "${task}" | jq -r '.description')
        local author=$(echo "${task}" | jq -r '.author')
        local path=$(echo "${task}" | jq -r '.path // ""')
        local line=$(echo "${task}" | jq -r '.line // ""')
        local context=$(echo "${task}" | jq -r '.context // ""')
        local url=$(echo "${task}" | jq -r '.url // ""')
        
        log_info "Processing task ${task_id} from ${author}"
        if [[ -n "${context}" ]] && [[ "${context}" != "null" ]]; then
            log_info "Context: ${context}"
        fi
        
        # Create worker directory
        local worker_dir="${review_dir}/workers/${task_id}"
        mkdir -p "${worker_dir}"
        
        # Save task
        echo "${task}" > "${worker_dir}/task.json"
        
        # Build comprehensive file context for prompt
        local file_context=""
        local code_context=""
        local pr_files_context=""
        
        if [[ -n "${path}" ]] && [[ "${path}" != "null" ]] && [[ "${path}" != "" ]]; then
            file_context="FILE: ${path}"
            if [[ -n "${line}" ]] && [[ "${line}" != "null" ]] && [[ "${line}" != "" ]]; then
                file_context="${file_context} (Line ${line})"
                
                # Try to get actual code context around the line
                if [[ -f "${repo_dir}/${path}" ]]; then
                    local start_line=$((line - 3))
                    local end_line=$((line + 3))
                    if [[ ${start_line} -lt 1 ]]; then start_line=1; fi
                    
                    code_context=$(sed -n "${start_line},${end_line}p" "${repo_dir}/${path}" 2>/dev/null | nl -v${start_line} | sed "s/^[[:space:]]*${line}[[:space:]]/>>> ${line} /" || echo "Could not read file context")
                fi
            fi
        else
            file_context="GENERAL PR COMMENT (applies to overall changes)"
            # For general comments, show all files in the PR
            if [[ -n "${pr_files}" ]]; then
                pr_files_context=$(echo "${pr_files}" | head -20 | sed 's/^/  - /')
                if [[ $(echo "${pr_files}" | wc -l) -gt 20 ]]; then
                    pr_files_context="${pr_files_context}
  ... and $(($(echo "${pr_files}" | wc -l) - 20)) more files"
                fi
            fi
        fi
        
        # Create prompt for Claude
        cat > "${worker_dir}/prompt.txt" << EOF
You are addressing code review feedback on a pull request.

Repository: ${repo}
Branch: ${branch}
Working Directory: ${repo_dir}

REVIEW FEEDBACK FROM ${author}:
${description}

COMMENT LOCATION:
${file_context}
$(if [[ -n "${code_context}" ]]; then
    echo ""
    echo "CODE CONTEXT (showing lines around the comment):"
    echo "${code_context}"
fi)
$(if [[ -n "${pr_files_context}" ]]; then
    echo ""
    echo "FILES CHANGED IN THIS PR:"
    echo "${pr_files_context}"
fi)

Comment URL: ${url}

INSTRUCTIONS:
1. **Understand the feedback**: Read the comment carefully and determine what changes are needed
$(if [[ -n "${path}" ]] && [[ "${path}" != "null" ]]; then
    echo "2. **Focus on ${path}**: This comment is specifically about this file"
    if [[ -n "${line}" ]] && [[ "${line}" != "null" ]]; then
        echo "   - The comment refers to around line ${line}"
        echo "   - Look at the code context shown above to understand what needs to change"
    fi
else
    echo "2. **General PR feedback**: This comment applies to the overall changes in the PR"
    echo "   - Consider all files listed above as potentially needing changes"
    echo "   - The feedback might affect multiple files or the overall approach"
fi)
3. **Make the changes**: Use the Edit tool to modify the appropriate files
4. **Test your changes**: Make sure the changes work and don't break anything
5. **Commit your work**: Create a git commit with a clear message

IMPORTANT NOTES:
- Use the Edit tool to make actual file changes
- Create a git commit when you're done
- Commit message should reference addressing review feedback from ${author}
- If unsure which file to edit, examine the files mentioned in the feedback first
- Focus on exactly what the reviewer is asking for

Start by examining the relevant file(s) to understand the current implementation.
EOF
        
        # Spawn Claude Code worker
        log_info "Spawning Claude Code to address: ${description:0:60}..."
        
        (
            cd "${repo_dir}"
            claude --print --dangerously-skip-permissions --max-turns 20 \
                < "${worker_dir}/prompt.txt" \
                > "${worker_dir}/output.log" 2>&1
        ) &
        
        local worker_pid=$!
        echo "${worker_pid}" > "${worker_dir}/pid"
        
        # Update task status
        echo "${task}" | jq '.status = "in_progress"' > "${worker_dir}/task.json"
        
        ((task_index++))
        
        # Rate limit if processing multiple tasks
        if [[ ${task_index} -lt ${task_count} ]]; then
            sleep 2
        fi
    done < <(jq -c '.[]' "${tasks_file}")
    
    # Wait for all workers to complete
    log_info "Waiting for workers to complete..."
    wait
    
    # Check results and push changes
    cd "${repo_dir}"
    if [[ -n "$(git status --porcelain)" ]]; then
        log_warning "Uncommitted changes found, committing them..."
        git add -A
        git commit -m "Address remaining review feedback"
    fi
    
    # Push all changes
    if [[ -n "$(git log origin/${branch}..HEAD)" ]]; then
        log_info "Pushing updates to PR..."
        # Use git push, but first ensure we have proper credentials
        if ! git push origin "${branch}" 2>/dev/null; then
            log_warning "Git push failed, trying to configure credentials..."
            # Set up git credential helper to use gh
            git config credential.helper ""
            git config credential.https://github.com.helper '!gh auth git-credential'
            git push origin "${branch}"
        fi
        log_success "Review feedback addressed and pushed!"
        
        # Post comment on PR
        gh pr comment "${pr_number}" --repo "${repo}" --body "🤖 I've addressed the review feedback in the latest commits. Please review the changes."
    else
        log_warning "No changes were made"
    fi
}

# Extract feedback into tasks
extract_feedback_tasks() {
    local feedback_file="$1"
    local tasks_file="$2"
    
    log_info "Analyzing feedback and creating tasks..."
    
    # Extract actionable items from comments
    local tasks="[]"
    
    # Process each comment
    local comments=$(jq -c '.comments[]' "${feedback_file}")
    while IFS= read -r comment; do
        if [[ -z "${comment}" ]]; then continue; fi
        
        local body=$(echo "${comment}" | jq -r '.body')
        local user=$(echo "${comment}" | jq -r '.user.login')
        local created_at=$(echo "${comment}" | jq -r '.created_at')
        local path=$(echo "${comment}" | jq -r '.path // ""')
        local line=$(echo "${comment}" | jq -r '.line // .original_line // ""')
        local html_url=$(echo "${comment}" | jq -r '.html_url // ""')
        
        # Skip empty comments
        if [[ -z "${body}" ]] || [[ "${body}" == "null" ]]; then continue; fi
        
        # Build context string
        local context=""
        if [[ -n "${path}" ]] && [[ "${path}" != "null" ]]; then
            context="File: ${path}"
            if [[ -n "${line}" ]] && [[ "${line}" != "null" ]] && [[ "${line}" != "" ]]; then
                context="${context}, Line: ${line}"
            fi
        fi
        
        # Create task for each substantive comment
        local task=$(jq -n \
            --arg id "review-$(date +%s)-$(generate_id 4)" \
            --arg description "${body}" \
            --arg author "${user}" \
            --arg type "comment" \
            --arg created_at "${created_at}" \
            --arg context "${context}" \
            --arg path "${path}" \
            --arg line "${line}" \
            --arg url "${html_url}" \
            '{
                id: $id,
                type: $type,
                author: $author,
                description: $description,
                created_at: $created_at,
                context: $context,
                path: $path,
                line: $line,
                url: $url,
                status: "pending"
            }')
        
        tasks=$(echo "${tasks}" | jq ". + [${task}]")
    done <<< "${comments}"
    
    # Save tasks
    echo "${tasks}" > "${tasks_file}"
    
    local task_count=$(echo "${tasks}" | jq 'length')
    log_info "Created ${task_count} tasks from feedback"
}

# Process PR feedback
process_pr() {
    local pr_url="$1"
    local pr_info=$(extract_pr_info "${pr_url}")
    local repo=$(echo "${pr_info}" | cut -d: -f1)
    local pr_number=$(echo "${pr_info}" | cut -d: -f2)
    
    log_info "Processing PR: ${pr_url}"
    log_info "Repository: ${repo}"
    log_info "PR Number: ${pr_number}"
    
    # Create review session directory
    local review_session_id="review-$(date +%Y%m%d_%H%M%S)-${pr_number}"
    local review_dir="${WORKSPACE_DIR}/reviews/${review_session_id}"
    mkdir -p "${review_dir}"
    
    # Fetch feedback
    local feedback_file="${review_dir}/feedback.json"
    fetch_pr_feedback "${repo}" "${pr_number}" "${feedback_file}"
    
    # Extract tasks from feedback
    local tasks_file="${review_dir}/tasks.json"
    extract_feedback_tasks "${feedback_file}" "${tasks_file}"
    
    # Get PR branch info
    log_info "Getting PR branch information..."
    local pr_info=$(gh pr view "${pr_number}" --repo "${repo}" --json headRefName,baseRefName,files)
    local head_branch=$(echo "${pr_info}" | jq -r '.headRefName')
    local base_branch=$(echo "${pr_info}" | jq -r '.baseRefName')
    
    # Get list of files changed in PR
    local pr_files=$(echo "${pr_info}" | jq -r '.files[].path')
    local pr_files_list=$(echo "${pr_files}" | paste -sd ',' -)
    log_info "PR modifies files: ${pr_files_list}"
    
    # Save review session config
    jq -n \
        --arg review_id "${review_session_id}" \
        --arg pr_url "${pr_url}" \
        --arg repo "${repo}" \
        --arg pr_number "${pr_number}" \
        --arg head_branch "${head_branch}" \
        --arg base_branch "${base_branch}" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            review_id: $review_id,
            pr_url: $pr_url,
            repo: $repo,
            pr_number: $pr_number,
            head_branch: $head_branch,
            base_branch: $base_branch,
            created_at: $created_at,
            status: "in_progress"
        }' > "${review_dir}/config.json"
    
    # Ask user to confirm tasks
    echo -e "\n${BOLD}Review Tasks:${RESET}"
    jq -r '.[] | 
        if .context != "" then 
            "[\(.id)] \(.author) on \(.context): \(.description | split("\n")[0])"
        else 
            "[\(.id)] \(.author): \(.description | split("\n")[0])"
        end' "${tasks_file}"
    
    echo -e "\n${YELLOW}Ready to implement feedback?${RESET}"
    read -p "Press Enter to spawn workers for these tasks, or Ctrl+C to cancel: "
    
    # Spawn workers to address feedback  
    spawn_review_workers "${review_dir}" "${repo}" "${head_branch}" "${pr_number}" "${pr_files}"
}

# Process session PRs
process_session() {
    local session_dir="$1"
    local pr_file="${session_dir}/pull_requests.json"
    
    if [[ ! -f "${pr_file}" ]]; then
        log_error "No pull requests found for session: $(basename "${session_dir}")"
        exit 1
    fi
    
    local pr_urls=($(jq -r '.[]' "${pr_file}"))
    
    log_info "Found ${#pr_urls[@]} pull request(s) in session: $(basename "${session_dir}")"
    
    for pr_url in "${pr_urls[@]}"; do
        echo -e "\n${CYAN}Processing PR: ${pr_url}${RESET}"
        process_pr "${pr_url}"
    done
}

# Main review function
main() {
    print_banner "Scribe Review - Address PR Feedback"
    
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
    
    # Determine what to review
    if [[ -z "${TARGET}" ]]; then
        # No target specified - find latest session with PRs
        local session_dir=$(find_session_with_prs)
        log_info "Found latest session: $(basename "${session_dir}")"
        
        # Get the PR URL(s) from the session
        local pr_file="${session_dir}/pull_requests.json"
        local pr_urls=($(jq -r '.[]' "${pr_file}" 2>/dev/null))
        
        if [[ ${#pr_urls[@]} -eq 1 ]]; then
            # Single PR - process it directly
            log_info "Using PR from session: ${pr_urls[0]}"
            process_pr "${pr_urls[0]}"
        else
            # Multiple PRs - process the session
            log_info "Session has ${#pr_urls[@]} PRs"
            process_session "${session_dir}"
        fi
        
    elif is_pr_url "${TARGET}"; then
        # Target is a PR URL
        process_pr "${TARGET}"
        
    else
        # Target might be a session ID
        local session_dir="${WORKSPACE_DIR}/sessions/${TARGET}"
        if [[ -d "${session_dir}" ]]; then
            process_session "${session_dir}"
        else
            log_error "Invalid target: ${TARGET}"
            log_error "Must be a PR URL or valid session ID"
            exit 1
        fi
    fi
    
    echo -e "\n${GREEN}Review processing complete!${RESET}"
}

# Run main function
main "$@"