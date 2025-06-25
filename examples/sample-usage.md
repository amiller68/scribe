# Scribe Usage Examples

This document provides practical examples of using Scribe for various scenarios.

## Example 1: Adding a Feature to a React Application

### Scenario
You want to add a dark mode toggle to your React application's settings page.

### Command
```bash
./scribe.sh "Add dark mode toggle to settings page with theme persistence" \
    "https://github.com/myorg/react-app"
```

### Expected Task Decomposition
1. **Backend API** - Add theme preference endpoints
2. **Frontend Components** - Create toggle UI component
3. **State Management** - Implement theme context/store
4. **Styling** - Add dark mode CSS variables
5. **Tests** - Write unit and integration tests

### Result
- Single PR with all changes integrated
- Each component developed in isolation
- Clean commit history per task

## Example 2: API Refactoring with Federated PRs

### Scenario
Refactoring a monolithic API into microservices-ready modules.

### Command
```bash
./scribe.sh -s federated -w 4 \
    "Refactor user management into separate service module" \
    "https://github.com/myorg/api"
```

### Expected Task Decomposition
1. **Extract User Models** - Separate user data models
2. **Create Service Layer** - Build user service interface
3. **Refactor Controllers** - Update API endpoints
4. **Update Tests** - Migrate and update test suite

### Result
- 4 separate PRs, each reviewable independently
- Tracking issue linking all PRs
- Can be merged in sequence or parallel

## Example 3: Full-Stack Feature Implementation

### Scenario
Implementing a complete feature across frontend and backend.

### Command
```bash
./scribe.sh -w 5 -t 7200 \
    "Implement real-time notifications system with WebSocket support" \
    "https://github.com/myorg/fullstack-app"
```

### Expected Task Decomposition
1. **WebSocket Server** - Backend WebSocket implementation
2. **Database Schema** - Notification storage design
3. **API Endpoints** - REST endpoints for notifications
4. **Frontend Integration** - WebSocket client and UI
5. **Testing & Docs** - Comprehensive tests and documentation

### Options Explained
- `-w 5`: Use 5 parallel workers
- `-t 7200`: 2-hour timeout per worker

## Example 4: Bug Fix Across Multiple Components

### Scenario
Fixing a bug that affects multiple parts of the codebase.

### Command
```bash
./scribe.sh -b develop \
    "Fix timezone handling bug in calendar, scheduling, and reporting modules" \
    "https://github.com/myorg/scheduling-app"
```

### Expected Task Decomposition
1. **Calendar Module** - Fix timezone display
2. **Scheduling Logic** - Correct timezone calculations
3. **Reports** - Update timezone in exports
4. **Timezone Utilities** - Centralize timezone handling

### Options Explained
- `-b develop`: Use 'develop' as base branch instead of 'main'

## Example 5: Documentation and Testing Sprint

### Scenario
Improving documentation and test coverage for existing features.

### Command
```bash
./scribe.sh -s federated \
    "Add comprehensive documentation and increase test coverage for payment module" \
    "https://github.com/myorg/payment-service"
```

### Expected Task Decomposition
1. **API Documentation** - Document all endpoints
2. **Integration Tests** - Add integration test suite
3. **Unit Tests** - Increase unit test coverage
4. **Developer Guide** - Create setup and contribution guide

## Common Patterns

### 1. Frontend/Backend Separation
```bash
./scribe.sh "Implement user profile page with edit capabilities" "repo-url"
```
Tasks typically split between:
- Backend API changes
- Frontend UI implementation
- Shared type definitions
- Tests for both layers

### 2. Horizontal Slicing (by Feature Area)
```bash
./scribe.sh "Add multi-language support to dashboard, reports, and emails" "repo-url"
```
Tasks divided by feature area:
- Dashboard i18n
- Report generation i18n
- Email template i18n
- Language selection UI

### 3. Vertical Slicing (Full Stack per Feature)
```bash
./scribe.sh "Add commenting system to blog posts, products, and user profiles" "repo-url"
```
Each task includes full stack:
- Blog comments (API + UI)
- Product comments (API + UI)
- Profile comments (API + UI)

## Tips for Best Results

1. **Clear Feature Descriptions**
   - Be specific about requirements
   - Mention key components affected
   - Include technical constraints

2. **Repository Preparation**
   - Ensure clean working tree
   - Update base branch
   - Run tests before starting

3. **Worker Count Guidelines**
   - 2-3 workers: Simple features
   - 4-5 workers: Complex features
   - 5+ workers: Large refactoring

4. **Timeout Considerations**
   - Default (1 hour): Most features
   - 2 hours: Complex implementations
   - 30 minutes: Simple changes

5. **Strategy Selection**
   - Single PR: Cohesive features
   - Federated: Independent modules
   - Federated: When reviews needed separately

## Debugging Failed Runs

### Check Session Logs
```bash
ls workspace/sessions/
cat workspace/sessions/[session-id]/logs/orchestrator.log
```

### Review Worker Status
```bash
cat workspace/sessions/[session-id]/workers/worker-*/status.json
```

### Examine Worker Output
```bash
cat workspace/sessions/[session-id]/workers/worker-*/output.log
```

## Advanced Usage

### Custom Configuration
Create a custom config for specific project:
```bash
cp config/settings.conf my-project.conf
# Edit my-project.conf
SCRIBE_CONFIG=my-project.conf ./scribe.sh "Feature" "repo-url"
```

### Dry Run Mode
Test task decomposition without execution:
```bash
SCRIBE_DRY_RUN=1 ./scribe.sh "Feature" "repo-url"
```

### Debug Mode
Enable verbose output:
```bash
SCRIBE_DEBUG=1 ./scribe.sh "Feature" "repo-url"
```