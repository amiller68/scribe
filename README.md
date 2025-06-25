# Scribe: Multi-Agent Code Orchestration System

Scribe is a prototype orchestration system that coordinates multiple Claude Code instances to implement features in parallel across different areas of a codebase. It analyzes repository structure, decomposes feature requirements into independent tasks, and manages parallel execution using Git worktrees.

## Overview

Scribe enables parallel development by:
- Analyzing your codebase structure and architecture
- Breaking down feature tickets into independent, parallelizable tasks
- Spawning multiple Claude Code instances to work on tasks simultaneously
- Managing Git worktrees for isolated development environments
- Merging changes back together with configurable strategies

## Prerequisites

- Git (2.20+)
- GitHub CLI (`gh`) for PR creation
- Claude Code CLI (`claude`)
- Bash 4.0+
- `jq` for JSON processing

## Installation

1. Clone the repository:
```bash
git clone <scribe-repo-url>
cd scribe
```

2. Make scripts executable:
```bash
chmod +x scribe.sh lib/*.sh
```

3. (Optional) Add to PATH:
```bash
export PATH="$PATH:/path/to/scribe"
```

## Usage

### Quick Start

```bash
# Install Scribe
./install.sh
source ~/.zshrc  # or ~/.bashrc

# Work on a GitHub issue
scribe issue

# Run orchestration directly
scribe "Add dark mode toggle" "https://github.com/user/repo"

# Open interactive menu
scribe work
```

### Command Structure

```bash
scribe [COMMAND] [OPTIONS]
```

#### Available Commands

- `run` - Execute orchestration (default command)
- `issue` - Work on GitHub issues interactively
- `work` - Interactive workflow menu
- `analyze` - Analyze repository structure
- `list` - List recent sessions
- `clean` - Clean up old sessions
- `help` - Show help for commands

### Advanced Options

```bash
# Orchestration options
scribe run [OPTIONS] "Feature description" "repo-url"
    -w, --workers NUM       Maximum parallel workers (default: 3)
    -t, --timeout SECONDS   Worker timeout in seconds (default: 3600)
    -b, --branch NAME       Base branch name (default: main)
    -s, --strategy TYPE     Merge strategy: single-pr or federated

# Issue workflow options
scribe issue [OPTIONS]
    -n, --number NUM       Work on specific issue number
    -r, --repo URL         Repository URL (default: current repo)
    -l, --limit NUM        Maximum issues to display
    list                   Just list issues without selection
```

### Examples

1. **Work on GitHub issues:**
```bash
# Interactive issue selection
scribe issue

# Work on specific issue
scribe issue -n 123

# Just list issues
scribe issue list
```

2. **Run orchestration directly:**
```bash
# Simple feature
scribe "Add user authentication" "https://github.com/myorg/myapp"

# Complex feature with more workers
scribe run -w 5 "Implement shopping cart" "https://github.com/myorg/ecommerce"

# Using federated PR strategy
scribe run -s federated "Refactor database layer" "https://github.com/myorg/api"
```

3. **Repository analysis:**
```bash
# Analyze current directory
scribe analyze

# Analyze specific repo and save results
scribe analyze /path/to/repo -o analysis.json
```

4. **Session management:**
```bash
# List recent sessions
scribe list

# Clean up old sessions
scribe clean --days 30
```

## How It Works

### 1. Repository Analysis
Scribe analyzes your repository to understand:
- Project type and frameworks
- Directory structure and purposes
- Code distribution and architecture
- Testing frameworks and patterns

### 2. Task Decomposition
Using Claude, Scribe breaks down your feature into:
- 3-5 independent tasks
- Each with specific scope and boundaries
- Minimal overlap between tasks
- Clear interfaces and contracts

### 3. Parallel Execution
For each task, Scribe:
- Creates a Git worktree with isolated branch
- Generates a focused prompt for Claude Code
- Spawns a Claude Code instance
- Monitors progress and handles failures

### 4. Integration
After workers complete, Scribe:
- Collects changes from all worktrees
- Executes chosen merge strategy
- Creates GitHub PR(s)
- Cleans up temporary resources

## Merge Strategies

### Single PR Strategy
- Merges all changes to one integration branch
- Creates a single comprehensive PR
- Best for cohesive features

### Federated PR Strategy
- Creates individual PRs for each task
- Links them with a tracking issue
- Best for large, modular changes

## Configuration

Edit `config/settings.conf` to customize:
- Worker limits and timeouts
- Git branch preferences
- Merge strategies
- Analysis depth
- Logging levels

## Architecture

```
scribe/
├── scribe.sh              # Main orchestrator
├── lib/
│   ├── analyze-repo.sh    # Repository analysis
│   ├── spawn-worker.sh    # Worker management
│   ├── merge-strategy.sh  # Integration logic
│   ├── common.sh          # Shared utilities
│   └── prompts/           # Claude prompts
├── config/
│   └── settings.conf      # Configuration
├── workspace/             # Runtime data
│   └── sessions/          # Session tracking
└── examples/              # Usage examples
```

## Session Management

Each orchestration creates a session with:
- Unique session ID
- Task definitions and status
- Worker outputs and logs
- Integration results

Sessions are stored in `workspace/sessions/` for debugging and auditing.

## Troubleshooting

### Common Issues

1. **Claude Code not found**
   - Ensure `claude` CLI is installed and in PATH
   - Check with: `which claude`

2. **Git worktree errors**
   - Requires Git 2.20+
   - Clean up stale worktrees: `git worktree prune`

3. **PR creation fails**
   - Install GitHub CLI: `gh auth login`
   - Ensure repository permissions

### Debug Mode

Enable verbose logging:
```bash
export SCRIBE_DEBUG=1
./scribe.sh "Feature" "repo-url"
```

## Limitations

- Currently supports single repository only
- Limited to 5 parallel workers by default
- Requires manual conflict resolution for complex merges
- Task decomposition quality depends on feature description

## Future Enhancements

- [ ] Support for multiple repositories
- [ ] Dependency graph between tasks
- [ ] Real-time progress dashboard
- [ ] Integration with CI/CD pipelines
- [ ] Learning from past decompositions
- [ ] Automated testing verification

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## License

[Your License Here]

## Acknowledgments

Built to demonstrate multi-agent orchestration patterns with Claude Code.# scribe
