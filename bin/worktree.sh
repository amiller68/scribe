#!/bin/bash

# Git Worktree Setup Script for Multiple Claude Code Instances
# This script helps create separate git worktrees for working with multiple
# instances of Claude Code on the quotient repository

set -e

QUOTIENT_DIR="/Users/al/work/quotient"
WORKTREES_BASE_DIR="/Users/al/work/worktrees"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_usage() {
    echo "Usage: $0 <command> [worktree-name] [branch-name]"
    echo ""
    echo "Commands:"
    echo "  create <name> [branch]  - Create a new worktree (branch defaults to new branch from origin/dev)"
    echo "  list                    - List all worktrees"
    echo "  remove <name>           - Remove a worktree"
    echo "  open <name>             - Change to worktree directory"
    echo "  cleanup                 - Remove all worktrees"
    echo ""
    echo "Examples:"
    echo "  $0 create feature-branch"
    echo "  $0 create hotfix origin/hotfix-123"
    echo "  $0 open feature-branch"
    echo "  $0 remove feature-branch"
}

check_git_repo() {
    if [ ! -d "$QUOTIENT_DIR/.git" ]; then
        echo -e "${RED}Error: $QUOTIENT_DIR is not a git repository${NC}"
        exit 1
    fi
}

create_worktree() {
    local name="$1"
    local branch="${2:-$name}"
    local worktree_path="$WORKTREES_BASE_DIR/$name"
    
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Worktree name is required${NC}"
        print_usage
        exit 1
    fi
    
    if [ -d "$worktree_path" ]; then
        echo -e "${RED}Error: Worktree '$name' already exists at $worktree_path${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Creating worktree '$name' from branch '$branch'...${NC}"
    
    # Create the base directory if it doesn't exist
    mkdir -p "$WORKTREES_BASE_DIR"
    
    # Change to quotient directory and create worktree
    cd "$QUOTIENT_DIR"
    
    # If using default branch name (same as worktree), check if branch exists
    if [ "$branch" = "$name" ]; then
        # Check if branch exists locally or remotely
        if git show-ref --verify --quiet "refs/heads/$name" || git show-ref --verify --quiet "refs/remotes/origin/$name"; then
            echo -e "${YELLOW}Using existing branch '$name'${NC}"
            git worktree add "$worktree_path" "$name"
        else
            echo -e "${YELLOW}Creating new branch '$name' from origin/dev${NC}"
            git worktree add -b "$name" "$worktree_path" origin/dev
        fi
    else
        git worktree add "$worktree_path" "$branch"
    fi
    
    echo -e "${GREEN}Worktree created successfully!${NC}"
    echo -e "${YELLOW}Path: $worktree_path${NC}"
    echo -e "${YELLOW}To use with Claude Code:${NC}"
    echo "  cd $worktree_path"
    echo "  claude"
}

list_worktrees() {
    echo -e "${BLUE}Git worktrees:${NC}"
    cd "$QUOTIENT_DIR"
    git worktree list
    
    echo ""
    echo -e "${BLUE}Available worktree directories:${NC}"
    if [ -d "$WORKTREES_BASE_DIR" ]; then
        ls -la "$WORKTREES_BASE_DIR"
    else
        echo "No worktrees directory found"
    fi
}

remove_worktree() {
    local name="$1"
    local worktree_path="$WORKTREES_BASE_DIR/$name"
    
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Worktree name is required${NC}"
        print_usage
        exit 1
    fi
    
    if [ ! -d "$worktree_path" ]; then
        echo -e "${RED}Error: Worktree '$name' does not exist${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Removing worktree '$name'...${NC}"
    
    cd "$QUOTIENT_DIR"
    git worktree remove "$worktree_path"
    
    echo -e "${GREEN}Worktree removed successfully!${NC}"
}

open_worktree() {
    local name="$1"
    local worktree_path="$WORKTREES_BASE_DIR/$name"
    
    if [ -z "$name" ]; then
        echo -e "${RED}Error: Worktree name is required${NC}"
        print_usage
        exit 1
    fi
    
    if [ ! -d "$worktree_path" ]; then
        echo -e "${RED}Error: Worktree '$name' does not exist${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Opening worktree '$name'...${NC}"
    cd "$worktree_path" && exec claude
}

cleanup_worktrees() {
    echo -e "${YELLOW}Cleaning up all worktrees...${NC}"
    
    if [ -d "$WORKTREES_BASE_DIR" ]; then
        cd "$QUOTIENT_DIR"
        
        # Remove all worktrees
        for worktree_dir in "$WORKTREES_BASE_DIR"/*; do
            if [ -d "$worktree_dir" ]; then
                local name=$(basename "$worktree_dir")
                echo "Removing worktree: $name"
                git worktree remove "$worktree_dir" 2>/dev/null || true
            fi
        done
        
        # Remove the base directory
        rm -rf "$WORKTREES_BASE_DIR"
    fi
    
    echo -e "${GREEN}Cleanup complete!${NC}"
}

# Main script logic
check_git_repo

case "$1" in
    create)
        create_worktree "$2" "$3"
        ;;
    list)
        list_worktrees
        ;;
    remove)
        remove_worktree "$2"
        ;;
    open)
        open_worktree "$2"
        ;;
    cleanup)
        cleanup_worktrees
        ;;
    *)
        print_usage
        exit 1
        ;;
esac