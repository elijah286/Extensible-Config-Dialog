<#
.SYNOPSIS
    Run the configured LabVIEW unit-test frameworks headlessly and emit one JUnit
    XML file per tool into -ResultsDir. Runs INSIDE the LabVIEW CI container
    (same environment as run-vi-analyzer.ps1). Its JUnit output is consumed by
    build-unittest-report.py, which merges every *.xml into one friendly report.

.DESCRIPTION
    Reads `config.unitTests.tools[]` from .github/labview-ci.yml. For each enabled
    tool it resolves the configured test locations (each a directory to recurse or
    a glob / file-extension pattern) and invokes that tool's headless runner via
    g-cli (already baked into the CI image), writing JUnit XML.

    Caraya is the reference implementation. JKI VI Tester and NI UTF are scaffolded
    with the same contract. The exact g-cli command for each tool is a per-tool
    template that can be overridden from the config (`command:` key) so the precise
    invocation can be corrected on a real worker without editing this script.

    HEADLESS: LabVIEW must run -Headless in LabVIEW 2026+ Windows containers (same
    constraint run-vi-analyzer.ps1 documents) or VI Server fails with -350000. g-cli
    launches LabVIEW the same way, so we pass the LabVIEW path/version through.

.PARAMETER WorkspaceRoot
    Absolute path to the checked-out project inside the container. Default C:\workspace.

.PARAMETER ResultsDir
    Directory to write the per-tool JUnit XML into. build-unittest-report.py reads
    every *.xml here and infers the tool from the file name (caraya*.xml -> Caraya,
    vitester*/vi-tester* -> VI Tester, utf*/unit-test* -> UTF).

.PARAMETER ConfigPath
    Path to labview-ci.yml. Default: <WorkspaceRoot>\.github\labview-ci.yml.
#>
param(
    [string]$WorkspaceRoot  = 'C:\workspace',
    [string]$ResultsDir     = 'C:\workspace\ci-out\unit-tests\results',
    [string]$ConfigPath     = '',
    [string]$LabVIEWVersion = '2026',
    [string]$LabVIEWPath    = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not $ConfigPath) { $ConfigPath = Join-Path $WorkspaceRoot '.github\labview-ci.yml' }
New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null

# -- Resolve LabVIEW / LabVIEWCLI / g-cli (mirror run-vi-analyzer.ps1) ----------
function Resolve-LabVIEWPath([string]$PreferredPath) {
    if ($PreferredPath -and (Test-Path $PreferredPath)) { return $PreferredPath }
    $candidates = @(Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'LabVIEW.exe' } |
        Where-Object { Test-Path $_ })
    if ($candidates.Count -gt 0) { return $candidates[0] }
    throw "LabVIEW.exe not found (preferred '$PreferredPath')."
}

function Resolve-Cmd([string[]]$names) {
    foreach ($n in $names) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c -and $c.Source) { return $c.Source }
    }
    return $null
}

$LabVIEWPath = Resolve-LabVIEWPath $LabVIEWPath
$GCli        = Resolve-Cmd @('g-cli', 'g-cli.exe')

Write-Host "=== Unit Tests (Windows) ==="
Write-Host "  Workspace : $WorkspaceRoot"
Write-Host "  Results   : $ResultsDir"
Write-Host "  LabVIEW   : $LabVIEWPath  (v$LabVIEWVersion)"
Write-Host "  g-cli     : $(if ($GCli) { $GCli } else { '<not found on PATH>' })"
Write-Host "  Config    : $ConfigPath"
Write-Host ""

# -- Minimal reader for config.unitTests.tools[] -------------------------------
# Repo convention is regex/state-machine YAML parsing (see the awk parsers in the
# container workflows). We only need this fixed, shallow shape:
#   config:
#     unitTests:
#       tools:
#         caraya:
#           enabled: true
#           command: "<optional g-cli override with {ver} {dir} {out} tokens>"
#           locations:
#             - "tests/"
#             - "**/*.vi"
#         vi-tester:
#           enabled: false
#           locations: []
# Only tools with `enabled: true` are returned. Blank/empty locations = whole project.
function Read-UnitTestTools([string]$path) {
    $tools = @()
    if (-not (Test-Path $path)) { return ,$tools }
    $inUT = $false; $inTools = $false; $inLoc = $false
    $cur = $null
    foreach ($raw in (Get-Content -LiteralPath $path)) {
        $line = ($raw -replace '\t', '    ')
        if ($line -match '^\s*unitTests:\s*$') { $inUT = $true; $inTools = $false; $inLoc = $false; $cur = $null; continue }
        if (-not $inUT) { continue }
        if ($line -match '^\s{2}tools:\s*$')   { $inTools = $true; continue }

        # A tool entry is a map key under tools:, e.g. "    caraya:" (4-space indent).
        $m = [regex]::Match($line, '^\s{4}([A-Za-z0-9_.-]+):\s*$')
        if ($inTools -and $m.Success) {
            if ($cur -and $cur.enabled) { $tools += $cur }
            $cur = [ordered]@{ tool = $m.Groups[1].Value.ToLower(); enabled = $false; command = ''; locations = @() }
            $inLoc = $false
            continue
        }
        if ($null -ne $cur) {
            if ($line -match '^\s{6}enabled:\s*(true|false)\s*$') { $cur.enabled = ($Matches[1] -eq 'true'); $inLoc = $false; continue }
            $cm = [regex]::Match($line, '^\s{6}command:\s*"?(.+?)"?\s*$')
            if ($cm.Success) { $cur.command = $cm.Groups[1].Value; $inLoc = $false; continue }
            if ($line -match '^\s{6}locations:\s*\[\s*\]\s*$') { $cur.locations = @(); $inLoc = $false; continue }
            if ($line -match '^\s{6}locations:\s*$') { $inLoc = $true; continue }
            if ($inLoc) {
                $lm = [regex]::Match($line, '^\s{8}-\s*"?([^"]+?)"?\s*$')
                if ($lm.Success) { $cur.locations += $lm.Groups[1].Value; continue }
            }
        }
        # A top-level key (column 0) ends the unitTests block.
        if ($line -match '^\S') {
            if ($cur -and $cur.enabled) { $tools += $cur }
            $cur = $null; $inUT = $false; $inTools = $false; $inLoc = $false
        }
    }
    if ($cur -and $cur.enabled) { $tools += $cur }
    return ,$tools
}

# -- Resolve a tool's locations (dir OR glob/extension) to scan-root directories -
function Resolve-TestRoots([string[]]$locations) {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($loc in $locations) {
        if (-not $loc) { continue }
        $rel  = ($loc -replace '/', '\')
        $full = Join-Path $WorkspaceRoot $rel
        if (Test-Path -LiteralPath $full -PathType Container) {
            $roots.Add((Resolve-Path -LiteralPath $full).Path); continue
        }
        # Glob / extension: expand and take each match's parent directory.
        try {
            $matches = Get-ChildItem -Path (Join-Path $WorkspaceRoot $rel) -Recurse -File -ErrorAction SilentlyContinue
            foreach ($f in $matches) { $roots.Add($f.DirectoryName) }
        } catch { }
    }
    return ($roots | Sort-Object -Unique)
}

# -- Per-tool default g-cli command templates ---------------------------------
# Tokens: {ver}=LabVIEW year, {dir}=a resolved test-root directory, {out}=JUnit
# output path, {lv}=LabVIEW.exe path. A `command:` in the tool's config overrides
# the default. THESE DEFAULTS ARE BEST-EFFORT and must be confirmed on a real
# worker (the exact g-cli plugin name + flags per tool); the override key exists
# so that confirmation needs no script change.
$DEFAULT_CMD = @{
    # Caraya CLI g-cli extension (lvos_lib_caraya_cli_extension): run every Caraya
    # test under a directory and export JUnit. Reference implementation.
    'caraya'    = 'g-cli --lv-ver {ver} -- caraya -- --directory "{dir}" --junit "{out}"'
    # JKI VI Tester via sas_workshops_lib_vitester_for_g_cli (scaffold).
    'vi-tester' = 'g-cli --lv-ver {ver} -- vitester -- --directory "{dir}" --junit "{out}"'
    # NI Unit Test Framework: no first-party headless CLI confirmed yet (scaffold).
    'utf'       = ''
}

function Invoke-Tool($tool, [int]$index) {
    $id   = $tool.tool
    $tmpl = if ($tool.command) { $tool.command } elseif ($DEFAULT_CMD.ContainsKey($id)) { $DEFAULT_CMD[$id] } else { '' }
    $locs = @($tool.locations | Where-Object { $_ -and $_.Trim() })
    # Empty locations means "the whole project" (the config page documents this).
    $roots = if ($locs.Count -gt 0) { Resolve-TestRoots $locs } else { @($WorkspaceRoot) }

    Write-Host "--- tool: $id ---"
    if ($roots.Count -eq 0) { Write-Warning "  no test locations resolved for '$id' (locations: $($tool.locations -join ', ')) - skipping."; return }
    if (-not $tmpl)         { Write-Warning "  no headless command known for '$id' yet (set config.unitTests.tools[].command to enable) - skipping."; return }
    if (-not $GCli -and $tmpl -match '(^|\s)g-cli(\s|$)') { Write-Warning "  g-cli not found on PATH; cannot run '$id'."; return }

    $i = 0
    foreach ($dir in $roots) {
        $out = Join-Path $ResultsDir ("{0}-{1}.xml" -f $id, ($index * 100 + $i))
        $cmd = $tmpl.Replace('{ver}', $LabVIEWVersion).Replace('{dir}', $dir).Replace('{out}', $out).Replace('{lv}', $LabVIEWPath)
        Write-Host "  [$id] $cmd"
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try {
            & cmd.exe /c $cmd 2>&1 | Out-Host
            Write-Host ("  [$id] exit={0}" -f $LASTEXITCODE)
        } catch {
            Write-Warning "  [$id] runner error: $($_.Exception.Message)"
        }
        $ErrorActionPreference = $prevEAP
        if (Test-Path -LiteralPath $out) { Write-Host "  [$id] wrote $out" }
        else { Write-Warning "  [$id] produced no JUnit at $out (check the command/plugin for this tool)." }
        $i++
    }
}

# -- Main ---------------------------------------------------------------------
$tools = Read-UnitTestTools $ConfigPath
if (-not $tools -or $tools.Count -eq 0) {
    Write-Warning "No config.unitTests.tools configured in $ConfigPath - nothing to run."
    Write-Host "Wrote 0 JUnit file(s) to $ResultsDir."
    exit 0
}

Write-Host ("Configured tools: {0}" -f (($tools | ForEach-Object { $_.tool }) -join ', '))
Write-Host ""

$idx = 0
foreach ($t in $tools) { Invoke-Tool $t $idx; $idx++; Write-Host "" }

$xml = @(Get-ChildItem -Path $ResultsDir -Filter '*.xml' -File -ErrorAction SilentlyContinue)
Write-Host "=== Unit Tests finished: wrote $($xml.Count) JUnit file(s) to $ResultsDir ==="
# Always exit 0: pass/fail is derived from the JUnit content by
# build-unittest-report.py (its summary.json drives the commit status), exactly
# like the Mass Compile report. A runner-level error surfaces as a missing/empty
# report, not a hard CI failure here.
exit 0
