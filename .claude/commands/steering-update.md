---
description: Update Kiro steering documents based on recent project changes
allowed-tools: Bash, Read, Write, Edit, MultiEdit, Glob, Grep, LS
---

# Kiro Steering Update

Update existing steering documents in `.kiro/steering/` to reflect recent project changes and maintain accurate project knowledge for ongoing spec-driven development.

## Change Analysis

### Recent Git Activity
- Recent commits: !`git log --oneline -15`
- Modified files (last 10 commits): !`git diff --name-only HEAD~10`
- Added files: !`git diff --name-status HEAD~10 | grep "^A"`
- Deleted files: !`git diff --name-status HEAD~10 | grep "^D"`
- Renamed files: !`git diff --name-status HEAD~10 | grep "^R"`

### Dependency Changes
- Package.json changes: !`git diff HEAD~10 -- package.json 2>/dev/null || echo "No package.json changes"`
- Requirements.txt changes: !`git diff HEAD~10 -- requirements.txt 2>/dev/null || echo "No requirements.txt changes"`
- Config changes: !`git diff HEAD~10 --name-only | grep -E "(tsconfig|webpack|vite|rollup|babel|eslint|prettier)"`

### Current Project State
- Current structure: !`find . -type f -name "*.py" -o -name "*.js" -o -name "*.ts" -o -name "*.jsx" -o -name "*.tsx" -o -name "*.java" -o -name "*.go" -o -name "*.rs" | grep -v node_modules | grep -v .git | grep -v dist | head -30`
- Dependencies: !`find . -maxdepth 3 -name "package.json" -o -name "requirements.txt" -o -name "pom.xml" -o -name "Cargo.toml" -o -name "go.mod" -o -name "pyproject.toml" -o -name "tsconfig.json"`

## Current Steering Documents

### Load Existing Steering Context
- Product overview: @.kiro/steering/product.md
- Technology stack: @.kiro/steering/tech.md
- Project structure: @.kiro/steering/structure.md
- Custom steering files: !`find .kiro/steering -name "*.md" | grep -v -E "(product|tech|structure).md" || echo "No custom steering files found"`

## Task: Update Steering Documents

Analyze recent changes and update the steering documents to maintain accuracy:

### 1. Update Product Overview (`product.md`)
Review and update if there are:
- **New features** added to the product
- **Removed features** or deprecated functionality
- **Changed use cases** or target audience
- **Updated value propositions** or benefits
- **Modified product goals** or roadmap items

Only update sections that have actually changed.

### 2. Update Technology Stack (`tech.md`)
Check for changes in:
- **New dependencies** added via package managers
- **Removed libraries** or frameworks
- **Version upgrades** of major dependencies
- **New development tools** or build processes
- **Changed environment variables** or configuration
- **Modified port assignments** or service architecture
- **Updated common commands** or scripts

Focus on significant technology changes, not minor version bumps.

### 3. Update Project Structure (`structure.md`)
Look for changes in:
- **New directories** or major reorganization
- **Changed file organization** patterns
- **New or modified naming conventions**
- **Updated architectural patterns** or principles
- **Refactored code structure** or module boundaries
- **Changed import patterns** or dependencies

Update only if there are meaningful structural changes.

### 4. Review Custom Steering Files
If custom steering files exist:
- Check if they're still relevant to current project state
- Update content based on recent changes
- Remove if no longer applicable
- Note any new areas that might need custom steering

## Instructions

1. **Analyze the git history** to understand what has changed
2. **Compare current state** with existing steering documents
3. **Update only what has changed** - don't rewrite unchanged sections
4. **Preserve existing structure** and formatting consistency
5. **Add new sections** only if there are significant new areas
6. **Mark deprecated content** rather than deleting (unless completely removed)
7. **Include dates** for major changes if helpful for context
8. **Maintain spec-driven development alignment** - ensure changes support future specifications

## Best Practices

- **Keep changes focused** - steering should remain concise and readable
- **Maintain consistency** with existing document style and format
- **Explain reasoning** for significant changes or architectural decisions
- **Provide examples** for new patterns or conventions
- **Regular maintenance** - run this after major features or refactoring
- **Version awareness** - consider backward compatibility when updating

The goal is to keep steering documents current without unnecessary churn, ensuring they continue to provide accurate guidance for AI interactions and support effective spec-driven development.