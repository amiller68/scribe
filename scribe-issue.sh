#!/bin/bash

# Scribe GitHub Issue Workflow
# Interactive script to select and work on GitHub issues

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null

# Colors for interactive UI
GREEN='\033[0;32m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

# Default values
REPO_URL=""
ISSUE_NUMBER=""
MAX_ISSUES=20
LIST_ONLY=false

# Clarifying question defaults
SCOPE=""
BREAKING_CHANGES=""
DEPENDENCIES=""
PERFORMANCE=""
ADDITIONAL=""
PRIORITY=""
WORKERS=""
STRATEGY=""
SKIP_CONFIRM=false
NO_TMUX=false

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Interactive GitHub issue selection and implementation workflow.

OPTIONS:
    -r, --repo URL         Repository URL (default: current repo)
    -n, --number NUM       Issue number (skip selection)
    -l, --limit NUM        Maximum issues to display (default: ${MAX_ISSUES})
    --list-only           Just list issues without selection
    
    # Clarifying question options (bypass prompts):
    --scope SCOPE         Scope: frontend/backend/fullstack/infra/docs
    --breaking-changes    Will require breaking changes (default: no)
    --dependencies DEPS   Dependencies to consider
    --performance PERF    Performance requirements
    --additional TEXT     Additional context
    --priority LEVEL      Priority: critical/high/medium/low
    
    # Execution options:
    --workers NUM         Number of parallel workers
    --strategy TYPE       Merge strategy: single-pr/federated
    -y, --yes            Skip confirmation prompts
    --no-tmux            Disable tmux monitoring (use background mode)
    -h, --help           Show this help message

EXAMPLES:
    $0                     # Interactive mode in current repo
    $0 -r https://github.com/org/repo
    $0 -n 123             # Work on specific issue
    $0 --list-only        # Just list issues
    
    # Fully automated with tmux monitoring (default):
    $0 -n 123 --scope frontend --priority medium --workers 3 --strategy federated --yes
    
    # Fully automated without tmux (background mode):
    $0 -n 123 --scope frontend --priority medium --workers 3 --strategy federated --yes --no-tmux
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--repo)
            REPO_URL="$2"
            shift 2
            ;;
        -n|--number)
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        -l|--limit)
            MAX_ISSUES="$2"
            shift 2
            ;;
        --list-only)
            LIST_ONLY=true
            shift
            ;;
        --scope)
            SCOPE="$2"
            shift 2
            ;;
        --breaking-changes)
            BREAKING_CHANGES="yes"
            shift
            ;;
        --dependencies)
            DEPENDENCIES="$2"
            shift 2
            ;;
        --performance)
            PERFORMANCE="$2"
            shift 2
            ;;
        --additional)
            ADDITIONAL="$2"
            shift 2
            ;;
        --priority)
            PRIORITY="$2"
            shift 2
            ;;
        --workers)
            WORKERS="$2"
            shift 2
            ;;
        --strategy)
            STRATEGY="$2"
            shift 2
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        --no-tmux)
            NO_TMUX=true
            shift
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

# Get repository URL
get_repo_url() {
    if [[ -n "${REPO_URL}" ]]; then
        echo "${REPO_URL}"
    elif git remote get-url origin >/dev/null 2>&1; then
        git remote get-url origin
    else
        log_error "Not in a git repository and no repo URL provided"
        exit 1
    fi
}

# Extract repo owner/name from URL
extract_repo_info() {
    local url="$1"
    echo "${url}" | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?.*|\1|'
}

# List GitHub issues
list_issues() {
    local repo="$1"
    
    if [[ "${LIST_ONLY}" != true ]]; then
        echo -e "${CYAN}${BOLD}Fetching open issues...${RESET}\n" >&2
    fi
    
    # Get issues using gh CLI
    gh issue list \
        --repo "${repo}" \
        --state open \
        --limit "${MAX_ISSUES}" \
        --json number,title,labels,assignees,createdAt,body
}

# Display issues for selection
display_issues() {
    local issues="$1"
    local count=1
    
    echo -e "${CYAN}${BOLD}Open Issues:${RESET}\n"
    
    # Process JSON array of issues
    # Debug: Validate JSON first
    if ! echo "${issues}" | jq . >/dev/null 2>&1; then
        echo "Error: Invalid JSON in display_issues" >&2
        echo "First 100 chars: ${issues:0:100}" >&2
        return 1
    fi
    
    # Debug: Check what we're parsing
    # echo "DEBUG in display_issues: about to get length of: ${issues:0:50}..." >&2
    local num_issues=$(echo "${issues}" | jq 'length')
    # echo "DEBUG: num_issues = ${num_issues}" >&2
    
    for ((i=0; i<num_issues; i++)); do
        local issue=$(echo "${issues}" | jq ".[$i]")
        local number=$(echo "${issue}" | jq -r '.number')
        local title=$(echo "${issue}" | jq -r '.title')
        local labels=$(echo "${issue}" | jq -r '.labels[].name' 2>/dev/null | paste -sd ', ' -)
        local assignees=$(echo "${issue}" | jq -r '.assignees[].login' 2>/dev/null | paste -sd ', ' -)
        
        # Format display
        echo -e "${BOLD}${count}.${RESET} ${GREEN}#${number}${RESET} - ${title}"
        
        if [[ -n "${labels}" ]]; then
            echo -e "   ${MAGENTA}Labels:${RESET} ${labels}"
        fi
        
        if [[ -n "${assignees}" ]]; then
            echo -e "   ${YELLOW}Assigned to:${RESET} ${assignees}"
        fi
        
        echo ""
        ((count++))
    done
}


# Get issue details
get_issue_details() {
    local repo="$1"
    local issue_number="$2"
    
    gh issue view "${issue_number}" \
        --repo "${repo}" \
        --json number,title,body,labels,assignees,comments \
        --jq '.'
}

# Display issue details
display_issue_details() {
    local issue="$1"
    
    local number=$(echo "${issue}" | jq -r '.number')
    local title=$(echo "${issue}" | jq -r '.title')
    local body=$(echo "${issue}" | jq -r '.body // "No description"')
    local labels=$(echo "${issue}" | jq -r '.labels[].name' | paste -sd ', ' -)
    
    echo -e "\n${CYAN}${BOLD}Issue #${number}: ${title}${RESET}\n"
    
    if [[ -n "${labels}" ]]; then
        echo -e "${MAGENTA}Labels:${RESET} ${labels}\n"
    fi
    
    echo -e "${BOLD}Description:${RESET}"
    echo "${body}" | head -20
    
    local body_lines=$(echo "${body}" | wc -l)
    if [[ ${body_lines} -gt 20 ]]; then
        echo -e "\n${YELLOW}... (truncated, ${body_lines} total lines)${RESET}"
    fi
    
    echo ""
}

# Ask clarifying questions
ask_clarifying_questions() {
    local issue="$1"
    local title=$(echo "${issue}" | jq -r '.title')
    local body=$(echo "${issue}" | jq -r '.body // ""')
    local labels=$(echo "${issue}" | jq -r '.labels[].name' | paste -sd ', ' -)
    
    echo -e "\n${CYAN}${BOLD}Let me ask some clarifying questions to better understand the implementation:${RESET}\n" >&2
    
    local clarifications=""
    
    # Question 1: Scope
    if [[ -n "${SCOPE}" ]]; then
        # Use provided scope
        case "${SCOPE}" in
            frontend) clarifications+="Scope: Frontend only\n" ;;
            backend) clarifications+="Scope: Backend only\n" ;;
            fullstack) clarifications+="Scope: Full stack\n" ;;
            infra) clarifications+="Scope: Infrastructure/DevOps\n" ;;
            docs) clarifications+="Scope: Documentation/Tests\n" ;;
            *) clarifications+="Scope: ${SCOPE}\n" ;;
        esac
    else
        echo -e "\n${BOLD}1. What is the main scope of this issue?${RESET}" >&2
        echo "   a) Frontend only" >&2
        echo "   b) Backend only" >&2
        echo "   c) Full stack (both frontend and backend)" >&2
        echo "   d) Infrastructure/DevOps" >&2
        echo "   e) Documentation/Tests" >&2
        printf "\n${GREEN}Select (a-e): ${RESET}" >&2
        read -r scope_choice
        
        case "${scope_choice}" in
            a) clarifications+="Scope: Frontend only\n" ;;
            b) clarifications+="Scope: Backend only\n" ;;
            c) clarifications+="Scope: Full stack\n" ;;
            d) clarifications+="Scope: Infrastructure/DevOps\n" ;;
            e) clarifications+="Scope: Documentation/Tests\n" ;;
            *) clarifications+="Scope: Full stack (default)\n" ;;
        esac
    fi
    
    # Question 2: Breaking changes
    if [[ -n "${BREAKING_CHANGES}" ]]; then
        breaking_changes_lower=$(echo "${BREAKING_CHANGES}" | tr '[:upper:]' '[:lower:]')
        if [[ "${breaking_changes_lower}" == "yes" || "${breaking_changes_lower}" == "y" ]]; then
            clarifications+="Breaking changes: Yes - ensure backward compatibility or migration path\n"
        else
            clarifications+="Breaking changes: No\n"
        fi
    elif [[ "${SKIP_CONFIRM}" == true ]]; then
        # Default to no breaking changes in non-interactive mode
        clarifications+="Breaking changes: No\n"
    else
        echo -e "\n${BOLD}2. Will this require any breaking changes?${RESET}" >&2
        printf "Yes/No (default: No): " >&2
        read -r breaking_changes
        breaking_changes_lower=$(echo "${breaking_changes}" | tr '[:upper:]' '[:lower:]')
        if [[ "${breaking_changes_lower}" == "yes" || "${breaking_changes_lower}" == "y" ]]; then
            clarifications+="Breaking changes: Yes - ensure backward compatibility or migration path\n"
        else
            clarifications+="Breaking changes: No\n"
        fi
    fi
    
    # Question 3: Dependencies
    if [[ -n "${DEPENDENCIES}" ]]; then
        clarifications+="Dependencies: ${DEPENDENCIES}\n"
    elif [[ "${SKIP_CONFIRM}" == true ]]; then
        # Skip in non-interactive mode
        :
    else
        echo -e "\n${BOLD}3. Are there any specific dependencies or integrations to consider?${RESET}" >&2
        printf "Enter any dependencies (or press Enter to skip): " >&2
        read -r dependencies
        if [[ -n "${dependencies}" ]]; then
            clarifications+="Dependencies: ${dependencies}\n"
        fi
    fi
    
    # Question 4: Performance
    if [[ "${labels}" =~ "performance" ]] || [[ "${body}" =~ [Pp]erformance ]]; then
        if [[ -n "${PERFORMANCE}" ]]; then
            clarifications+="Performance requirements: ${PERFORMANCE}\n"
        else
            echo -e "\n${BOLD}4. What are the performance requirements?${RESET}" >&2
            printf "Describe performance needs: " >&2
            read -r performance
            if [[ -n "${performance}" ]]; then
                clarifications+="Performance requirements: ${performance}\n"
            fi
        fi
    fi
    
    # Question 5: Additional context
    if [[ -n "${ADDITIONAL}" ]]; then
        clarifications+="Additional context: ${ADDITIONAL}\n"
    elif [[ "${SKIP_CONFIRM}" == true ]]; then
        # Skip in non-interactive mode
        :
    else
        echo -e "\n${BOLD}5. Any additional context or requirements not mentioned in the issue?${RESET}" >&2
        printf "Enter additional context (or press Enter to skip): " >&2
        read -r additional
        if [[ -n "${additional}" ]]; then
            clarifications+="Additional context: ${additional}\n"
        fi
    fi
    
    # Question 6: Priority/Timeline
    if [[ -n "${PRIORITY}" ]]; then
        # Use provided priority
        case "${PRIORITY}" in
            critical) clarifications+="Priority: Critical\n" ;;
            high) clarifications+="Priority: High\n" ;;
            medium) clarifications+="Priority: Medium\n" ;;
            low) clarifications+="Priority: Low\n" ;;
            *) clarifications+="Priority: ${PRIORITY}\n" ;;
        esac
    else
        echo -e "\n${BOLD}6. What's the priority level for this implementation?${RESET}" >&2
        echo "   a) Critical - needs immediate attention" >&2
        echo "   b) High - important but not urgent" >&2
        echo "   c) Medium - standard priority" >&2
        echo "   d) Low - nice to have" >&2
        printf "\n${GREEN}Select (a-d): ${RESET}" >&2
        read -r priority_choice
        
        case "${priority_choice}" in
            a) clarifications+="Priority: Critical\n" ;;
            b) clarifications+="Priority: High\n" ;;
            c) clarifications+="Priority: Medium\n" ;;
            d) clarifications+="Priority: Low\n" ;;
            *) clarifications+="Priority: Medium (default)\n" ;;
        esac
    fi
    
    echo "${clarifications}"
}

# Build enhanced ticket description
build_ticket_description() {
    local issue="$1"
    local clarifications="$2"
    
    local number=$(echo "${issue}" | jq -r '.number')
    local title=$(echo "${issue}" | jq -r '.title')
    local body=$(echo "${issue}" | jq -r '.body // "No description"')
    local labels=$(echo "${issue}" | jq -r '.labels[].name' | paste -sd ', ' -)
    
    # Build comprehensive description
    local description="GitHub Issue #${number}: ${title}"
    description+="\n\nOriginal Description:\n${body}"
    
    if [[ -n "${labels}" ]]; then
        description+="\n\nLabels: ${labels}"
    fi
    
    if [[ -n "${clarifications}" ]]; then
        description+="\n\nImplementation Details:\n${clarifications}"
    fi
    
    echo -e "${description}"
}

# Confirm before execution
confirm_execution() {
    local issue_number="$1"
    local description="$2"
    
    echo -e "\n${CYAN}${BOLD}Ready to implement issue #${issue_number}${RESET}\n"
    echo -e "${BOLD}Summary of work:${RESET}"
    echo "${description}" | head -15
    echo ""
    
    if [[ "${SKIP_CONFIRM}" == true ]]; then
        return 0
    fi
    
    read -r -p "Proceed with implementation? (y/n): " confirm
    
    confirm_lower=$(echo "${confirm}" | tr '[:upper:]' '[:lower:]')
    if [[ "${confirm_lower}" != "y" && "${confirm_lower}" != "yes" ]]; then
        echo "Cancelled."
        return 1
    fi
    
    return 0
}

# Execute Scribe
execute_scribe() {
    local description="$1"
    local repo_url="$2"
    local issue_number="$3"
    
    # Additional Scribe options
    local scribe_opts=""
    
    if [[ -n "${WORKERS}" ]] || [[ -n "${STRATEGY}" ]]; then
        # Use provided options
        if [[ -n "${WORKERS}" ]] && [[ "${WORKERS}" =~ ^[0-9]+$ ]]; then
            scribe_opts+=" -w ${WORKERS}"
        fi
        if [[ -n "${STRATEGY}" ]]; then
            scribe_opts+=" -s ${STRATEGY}"
        fi
    else
        echo -e "\n${CYAN}${BOLD}Configure Scribe execution:${RESET}\n"
        
        # Number of workers
        read -r -p "Number of parallel workers (default: 3): " workers
        if [[ -n "${workers}" ]] && [[ "${workers}" =~ ^[0-9]+$ ]]; then
            scribe_opts+=" -w ${workers}"
        fi
        
        # Merge strategy
        echo -e "\nMerge strategy:"
        echo "  1) Single PR (all changes in one PR)"
        echo "  2) Federated (separate PRs per task)"
        read -r -p "Select (1-2, default: 1): " strategy_choice
        
        if [[ "${strategy_choice}" == "2" ]]; then
            scribe_opts+=" -s federated"
        fi
    fi
    
    # Create feature branch name
    local branch_name="issue-${issue_number}-$(echo "${description}" | head -1 | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | cut -c1-30)"
    
    echo -e "\n${GREEN}${BOLD}Launching Scribe...${RESET}\n"
    
    # Add no-tmux flag if enabled
    if [[ "${NO_TMUX}" == true ]]; then
        export SCRIBE_NO_TMUX=1
    fi
    
    # Execute Scribe
    "${SCRIPT_DIR}/scribe.sh" ${scribe_opts} "${description}" "${repo_url}"
    
    # Link PR to issue
    if [[ -f "${SCRIPT_DIR}/workspace/sessions/*/pr_url.txt" ]]; then
        local pr_url=$(cat "${SCRIPT_DIR}"/workspace/sessions/*/pr_url.txt | tail -1)
        echo -e "\n${GREEN}${BOLD}Created PR: ${pr_url}${RESET}"
        
        # Comment on issue
        echo -e "\nLinking PR to issue #${issue_number}..."
        gh issue comment "${issue_number}" \
            --repo "${repo_url}" \
            --body "🤖 Scribe has created a PR for this issue: ${pr_url}"
    fi
}

# Main workflow
main() {
    # Skip banner for list-only mode
    if [[ "${LIST_ONLY}" != true ]]; then
        print_banner "Scribe GitHub Issue Workflow"
    fi
    
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
    
    # Get repository info
    REPO_URL=$(get_repo_url)
    REPO_INFO=$(extract_repo_info "${REPO_URL}")
    
    if [[ "${LIST_ONLY}" != true ]]; then
        log_info "Repository: ${REPO_INFO}"
    fi
    
    # Handle direct issue number
    if [[ -n "${ISSUE_NUMBER}" ]]; then
        log_info "Working on issue #${ISSUE_NUMBER}"
        issue_json=$(get_issue_details "${REPO_INFO}" "${ISSUE_NUMBER}")
    else
        # List and select issue
        issues_json=$(list_issues "${REPO_INFO}")
        
        # Debug: Show what we got
        # echo "DEBUG: issues_json first 200 chars: ${issues_json:0:200}" >&2
        
        if [[ -z "${issues_json}" ]] || [[ "${issues_json}" == "[]" ]]; then
            log_error "No open issues found in ${REPO_INFO}"
            exit 1
        fi
        
        # Debug: Check if issues_json is valid JSON
        if ! echo "${issues_json}" | jq . >/dev/null 2>&1; then
            log_error "Invalid JSON returned from GitHub API"
            log_error "First 200 chars: ${issues_json:0:200}"
            exit 1
        fi
        
        # Display issues
        display_issues "${issues_json}"
        
        # Show how to work on an issue
        echo -e "\n${CYAN}To work on an issue, run:${RESET}"
        echo -e "${GREEN}  scribe issue -n <number>${RESET}\n"
        exit 0
    fi
    
    # Display issue details
    display_issue_details "${issue_json}"
    
    # Ask clarifying questions
    clarifications=$(ask_clarifying_questions "${issue_json}")
    
    # Build enhanced description
    ticket_description=$(build_ticket_description "${issue_json}" "${clarifications}")
    
    # Confirm execution
    if confirm_execution "${ISSUE_NUMBER}" "${ticket_description}"; then
        execute_scribe "${ticket_description}" "${REPO_URL}" "${ISSUE_NUMBER}"
    fi
}

# Run main
main "$@"