#!/usr/bin/env bash

# SonarQube analysis script
# Outputs JSON: {"quality_gate": "PASSED|FAILED", "issues": {...}, "metrics": {...}}

set -e

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Load environment variables from .env files
load_env_file

JSON_MODE=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        --help|-h) cat << 'EOF'
Usage: sonar.sh [--json]

Runs SonarQube analysis on the current project.
Requires: sonar-scanner, SONAR_TOKEN, SONAR_HOST_URL (or SONAR_PROJECT_KEY)

Environment:
  SONAR_TOKEN         - Authentication token (required)
  SONAR_HOST_URL      - SonarQube server URL (e.g., https://sonarcloud.io)
  SONAR_PROJECT_KEY   - Project key (optional, auto-detected from sonar-project.properties)
  SONAR_PROJECT_NAME  - Project display name (optional)
  SONAR_ORGANIZATION  - Organization key for SonarCloud (optional)
EOF
            exit 0 ;;
    esac
done

# Validate prerequisites
command -v sonar-scanner >/dev/null 2>&1 || {
    error_json "sonar-scanner not installed. Install from https://docs.sonarqube.org/latest/analysis/scan/sonarscanner/"
    exit 2
}

[[ -n "${SONAR_TOKEN:-}" ]] || { error_json "SONAR_TOKEN not set"; exit 2; }
[[ -n "${SONAR_HOST_URL:-}" || -n "${SONAR_PROJECT_KEY:-}" ]] || { error_json "SONAR_HOST_URL or SONAR_PROJECT_KEY required"; exit 2; }

# Build sonar-scanner command
SONAR_ARGS=()
[[ -n "${SONAR_HOST_URL:-}" ]] && SONAR_ARGS+=("-Dsonar.host.url=${SONAR_HOST_URL}")
[[ -n "${SONAR_TOKEN:-}" ]] && SONAR_ARGS+=("-Dsonar.token=${SONAR_TOKEN}")
[[ -n "${SONAR_PROJECT_KEY:-}" ]] && SONAR_ARGS+=("-Dsonar.projectKey=${SONAR_PROJECT_KEY}")
[[ -n "${SONAR_PROJECT_NAME:-}" ]] && SONAR_ARGS+=("-Dsonar.projectName=${SONAR_PROJECT_NAME}")
[[ -n "${SONAR_ORGANIZATION:-}" ]] && SONAR_ARGS+=("-Dsonar.organization=${SONAR_ORGANIZATION}")

# Get repo root
REPO_ROOT=$(get_repo_root)

# Get feature directory for report output
FEATURE_DIR=""
if [[ -f "$REPO_ROOT/.specify/feature.json" ]]; then
    FEATURE_DIR=$(read_feature_json_feature_directory "$REPO_ROOT")
    [[ "$FEATURE_DIR" != /* ]] && FEATURE_DIR="$REPO_ROOT/$FEATURE_DIR"
fi

# Run sonar-scanner
if $JSON_MODE; then
    # Run with JSON output (requires SonarQube 9.9+ or SonarCloud)
    SONAR_ARGS+=("-Dsonar.scanner.metadataFilePath=${REPO_ROOT}/.scannerwork/report-task.txt")
    sonar-scanner "${SONAR_ARGS[@]}" 2>&1 | tail -20
    
    # Parse quality gate from report-task.txt
    quality_gate="UNKNOWN"
    if [[ -f "${REPO_ROOT}/.scannerwork/report-task.txt" ]]; then
        CE_TASK_URL=$(grep "ceTaskUrl" "${REPO_ROOT}/.scannerwork/report-task.txt" | cut -d= -f2-)
        # Poll for quality gate status
        quality_gate=$(poll_quality_gate "$CE_TASK_URL" "$SONAR_TOKEN")
    fi
    
    # Parse issues summary
    issues_json=$(parse_sonar_issues "${REPO_ROOT}")
    
    output_json "$quality_gate" "$issues_json"
else
    sonar-scanner "${SONAR_ARGS[@]}"
fi


# Helper functions

poll_quality_gate() {
    local ce_task_url="$1"
    local token="$2"
    
    [[ -z "$ce_task_url" ]] && { echo "UNKNOWN"; return; }
    
    for i in {1..30}; do
        # Get task status
        local response
        response=$(curl -s -H "Authorization: Bearer $token" "$ce_task_url" 2>/dev/null) || { sleep 10; continue; }
        
        local status
        status=$(echo "$response" | grep -o '"status":"[^"]*"' | cut -d'"' -f4)
        
        if [[ "$status" == "SUCCESS" ]]; then
            # Get analysis ID and check quality gate
            local analysis_id
            analysis_id=$(echo "$response" | grep -o '"analysisId":"[^"]*"' | cut -d'"' -f4)
            [[ -z "$analysis_id" ]] && { echo "UNKNOWN"; return; }
            
            local qg_url
            qg_url="${ce_task_url%/api/ce/task*}/api/qualitygates/project_status?analysisId=$analysis_id"
            
            local qg_response
            qg_response=$(curl -s -H "Authorization: Bearer $token" "$qg_url" 2>/dev/null) || { echo "UNKNOWN"; return; }
            
            local qg_status
            qg_status=$(echo "$qg_response" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
            echo "${qg_status:-UNKNOWN}"
            return
        elif [[ "$status" == "FAILED" || "$status" == "CANCELED" ]]; then
            echo "ERROR"
            return
        fi
        sleep 10
    done
    echo "TIMEOUT"
}

parse_sonar_issues() {
    local repo_root="$1"
    local report_file="$repo_root/.scannerwork/report-task.txt"
    
    # Default values
    local bugs=0 vulnerabilities=0 code_smells=0 coverage=0 duplication=0
    
    # Try to get metrics from SonarQube API if we have the info
    if [[ -f "$report_file" ]]; then
        local ce_task_url
        ce_task_url=$(grep "ceTaskUrl" "$report_file" | cut -d= -f2-)
        local project_key
        project_key=$(grep "projectKey" "$report_file" | cut -d= -f2-)
        
        if [[ -n "$ce_task_url" && -n "$project_key" && -n "${SONAR_TOKEN:-}" ]]; then
            # Get component measures
            local metrics_url
            metrics_url="${ce_task_url%/api/ce/task*}/api/measures/component?component=$project_key&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density"
            
            local metrics_response
            metrics_response=$(curl -s -H "Authorization: Bearer $SONAR_TOKEN" "$metrics_url" 2>/dev/null) || return
            
            # Parse metrics (basic grep-based parsing)
            bugs=$(echo "$metrics_response" | grep -o '"bugs","value":"[^"]*"' | cut -d'"' -f5)
            vulnerabilities=$(echo "$metrics_response" | grep -o '"vulnerabilities","value":"[^"]*"' | cut -d'"' -f5)
            code_smells=$(echo "$metrics_response" | grep -o '"code_smells","value":"[^"]*"' | cut -d'"' -f5)
            coverage=$(echo "$metrics_response" | grep -o '"coverage","value":"[^"]*"' | cut -d'"' -f5)
            duplication=$(echo "$metrics_response" | grep -o '"duplicated_lines_density","value":"[^"]*"' | cut -d'"' -f5)
        fi
    fi
    
    # Ensure numeric values
    bugs=${bugs:-0}
    vulnerabilities=${vulnerabilities:-0}
    code_smells=${code_smells:-0}
    coverage=${coverage:-0}
    duplication=${duplication:-0}
    
    cat << EOF
{
  "bugs": $bugs,
  "vulnerabilities": $vulnerabilities,
  "code_smells": $code_smells,
  "coverage": $coverage,
  "duplication": $duplication
}
EOF
}

error_json() {
    local msg="$1"
    if $JSON_MODE; then
        printf '{"error":"%s","exit_code":2}\n' "$(json_escape "$msg")"
    else
        echo "ERROR: $msg" >&2
    fi
}

output_json() {
    local quality_gate="$1"
    local issues_json="$2"
    
    if $JSON_MODE; then
        printf '{"quality_gate":"%s","issues":%s,"exit_code":%d}\n' \
            "$quality_gate" "$issues_json" $([[ "$quality_gate" == "PASSED" ]] && echo 0 || echo 1)
    fi
}