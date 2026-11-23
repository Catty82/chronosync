# Проверка time-sync.ps1 без изменения часов системы.
#requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $root 'time-sync.ps1'
$cmdPath = Join-Path $root 'time-sync.cmd'
$fail = $false
$script:LastOut = ''

function Write-Line([string]$Message) {
  [Console]::Out.WriteLine($Message)
}

function Fail-Case([string]$Name, [string]$Detail) {
  [Console]::Error.WriteLine("FAIL $Name $Detail")
  if (-not [string]::IsNullOrEmpty($script:LastOut)) {
    [Console]::Error.WriteLine($script:LastOut)
  }
  $script:FailFlag = $true
}

$script:FailFlag = $false

function Assert-Crlf([string]$Path, [bool]$WantBom) {
  $name = Split-Path -Leaf $Path
  $bytes = [IO.File]::ReadAllBytes($Path)
  $hasCrlf = $false
  $bareLf = $false
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq 10) {
      if ($i -eq 0 -or $bytes[$i - 1] -ne 13) { $bareLf = $true } else { $hasCrlf = $true }
    }
  }
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  if (-not $hasCrlf -or $bareLf) { Fail-Case "CRLF $name" 'ожидались только CRLF' }
  else { Write-Line "OK CRLF $name" }
  if ($WantBom -and -not $bom) { Fail-Case "BOM $name" 'нет UTF-8 BOM' }
  elseif ($WantBom) { Write-Line "OK BOM $name" }
  if (-not $WantBom -and $bom) { Fail-Case "BOM $name" 'лишний BOM' }
  elseif (-not $WantBom) { Write-Line "OK no BOM $name" }
}

if (-not (Test-Path -LiteralPath $scriptPath)) { [Console]::Error.WriteLine("Нет файла $scriptPath"); exit 1 }

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
if ($errors -and @($errors).Count -gt 0) {
  [Console]::Error.WriteLine('FAIL parse')
  foreach ($err in @($errors)) { [Console]::Error.WriteLine($err.ToString()) }
  exit 1
}
Write-Line 'OK parse'

Assert-Crlf $scriptPath $true
Assert-Crlf $cmdPath $false
$cmdText = [IO.File]::ReadAllText($cmdPath)
if ($cmdText.Contains('time-sync.ps1') -and $cmdText.Contains('-ExecutionPolicy Bypass')) { Write-Line 'OK cmd launcher' }
else { Fail-Case 'cmd launcher' 'нет вызова time-sync.ps1' }

function Invoke-Case([string]$Name, [int]$Expected, [string[]]$ArgList) {
  $exe = (Get-Process -Id $PID).Path
  $out = & $exe -NoProfile -File $scriptPath @ArgList 2>&1 | Out-String
  $code = $LASTEXITCODE
  $script:LastOut = [string]$out
  if ($code -ne $Expected) {
    Fail-Case $Name "(код $code, ожидался $Expected)"
    return
  }
  Write-Line "OK $Name"
}

function Assert-Contains([string]$Name, [string]$Needle) {
  if ($script:LastOut.Contains($Needle)) { Write-Line "OK $Name"; return }
  Fail-Case $Name "нет строки: $Needle"
}

function Assert-NotContains([string]$Name, [string]$Needle) {
  if (-not $script:LastOut.Contains($Needle)) { Write-Line "OK $Name"; return }
  Fail-Case $Name "лишняя строка: $Needle"
}

Remove-Item Env:CHRONOSYNC_ENGINE -ErrorAction SilentlyContinue
Remove-Item Env:CHRONOSYNC_ALLOW -ErrorAction SilentlyContinue

Invoke-Case 'self-test' 0 @('self-test')
Assert-Contains 'self-test ok' 'self-test: ok'

Invoke-Case 'help' 0 @('--help')
Assert-Contains 'help sync-from' 'sync-from'
Assert-Contains 'help check' 'check'
Assert-NotContains 'help ok' 'CHRONOSYNC_OK'

Invoke-Case 'no args' 1 @()
Assert-NotContains 'no args ok' 'CHRONOSYNC_OK'

Invoke-Case 'bad mode' 1 @('--dry-run', 'frobnicate')
Assert-NotContains 'bad mode ok' 'CHRONOSYNC_OK'

Invoke-Case 'set without time' 1 @('--dry-run', 'set-time')
Invoke-Case 'bad time' 1 @('--dry-run', 'set-time', '2026-13-40 00:00:00')
Invoke-Case 'bad host' 1 @('--dry-run', 'sync-from', '192.168.0.256')
Invoke-Case 'ipv6' 1 @('--dry-run', 'sync-from', '2001:db8::1')
Assert-Contains 'ipv6 msg' 'IPv6'
Invoke-Case 'flag host' 1 @('--dry-run', 'sync-from', '--', '-rf')
Invoke-Case 'allow on set' 1 @('--dry-run', 'set-time', '--allow', '10.1.0.0/16', '1761307080')
Invoke-Case 'two hosts' 1 @('--dry-run', 'sync-from', '192.168.0.10', 'extra')
Invoke-Case 'bad allow' 1 @('--dry-run', 'time-server', '--allow', '10.1.2.3/33')

$before = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Invoke-Case 'dry set epoch' 0 @('--dry-run', 'set-time', '1761307080')
$after = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$delta = [Math]::Abs([int64]$after - [int64]$before)
if ($delta -gt 30) { Fail-Case 'clock unchanged' "часы изменились на $delta с" } else { Write-Line 'OK clock unchanged' }
Assert-Contains 'dry set date' '[dry-run] Set-Date @1761307080'
Assert-Contains 'dry set ok' 'CHRONOSYNC_OK mode=set-time'
Assert-Contains 'dry set ntp off' 'Службы синхронизации времени выключены'
Assert-Contains 'dry set disabled' '[dry-run] Set-Service W32Time -StartupType Disabled'
Assert-NotContains 'dry set windows' 'time.windows.com'

Invoke-Case 'dry set wall' 0 @('--dry-run', 'set-time', '2026-10-24', '14:18:00+05:00')
Assert-Contains 'wall spec' '[dry-run] Set-Date 2026-10-24 14:18:00+05:00'

Invoke-Case 'dry set ru' 0 @('--dry-run', 'время', '24.10.2026 14:18:00')
Assert-Contains 'ru spec' '[dry-run] Set-Date 2026-10-24 14:18:00'

Invoke-Case 'dry server' 0 @('--dry-run', 'time-server', '1761307080')
Assert-Contains 'server nosync' 'Type=NoSync'
Assert-Contains 'server announce' 'AnnounceFlags=5'
Assert-Contains 'server on' 'TimeProviders\NtpServer Enabled=1'
Assert-Contains 'server client off' 'TimeProviders\NtpClient Enabled=0'
Assert-Contains 'server allow' '192.168.0.0/16'
Assert-Contains 'server link' '169.254.0.0/16'
Assert-Contains 'server ok' 'CHRONOSYNC_OK mode=time-server engine=w32time sync=standalone'
Assert-Contains 'server standalone log' 'Синхронизация upstream: выкл.'
Assert-Contains 'server engine' 'Движок: w32time'
Assert-Contains 'server date' '[dry-run] Set-Date @1761307080'
Assert-Contains 'server compat' 'AllowNonstandardModeCombinations=1'
Assert-NotContains 'server pool' 'pool.ntp.org'
Assert-NotContains 'server windows' 'time.windows.com'
Assert-NotContains 'server peer' ',0x8'
Assert-NotContains 'server type ntp' 'Type=NTP'

Invoke-Case 'dry server no time' 0 @('--dry-run', 'сервер')
Assert-Contains 'warn no time' 'время не передано'
Assert-NotContains 'no date' '[dry-run] Set-Date'

Invoke-Case 'dry allow' 0 @('--dry-run', 'time-server', '--allow', '10.50.1.5/16', '1761307080')
Assert-Contains 'extra allow' '10.50.0.0/16'

Invoke-Case 'dry server upstream' 0 @('--dry-run', 'time-server', '--upstream', '10.0.0.5,ntp.example.com', '1761307080')
Assert-Contains 'upstream type' 'Type=NTP'
Assert-Contains 'upstream peer' 'NtpServer=10.0.0.5,0x8 ntp.example.com,0x8'
Assert-Contains 'upstream client on' 'TimeProviders\NtpClient Enabled=1'
Assert-Contains 'upstream log' 'Синхронизация upstream: 10.0.0.5 ntp.example.com'
Assert-Contains 'upstream ok' 'CHRONOSYNC_OK mode=time-server engine=w32time sync=upstream upstream=10.0.0.5,ntp.example.com'

Invoke-Case 'upstream on client' 1 @('--dry-run', 'sync-from', '--upstream', '10.0.0.5', '192.168.0.10')
Invoke-Case 'upstream empty' 1 @('--dry-run', 'time-server', '--upstream')
Invoke-Case 'upstream conflict' 1 @('--dry-run', 'time-server', '--standalone', '--upstream', '10.0.0.5')
Invoke-Case 'bad upstream' 1 @('--dry-run', 'time-server', '--upstream', '192.168.0.256')

$env:CHRONOSYNC_ALLOW = '10.50.1.5/16'
try {
  Invoke-Case 'dry allow env' 0 @('--dry-run', 'time-server')
  Assert-Contains 'env allow' '10.50.0.0/16'
} finally {
  Remove-Item Env:CHRONOSYNC_ALLOW -ErrorAction SilentlyContinue
}

Invoke-Case 'dry client' 0 @('--dry-run', 'sync-from', '192.168.0.10')
Assert-Contains 'client server' 'NtpServer=192.168.0.10,0x8'
Assert-Contains 'client type' 'Type=NTP'
Assert-Contains 'client on' 'TimeProviders\NtpClient Enabled=1'
Assert-Contains 'client server off' 'TimeProviders\NtpServer Enabled=0'
Assert-Contains 'client phase' 'MaxPosPhaseCorrection=4294967295'
Assert-Contains 'client ok' 'CHRONOSYNC_OK mode=sync-from engine=w32time server=192.168.0.10'
Assert-Contains 'client firewall' 'remoteip=192.168.0.10'
Assert-NotContains 'client reliable' 'AnnounceFlags=5'
Assert-NotContains 'client pool' 'pool.ntp.org'
Assert-NotContains 'client windows' 'time.windows.com'
Assert-NotContains 'client nosync' 'Type=NoSync'

Invoke-Case 'dry client alias' 0 @('--dry-run', 'клиент', 'time-server.lan')
Assert-Contains 'alias server' 'NtpServer=time-server.lan,0x8'
Assert-Contains 'alias name firewall' 'адрес сервера не IPv4'

$env:CHRONOSYNC_ENGINE = 'openntpd'
try {
  Invoke-Case 'bad engine' 1 @('--dry-run', 'time-server')
  Assert-Contains 'bad engine msg' 'W32Time'
  Assert-NotContains 'bad engine ok' 'CHRONOSYNC_OK'
} finally {
  Remove-Item Env:CHRONOSYNC_ENGINE -ErrorAction SilentlyContinue
}

$env:CHRONOSYNC_ENGINE = 'w32time'
try {
  Invoke-Case 'forced engine' 0 @('--dry-run', 'sync-from', '10.1.2.3')
  Assert-Contains 'forced ok' 'CHRONOSYNC_OK mode=sync-from engine=w32time server=10.1.2.3'
} finally {
  Remove-Item Env:CHRONOSYNC_ENGINE -ErrorAction SilentlyContinue
}

$before = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Invoke-Case 'check' 0 @('check')
$after = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$delta = [Math]::Abs([int64]$after - [int64]$before)
if ($delta -gt 30) { Fail-Case 'check clock' "часы изменились на $delta с" } else { Write-Line 'OK check clock' }
Assert-Contains 'check local' 'Время устройства (локальное):'
Assert-Contains 'check utc' 'Время устройства (UTC):'
Assert-Contains 'check unix' 'Unix-время:'
Assert-Contains 'check is server' 'Сервер времени:'
Assert-Contains 'check is client' 'Клиент сервера времени:'
Assert-Contains 'check ok' 'CHRONOSYNC_OK mode=check'
Invoke-Case 'check extra' 1 @('check', 'лишнее')
Assert-NotContains 'check extra ok' 'CHRONOSYNC_OK'
Invoke-Case 'check alias' 0 @('проверка')
Assert-Contains 'check alias ok' 'CHRONOSYNC_OK mode=check'

if ($script:FailFlag) {
  [Console]::Error.WriteLine('Тесты не прошли')
  exit 1
}
Write-Line 'Все проверки прошли'
exit 0
