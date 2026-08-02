#!/usr/bin/env python3
"""SonarQube analysis script - Python implementation."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Any

from common import find_specify_root, get_repo_root, load_env_file, read_feature_json_feature_directory


def run_sonar_scanner(args: list[str], repo_root: Path) -> subprocess.CompletedProcess:
    """Run sonar-scanner with given arguments."""
    return subprocess.run(
        ["sonar-scanner", *args],
        cwd=repo_root,
        capture_output=True,
        text=True,
        timeout=300,
    )


def poll_quality_gate(ce_task_url: str, token: str) -> str:
    """Poll SonarQube for quality gate status."""
    headers = {"Authorization": f"Bearer {token}"}
    for _ in range(30):  # Max 5 minutes
        req = urllib.request.Request(ce_task_url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.load(resp)
                status = data.get("task", {}).get("status")
                if status == "SUCCESS":
                    analysis_id = data["task"]["analysisId"]
                    # Get quality gate status
                    qg_url = f"{ce_task_url.replace('/api/ce/task', '/api/qualitygates/project_status')}?analysisId={analysis_id}"
                    req2 = urllib.request.Request(qg_url, headers=headers)
                    with urllib.request.urlopen(req2, timeout=10) as resp2:
                        qg_data = json.load(resp2)
                        return qg_data.get("projectStatus", {}).get("status", "UNKNOWN")
                elif status in ("FAILED", "CANCELED"):
                    return "ERROR"
        except Exception:
            pass
        time.sleep(10)
    return "TIMEOUT"


def parse_issues(repo_root: Path, ce_task_url: str, project_key: str, token: str) -> dict[str, Any]:
    """Parse SonarQube issues from API."""
    if not (ce_task_url and project_key and token):
        return {"bugs": 0, "vulnerabilities": 0, "code_smells": 0, "coverage": 0.0, "duplication": 0.0}
    
    try:
        metrics_url = f"{ce_task_url.replace('/api/ce/task', '/api/measures/component')}?component={project_key}&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density"
        req = urllib.request.Request(metrics_url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.load(resp)
        
        result = {"bugs": 0, "vulnerabilities": 0, "code_smells": 0, "coverage": 0.0, "duplication": 0.0}
        for measure in data.get("component", {}).get("measures", []):
            metric = measure.get("metric")
            value = measure.get("value", "0")
            if metric == "bugs":
                result["bugs"] = int(value)
            elif metric == "vulnerabilities":
                result["vulnerabilities"] = int(value)
            elif metric == "code_smells":
                result["code_smells"] = int(value)
            elif metric == "coverage":
                result["coverage"] = float(value)
            elif metric == "duplicated_lines_density":
                result["duplication"] = float(value)
        return result
    except Exception:
        return {"bugs": 0, "vulnerabilities": 0, "code_smells": 0, "coverage": 0.0, "duplication": 0.0}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()
    
    # Load .env
    load_env_file()
    
    # Validate
    if not subprocess.run(["which", "sonar-scanner"], capture_output=True).returncode == 0:
        if args.json:
            print(json.dumps({"error": "sonar-scanner not installed", "exit_code": 2}))
        else:
            print("ERROR: sonar-scanner not installed", file=sys.stderr)
        sys.exit(2)
    
    token = os.environ.get("SONAR_TOKEN")
    host_url = os.environ.get("SONAR_HOST_URL")
    project_key = os.environ.get("SONAR_PROJECT_KEY")
    
    if not token or (not host_url and not project_key):
        if args.json:
            print(json.dumps({"error": "Missing SONAR_TOKEN or SONAR_HOST_URL/SONAR_PROJECT_KEY", "exit_code": 2}))
        else:
            print("ERROR: Missing required environment variables", file=sys.stderr)
        sys.exit(2)
    
    repo_root = get_repo_root()
    
    # Get feature directory for report output
    feature_dir_raw = os.environ.get("SPECIFY_FEATURE_DIRECTORY", "")
    if not feature_dir_raw:
        feature_dir_raw = read_feature_json_feature_directory(repo_root)
    
    # Build sonar args
    sonar_args = []
    if host_url:
        sonar_args.append(f"-Dsonar.host.url={host_url}")
    sonar_args.append(f"-Dsonar.token={token}")
    if project_key:
        sonar_args.append(f"-Dsonar.projectKey={project_key}")
    if org := os.environ.get("SONAR_ORGANIZATION"):
        sonar_args.append(f"-Dsonar.organization={org}")
    if name := os.environ.get("SONAR_PROJECT_NAME"):
        sonar_args.append(f"-Dsonar.projectName={name}")
    
    if args.json:
        # Run with JSON output
        sonar_args.append(f"-Dsonar.scanner.metadataFilePath={repo_root}/.scannerwork/report-task.txt")
        result = run_sonar_scanner(sonar_args, repo_root)
        
        # Parse quality gate
        report_file = repo_root / ".scannerwork" / "report-task.txt"
        quality_gate = "UNKNOWN"
        ce_task_url = ""
        parsed_project_key = ""
        
        if report_file.exists():
            for line in report_file.read_text().splitlines():
                if line.startswith("ceTaskUrl="):
                    ce_task_url = line.split("=", 1)[1]
                elif line.startswith("projectKey="):
                    parsed_project_key = line.split("=", 1)[1]
        
        if ce_task_url:
            quality_gate = poll_quality_gate(ce_task_url, token)
        
        # Use parsed project key if env var not set
        effective_project_key = project_key or parsed_project_key
        
        issues = parse_issues(repo_root, ce_task_url, effective_project_key, token)
        
        output = {
            "quality_gate": quality_gate,
            "issues": issues,
            "exit_code": 0 if quality_gate == "PASSED" else 1,
        }
        print(json.dumps(output))
    else:
        result = run_sonar_scanner(sonar_args, repo_root)
        print(result.stdout)
        if result.stderr:
            print(result.stderr, file=sys.stderr)
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()