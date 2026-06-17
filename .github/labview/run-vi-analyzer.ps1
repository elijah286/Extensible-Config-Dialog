<#
.SYNOPSIS
    Runs LabVIEW VI Analyzer (Windows container) and generates an HTML report.

.PARAMETER WorkspaceRoot
    Absolute path to the project inside the container. Default: C:\workspace

.PARAMETER ReportDir
    Output directory for the XML results and HTML report.

.PARAMETER ConfigTemplate
    Path to the .viancfg template file (uses __WORKSPACE_PATH__ placeholder).

.PARAMETER LabVIEWPath
    Path to LabVIEW.exe inside the container.
#>
param(
    [string]$WorkspaceRoot   = 'C:\workspace',
    [string]$ReportDir       = 'C:\report',
    [string]$ConfigTemplate  = 'C:\workspace\.github\labview\via-configs\via-config-default.viancfg',
    [string]$LabVIEWPath     = 'C:\Program Files\National Instruments\LabVIEW 2026\LabVIEW.exe'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Resolve-LabVIEWPath([string]$PreferredPath) {
    if ($PreferredPath -and (Test-Path $PreferredPath)) {
        return $PreferredPath
    }

    $candidates = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
        Where-Object { Test-Path $_ })

    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }

    throw "LabVIEW.exe not found. Checked preferred path '$PreferredPath' and C:\Program Files\National Instruments\LabVIEW *"
}

function Resolve-LabVIEWCLI([string]$LabVIEWExePath) {
    $cliCmd = Get-Command LabVIEWCLI.exe -ErrorAction SilentlyContinue
    if ($null -eq $cliCmd) {
        $cliCmd = Get-Command LabVIEWCLI -ErrorAction SilentlyContinue
    }
    if ($null -ne $cliCmd -and $cliCmd.Source) {
        return $cliCmd.Source
    }

    $candidate = Join-Path (Split-Path $LabVIEWExePath) 'LabVIEWCLI.exe'
    if (Test-Path $candidate) {
        return $candidate
    }

    throw "LabVIEWCLI not found on PATH and not found beside LabVIEW.exe ('$candidate')."
}

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
$CliExe     = Resolve-LabVIEWCLI $LabVIEWPath
$ConfigFile = Join-Path $ReportDir 'via-config.viancfg'
$ResultsXml = Join-Path $ReportDir 'via-results.xml'
$HtmlOut    = Join-Path $ReportDir 'index.html'

New-Item -ItemType Directory -Force -Path $ReportDir | Out-Null

Write-Host "=== VI Analyzer (Windows) ==="
Write-Host "  Workspace  : $WorkspaceRoot"
Write-Host "  LabVIEW    : $LabVIEWPath"
Write-Host "  Mode       : full default suite (analyze workspace directory)"
Write-Host ""

# Directory-mode analysis (see the RunVIAnalyzer call below): passing the workspace
# DIRECTORY as -ConfigPath makes LabVIEWCLI run the FULL DEFAULT VI Analyzer test
# configuration against every VI under it. This is the invocation that produced the
# historical working reports (hundreds of VIs, ~24k tests). Do NOT swap this for a
# .viancfg config FILE with an empty <TestConfigData> — an empty test list makes the
# analyzer run ZERO tests and report "VIs Analyzed 1 / Total Tests Run 0" (the
# empty-report regression this restores).

# ── Recompile the workspace to this image's LabVIEW version BEFORE analyzing ──
# The VI Analyzer only analyzes VIs already saved in the running LabVIEW's
# version; VIs saved in an OLDER version (e.g. the LV2019 example project) are
# silently skipped, producing an empty "0 VIs analyzed" report even though the
# VIs load fine. A headless MassCompile pass mutates every VI in the workspace up
# to the current version in place, so the following RunVIAnalyzer sees and
# analyzes them. Best-effort: a non-zero MassCompile exit (e.g. one library VI
# that can't compile against the CI image) must not block analysis — we relax
# ErrorActionPreference, log the exit code, and continue regardless.
Write-Host "=== Pre-analysis MassCompile (upgrade VIs to image LabVIEW version) ==="
$preStart = Get-Date
$prevEAP  = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $CliExe `
        -LogToConsole       TRUE `
        -OperationName      MassCompile `
        -DirectoryToCompile $WorkspaceRoot `
        -LabVIEWPath        $LabVIEWPath `
        -Headless 2>&1 | Out-Host
    Write-Host ("  MassCompile exit={0} duration={1}s" -f $LASTEXITCODE, [math]::Round(((Get-Date) - $preStart).TotalSeconds, 1))
} catch {
    Write-Warning "  Pre-analysis MassCompile skipped: $($_.Exception.Message)"
}
$ErrorActionPreference = $prevEAP
Write-Host ""

$Start = Get-Date

# Passing the workspace DIRECTORY as -ConfigPath runs the full default VI Analyzer
# test set against every VI under it; -ReportSaveType HTML writes the native,
# richly formatted report straight to index.html (which the friendly-report step
# then parses). -Headless is REQUIRED for LabVIEW 2026+ in Windows containers,
# otherwise LabVIEWCLI cannot establish a VI Server connection (error -350000).
& $CliExe `
    -LogToConsole   TRUE `
    -OperationName  RunVIAnalyzer `
    -ConfigPath     $WorkspaceRoot `
    -ReportPath     $HtmlOut `
    -ReportSaveType HTML `
    -LabVIEWPath    $LabVIEWPath `
    -Headless

$ExitCode = $LASTEXITCODE
$Duration = [math]::Round(((Get-Date) - $Start).TotalSeconds, 1)

Write-Host ""
Write-Host "=== VI Analyzer finished (exit=$ExitCode duration=${Duration}s) ==="

# Directory-mode + -ReportSaveType HTML wrote the NATIVE VI Analyzer report to
# $HtmlOut (index.html). The workflow's "Build friendly report" step parses that
# native report into the navigable one (preserving the native as raw.html), so we
# must NOT overwrite or wrap it here.
if (Test-Path $HtmlOut) {
    $size = (Get-Item $HtmlOut).Length
    Write-Host "Native VI Analyzer report -> $HtmlOut ($size bytes)"
} else {
    Write-Warning "No VI Analyzer report was generated at $HtmlOut"
}

# Exit code 3 = analysis succeeded but found rule failures -> treat as success
# (the failures are detailed in the report). Any other non-zero code is a real error.
if ($ExitCode -eq 3) {
    Write-Host "VI Analyzer completed with rule failures (exit 3) - see report."
    exit 0
} elseif ($ExitCode -ne 0) {
    exit $ExitCode
}

exit 0
