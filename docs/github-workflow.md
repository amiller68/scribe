# GitHub Issue Workflow Guide

This guide explains how to use Scribe's GitHub integration to work on issues interactively.

## Overview

The GitHub workflow allows you to:
1. List and browse open issues from your repository
2. Select an issue to work on
3. Answer clarifying questions to better understand requirements
4. Automatically launch Scribe to implement the solution
5. Create PRs that are linked back to the original issue

## Commands

### `scribe-issue` - Interactive Issue Selection

The main command for working with GitHub issues.

```bash
# Interactive mode - list and select issues
scribe-issue

# Work on a specific issue
scribe-issue -n 123

# Specify a different repository
scribe-issue -r https://github.com/org/repo

# Limit number of issues shown
scribe-issue -l 10
```

### `scribe-work` - Unified Workflow Menu

A menu-driven interface for all Scribe workflows.

```bash
# Launch interactive menu
scribe-work

# Pass-through to scribe-issue
scribe-work -n 123
```

## Workflow Steps

### 1. Authentication

Before using the GitHub workflow, ensure you're authenticated:
```bash
gh auth login
```

### 2. Issue Selection

When you run `scribe-issue`, you'll see:

```
Fetching open issues...

Open Issues:

1. #42 - Add dark mode support
   Labels: enhancement, frontend
   
2. #38 - Fix memory leak in data processor
   Labels: bug, backend, priority-high
   Assigned to: alice

3. #35 - Update API documentation
   Labels: documentation

Select an issue number (1-3) or 'q' to quit:
```

### 3. Issue Details

After selection, you'll see the full issue details:

```
Issue #42: Add dark mode support

Labels: enhancement, frontend

Description:
Users have requested the ability to switch between light and dark themes.
The dark mode should:
- Persist across sessions
- Respect system preferences
- Be accessible via settings menu
```

### 4. Clarifying Questions

The system will ask targeted questions to better understand the implementation:

```
Let me ask some clarifying questions:

1. What is the main scope of this issue?
   a) Frontend only
   b) Backend only
   c) Full stack (both frontend and backend)
   d) Infrastructure/DevOps
   e) Documentation/Tests
Select (a-e): c

2. Will this require any breaking changes?
Yes/No (default: No): no

3. Are there any specific dependencies or integrations?
Enter any dependencies: React Context API, CSS variables

4. Any additional context or requirements?
Enter additional context: Should work with existing theme system

5. What's the priority level?
   a) Critical
   b) High
   c) Medium
   d) Low
Select (a-d): b
```

### 5. Execution Configuration

Before launching Scribe, configure the execution:

```
Configure Scribe execution:

Number of parallel workers (default: 3): 4

Merge strategy:
  1) Single PR (all changes in one PR)
  2) Federated (separate PRs per task)
Select (1-2, default: 1): 1
```

### 6. Automatic PR Linking

After Scribe completes, it will:
- Create PR(s) with the implementation
- Comment on the original issue with a link to the PR
- Add appropriate labels

## Example Scenarios

### Scenario 1: Bug Fix

```bash
# List bugs in current repo
scribe-issue

# Select bug issue #87
# Answer: backend only, no breaking changes, high priority
# Scribe creates focused fix with tests
```

### Scenario 2: Feature Implementation

```bash
# Work on specific feature request
scribe-issue -n 123

# Answer: full stack, needs new dependencies
# Configure 5 workers for complex feature
# Scribe parallelizes frontend, backend, tests, docs
```

### Scenario 3: Multiple Repository Work

```bash
# Work on issue in different repo
scribe-issue -r https://github.com/myorg/other-repo

# Useful for maintaining multiple projects
```

## Tips and Best Practices

### 1. Issue Preparation

Before using scribe-issue, ensure your issues have:
- Clear descriptions
- Appropriate labels
- Acceptance criteria
- Examples or mockups (if applicable)

### 2. Clarifying Questions

When answering questions:
- Be specific about technical requirements
- Mention any non-obvious dependencies
- Clarify performance or security needs
- Add context that's not in the issue

### 3. Worker Configuration

- **2-3 workers**: Simple bugs, documentation
- **3-4 workers**: Standard features
- **4-5 workers**: Complex features, refactoring

### 4. Merge Strategies

**Single PR**:
- Best for cohesive features
- Easier to review as a unit
- Good for smaller changes

**Federated PRs**:
- Best for large features
- Allows parallel review
- Good for modular changes

### 5. Issue Labels

Scribe recognizes these labels for better task decomposition:
- `frontend` / `backend` - Scope hints
- `bug` / `enhancement` - Change type
- `performance` - Triggers performance questions
- `breaking-change` - Extra compatibility checks
- `documentation` - Focus on docs

## Troubleshooting

### "No open issues found"

Check:
- Repository has open issues
- You have access to the repository
- Correct repository URL

### "gh: command not found"

Install GitHub CLI:
```bash
# macOS
brew install gh

# Linux
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
```

### Authentication Issues

```bash
# Check auth status
gh auth status

# Re-authenticate
gh auth login
```

### PR Creation Fails

Ensure you have:
- Push access to the repository
- Correct base branch permissions
- No branch protection conflicts

## Advanced Usage

### Custom Templates

Create issue templates that work well with Scribe:

```markdown
## Description
[Clear description of the feature/bug]

## Technical Requirements
- Scope: [frontend/backend/full-stack]
- Breaking changes: [yes/no]
- Dependencies: [list any]

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2

## Implementation Notes
[Any technical details for implementation]
```

### Batch Processing

Process multiple related issues:

```bash
# Work on issue 1
scribe-issue -n 101

# Then issue 2 that depends on it
scribe-issue -n 102
```

### Integration with CI/CD

The created PRs can trigger:
- Automated tests
- Preview deployments
- Code quality checks

## Workflow Automation

You can create shell functions for common patterns:

```bash
# Add to ~/.zshrc or ~/.bashrc

# Quick bug fix workflow
fix-bug() {
    scribe-issue -n "$1"
}

# Start working on highest priority issue
work-on-next() {
    scribe-issue -l 1
}

# Work on issues with specific label
work-on-label() {
    gh issue list --label "$1" --limit 1 --json number --jq '.[0].number' | xargs scribe-issue -n
}
```

## Summary

The GitHub issue workflow streamlines the development process by:
1. Eliminating context switching between issue tracking and coding
2. Ensuring implementations match requirements through clarifying questions
3. Automatically managing Git workflows and PR creation
4. Maintaining traceability between issues and code changes

This creates a seamless flow from issue selection to completed PR, leveraging Scribe's parallel execution capabilities for faster delivery.