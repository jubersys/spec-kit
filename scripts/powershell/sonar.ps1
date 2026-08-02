<# 
.SYNOPSIS
    SonarQube analysis script for PowerShell

.DESCRIPTION
    Runs SonarQube analysis on the current project.
    Requires: sonar-scanner, SONAR_TOKEN, SONAR_HOST_URL (or SONAR_PROJECT_KEY)

.PARAMETER Json
    Output results as JSON

.PARAMETER Help
    Show help message
#>

param(
    [switch]$Json,
    [switch]$Help
)

if ($Help) {
    @"
Usage: sonar.ps1 [-Json] [-Help]

Runs SonarQube analysis on the current project.
Requires: sonar-scanner, SONAR_TOKEN, SONAR_HOST_URL (or SONAR_PROJECT_KEY)

Environment:
  SONAR_TOKEN         - Authentication token (required)
  SONAR_HOST_URL      - SonarQube server URL (e.g., https://sonarcloud.io)
  SONAR_PROJECT_KEY   - Project key (optional, auto-detected from sonar-project.properties)
  SONAR_PROJECT_NAME  - Project display name (optional)
  SONAR_ORGANIZATION  - Organization key for SonarCloud (optional)
"@
    exit 0
}

# Load common functions
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$ScriptDir/common.ps1"

# Load environment variables from .env files
Load-EnvFile

# Validate prerequisites
if (-not (Get-Command sonar-scanner -ErrorAction SilentlyContinue)) {
    if ($Json) { Write-Output '{"error":"sonar-scanner not installed. Install from https://docs.sonarqube.org/latest/analysis/scan/sonarscanner/","exit_code":2}' }
    else { Write-Error "sonar-scanner not installed. Install from https://docs.sonarqube.org/latest/analysis/scan/sonarscanner/" }
    exit 2
}

if (-not $env:SONAR_TOKEN) {
    if ($Json) { Write-Output '{"error":"SONAR_TOKEN not set","exit_code":2}' }
    else { Write-Error "SONAR_TOKEN not set" }
    exit 2
}

if (-not $env:SONAR_HOST_URL -and -not $env:SONAR_PROJECT_KEY) {
    if ($Json) { Write-Output '{"error":"SONAR_HOST_URL or SONAR_PROJECT_KEY required","exit_code":2}' }
    else { Write-Error "SONAR_HOST_URL or SONAR_PROJECT_KEY required" }
    exit 2
}

# Build sonar-scanner command
$SonarArgs = @()
if ($env:SONAR_HOST_URL) { $SonarArgs += "-Dsonar.host.url=$env:SONAR_HOST_URL" }
$SonarArgs += "-Dsonar.token=$env:SONAR_TOKEN"
if ($env:SONAR_PROJECT_KEY) { $SonarArgs += "-Dsonar.projectKey=$env:SONAR_PROJECT_KEY" }
if ($env:SONAR_PROJECT_NAME) { $SonarArgs += "-Dsonar.projectName=$env:SONAR_PROJECT_NAME" }
if ($env:SONAR_ORGANIZATION) { $SonarArgs += "-Dsonar.organization=$env:SONAR_ORGANIZATION" }

# Get repo root
$RepoRoot = Get-RepoRoot

# Get feature directory for report output
$FeatureDir = ""
if (Test-Path "$RepoRoot/.specify/feature.json") {
    $FeatureDir = Read-FeatureJsonFeatureDirectory -RepoRoot $RepoRoot
    if (-not [IO.Path]::IsPathRooted($FeatureDir)) {
        $FeatureDir = Join-Path $RepoRoot $FeatureDir
    }
}

if ($Json) {
    # Run with JSON output
    $SonarArgs += "-Dsonar.scanner.metadataFilePath=$RepoRoot/.scannerwork/report-task.txt"
    & sonar-scanner @SonarArgs 2>&1 | Select-Object -Last 20
    
    # Parse quality gate from report-task.txt
    $QualityGate = "UNKNOWN"
    $ReportTaskFile = "$RepoRoot/.scannerwork/report-task.txt"
    if (Test-Path $ReportTaskFile) {
        $CeTaskUrl = (Get-Content $ReportTaskFile | Where-Object { $_ -like "ceTaskUrl=*" }) -replace "ceTaskUrl=", ""
        $QualityGate = Invoke-PollQualityGate -CeTaskUrl $CeTaskUrl -Token $env:SONAR_TOKEN
    }
    
    # Parse issues summary
    $IssuesJson = Invoke-ParseSonarIssues -RepoRoot $RepoRoot
    
    $ExitCode = if ($QualityGate -eq "PASSED") { 0 } else { 1 }
    $Output = @{
        quality_gate = $QualityGate
        issues = $IssuesJson | ConvertFrom-Json
        exit_code = $ExitCode
    } | ConvertTo-Json -Compress
    Write-Output $Output
} else {
    & sonar-scanner @SonarArgs
}

function Invoke-PollQualityGate {
    param(
        [string]$CeTaskUrl,
        [string]$Token
    )
    
    if (-not $CeTaskUrl) { return "UNKNOWN" }
    
    for ($i = 0; $i -lt 30; $i++) {
        try {
            $Headers = @{ Authorization = "Bearer $Token" }
            $Response = Invoke-RestMethod -Uri $CeTaskUrl -Headers $Headers -Method Get -ErrorAction Stop
            
            if ($Response.task.status -eq "SUCCESS") {
                $AnalysisId = $Response.task.analysisId
                if (-not $AnalysisId) { return "UNKNOWN" }
                
                $QgUrl = "$($CeTaskUrl.Replace('/api/ce/task', ''))/api/qualitygates/project_status?analysisId=$AnalysisId"
                $QgResponse = Invoke-RestMethod -Uri $QgUrl -Headers $Headers -Method Get -ErrorAction Stop
                return $QgResponse.projectStatus.status
            } elseif ($Response.task.status -in @("FAILED", "CANCELED")) {
                return "ERROR"
            }
        } catch {
            # Ignore errors, retry
        }
        Start-Sleep -Seconds 10
    }
    return "TIMEOUT"
}

function Invoke-ParseSonarIssues {
    param(
        [string]$RepoRoot
    )
    
    $Bugs = 0
    $Vulnerabilities = 0
    $CodeSmells = 0
    $Coverage = 0
    $Duplication = 0
    
    $ReportTaskFile = "$RepoRoot/.scannerwork/report-task.txt"
    if (Test-Path $ReportTaskFile) {
        $CeTaskUrl = (Get-Content $ReportTaskFile | Where-Object { $_ -like "ceTaskUrl=*" }) -replace "ceTaskUrl=", ""
        $ProjectKey = (Get-Content $ReportTaskFile | Where-Object { $_ -like "projectKey=*" }) -replace "projectKey=", ""
        
        if ($CeTaskUrl -and $ProjectKey -and $env:SONAR_TOKEN) {
            $MetricsUrl = "$($CeTaskUrl.Replace('/api/ce/task', ''))/api/measures/component?component=$ProjectKey&metricKeys=bugs,vulnerabilities,code_smells,coverage,duplicated_lines_density"
            try {
                $Headers = @{ Authorization = "Bearer $env:SONAR_TOKEN" }
                $MetricsResponse = Invoke-RestMethod -Uri $MetricsUrl -Headers $Headers -Method Get -ErrorAction Stop
                
                foreach ($Measure in $MetricsResponse.component.measures) {
                    switch ($Measure.metric) {
                        "bugs" { $Bugs = [int]$Measure.value }
                        "vulnerabilities" { $Vulnerabilities = [int]$Measure.value }
                        "code_smells" { $CodeSmells = [int]$Measure.value }
                        "coverage" { $Coverage = [double]$Measure.value }
                        "duplicated_lines_density" { $Duplication = [double]$Measure.value }
                    }
                }
            } catch {
                # Ignore errors
            }
        }
    }
    
    @{
        bugs = $Bugs
        vulnerabilities = $Vulnerabilities
        code_smells = $CodeSmells
        coverage = $Coverage
        duplication = $Duplication
    } | ConvertTo-Json -Compress
}