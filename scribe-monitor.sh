#!/bin/bash

# Scribe Session Monitor
# Monitor active or completed Scribe sessions

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null

# Colors for status display
STATUS_RUNNING='\033[0;93m'    # Yellow
STATUS_COMPLETED='\033[0;92m'  # Green
STATUS_FAILED='\033[0;91m'     # Red
STATUS_UNKNOWN='\033[0;90m'    # Gray
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

# Default values
SESSION_ID=""
TAIL_LOGS=false
STATUS_ONLY=false
ATTACH_TMUX=false
REFRESH_INTERVAL=2
WORKSPACE_DIR="${SCRIPT_DIR}/workspace"

# Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [SESSION_ID]

Monitor Scribe orchestration sessions in real-time.

OPTIONS:
    -t, --tail              Tail worker logs in real-time
    -s, --status            Show status only (no log tailing)
    -a, --attach            Attach to tmux session if available
    -r, --refresh SECONDS   Refresh interval for status (default: ${REFRESH_INTERVAL})
    -h, --help             Show this help message

ARGUMENTS:
    SESSION_ID             Specific session to monitor (optional)
                          If not provided, monitors the latest active session

EXAMPLES:
    $0                     # Monitor latest session with status updates
    $0 --tail             # Monitor latest session and tail logs
    $0 20250625_131706_17508718264267  # Monitor specific session
    $0 --status           # Show status once and exit

INTERACTIVE COMMANDS:
    q, Ctrl+C            Quit monitoring
    t                    Toggle log tailing
    r                    Refresh status
    w WORKER             Show specific worker log
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--tail)
            TAIL_LOGS=true
            shift
            ;;
        -s|--status)
            STATUS_ONLY=true
            shift
            ;;
        -a|--attach)
            ATTACH_TMUX=true
            shift
            ;;
        -r|--refresh)
            REFRESH_INTERVAL="$2"
            shift 2
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
        # Find latest session
        local latest=$(ls -t "${sessions_dir}" 2>/dev/null | head -1)
        if [[ -z "${latest}" ]]; then
            log_error "No sessions found"
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
        echo "Session info not available"
        return 1
    fi
    
    local session_id=$(basename "${session_dir}")
    local ticket=$(jq -r '.ticket_description' "${config_file}" | head -1)
    local status=$(jq -r '.status' "${config_file}")
    local created=$(jq -r '.created_at' "${config_file}")
    local repo=$(jq -r '.repo_url' "${config_file}")
    
    echo -e "${BOLD}Session:${RESET} ${session_id}"
    echo -e "${BOLD}Status:${RESET} ${status}"
    echo -e "${BOLD}Created:${RESET} ${created}"
    echo -e "${BOLD}Repository:${RESET} ${repo}"
    echo -e "${BOLD}Ticket:${RESET} ${ticket:0:80}..."
}

# Get worker status
get_worker_status() {
    local session_dir="$1"
    local workers_dir="${session_dir}/workers"
    
    if [[ ! -d "${workers_dir}" ]]; then
        echo "No workers found"
        return
    fi
    
    echo -e "\\n${BOLD}Workers:${RESET}"
    printf "%-30s %-15s %-10s %s\\n" "Task" "Status" "Duration" "Progress"
    printf "%-30s %-15s %-10s %s\\n" "----" "------" "--------" "--------"
    
    for worker_dir in "${workers_dir}"/worker-*; do
        if [[ -d "${worker_dir}" ]]; then
            local worker_id=$(basename "${worker_dir}")
            local task_file="${worker_dir}/task.json"
            local status_file="${worker_dir}/status.json"
            
            local task_name="Unknown"
            local status="unknown"
            local start_time=""
            local duration=""
            
            if [[ -f "${task_file}" ]]; then
                task_name=$(jq -r '.name // "Unknown"' "${task_file}")
            fi
            
            if [[ -f "${status_file}" ]]; then
                status=$(jq -r '.status // "unknown"' "${status_file}")
                start_time=$(jq -r '.start_time // ""' "${status_file}")
                
                if [[ -n "${start_time}" ]]; then
                    local current_time=$(date +%s)
                    local start_seconds=$(date -d "${start_time}" +%s 2>/dev/null || echo "0")
                    if [[ ${start_seconds} -gt 0 ]]; then
                        local elapsed=$((current_time - start_seconds))
                        duration="${elapsed}s"
                    fi
                fi
            fi
            
            # Color code status
            local status_color=""
            case "${status}" in
                running) status_color="${STATUS_RUNNING}" ;;
                completed) status_color="${STATUS_COMPLETED}" ;;
                failed) status_color="${STATUS_FAILED}" ;;
                *) status_color="${STATUS_UNKNOWN}" ;;
            esac
            
            # Show progress indicator
            local progress=""
            if [[ "${status}" == "running" ]]; then
                progress="🔄"
            elif [[ "${status}" == "completed" ]]; then
                progress="✅"
            elif [[ "${status}" == "failed" ]]; then
                progress="❌"
            else
                progress="⏸️"
            fi
            
            local task_display="${task_name:0:29}"
            echo -e "$(printf "%-30s" "${task_display}") ${status_color}$(printf "%-15s" "${status}")${RESET} $(printf "%-10s" "${duration}") ${progress}"
        fi
    done
}

# Show session overview
show_session_overview() {
    local session_dir="$1"
    
    if [[ "${STATUS_ONLY}" != true ]]; then
        clear
    fi
    print_banner "Scribe Session Monitor"
    
    get_session_info "${session_dir}"
    get_worker_status "${session_dir}"
    
    echo ""
    if [[ "${TAIL_LOGS}" == true ]]; then
        echo -e "${CYAN}Tailing logs... (Press Ctrl+C to stop)${RESET}"
    else
        echo -e "${CYAN}Press 't' to tail logs, 'q' to quit, 'r' to refresh${RESET}"
    fi
}

# Tail worker logs
tail_worker_logs() {
    local session_dir="$1"
    local workers_dir="${session_dir}/workers"
    
    if [[ ! -d "${workers_dir}" ]]; then
        log_error "No workers directory found"
        return 1
    fi
    
    echo -e "\\n${CYAN}${BOLD}Worker Logs:${RESET}"
    echo -e "${CYAN}Press Ctrl+C to stop tailing${RESET}\\n"
    
    # Tail all worker logs with worker identification
    tail -f "${workers_dir}"/*/output.log 2>/dev/null | while read -r line; do
        # Extract worker ID from tail output
        if [[ "${line}" =~ ==\>.*worker-(.*)\/output\.log ]]; then
            worker_id="${BASH_REMATCH[1]}"
            echo -e "${YELLOW}[${worker_id}]${RESET}"
        else
            echo "${line}"
        fi
    done
}

# Interactive monitoring loop
interactive_monitor() {
    local session_dir="$1"
    
    while true; do
        show_session_overview "${session_dir}"
        
        if [[ "${STATUS_ONLY}" == true ]]; then
            break
        fi
        
        if [[ "${TAIL_LOGS}" == true ]]; then
            tail_worker_logs "${session_dir}"
            break
        fi
        
        # Wait for input or timeout
        if read -t "${REFRESH_INTERVAL}" -n 1 key 2>/dev/null; then
            case "${key}" in
                q|Q)
                    echo -e "\\nExiting monitor..."
                    break
                    ;;
                t|T)
                    TAIL_LOGS=true
                    ;;
                r|R)
                    continue
                    ;;
                *)
                    echo -e "\\nUnknown command: ${key}"
                    echo "Press 't' to tail logs, 'q' to quit, 'r' to refresh"
                    sleep 1
                    ;;
            esac
        fi
    done
}

# Check for running processes and tmux session
check_running_processes() {
    local session_dir="$1"
    local session_id=$(basename "${session_dir}")
    
    # Check for tmux session
    local tmux_session_file="${session_dir}/tmux_session.txt"
    if [[ -f "${tmux_session_file}" ]]; then
        local tmux_session=$(cat "${tmux_session_file}")
        if tmux has-session -t "${tmux_session}" 2>/dev/null; then
            echo -e "${STATUS_RUNNING}Tmux session '${tmux_session}' is active${RESET}"
            echo -e "${CYAN}  Attach with: tmux attach-session -t ${tmux_session}${RESET}"
            
            # Offer to attach
            if [[ "${ATTACH_TMUX}" == true ]]; then
                echo -e "\n${CYAN}Attaching to tmux session...${RESET}"
                exec tmux attach-session -t "${tmux_session}"
            fi
        else
            echo -e "${STATUS_UNKNOWN}Tmux session '${tmux_session}' no longer exists${RESET}"
        fi
    fi
    
    # Check if main orchestration is still running
    if pgrep -f "scribe.sh.*${session_id}" >/dev/null; then
        echo -e "${STATUS_RUNNING}Main orchestration process is running${RESET}"
    fi
    
    # Check for Claude processes
    local claude_count=$(pgrep -c "claude" 2>/dev/null || echo "0")
    if [[ ${claude_count} -gt 0 ]]; then
        echo -e "${STATUS_RUNNING}${claude_count} Claude worker(s) running${RESET}"
    fi
}

# Main function
main() {
    local session_dir=$(find_session)
    
    echo -e "${BLUE}Monitoring session: $(basename "${session_dir}")${RESET}\\n"
    
    check_running_processes "${session_dir}"
    
    if [[ "${TAIL_LOGS}" == true ]]; then
        show_session_overview "${session_dir}"
        tail_worker_logs "${session_dir}"
    else
        interactive_monitor "${session_dir}"
    fi
}

# Handle Ctrl+C gracefully
trap 'echo -e "\\n\\nMonitoring stopped."; exit 0' INT

# Run main function
main "$@"