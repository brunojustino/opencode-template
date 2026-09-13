#Requires -Version 5.1
<#
.SYNOPSIS
  Installs the opencode workflow template into a project (new or ongoing).

.DESCRIPTION
  Safety model - nothing can be lost:
    - EVERY existing file the installer touches is backed up first to
      .template-backup\<timestamp>\<relative path> (re-runs create a new timestamped folder).
    - AGENTS.md / CONTEXT.md / .gitignore are merged into (idempotent markers / line merge).
    - .opencode skills + agents are updated to the template version.
    - Template-owned rules files (docs/rules/*.md, docs/plans/plan-template.md) are
      refreshed inside owt markers (backup-first); other docs/ files are created
      only if missing and never written.
    - opencode.json is JSON-merged (missing keys only) with a .pre-install.bak beside it.
    - A write-guard aborts rather than writing to any file not backed up in this run.

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
$backupStamp = (Get-Date).ToString("yyyyMMdd-HHmmss-fff")
$runBackup = Join-Path $target ".template-backup\$backupStamp"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath (Join-Path $source ".opencode\skills\grill-with-docs\SKILL.md"))) {
  throw "Template files not found next to install.ps1 (missing .opencode\skills). Run from the template root."
}

$created   = New-Object System.Collections.Generic.List[string]
$merged    = New-Object System.Collections.Generic.List[string]
$updated   = New-Object System.Collections.Generic.List[string]
$backedUp  = New-Object System.Collections.Generic.List[string]
$untouched = New-Object System.Collections.Generic.List[string]

# --- safety helpers -------------------------------------------------------------

function Backup-TemplateItem {
  param([string]$RelPath)
  $src = Join-Path $target $RelPath
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { return }
  $dst = Join-Path $runBackup $RelPath
  $dstDir = Split-Path -Parent $dst
  if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
  Copy-Item -LiteralPath $src -Destination $dst -Force
  if (-not $script:backedUp.Contains($RelPath)) { $script:backedUp.Add($RelPath) }
}

function Write-TemplateFile {
  # Guarded write: refuses to overwrite a file that was not backed up in this run.
  param([string]$RelPath, [string]$Text)
  $dst = Join-Path $target $RelPath
  if ((Test-Path -LiteralPath $dst -PathType Leaf) -and -not $script:backedUp.Contains($RelPath)) {
    throw "Refusing to write '$RelPath' - it exists but was not backed up this run. Aborting so nothing is lost."
  }
  $dstDir = Split-Path -Parent $dst
  if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
  [System.IO.File]::WriteAllText($dst, $Text, $utf8NoBom)
}

# --- merge helpers --------------------------------------------------------------

function Copy-TemplateTree {
  param([string]$RelPath, [ValidateSet("MissingOnly", "Update")][string]$Mode = "MissingOnly")
  $src = Join-Path $source $RelPath
  if (-not (Test-Path -LiteralPath $src)) { return }
  if (Test-Path -LiteralPath $src -PathType Container) {
    $items = Get-ChildItem -LiteralPath $src -Force
    foreach ($item in $items) {
      # Never copy dependency/VCS directories into the target.
      if ($item.PSIsContainer -and $item.Name -in @("node_modules", ".git")) { continue }
      # Never copy opencode runtime artifacts living at .opencode root (opencode/skills CLI
      # creates these per project; they are not template assets).
      if (-not $item.PSIsContainer -and $RelPath -eq ".opencode" -and
          $item.Name -in @("package.json", "package-lock.json", ".gitignore")) { continue }
      Copy-TemplateTree -RelPath (Join-Path $RelPath $item.Name) -Mode $Mode
    }
    return
  }
  $dst = Join-Path $target $RelPath
  if (Test-Path -LiteralPath $dst) {
    $srcText = "$(Get-Content -LiteralPath $src -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
    $dstText = "$(Get-Content -LiteralPath $dst -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
    if ($srcText.Trim() -eq $dstText.Trim()) {
      $script:untouched.Add($RelPath)
      return
    }
    Backup-TemplateItem -RelPath $RelPath
    if ($Mode -eq "Update") {
      Write-TemplateFile -RelPath $RelPath -Text $srcText
      $script:updated.Add($RelPath)
    } else {
      $script:untouched.Add($RelPath)
    }
  } else {
    Write-TemplateFile -RelPath $RelPath -Text "$(Get-Content -LiteralPath $src -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
    $script:created.Add($RelPath)
  }
}

function Merge-MarkdownBlock {
  # Idempotent markdown merge: appends/replaces the template inside owt markers.
  param([string]$RelPath)
  $tpl = "$(Get-Content -LiteralPath (Join-Path $source $RelPath) -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
  $file = Join-Path $target $RelPath
  if (-not (Test-Path -LiteralPath $file)) {
    Write-TemplateFile -RelPath $RelPath -Text $tpl
    $script:created.Add($RelPath)
    return
  }
  $content = "$(Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
  if ($content.Trim() -eq $tpl.Trim()) {
    $script:untouched.Add($RelPath)
    return
  }
  Backup-TemplateItem -RelPath $RelPath
  $start = "<!-- owt:start -->"
  $end = "<!-- owt:end -->"
  $block = "$start`n$tpl$end"
  if ($content.Contains($start) -and $content.Contains($end)) {
    $pre = $content.Substring(0, $content.IndexOf($start)).TrimEnd()
    $post = $content.Substring($content.IndexOf($end) + $end.Length)
    $new = $pre + "`n`n" + $block + "`n" + $post.TrimStart()
  } else {
    $new = $content.TrimEnd() + "`n`n" + $block + "`n"
  }
  Write-TemplateFile -RelPath $RelPath -Text $new
  $script:merged.Add($RelPath)
}

function Merge-GitIgnoreLines {
  param([string]$RelPath, [string[]]$Lines)
  $file = Join-Path $target $RelPath
  if (-not (Test-Path -LiteralPath $file)) {
    Write-TemplateFile -RelPath $RelPath -Text (($Lines -join "`r`n") + "`n")
    $script:created.Add($RelPath)
    return
  }
  Backup-TemplateItem -RelPath $RelPath
  $existing = @(Get-Content -LiteralPath $file -Encoding UTF8)
  $missing = @($Lines | Where-Object { $existing -notcontains $_ })
  if ($missing.Count -eq 0) {
    $script:untouched.Add($RelPath)
    return
  }
  $new = ($existing -join "`n").TrimEnd()
  if ($new.Length -gt 0) { $new += "`n`n" }
  $new += ($missing -join "`n") + "`n"
  Write-TemplateFile -RelPath $RelPath -Text $new
  $script:merged.Add($RelPath)
}

function Merge-ContextFile {
  param([string]$RelPath)
  $file = Join-Path $target $RelPath
  $tpl = "$(Get-Content -LiteralPath (Join-Path $source $RelPath) -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
  if (-not (Test-Path -LiteralPath $file)) {
    Write-TemplateFile -RelPath $RelPath -Text $tpl
    $script:created.Add($RelPath)
    return
  }
  Backup-TemplateItem -RelPath $RelPath
  $content = "$(Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
  if ($content -match "(?m)^## Language\s*$") {
    $script:untouched.Add($RelPath)
    return
  }
  $stub = @"

## Language

<!-- Terms appear here one by one as grill-with-docs / domain-modeling sessions resolve them.
Format: **Term**: a 1-2 sentence definition, plus _Avoid_: alternate words.
Pure vocabulary only - no implementation details, no specs. -->
"@
  $new = $content.TrimEnd() + "`n" + $stub + "`n"
  Write-TemplateFile -RelPath $RelPath -Text $new
  $script:merged.Add($RelPath)
}

function Merge-RulesFile {
  # Template-owned rules files: refresh inside owt markers, backup-first.
  # Marker-less files are stale template installs -> backup + replace with the
  # marker-wrapped template version (user content is diffable in .template-backup).
  param([string[]]$RelPaths)
  foreach ($RelPath in $RelPaths) {
    $file = Join-Path $target $RelPath
    if (-not (Test-Path -LiteralPath $file)) {
      Merge-MarkdownBlock -RelPath $RelPath
      continue
    }
    $content = "$(Get-Content -LiteralPath $file -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
    if ($content.Contains("<!-- owt:start -->") -and $content.Contains("<!-- owt:end -->")) {
      Merge-MarkdownBlock -RelPath $RelPath
    } else {
      Backup-TemplateItem -RelPath $RelPath
      $tpl = "$(Get-Content -LiteralPath (Join-Path $source $RelPath) -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)"
      Write-TemplateFile -RelPath $RelPath -Text $tpl
      $script:merged.Add($RelPath)
      Write-Host "  ~ $RelPath was marker-less (stale template install) - replaced; original in .template-backup" -ForegroundColor Yellow
    }
  }
}

function Merge-Json {
  # Deep-merge: add keys from $Tpl that are missing in $Dst. Never overwrites existing values.
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

# --- 0. preflight ---------------------------------------------------------------

Write-Host "Installing opencode workflow template into: $target" -ForegroundColor Cyan
if (Test-Path -LiteralPath (Join-Path $target ".git")) {
  $dirty = & git -C $target status --porcelain 2>$null
  if ($dirty) {
    Write-Warning "Target has uncommitted changes - consider committing first so you can review/revert the install via git."
  }
}

# --- 1. trees -------------------------------------------------------------------
# docs: create if missing, never modify existing project docs - except the
# template-owned rules files refreshed by Merge-RulesFile below.
Copy-TemplateTree -RelPath "docs" -Mode "MissingOnly"
Merge-RulesFile -RelPaths @(
  "docs\rules\task-execution.md",
  "docs\rules\git-workflow.md",
  "docs\rules\agent-constraints.md",
  "docs\plans\plan-template.md"
)
# .opencode skills + agent: versioned template assets -> backup + update
Copy-TemplateTree -RelPath ".opencode" -Mode "Update"

# --- 2. root files --------------------------------------------------------------
Merge-GitIgnoreLines -RelPath ".gitignore" -Lines @(".opencode/tmp/", ".opencode/node_modules/", ".template-backup/", ".env", "Thumbs.db", ".DS_Store")
Merge-MarkdownBlock -RelPath "AGENTS.md"
Merge-ContextFile -RelPath "CONTEXT.md"

# .env: backed up every run, NEVER written when it exists
$envFile = Join-Path $target ".env"
if (Test-Path -LiteralPath $envFile) {
  Backup-TemplateItem -RelPath ".env"
  $untouched.Add(".env")
} elseif (Test-Path -LiteralPath (Join-Path $source ".env.example")) {
  Write-TemplateFile -RelPath ".env" -Text (Get-Content -LiteralPath (Join-Path $source ".env.example") -Raw -Encoding UTF8)
  $created.Add(".env")
}

# opencode.json: backup + JSON merge (missing keys only)
$ocJson = Join-Path $target "opencode.json"
$ocJsonc = Join-Path $target "opencode.jsonc"
$tplJson = Get-Content -LiteralPath (Join-Path $source "opencode.template.json") -Raw -Encoding UTF8 | ConvertFrom-Json

if (Test-Path -LiteralPath $ocJsonc) {
  Write-Warning "opencode.jsonc exists - JSONC comments prevent safe merging. Merge manually from opencode.template.json:"
  Write-Host (Get-Content -LiteralPath (Join-Path $source "opencode.template.json") -Raw -Encoding UTF8)
} elseif (Test-Path -LiteralPath $ocJson) {
  try {
    Backup-TemplateItem -RelPath "opencode.json"
    Copy-Item -LiteralPath $ocJson -Destination "$ocJson.pre-install.bak" -Force
    $cfg = Get-Content -LiteralPath $ocJson -Raw -Encoding UTF8 | ConvertFrom-Json
    Merge-Json -Dst $cfg -Tpl $tplJson
    $json = ($cfg | ConvertTo-Json -Depth 20) + "`n"
    Write-TemplateFile -RelPath "opencode.json" -Text $json
    $script:merged.Add("opencode.json")
    Write-Host "Merged mcp + permission into existing opencode.json (existing keys preserved)." -ForegroundColor Green
  } catch {
    Write-Warning "opencode.json merge failed: $($_.Exception.Message). Restore from .template-backup\$backupStamp\opencode.json if needed."
  }
} else {
  Write-TemplateFile -RelPath "opencode.json" -Text (($tplJson | ConvertTo-Json -Depth 20) + "`n")
  $created.Add("opencode.json")
}

# --- 3. sanity checks -----------------------------------------------------------
$required = @("grill-with-docs", "grilling", "domain-modeling", "to-spec", "to-tickets", "implement", "code-review", "tdd", "execute-task", "analyze-architecture")
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

# --- 4. report ------------------------------------------------------------------
Write-Host ""
if ($backedUp.Count -gt 0) {
  Write-Host "Backed up to .template-backup\$backupStamp\:" -ForegroundColor Cyan
  $backedUp | Sort-Object | ForEach-Object { Write-Host "  ~ $_" }
}
if ($created.Count -gt 0) {
  Write-Host "Created:" -ForegroundColor Green
  $created | Sort-Object | ForEach-Object { Write-Host "  + $_" }
}
if ($merged.Count -gt 0) {
  Write-Host "Merged (existing content preserved):" -ForegroundColor Green
  $merged | Sort-Object | ForEach-Object { Write-Host "  * $_" }
}
if ($updated.Count -gt 0) {
  Write-Host "Updated to template version:" -ForegroundColor Green
  $updated | Sort-Object | ForEach-Object { Write-Host "  ^ $_" }
}
if ($untouched.Count -gt 0) {
  Write-Host "Left untouched:" -ForegroundColor Yellow
  $untouched | Sort-Object | ForEach-Object { Write-Host "  = $_" }
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Edit .env to set CONTEXT7_API_KEY (optional - keyless works, just rate-limited)."
Write-Host "  2. Review AGENTS.md: your content is above the owt block, the template router inside it."
Write-Host "  3. Start opencode in this project; try /grill-with-docs on your next plan."
Write-Host "  4. To restore anything: copy files back from .template-backup\$backupStamp\"
