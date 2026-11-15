#Requires -Version 5.1
<#
.SYNOPSIS
  Builds human-friendly changelog lines from git commits via Codex CLI (Windows).

.DESCRIPTION
  For each commit: reads message/author/date/diff, asks Codex for a short
  human-friendly explanation, then prints either a simplified MA journal
  line or Keep a Changelog (https://keepachangelog.com) style.

  MA line (date = commit date; no task/+ second date):
    18.09.2026		MA	Исправление ...  v8.8.1-13-g86484e445

  Keep a Changelog entry includes the short commit hash.

  Requires: git, Codex CLI (`codex`) already logged in / CODEX_API_KEY set.

  Codex is called as: codex exec --sandbox read-only --output-schema ... -
  Prompt (commit message + diff) is sent on stdin to avoid Windows argv line breaks.
  Progress goes to stderr; the final explanation is read from -o.

.EXAMPLE
  .\commit-changelog.ps1 -Commits a1b2c3d,e4f5a6b

.EXAMPLE
  .\commit-changelog.ps1 -From v8.8.1-3 -To HEAD -Format Ma -AuthorCode MA

.EXAMPLE
  .\commit-changelog.ps1 -CommitsFile .\commits.txt -Format KeepAChangelog -OutFile CHANGELOG.snippet.md

.EXAMPLE
  # Dry run without Codex (uses commit subject as description)
  .\commit-changelog.ps1 -Commits HEAD -SkipCodex
#>
[CmdletBinding(DefaultParameterSetName = 'List')]
param(
  [Parameter(ParameterSetName = 'List', Mandatory = $true, Position = 0)]
  [string[]] $Commits,

  [Parameter(ParameterSetName = 'Range')]
  [string] $From,

  [Parameter(ParameterSetName = 'Range')]
  [string] $To = 'HEAD',

  [Parameter(ParameterSetName = 'File')]
  [string] $CommitsFile,

  [ValidateSet('Ma', 'KeepAChangelog')]
  [string] $Format = 'Ma',

  [string] $AuthorCode = 'MA',

  [string] $RepoPath = (Get-Location).Path,

  [string] $OutFile,

  [string] $CodexCommand = 'codex',

  [string] $Model,

  [ValidateSet('low', 'medium', 'high', 'xhigh')]
  [string] $Effort = 'medium',

  [int] $DiffMaxChars = 12000,

  [string] $ReleaseDate,

  [switch] $SkipCodex,

  [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Err([string] $Message) {
  Write-Error -Message $Message -ErrorAction Stop
}

function Test-CommandExists([string] $Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-CodexExecutable([string] $Name) {
  $cmd = Get-Command $Name -ErrorAction Stop
  $src = $cmd.Source
  if ($src -match '\.exe$') { return $src }

  $dir = Split-Path -Parent $src
  $candidates = @(
    (Join-Path $dir 'codex.exe'),
    (Join-Path $dir 'node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\codex\codex.exe'),
    (Join-Path $dir 'node_modules\@openai\codex\vendor\x86_64-pc-windows-msvc\codex\codex.exe')
  )
  foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path }
  }
  return $src
}

function Get-CommitList {
  $list = New-Object System.Collections.Generic.List[string]

  switch ($PSCmdlet.ParameterSetName) {
    'List' {
      foreach ($c in $Commits) {
        foreach ($part in ($c -split '[,;\s]+')) {
          if ($part) { [void]$list.Add($part.Trim()) }
        }
      }
    }
    'File' {
      if (-not (Test-Path -LiteralPath $CommitsFile)) {
        Write-Err "Commits file not found: $CommitsFile"
      }
      Get-Content -LiteralPath $CommitsFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $sha = ($line -split '\s+')[0]
        if ($sha) { [void]$list.Add($sha) }
      }
    }
    'Range' {
      if (-not $From) { Write-Err '-From is required for range mode.' }
      $range = '{0}..{1}' -f $From, $To
      $raw = & git -C $RepoPath rev-list --reverse $range
      if ($LASTEXITCODE -ne 0) {
        Write-Err "git rev-list failed for range $range"
      }
      foreach ($sha in $raw) {
        if ($sha) { [void]$list.Add($sha.Trim()) }
      }
    }
  }

  if ($list.Count -eq 0) {
    Write-Err 'No commits to process.'
  }
  return $list
}

function Get-GitText([string[]] $GitArgs) {
  $out = & git -C $RepoPath @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Err ("git {0} failed: {1}" -f ($GitArgs -join ' '), ($out | Out-String))
  }
  if ($null -eq $out) { return '' }
  if ($out -is [array]) { return ($out -join "`n") }
  return [string]$out
}

function Format-RuDate([datetime] $Date) {
  return $Date.ToString('dd.MM.yyyy')
}

function Get-AuthorInitials([string] $AuthorName) {
  if (-not [string]::IsNullOrWhiteSpace($AuthorCode)) {
    return $AuthorCode
  }
  $parts = $AuthorName.Trim() -split '\s+'
  if ($parts.Count -eq 0) { return '??' }
  if ($parts.Count -eq 1) {
    return $parts[0].Substring(0, [Math]::Min(2, $parts[0].Length)).ToUpperInvariant()
  }
  return ($parts[0].Substring(0, 1) + $parts[1].Substring(0, 1)).ToUpperInvariant()
}

function Get-CommitInfo([string] $Ref) {
  $sha = (Get-GitText @('rev-parse', '--verify', "$Ref^{commit}")).Trim()
  $subject = (Get-GitText @('log', '-1', '--format=%s', $sha)).Trim()
  $body = (Get-GitText @('log', '-1', '--format=%b', $sha)).Trim()
  $author = (Get-GitText @('log', '-1', '--format=%an', $sha)).Trim()
  $iso = (Get-GitText @('log', '-1', '--format=%cI', $sha)).Trim()
  $commitDate = [datetimeoffset]::Parse($iso).LocalDateTime

  $describe = ''
  try {
    $describe = (Get-GitText @('describe', '--tags', '--always', $sha)).Trim()
  } catch {
    $describe = $sha.Substring(0, [Math]::Min(9, $sha.Length))
  }

  $stat = Get-GitText @('show', '--stat', '--format=', '--no-ext-diff', $sha)
  $patch = Get-GitText @('show', '--format=', '--no-ext-diff', '--unified=2', $sha)
  if ($patch.Length -gt $DiffMaxChars) {
    $patch = $patch.Substring(0, $DiffMaxChars) + "`n...[diff truncated]..."
  }

  return [pscustomobject]@{
    Sha         = $sha
    ShortSha    = $sha.Substring(0, [Math]::Min(9, $sha.Length))
    Subject     = $subject
    Body        = $body
    AuthorName  = $author
    CommitDate  = $commitDate
    Describe    = $describe
    Stat        = $stat
    Patch       = $patch
  }
}

function New-CodexPrompt([pscustomobject] $Info) {
  $bodyBlock = if ($Info.Body) { "`n`nCommit body:`n$($Info.Body)" } else { '' }
  return @"
Ты готовишь строку журнала изменений для релизных заметок продукта.

По данным git-коммита напиши ОДНО короткое human-friendly пояснение на русском.
Правила:
- Не копируй subject дословно: перефразируй понятным языком для пользователя/тестировщика.
- Сохрани важные сущности, коды модулей, имена экранов/панелей в кавычках, если они есть.
- Начни с типа: "Исправление:", "Улучшение:", "Функция:" или без префикса, если это точнее.
- 1 предложение, максимум 2. Без маркеров списка, без кавычек вокруг всей фразы.
- Не упоминай hash, автора, файлы, "commit", "diff".
- Если в коммите несколько изменений — объедини в одну связную фразу.

Commit subject: $($Info.Subject)$bodyBlock

git describe: $($Info.Describe)

Diffstat:
$($Info.Stat)

Diff (может быть обрезан):
$($Info.Patch)
"@
}

function Invoke-CodexExplain([pscustomobject] $Info) {
  if ($SkipCodex) {
    return $Info.Subject.Trim()
  }

  $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-changelog-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmpDir | Out-Null
  $promptFile = Join-Path $tmpDir 'prompt.txt'
  $outFile = Join-Path $tmpDir 'last.txt'
  $schemaFile = Join-Path $tmpDir 'schema.json'

  try {
    $schema = @'
{
  "type": "object",
  "properties": {
    "summary": {
      "type": "string",
      "description": "One short Russian human-friendly changelog explanation"
    }
  },
  "required": ["summary"],
  "additionalProperties": false
}
'@
    [System.IO.File]::WriteAllText($schemaFile, $schema, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($promptFile, (New-CodexPrompt $Info), [System.Text.UTF8Encoding]::new($false))

    $argList = New-Object System.Collections.Generic.List[string]
    [void]$argList.Add('exec')
    [void]$argList.Add('--skip-git-repo-check')
    [void]$argList.Add('--ephemeral')
    [void]$argList.Add('--sandbox')
    [void]$argList.Add('read-only')
    [void]$argList.Add('--output-schema')
    [void]$argList.Add($schemaFile)
    [void]$argList.Add('-o')
    [void]$argList.Add($outFile)
    [void]$argList.Add('--config')
    [void]$argList.Add(('model_reasoning_effort="{0}"' -f $Effort))
    if ($Model) {
      [void]$argList.Add('-m')
      [void]$argList.Add($Model)
    }
    [void]$argList.Add('-C')
    [void]$argList.Add($RepoPath)
    # Short argv instruction + long context on stdin (Windows-safe; avoids .cmd argv breakage).
    [void]$argList.Add('Сформируй human-friendly описание по данным коммита из stdin. Верни только JSON по output-schema.')

    $resolved = Resolve-CodexExecutable $CodexCommand
    Write-Verbose ("Codex: {0} {1}" -f $resolved, ($argList -join ' '))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $quoted = foreach ($a in $argList) {
      if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a }
    }
    $argString = ($quoted -join ' ')
    if ($resolved -match '\.(cmd|bat)$') {
      # .cmd cannot host redirected stdin under CreateProcess; run through cmd.exe.
      $psi.FileName = $env:ComSpec
      $psi.Arguments = '/d /s /c "' + ('"{0}" {1}' -f $resolved, $argString) + '"'
    } else {
      $psi.FileName = $resolved
      $psi.Arguments = $argString
    }
    $psi.WorkingDirectory = $RepoPath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    # Start reads before closing stdin so stderr progress cannot fill the pipe.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    $promptText = [System.IO.File]::ReadAllText($promptFile, [System.Text.UTF8Encoding]::new($false))
    $proc.StandardInput.Write($promptText)
    $proc.StandardInput.Close()

    $proc.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result

    if ($proc.ExitCode -ne 0) {
      Write-Err ("codex exec failed (exit {0}). stderr:`n{1}`nstdout:`n{2}" -f $proc.ExitCode, $stderr, $stdout)
    }

    $raw = ''
    if (Test-Path -LiteralPath $outFile) {
      $raw = [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false)).Trim()
    }
    if (-not $raw) { $raw = $stdout.Trim() }
    if (-not $raw) {
      Write-Err ("Codex returned empty explanation for {0}. stderr:`n{1}" -f $Info.ShortSha, $stderr)
    }

    try {
      $json = $raw | ConvertFrom-Json
      if ($json.summary) { return ([string]$json.summary).Trim() }
    } catch {
      # fall through: plain text
    }

    # Strip accidental markdown fences / quotes
    $text = $raw -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
    $text = $text.Trim().Trim('"').Trim("'")
    return $text
  }
  finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Format-MaLine(
  [pscustomobject] $Info,
  [string] $Summary,
  [string] $Code
) {
  $d1 = Format-RuDate $Info.CommitDate
  $ver = $Info.Describe
  if ($ver -notmatch [regex]::Escape($Info.ShortSha)) {
    $ver = '{0} ({1})' -f $ver, $Info.ShortSha
  }
  # Date = commit date (task-open date is not in git). No "+" / second date.
  return ("{0}`t`t{1}`t{2}  {3}" -f $d1, $Code, $Summary.Trim(), $ver)
}

function Get-KeepAChangelogSection([string] $Summary) {
  $s = $Summary.Trim()
  if ($s -match '^(?i)исправление\b') { return 'Fixed' }
  if ($s -match '^(?i)улучшение\b') { return 'Changed' }
  if ($s -match '^(?i)(функция|добавлен)\b') { return 'Added' }
  return 'Changed'
}

function Format-KeepAChangelogLine([pscustomobject] $Info, [string] $Summary) {
  $section = Get-KeepAChangelogSection $Summary
  # Keep a Changelog bullet; hash is always shown (short SHA).
  return [pscustomobject]@{
    Section = $section
    Line    = ('- {0} ({1}) [`{2}`]' -f $Summary.TrimEnd('.'), (Format-RuDate $Info.CommitDate), $Info.ShortSha)
  }
}

# --- main ---
if (-not (Test-CommandExists 'git')) {
  Write-Err 'git not found in PATH.'
}
if (-not $SkipCodex -and -not (Test-CommandExists $CodexCommand)) {
  Write-Err ("Codex CLI not found: {0}. Install/login Codex or pass -SkipCodex." -f $CodexCommand)
}
if (-not (Test-Path -LiteralPath (Join-Path $RepoPath '.git'))) {
  Write-Err ("Not a git repository: {0}" -f $RepoPath)
}

$refs = Get-CommitList

$maLines = New-Object System.Collections.Generic.List[string]
$kac = @{
  Added   = New-Object System.Collections.Generic.List[string]
  Changed = New-Object System.Collections.Generic.List[string]
  Fixed   = New-Object System.Collections.Generic.List[string]
  Removed = New-Object System.Collections.Generic.List[string]
}
$objects = New-Object System.Collections.Generic.List[object]

foreach ($ref in $refs) {
  Write-Host ("Processing {0} ..." -f $ref) -ForegroundColor Cyan
  $info = Get-CommitInfo $ref
  $summary = Invoke-CodexExplain $info
  $code = Get-AuthorInitials $info.AuthorName

  $obj = [pscustomobject]@{
    Sha        = $info.Sha
    ShortSha   = $info.ShortSha
    Date       = (Format-RuDate $info.CommitDate)
    AuthorCode = $code
    Summary    = $summary
    Describe   = $info.Describe
    Subject    = $info.Subject
  }
  [void]$objects.Add($obj)

  if ($Format -eq 'Ma') {
    [void]$maLines.Add((Format-MaLine $info $summary $code))
  } else {
    $row = Format-KeepAChangelogLine $info $summary
    [void]$kac[$row.Section].Add($row.Line)
  }
}

$output = New-Object System.Collections.Generic.List[string]
if ($Format -eq 'Ma') {
  foreach ($line in $maLines) { [void]$output.Add($line) }
} else {
  $titleDate = if ($ReleaseDate -match '^\d{4}-\d{2}-\d{2}$') {
    $ReleaseDate
  } elseif ($ReleaseDate) {
    # accept dd.MM.yyyy and convert
    try {
      [datetime]::ParseExact($ReleaseDate, 'dd.MM.yyyy', [System.Globalization.CultureInfo]::InvariantCulture).ToString('yyyy-MM-dd')
    } catch {
      (Get-Date).ToString('yyyy-MM-dd')
    }
  } else {
    (Get-Date).ToString('yyyy-MM-dd')
  }
  $versionLabel = if ($objects.Count -gt 0) { $objects[$objects.Count - 1].Describe } else { 'Unreleased' }
  [void]$output.Add(('## [{0}] - {1}' -f $versionLabel, $titleDate))
  [void]$output.Add('')
  foreach ($name in @('Added', 'Changed', 'Fixed', 'Removed')) {
    if ($kac[$name].Count -eq 0) { continue }
    [void]$output.Add(('### {0}' -f $name))
    [void]$output.Add('')
    foreach ($line in $kac[$name]) { [void]$output.Add($line) }
    [void]$output.Add('')
  }
}

$text = ($output -join "`r`n")
Write-Host ''
Write-Host '----- changelog -----' -ForegroundColor Green
Write-Output $text

if ($OutFile) {
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
  }
  [System.IO.File]::WriteAllText($OutFile, $text + "`r`n", [System.Text.UTF8Encoding]::new($false))
  Write-Host ("Wrote {0}" -f $OutFile) -ForegroundColor Green
}

if ($PassThru) {
  return $objects
}
