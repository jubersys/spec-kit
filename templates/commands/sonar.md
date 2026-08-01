---
description: Analyze code quality and technical debt using SonarQube/SonarCloud
scripts:
  sh: scripts/bash/sonar.sh --json
  ps: scripts/powershell/sonar.ps1 -Json
  py: scripts/python/sonar.py --json
handoffs:
  - label: View Full Report
    agent: speckit.sonar.report
    prompt: Show detailed SonarQube analysis report
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Pre-Execution Checks

**Check for extension hooks (before sonar):**
- Check if `.specify/extensions.yml` exists
- Look for `hooks.before_sonar` key
- Process hooks per standard protocol

**Load environment variables:**
- Load `.env` from project root if exists
- Load `.env.local` for local overrides (gitignored)
- Required vars when enabled: `SONAR_TOKEN`, `SONAR_HOST_URL` (or `SONAR_PROJECT_KEY`)

## Execution Flow

1. **Validate environment**:
   - Check if `sonar-scanner` is installed
   - Check for required env vars (`SONAR_TOKEN`, `SONAR_HOST_URL` or `SONAR_PROJECT_KEY`)
   - If missing, guide user to configure

2. **Run analysis**:
   - Execute `{SCRIPT}` with project config
   - Parse results for quality gate status

3. **Generate report**:
   - Create summary in `SPECIFY_FEATURE_DIRECTORY/sonar-report.md`
   - Include: bugs, vulnerabilities, code smells, coverage, duplication
   - Quality Gate: PASSED/FAILED

## Output Format

Report to user:
- Quality Gate: PASSED/FAILED
- New Issues: X bugs, Y vulnerabilities, Z code smells
- Coverage: N%
- Duplication: M%
- Link to SonarQube dashboard (if configured)

## Exit Codes
- 0: Quality Gate PASSED
- 1: Quality Gate FAILED (issues found)
- 2: Configuration error (missing scanner, token, etc.)

## Mandatory Post-Execution Hooks

Check `.specify/extensions.yml` for `hooks.after_sonar` and process per protocol.