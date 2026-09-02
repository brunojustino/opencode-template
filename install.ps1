#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the opencode workflow template into a project (new or ongoing).
  Non-destructive: existing files are never overwritten; opencode.json is merged, not replaced.

.PARAMETER Target
  Target project directory. Defaults to the current directory.

.EXAMPLE
  .\install.ps1 -Target C:\code\myproject
#>
[CmdletBinding()]
param(
  [string]$Target = (Get-Location).Path
)

$ErrorActionPreference = "Stop"
$source = $PSScriptRoot
$target = (Resolve-Path -LiteralPath $Target).Path

if (-not (Test-Path -LiteralPath (Join-Path $source ".opencode\skills\grill-with-docs\SKILL.md"))) {
  throw "Template files not found next to install.ps1 (missing .opencode\skills). Run from the template root."
}

$created = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]

function Copy-TemplateItem {
  param([string]$RelPath)
  $src = Join-Path $source $RelPath
  $dst = Join-Path $target $RelPath
  if (-not (Test-Path -LiteralPath $src)) { return }
  if (Test-Path -LiteralPath $src -PathType Container) {
    if (-not (Test-Path -LiteralPath $dst)) {
      New-Item -ItemType Directory -Path $dst -Force | Out-Null
      $created.Add("$RelPath\")
    }
    Get-ChildItem -LiteralPath $src | ForEach-Object {
      Copy-TemplateItem -RelPath (Join-Path $RelPath $_.Name)
    }
    return
  }
  if (Test-Path -LiteralPath $dst) {
    $skipped.Add($RelPath)
  } else {
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst
    $created.Add($RelPath)
  }
}

# Deep-merge: add keys from $tpl that are missing in $dst. Never overwrites existing values.
function Merge-Json {
  param($Dst, $Tpl)
  foreach ($p in $Tpl.PSObject.Properties) {
    if (-not $Dst.PSObject.Properties[$p.Name]) {
      $copy = if ($p.Value -is [System.Management.Automation.PSCustomObject]) {
        $clone = [pscustomobject]@{}
        Merge-Json -Dst $clone -Tpl $p.Value
        $clone
      } else { $p.Value }
      $Dst | Add-Member -NotePropertyName $p.Name -NotePropertyValue $copy
    } elseif ($p.Value -is [System.Management.Automation.PSCustomObject] -and $Dst.($p.Name) -is [System.Management.Automation.PSCustomObject]) {
      Merge-Json -Dst $Dst.($p.Name) -Tpl $p.Value
    }
  }
}

Write-Host "Installing opencode workflow template into: $target" -ForegroundColor Cyan

# 1. Files and folders (skip-existing)
$items = @("AGENTS.md", "CONTEXT.md", "docs", ".opencode", ".gitignore")
foreach ($i in $items) { Copy-TemplateItem -RelPath $i }

# 1b. .env from .env.example (skip if exists - never overwrite real keys)
$envExample = Join-Path $source ".env.example"
$envFile = Join-Path $target ".env"
if (Test-Path -LiteralPath $envFile) {
  $skipped.Add(".env")
} elseif (Test-Path -LiteralPath $envExample) {
  Copy-Item -LiteralPath $envExample -Destination $envFile
  $created.Add(".env")
}

# 2. opencode.json
$ocJson = Join-Path $target "opencode.json"
$ocJsonc = Join-Path $target "opencode.jsonc"
$tplJson = Get-Content -LiteralPath (Join-Path $source "opencode.template.json") -Raw | ConvertFrom-Json

if (Test-Path -LiteralPath $ocJsonc) {
  Write-Warning "opencode.jsonc exists - JSONC comments prevent safe merging. Merge manually:"
  Write-Host (Get-Content -LiteralPath (Join-Path $source "opencode.template.json") -Raw)
} elseif (Test-Path -LiteralPath $ocJson) {
  try {
    $cfg = Get-Content -LiteralPath $ocJson -Raw | ConvertFrom-Json
    Merge-Json -Dst $cfg -Tpl $tplJson
    $cfg | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ocJson -Encoding UTF8
    Write-Host "Merged mcp + permission into existing opencode.json (existing keys preserved)." -ForegroundColor Green
  } catch {
    Write-Warning "opencode.json merge failed: $($_.Exception.Message). Merge manually from opencode.template.json."
  }
} else {
  $tplJson | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ocJson -Encoding UTF8
  $created.Add("opencode.json")
}

# 3. Sanity checks
$required = @("grill-with-docs", "grilling", "domain-modeling", "to-spec", "to-tickets", "implement", "code-review", "tdd", "execute-task")
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $target ".opencode\skills\$_\SKILL.md")) })
if ($missing.Count -gt 0) {
  Write-Warning "Missing skills: $($missing -join ', '). grill-with-docs needs grilling + domain-modeling or it breaks."
} else {
  Write-Host "All $($required.Count) skills present (dependency chain intact)." -ForegroundColor Green
}
if (-not (Test-Path -LiteralPath (Join-Path $target ".git"))) {
  Write-Warning "Target is not a git repo - the workflow commits after each task. Run: git init"
}
$serena = Get-Command serena -ErrorAction SilentlyContinue
if (-not $serena) {
  $uv = Get-Command uv -ErrorAction SilentlyContinue
  if ($uv) {
    Write-Host "Serena CLI not found - installing via uv (may take a minute)..." -ForegroundColor Cyan
    & uv tool install -p 3.13 serena-agent
    if (Get-Command serena -ErrorAction SilentlyContinue) {
      Write-Host "Serena installed successfully." -ForegroundColor Green
    } else {
      Write-Warning "Serena installed but 'serena' is not on PATH in this session - open a new shell, or add uv's tools bin to PATH."
    }
  } else {
    Write-Warning "Serena CLI not found and uv is not installed. Install uv: https://docs.astral.sh/uv/getting-started/installation/ then run: uv tool install -p 3.13 serena-agent"
  }
}

# 4. Report
Write-Host ""
Write-Host "Created:" -ForegroundColor Green
$created | Sort-Object | ForEach-Object { Write-Host "  + $_" }
if ($skipped.Count -gt 0) {
  Write-Host "Skipped (already exist, untouched):" -ForegroundColor Yellow
  $skipped | Sort-Object | ForEach-Object { Write-Host "  = $_" }
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit .env to set CONTEXT7_API_KEY (optional - keyless works, just rate-limited)."
Write-Host "  2. Fill the placeholders in AGENTS.md (commands) and CONTEXT.md intro."
Write-Host "  3. Start opencode in this project; try /grill-with-docs on your next plan."
