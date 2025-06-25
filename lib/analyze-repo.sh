#!/bin/bash

# Repository analysis script for Scribe orchestration system
# Analyzes repository structure and outputs JSON metadata

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# Usage
usage() {
    cat << EOF
Usage: $0 REPO_DIR

Analyze repository structure and output JSON metadata.

Arguments:
    REPO_DIR    Path to the repository to analyze

Output:
    JSON structure describing the repository architecture
EOF
    exit 1
}

# Validate arguments
if [[ $# -ne 1 ]]; then
    usage
fi

REPO_DIR="$1"

if [[ ! -d "${REPO_DIR}" ]]; then
    log_error "Repository directory does not exist: ${REPO_DIR}"
    exit 1
fi

# Change to repo directory
cd "${REPO_DIR}"

# Detect project type
detect_project_type() {
    local project_type="unknown"
    local frameworks=()
    
    # Node.js/JavaScript
    if [[ -f "package.json" ]]; then
        project_type="nodejs"
        
        # Detect frameworks
        if [[ -f "package.json" ]] && grep -q '"react"' package.json 2>/dev/null; then
            frameworks+=("react")
        fi
        if [[ -f "package.json" ]] && grep -q '"vue"' package.json 2>/dev/null; then
            frameworks+=("vue")
        fi
        if [[ -f "package.json" ]] && grep -q '"express"' package.json 2>/dev/null; then
            frameworks+=("express")
        fi
        if [[ -f "package.json" ]] && grep -q '"next"' package.json 2>/dev/null; then
            frameworks+=("nextjs")
        fi
    fi
    
    # Python
    if [[ -f "requirements.txt" ]] || [[ -f "setup.py" ]] || [[ -f "pyproject.toml" ]]; then
        project_type="python"
        
        # Detect frameworks
        if [[ -f "requirements.txt" ]] && grep -qE '(django|Django)' requirements.txt 2>/dev/null; then
            frameworks+=("django")
        fi
        if [[ -f "requirements.txt" ]] && grep -qE '(flask|Flask)' requirements.txt 2>/dev/null; then
            frameworks+=("flask")
        fi
        if [[ -f "requirements.txt" ]] && grep -qE '(fastapi|FastAPI)' requirements.txt 2>/dev/null; then
            frameworks+=("fastapi")
        fi
    fi
    
    # Go
    if [[ -f "go.mod" ]]; then
        project_type="go"
    fi
    
    # Rust
    if [[ -f "Cargo.toml" ]]; then
        project_type="rust"
    fi
    
    # Java
    if [[ -f "pom.xml" ]] || [[ -f "build.gradle" ]]; then
        project_type="java"
        
        if [[ -f "pom.xml" ]] && grep -q '<artifactId>spring-boot' pom.xml 2>/dev/null; then
            frameworks+=("spring-boot")
        fi
    fi
    
    # Ruby
    if [[ -f "Gemfile" ]]; then
        project_type="ruby"
        
        if [[ -f "Gemfile" ]] && grep -q 'rails' Gemfile 2>/dev/null; then
            frameworks+=("rails")
        fi
    fi
    
    echo "${project_type}"
    if [[ ${#frameworks[@]} -gt 0 ]]; then
        printf '%s\n' "${frameworks[@]}"
    fi
}

# Analyze directory structure
analyze_directories() {
    local max_depth=3
    local directories=()
    
    # Find main directories (exclude common ignore patterns)
    while IFS= read -r dir; do
        # Skip hidden directories and common ignore patterns
        if [[ ! "${dir}" =~ ^\.|node_modules|venv|__pycache__|\.git|dist|build|target ]]; then
            # Determine directory purpose
            local purpose="unknown"
            local base_dir=$(basename "${dir}")
            
            case "${base_dir}" in
                src|source)
                    purpose="source_code"
                    ;;
                test|tests|spec|specs)
                    purpose="tests"
                    ;;
                doc|docs|documentation)
                    purpose="documentation"
                    ;;
                lib|libs|library|libraries)
                    purpose="libraries"
                    ;;
                api)
                    purpose="api"
                    ;;
                frontend|client|web|ui)
                    purpose="frontend"
                    ;;
                backend|server)
                    purpose="backend"
                    ;;
                config|conf|configuration)
                    purpose="configuration"
                    ;;
                scripts|bin)
                    purpose="scripts"
                    ;;
                public|static|assets)
                    purpose="static_assets"
                    ;;
                database|db|migrations)
                    purpose="database"
                    ;;
                models)
                    purpose="models"
                    ;;
                controllers)
                    purpose="controllers"
                    ;;
                views|templates)
                    purpose="views"
                    ;;
                components)
                    purpose="components"
                    ;;
                services)
                    purpose="services"
                    ;;
                utils|utilities|helpers)
                    purpose="utilities"
                    ;;
            esac
            
            # Count files in directory
            local file_count=$(find "${dir}" -type f -name "*.${project_type}*" 2>/dev/null | wc -l | tr -d ' ')
            
            directories+=("{\"path\": \"${dir}\", \"purpose\": \"${purpose}\", \"file_count\": ${file_count}}")
        fi
    done < <(find . -type d -maxdepth ${max_depth} | grep -v '^\.$' | sort)
    
    # Return as JSON array
    if [[ ${#directories[@]} -gt 0 ]]; then
        printf '[%s]' "$(IFS=,; echo "${directories[*]}")"
    else
        echo '[]'
    fi
}

# Detect configuration files
detect_config_files() {
    local config_files=()
    local common_configs=(
        ".env" ".env.example" ".env.local"
        "config.json" "config.yaml" "config.yml" "config.toml"
        "settings.json" "settings.yaml" "settings.yml"
        "tsconfig.json" "jsconfig.json"
        ".eslintrc" ".prettierrc"
        "Dockerfile" "docker-compose.yml"
        "Makefile" "Rakefile"
        ".github/workflows"
    )
    
    for config in "${common_configs[@]}"; do
        if [[ -e "${config}" ]]; then
            config_files+=("\"${config}\"")
        fi
    done
    
    printf '[%s]' "$(IFS=,; echo "${config_files[*]}")"
}

# Count lines of code by language
count_lines_of_code() {
    local stats=()
    
    # JavaScript/TypeScript
    local js_lines=$(find . -type f \( -name "*.js" -o -name "*.jsx" -o -name "*.ts" -o -name "*.tsx" \) -not -path "*/node_modules/*" -not -path "*/dist/*" -not -path "*/build/*" -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    
    # Python
    local py_lines=$(find . -type f -name "*.py" -not -path "*/venv/*" -not -path "*/__pycache__/*" -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    
    # Go
    local go_lines=$(find . -type f -name "*.go" -not -path "*/vendor/*" -exec wc -l {} + 2>/dev/null | tail -1 | awk '{print $1}' || echo "0")
    
    # Add to stats if > 0
    [[ ${js_lines} -gt 0 ]] && stats+=("{\"language\": \"javascript\", \"lines\": ${js_lines}}")
    [[ ${py_lines} -gt 0 ]] && stats+=("{\"language\": \"python\", \"lines\": ${py_lines}}")
    [[ ${go_lines} -gt 0 ]] && stats+=("{\"language\": \"go\", \"lines\": ${go_lines}}")
    
    printf '[%s]' "$(IFS=,; echo "${stats[*]}")"
}

# Detect test framework
detect_test_framework() {
    local test_framework="unknown"
    
    # JavaScript
    if [[ -f "package.json" ]]; then
        if grep -q '"jest"' package.json 2>/dev/null; then
            test_framework="jest"
        elif grep -q '"mocha"' package.json 2>/dev/null; then
            test_framework="mocha"
        elif grep -q '"vitest"' package.json 2>/dev/null; then
            test_framework="vitest"
        elif grep -q '"cypress"' package.json 2>/dev/null; then
            test_framework="cypress"
        fi
    fi
    
    # Python
    if [[ -f "requirements.txt" ]] || [[ -f "setup.py" ]]; then
        if grep -qE '(pytest|py\.test)' requirements.txt 2>/dev/null || [[ -f "pytest.ini" ]]; then
            test_framework="pytest"
        elif grep -q 'unittest' requirements.txt 2>/dev/null; then
            test_framework="unittest"
        fi
    fi
    
    # Go
    if [[ -f "go.mod" ]] && find . -name "*_test.go" -type f | head -1 >/dev/null 2>&1; then
        test_framework="go-test"
    fi
    
    echo "${test_framework}"
}

# Main analysis function
main() {
    log_info "Analyzing repository: ${REPO_DIR}"
    
    # Get project info
    local project_info=($(detect_project_type))
    local project_type="${project_info[0]}"
    local frameworks=("${project_info[@]:1}")
    
    # Get git info
    local git_remote=$(git remote get-url origin 2>/dev/null || echo "none")
    local current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    local commit_count=$(git rev-list --count HEAD 2>/dev/null || echo "0")
    
    # Analyze structure
    local directories=$(analyze_directories)
    local config_files=$(detect_config_files)
    local code_stats=$(count_lines_of_code)
    local test_framework=$(detect_test_framework)
    
    # Build JSON output
    cat << EOF
{
    "repository": {
        "path": "${REPO_DIR}",
        "remote": "${git_remote}",
        "branch": "${current_branch}",
        "commit_count": ${commit_count}
    },
    "project": {
        "type": "${project_type}",
        "frameworks": [$(if [[ ${#frameworks[@]} -gt 0 ]]; then printf '"%s",' "${frameworks[@]}" | sed 's/,$//'; fi)],
        "test_framework": "${test_framework}"
    },
    "structure": {
        "directories": ${directories},
        "config_files": ${config_files}
    },
    "statistics": {
        "code_by_language": ${code_stats}
    },
    "analysis": {
        "timestamp": "$(get_timestamp)",
        "parallelization_areas": [
            "backend",
            "frontend",
            "tests",
            "documentation"
        ],
        "common_interfaces": [
            "api/endpoints",
            "database/models",
            "shared/types"
        ]
    }
}
EOF
}

# Run analysis
main