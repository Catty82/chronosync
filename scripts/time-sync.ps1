# Синхронизация времени для Windows 10.
#
# Windows-вариант scripts/time-sync.sh. Для установщика:
#   time-sync.cmd set-time <время>
#   time-sync.cmd time-server [время] [--standalone | --keep-upstream | --upstream <сервер>]
#                             [--allow a.b.c.d/nn]
#   time-sync.cmd sync-from <ip-или-имя-сервера>
#   time-sync.cmd sync-from --internet
#   time-sync.cmd check
#
# Почему PowerShell, а не batch и не Python.
# Windows 10 уже содержит Windows PowerShell 5.1 и службу W32Time.
# Python на машине установщика может не стоять. Batch плохо проверяет
# адреса и даты. Отдельный chrony или Meinberg NTP не нужен: и сервер,
# и клиент — это W32Time на udp/123.
#
# set-time выставляет часы и выключает синхронизацию.
# time-server по умолчанию (--standalone) раздаёт локальные часы и не ходит вверх.
# --keep-upstream сохраняет текущие внешние серверы NTP.
# --upstream задаёт один или несколько upstream-серверов (через запятую или повтор флага).
# sync-from берёт время только с указанного сервера и отключает раздачу.
#
# Нужны права администратора. Логин и пароль скрипт не принимает.
# Файл в UTF-8 с BOM: так PowerShell 5.1 читает русский текст на любой локали.
# Переводы строк — CRLF.

#requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
  $PSNativeCommandUseErrorActionPreference = $false
}

try {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [Console]::OutputEncoding = $utf8
  [Console]::InputEncoding = $utf8
  $script:OutputEncoding = $utf8
} catch {
}

$script:DryRun = $false
$script:Action = ''
$script:Rest = ''
$script:Allow = ''
$script:AllowFlag = $false
$script:ServerSync = 'standalone'
$script:ServerSyncChosen = $false
$script:UpstreamList = New-Object System.Collections.Generic.List[string]
$script:ServerUpstreamMode = 'none'
$script:Engine = ''
$script:Server = ''
$script:ClientInternet = $false
$script:NormKind = ''
$script:NormSpec = ''
$script:NormDto = $null
$script:NormLocal = $null
$script:Fails = 0

$script:RegBase = 'HKLM\SYSTEM\CurrentControlSet\Services\W32Time'
$script:RegDrive = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time'
$script:StateDir = 'C:\ProgramData\chronosync'

function Write-Line([string]$Message) {
  [Console]::Out.WriteLine($Message)
}

function Die([string]$Message) {
  [Console]::Error.WriteLine("Ошибка: $Message")
  exit 1
}

function Write-Ok([string]$Payload) {
  Write-Line "CHRONOSYNC_OK $Payload"
}

function Show-Usage {
  param([switch]$ToError)
  $text = @'
Использование:
  time-sync.cmd set-time <время>
  time-sync.cmd time-server [время] [--standalone | --keep-upstream | --upstream <сервер>]
  time-sync.cmd sync-from <адрес-сервера-времени>
  time-sync.cmd sync-from --internet
  time-sync.cmd check
  time-sync.cmd --dry-run <режим> [аргументы]
  time-sync.cmd self-test

Время:
  1761307080                         Unix-секунды, предпочтительно
  2026-10-24 14:18:00+05:00          абсолютное время со смещением
  2026-10-24 14:18:00Z               время UTC
  2026-10-24 14:18:00                локальное время устройства
  24.10.2026 14:18:00                локальное время устройства

Режимы:
  set-time      выставить время и выключить синхронизацию
  time-server   сделать это устройство сервером времени (udp/123)
  sync-from     брать время с сервера, настроенного как time-server
  check         показать время, роль сервера и адрес внешнего сервера

time-server и синхронизация (выберите один вариант; по умолчанию --standalone):
  --standalone      только локальные часы, без upstream (как раньше)
  --keep-upstream   оставить текущие внешние серверы NTP на устройстве
  --upstream <сервер>  задать upstream; через запятую или повтор флага

sync-from --internet берёт время из публичного NTP-пула, если имя сервера неизвестно:
  0.pool.ntp.org  1.pool.ntp.org  2.pool.ntp.org  3.pool.ntp.org
Слово internet (или интернет) означает то же, что --internet.

Примеры:
  time-sync.cmd time-server --keep-upstream
  time-sync.cmd time-server --upstream 10.0.0.1,pool.ntp.org
  time-sync.cmd sync-from --internet

Дополнительные имена режимов: set, server, client, check, время, сервер, клиент, проверка.

Служба — встроенная W32Time. sync-from с адресом использует один указанный сервер.
sync-from --internet использует публичный NTP-пул.
--allow добавляет одну сеть к частным диапазонам, которым сервер отдаёт время.
То же самое делает переменная CHRONOSYNC_ALLOW=a.b.c.d/nn.
CHRONOSYNC_SERVER_SYNC=standalone|keep|upstream выбирает режим для time-server.
CHRONOSYNC_UPSTREAM=host1,host2 задаёт upstream (это --upstream).
CHRONOSYNC_ENGINE на Windows может быть только w32time.

Логин, пароль и IP подключения скрипт не принимает.
Пароль в аргументы не передавайте.
'@
  if ($ToError) {
    [Console]::Error.WriteLine($text)
  } else {
    [Console]::Out.WriteLine($text)
  }
}

function Test-IsWindows {
  return ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
}

function Test-ValidOctet([string]$Octet) {
  if ($Octet -cnotmatch '^[0-9]+$') { return $false }
  if ($Octet.Length -gt 1 -and $Octet.StartsWith('0')) { return $false }
  $number = [int]$Octet
  return ($number -ge 0 -and $number -le 255)
}

function Test-ValidIpv4([string]$Ip) {
  if ($Ip -cnotmatch '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') { return $false }
  foreach ($octet in $Ip.Split('.')) {
    if (-not (Test-ValidOctet $octet)) { return $false }
  }
  return $true
}

function Test-ValidHost([string]$HostName) {
  if ([string]::IsNullOrEmpty($HostName)) { return $false }
  if ($HostName.StartsWith('-')) { return $false }
  if ($HostName -cmatch '^[0-9]{1,3}(\.[0-9]{1,3}){3}$') {
    if (-not (Test-ValidIpv4 $HostName)) { return $false }
    if ($HostName -eq '0.0.0.0' -or $HostName -eq '255.255.255.255') { return $false }
    return $true
  }
  if ($HostName.Length -gt 253) { return $false }
  $pattern = '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
  if ($HostName -cnotmatch $pattern) { return $false }
  return $true
}

function Test-ValidTime([string]$Value) {
  if ([string]::IsNullOrEmpty($Value)) { return $false }
  if ($Value -cmatch '^[0-9]{9,12}$') { return $true }
  if ($Value -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:?[0-9]{2}|Z)?$') {
    return $true
  }
  if ($Value -cmatch '^[0-9]{2}\.[0-9]{2}\.[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}$') { return $true }
  return $false
}

function Format-UInt32([uint64]$Number) {
  $Number = $Number -band 4294967295
  $b1 = [int]([Math]::Floor($Number / 16777216) % 256)
  $b2 = [int]([Math]::Floor($Number / 65536) % 256)
  $b3 = [int]([Math]::Floor($Number / 256) % 256)
  $b4 = [int]($Number % 256)
  return "$b1.$b2.$b3.$b4"
}

function ConvertTo-NetMaskPair([string]$Cidr) {
  if ($Cidr -cnotmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') { return '' }
  $o1 = [uint64]$Matches[1]
  $o2 = [uint64]$Matches[2]
  $o3 = [uint64]$Matches[3]
  $o4 = [uint64]$Matches[4]
  $prefix = [int]$Matches[5]
  if ($prefix -lt 1 -or $prefix -gt 32) { return '' }
  if ($o1 -gt 255 -or $o2 -gt 255 -or $o3 -gt 255 -or $o4 -gt 255) { return '' }
  $ipnum = $o1 * 16777216 + $o2 * 65536 + $o3 * 256 + $o4
  $mod = [uint64]1
  $shift = 32 - $prefix
  for ($i = 0; $i -lt $shift; $i++) { $mod = $mod * 2 }
  $netnum = $ipnum - ($ipnum % $mod)
  $mask = [uint64]0
  for ($i = 0; $i -lt 32; $i++) {
    $mask = $mask * 2
    if ($i -lt $prefix) { $mask = $mask + 1 }
  }
  return "$(Format-UInt32 $netnum) $(Format-UInt32 $mask)"
}

function Test-ValidCidr([string]$Cidr) {
  return -not [string]::IsNullOrEmpty((ConvertTo-NetMaskPair $Cidr))
}

function ConvertTo-NetworkCidr([string]$Cidr) {
  $pair = ConvertTo-NetMaskPair $Cidr
  if ([string]::IsNullOrEmpty($pair)) { return '' }
  $net = ($pair -split ' ')[0]
  $prefix = [int]($Cidr.Split('/')[1])
  return "$net/$prefix"
}

function ConvertTo-NormalizedTime([string]$Value) {
  $script:NormKind = ''
  $script:NormSpec = ''
  $script:NormDto = $null
  $script:NormLocal = $null
  if (-not (Test-ValidTime $Value)) { return $false }
  if ($Value -cmatch '^[0-9]{9,12}$') {
    try {
      $dto = [DateTimeOffset]::FromUnixTimeSeconds([int64]$Value)
    } catch {
      return $false
    }
    $script:NormKind = 'epoch'
    $script:NormSpec = "@$Value"
    $script:NormDto = $dto
    return $true
  }
  if ($Value -cmatch '^([0-9]{2})\.([0-9]{2})\.([0-9]{4}) ([0-9]{2}:[0-9]{2}:[0-9]{2})$') {
    $iso = '{0}-{1}-{2} {3}' -f $Matches[3], $Matches[2], $Matches[1], $Matches[4]
    try {
      $local = [DateTime]::ParseExact($iso, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    } catch {
      return $false
    }
    $script:NormKind = 'local'
    $script:NormSpec = $iso
    $script:NormLocal = $local
    return $true
  }
  $clean = $Value.Replace('T', ' ')
  $parse = $clean
  if ($parse.EndsWith('Z')) {
    $parse = $parse.Substring(0, $parse.Length - 1) + '+00:00'
  } elseif ($parse -cmatch '[+-][0-9]{4}$') {
    $parse = $parse.Substring(0, $parse.Length - 2) + ':' + $parse.Substring($parse.Length - 2)
  }
  $absolute = $clean -cmatch 'Z$|[+-][0-9]{2}:?[0-9]{2}$'
  if ($absolute) {
    try {
      $dto = [DateTimeOffset]::ParseExact($parse, 'yyyy-MM-dd HH:mm:sszzz', [Globalization.CultureInfo]::InvariantCulture)
    } catch {
      return $false
    }
    $script:NormKind = 'absolute'
    $script:NormSpec = $clean
    $script:NormDto = $dto
    return $true
  }
  try {
    $local = [DateTime]::ParseExact($clean, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
  } catch {
    return $false
  }
  $script:NormKind = 'local'
  $script:NormSpec = $clean
  $script:NormLocal = $local
  return $true
}

function Set-ServerSyncMode([string]$Mode) {
  if ($script:ServerSyncChosen -and $script:ServerSync -ne $Mode) {
    Die 'Для time-server укажите только один из параметров: --standalone, --keep-upstream, --upstream.'
  }
  $script:ServerSync = $Mode
  $script:ServerSyncChosen = $true
}

function Add-UpstreamHostsFromCsv([string]$Csv) {
  if ([string]::IsNullOrWhiteSpace($Csv)) { return }
  foreach ($item in (($Csv -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
  if ($item.Contains(':')) { Die "Нужен IPv4-адрес или DNS-имя для --upstream. IPv6 не поддерживается: $item" }
    if (-not (Test-ValidHost $item)) { Die "Некорректный адрес upstream: $item" }
    if (-not $script:UpstreamList.Contains($item)) { [void]$script:UpstreamList.Add($item) }
  }
}

function Apply-ChronoSyncUpstreamEnv {
  if (-not [string]::IsNullOrWhiteSpace([string]$env:CHRONOSYNC_UPSTREAM)) {
    Set-ServerSyncMode 'upstream'
    Add-UpstreamHostsFromCsv ([string]$env:CHRONOSYNC_UPSTREAM)
  }
  $forced = [string]$env:CHRONOSYNC_SERVER_SYNC
  if (-not [string]::IsNullOrWhiteSpace($forced)) {
    if ($forced -ne 'standalone' -and $forced -ne 'keep' -and $forced -ne 'upstream') {
      Die 'CHRONOSYNC_SERVER_SYNC должен быть standalone, keep или upstream.'
    }
    Set-ServerSyncMode $forced
  }
}

function Parse-TimeServerOption([string]$Option, [string]$Arg) {
  switch ($Option) {
    '--standalone' { Set-ServerSyncMode 'standalone'; return }
    '--keep-upstream' { Set-ServerSyncMode 'keep'; return }
    '--upstream' {
      if ([string]::IsNullOrWhiteSpace($Arg)) { Die '--upstream требует адрес сервера NTP (IPv4 или DNS).' }
      Set-ServerSyncMode 'upstream'
      Add-UpstreamHostsFromCsv $Arg
      return
    }
    default { Die "Неизвестный параметр time-server: $Option" }
  }
}

function Parse-TimeServerRest {
  if ([string]::IsNullOrWhiteSpace($script:Rest)) { return }
  $tokens = @($script:Rest -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $timeTokens = New-Object System.Collections.Generic.List[string]
  $index = 0
  while ($index -lt $tokens.Count) {
    $token = [string]$tokens[$index]
    if ($token -eq '--standalone' -or $token -eq '--keep-upstream') {
      Parse-TimeServerOption $token ''
      $index++
      continue
    }
    if ($token -eq '--upstream') {
      $index++
      if ($index -ge $tokens.Count) { Die '--upstream требует адрес сервера NTP (IPv4 или DNS).' }
      Parse-TimeServerOption '--upstream' ([string]$tokens[$index])
      $index++
      continue
    }
    if ($token.StartsWith('--')) { Die "Неизвестный параметр time-server: $token" }
    [void]$timeTokens.Add($token)
    $index++
  }
  if ($timeTokens.Count -gt 0) {
    $script:Rest = ($timeTokens -join ' ')
  } else {
    $script:Rest = ''
  }
}

function Parse-Arguments {
  $argv = @($args)
  $items = New-Object System.Collections.Generic.List[string]
  $script:ServerSync = 'standalone'
  $script:ServerSyncChosen = $false
  $script:UpstreamList = New-Object System.Collections.Generic.List[string]
  $script:ServerUpstreamMode = 'none'
  $script:ClientInternet = $false
  $index = 0
  $literal = $false
  while ($index -lt $argv.Count) {
    $token = [string]$argv[$index]
    if (-not $literal -and $token -eq '--dry-run') {
      $script:DryRun = $true
      $index++
      continue
    }
    if (-not $literal -and $token -eq '--allow') {
      if (($index + 1) -ge $argv.Count) { Die '--allow требует сеть в виде a.b.c.d/nn' }
      $script:Allow = [string]$argv[$index + 1]
      $script:AllowFlag = $true
      $index += 2
      continue
    }
    if (-not $literal -and ($token -eq '--standalone' -or $token -eq '--keep-upstream')) {
      Parse-TimeServerOption $token ''
      $index++
      continue
    }
    if (-not $literal -and $token -eq '--upstream') {
      if (($index + 1) -ge $argv.Count) { Die '--upstream требует адрес сервера NTP (IPv4 или DNS).' }
      Parse-TimeServerOption '--upstream' ([string]$argv[$index + 1])
      $index += 2
      continue
    }
    if (-not $literal -and $token -eq '--internet') {
      $script:ClientInternet = $true
      $index++
      continue
    }
    if (-not $literal -and ($token -eq '-h' -or $token -eq '--help')) {
      Show-Usage
      exit 0
    }
    if (-not $literal -and $token -eq '--') {
      $literal = $true
      $index++
      continue
    }
    if (-not $literal -and $token.StartsWith('-')) {
      Die "Неизвестный параметр: $token"
    }
    [void]$items.Add($token)
    $index++
  }
  if ($items.Count -eq 0) {
    Show-Usage -ToError
    exit 1
  }
  $script:Action = $items[0]
  if ($items.Count -gt 1) {
    $rest = New-Object System.Collections.Generic.List[string]
    for ($j = 1; $j -lt $items.Count; $j++) { [void]$rest.Add($items[$j]) }
    $script:Rest = ($rest -join ' ')
  }
  $raw = $script:Action
  if ($raw -eq 'set' -or $raw -eq 'set-time' -or $raw -eq 'set_time' -or $raw -eq 'время') {
    $script:Action = 'set-time'
  } elseif ($raw -eq 'server' -or $raw -eq 'time-server' -or $raw -eq 'time_server' -or $raw -eq 'ntp-server' -or $raw -eq 'сервер') {
    $script:Action = 'time-server'
  } elseif ($raw -eq 'client' -or $raw -eq 'sync-from' -or $raw -eq 'sync_from' -or $raw -eq 'sync' -or $raw -eq 'клиент') {
    $script:Action = 'sync-from'
  } elseif ($raw -eq 'check' -or $raw -eq 'проверка') {
    $script:Action = 'check'
  } elseif ($raw -eq 'self-test') {
    $script:Action = 'self-test'
  } else {
    Die "Неизвестный режим: $raw. Допустимо: set-time, time-server, sync-from, check."
  }
  if ([string]::IsNullOrEmpty($script:Allow) -and -not [string]::IsNullOrWhiteSpace([string]$env:CHRONOSYNC_ALLOW)) {
    $script:Allow = [string]$env:CHRONOSYNC_ALLOW
  }
  if ($script:Action -ne 'sync-from' -and $script:ClientInternet) {
    Die '--internet используется только вместе с sync-from'
  }
  if ($script:Action -ne 'time-server') {
    if ($script:AllowFlag) { Die '--allow используется только вместе с time-server' }
    if ($script:ServerSyncChosen) {
      Die 'Параметры --standalone, --keep-upstream и --upstream используются только с time-server'
    }
    $script:Allow = ''
    $script:ServerSync = 'standalone'
    $script:UpstreamList = New-Object System.Collections.Generic.List[string]
  }
  Apply-ChronoSyncUpstreamEnv
}

function Assert-Arguments {
  $badTime = "Некорректное время: $($script:Rest). Ожидаются Unix-секунды или дата ГГГГ-ММ-ДД ЧЧ:ММ:СС."
  if ($script:Action -eq 'set-time') {
    if ([string]::IsNullOrEmpty($script:Rest)) { Die 'Укажите время: time-sync.cmd set-time <время>' }
    if (-not (ConvertTo-NormalizedTime $script:Rest)) { Die $badTime }
    return
  }
  if ($script:Action -eq 'time-server') {
    Parse-TimeServerRest
    if ($script:ServerSync -eq 'upstream' -and $script:UpstreamList.Count -eq 0) {
      Die 'Не указан upstream. Используйте --upstream <сервер> или CHRONOSYNC_UPSTREAM.'
    }
    if (-not [string]::IsNullOrEmpty($script:Rest)) {
      if (-not (ConvertTo-NormalizedTime $script:Rest)) { Die $badTime }
    }
    if (-not [string]::IsNullOrEmpty($script:Allow) -and -not (Test-ValidCidr $script:Allow)) {
      Die "Некорректная сеть для --allow: $($script:Allow) (ожидается a.b.c.d/nn)"
    }
    return
  }
  if ($script:Action -eq 'sync-from') {
    if ($script:Rest -eq 'internet' -or $script:Rest -eq 'интернет') {
      $script:ClientInternet = $true
      $script:Rest = ''
    }
    if ($script:ClientInternet) {
      if (-not [string]::IsNullOrEmpty($script:Rest)) {
        Die '--internet не принимает адрес сервера. Используйте sync-from --internet'
      }
      Enable-InternetClient
      return
    }
    if ([string]::IsNullOrEmpty($script:Rest)) { Die 'Укажите адрес сервера: time-sync.cmd sync-from <ip>' }
    if ($script:Rest.Contains(' ')) { Die 'Адрес сервера времени — один аргумент, без пробелов.' }
    if ($script:Rest.Contains(':')) { Die "Нужен IPv4-адрес или DNS-имя. IPv6 не поддерживается: $($script:Rest)" }
    if (-not (Test-ValidHost $script:Rest)) { Die "Некорректный адрес сервера времени: $($script:Rest)" }
    $script:Server = $script:Rest
    return
  }
  if ($script:Action -eq 'check') {
    if (-not [string]::IsNullOrEmpty($script:Rest)) { Die 'Режим check не принимает дополнительные аргументы.' }
  }
}

function Assert-Admin {
  if ($script:DryRun -or $script:Action -eq 'check' -or $script:Action -eq 'self-test') { return }
  if (-not (Test-IsWindows)) {
    Die 'Этот скрипт настраивает время Windows и запускается на Windows 10.'
  }
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Die 'Нужны права администратора. Запустите time-sync.cmd от имени администратора.'
  }
}

function Select-Engine {
  $forced = [string]$env:CHRONOSYNC_ENGINE
  if (-not [string]::IsNullOrWhiteSpace($forced) -and $forced -ne 'w32time') {
    Die 'На Windows используется служба W32Time. CHRONOSYNC_ENGINE должен быть w32time.'
  }
  $script:Engine = 'w32time'
  Write-Line 'Движок: w32time'
}

function Get-PrivateCidrText {
  return '10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16'
}

function Get-ServerCidrText {
  $seen = New-Object System.Collections.Generic.List[string]
  foreach ($item in (Get-PrivateCidrText).Split(' ')) { [void]$seen.Add($item) }
  if (-not [string]::IsNullOrEmpty($script:Allow)) {
    $norm = ConvertTo-NetworkCidr $script:Allow
    if ([string]::IsNullOrEmpty($norm)) {
      Die "Некорректная сеть для --allow: $($script:Allow) (ожидается a.b.c.d/nn)"
    }
    if (-not $seen.Contains($norm)) { [void]$seen.Add($norm) }
  }
  return ($seen -join ' ')
}

function Get-ServerHybridSettingRows([string[]]$Peers) {
  if ($Peers.Count -eq 0) { return Get-ServerSettingRows }
  $peerField = ($Peers | ForEach-Object { "$_,0x8" }) -join ' '
  $rows = @(
    'Parameters|Type|NTP|String'
    ("Parameters|NtpServer|{0}|String" -f $peerField)
    'Config|AnnounceFlags|5|DWord'
    'TimeProviders\NtpServer|Enabled|1|DWord'
    'TimeProviders\NtpClient|Enabled|1|DWord'
    'TimeProviders\NtpServer|AllowNonstandardModeCombinations|1|DWord'
    'Config|UtilizeSslTimeData|0|DWord'
    'TimeProviders\VMICTimeProvider|Enabled|0|DWord'
  )
  return ($rows -join "`n")
}

function Get-ServerDomainHybridSettingRows {
  $type = 'NT5DS'
  if ($script:ServerSync -eq 'keep') {
    $live = Get-W32Value 'Parameters' 'Type'
    if ($live -eq 'AllSync') { $type = 'AllSync' }
  }
  $rows = @(
    ("Parameters|Type|{0}|String" -f $type)
    'Parameters|NtpServer||String'
    'Config|AnnounceFlags|5|DWord'
    'TimeProviders\NtpServer|Enabled|1|DWord'
    'TimeProviders\NtpClient|Enabled|1|DWord'
    'TimeProviders\NtpServer|AllowNonstandardModeCombinations|1|DWord'
    'Config|UtilizeSslTimeData|0|DWord'
    'TimeProviders\VMICTimeProvider|Enabled|0|DWord'
  )
  return ($rows -join "`n")
}

function Get-ConfiguredUpstreamInfo {
  $type = Get-W32Value 'Parameters' 'Type'
  $clientOn = (Get-W32Value 'TimeProviders\NtpClient' 'Enabled') -eq '1'
  $raw = Get-W32Value 'Parameters' 'NtpServer'
  $peers = @((Get-PeersFromRaw $raw) -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($clientOn -and ($type -eq 'NT5DS' -or $type -eq 'AllSync')) {
    return @{ Sync = 'domain'; Type = $type; Peers = @() }
  }
  if ($clientOn -and $peers.Count -gt 0) {
    return @{ Sync = 'ntp'; Type = 'NTP'; Peers = $peers }
  }
  return @{ Sync = 'none'; Type = $type; Peers = @() }
}

function Resolve-TimeServerUpstreams {
  $script:ServerUpstreamMode = 'none'
  switch ($script:ServerSync) {
    'standalone' { return }
    'keep' {
      $info = Get-ConfiguredUpstreamInfo
      if ($info.Sync -eq 'domain') {
        $script:ServerUpstreamMode = 'domain'
        return
      }
      if ($info.Peers.Count -gt 0) {
        $script:UpstreamList = New-Object System.Collections.Generic.List[string]
        foreach ($peer in $info.Peers) { [void]$script:UpstreamList.Add([string]$peer) }
        $script:ServerUpstreamMode = 'ntp'
        return
      }
      Write-Line 'Предупреждение: внешние серверы NTP в текущей конфигурации не найдены.'
      Write-Line 'Предупреждение: продолжаем как автономный сервер времени.'
      $script:ServerSync = 'standalone'
      return
    }
    'upstream' {
      $script:ServerUpstreamMode = 'ntp'
      return
    }
  }
}

function Get-ServerSettingRowsForMode {
  if ($script:ServerUpstreamMode -eq 'domain') { return Get-ServerDomainHybridSettingRows }
  if ($script:ServerUpstreamMode -eq 'ntp' -and $script:UpstreamList.Count -gt 0) {
    return Get-ServerHybridSettingRows ($script:UpstreamList.ToArray())
  }
  return Get-ServerSettingRows
}

function Get-UpstreamCsv {
  if ($script:UpstreamList.Count -eq 0) { return '' }
  return ($script:UpstreamList -join ',')
}

function Add-UpstreamClientFirewall {
  foreach ($peer in $script:UpstreamList) {
    if (-not (Test-ValidIpv4 $peer)) { continue }
    $saved = $script:Server
    $script:Server = $peer
    Add-ClientFirewall
    $script:Server = $saved
  }
}

function Wait-HybridUpstreamReady {
  if ($script:DryRun) {
    Write-Line '[dry-run] проверка синхронизации с upstream'
    return $true
  }
  if ($script:ServerUpstreamMode -eq 'domain') {
    $i = 0
    while ($i -lt 20) {
      if (($i % 4) -eq 0) { Invoke-W32tm '/resync' '/force' | Out-Null }
      $query = Invoke-W32tm '/query' '/source'
      if ($query.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$query.Text)) {
        $first = (($query.Text -split "`n")[0]).Trim().Trim("`r")
        $src = (($first -split ',')[0]).Trim()
        if ($src -notmatch '^(Local CMOS|Free-running)' ) { return $true }
      }
      Start-Sleep -Seconds 1
      $i++
    }
    return $false
  }
  if ($script:ServerUpstreamMode -ne 'ntp' -or $script:UpstreamList.Count -eq 0) { return $true }
  $saved = $script:Server
  $ready = $false
  foreach ($peer in $script:UpstreamList) {
    $script:Server = $peer
    if (Wait-ClientReady) { $ready = $true; break }
  }
  $script:Server = $saved
  return $ready
}

function Get-ServerSettingRows {
  $rows = @(
    'Parameters|Type|NoSync|String'
    'Parameters|NtpServer||String'
    'Config|AnnounceFlags|5|DWord'
    'TimeProviders\NtpServer|Enabled|1|DWord'
    'TimeProviders\NtpServer|AllowNonstandardModeCombinations|1|DWord'
    'TimeProviders\NtpClient|Enabled|0|DWord'
    'Config|UtilizeSslTimeData|0|DWord'
    'TimeProviders\VMICTimeProvider|Enabled|0|DWord'
  )
  return ($rows -join "`n")
}

function Enable-InternetClient {
  $script:ClientInternet = $true
  $script:Server = 'internet'
  $script:UpstreamList = New-Object System.Collections.Generic.List[string]
  foreach ($pool in @('0.pool.ntp.org', '1.pool.ntp.org', '2.pool.ntp.org', '3.pool.ntp.org')) {
    [void]$script:UpstreamList.Add($pool)
  }
}

function Get-InternetClientSettingRows {
  $peerField = ($script:UpstreamList | ForEach-Object { "$_,0x8" }) -join ' '
  $rows = @(
    'Parameters|Type|NTP|String'
    ("Parameters|NtpServer|{0}|String" -f $peerField)
    'Config|AnnounceFlags|10|DWord'
    'Config|MaxPosPhaseCorrection|4294967295|DWord'
    'Config|MaxNegPhaseCorrection|4294967295|DWord'
    'TimeProviders\NtpClient|Enabled|1|DWord'
    'TimeProviders\NtpServer|Enabled|0|DWord'
    'Config|UtilizeSslTimeData|0|DWord'
    'TimeProviders\VMICTimeProvider|Enabled|0|DWord'
  )
  return ($rows -join "`n")
}

function Get-ClientSettingRows {
  $peer = '{0},0x8' -f $script:Server
  $rows = @(
    'Parameters|Type|NTP|String'
    ('Parameters|NtpServer|{0}|String' -f $peer)
    'Config|AnnounceFlags|10|DWord'
    'Config|MaxPosPhaseCorrection|4294967295|DWord'
    'Config|MaxNegPhaseCorrection|4294967295|DWord'
    'TimeProviders\NtpClient|Enabled|1|DWord'
    'TimeProviders\NtpServer|Enabled|0|DWord'
    'Config|UtilizeSslTimeData|0|DWord'
    'TimeProviders\VMICTimeProvider|Enabled|0|DWord'
  )
  return ($rows -join "`n")
}

function Get-SetTimeSettingRows {
  $rows = @(
    'TimeProviders\NtpClient|Enabled|0|DWord'
    'TimeProviders\NtpServer|Enabled|0|DWord'
    'Config|UtilizeSslTimeData|0|DWord'
    'TimeProviders\VMICTimeProvider|Enabled|0|DWord'
  )
  return ($rows -join "`n")
}

function ConvertTo-Dword([string]$Value) {
  $number = [int64]$Value
  $bytes = [BitConverter]::GetBytes([uint32]$number)
  return [BitConverter]::ToInt32($bytes, 0)
}

function Set-W32Value([string]$Sub, [string]$Name, [string]$Value, [string]$Kind) {
  if ($script:DryRun) {
    Write-Line "[dry-run] $script:RegBase\$Sub $Name=$Value"
    return
  }
  $path = $script:RegDrive
  if (-not [string]::IsNullOrEmpty($Sub)) { $path = Join-Path $path $Sub }
  if (-not (Test-Path -LiteralPath $path)) {
    New-Item -Path $path -Force | Out-Null
  }
  if ($Kind -eq 'DWord') {
    $stored = ConvertTo-Dword $Value
    New-ItemProperty -LiteralPath $path -Name $Name -PropertyType DWord -Value $stored -Force | Out-Null
    return
  }
  if ($Kind -eq 'String') {
    New-ItemProperty -LiteralPath $path -Name $Name -PropertyType String -Value $Value -Force | Out-Null
    return
  }
  Die "Внутренняя ошибка типа реестра: $Kind"
}

function Apply-SettingRows([string]$Text) {
  foreach ($row in ($Text -split "`n")) {
    $row = $row.Trim()
    if ($row.Length -eq 0) { continue }
    $parts = $row.Split('|')
    if ($parts.Length -ne 4) { Die "Внутренняя ошибка строки настройки: $row" }
    $sub = $parts[0]
    $name = $parts[1]
    $value = $parts[2]
    $kind = $parts[3]
    if ($sub -eq 'TimeProviders\VMICTimeProvider' -and -not $script:DryRun) {
      $vmic = Join-Path $script:RegDrive 'TimeProviders\VMICTimeProvider'
      if (-not (Test-Path -LiteralPath $vmic)) { continue }
    }
    Set-W32Value $sub $name $value $kind
  }
}

function Get-W32Value([string]$Sub, [string]$Name) {
  $path = $script:RegDrive
  if (-not [string]::IsNullOrEmpty($Sub)) { $path = Join-Path $path $Sub }
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $item = Get-ItemProperty -LiteralPath $path -Name $Name -ErrorAction Stop
  } catch {
    return $null
  }
  $value = $item.$Name
  if ($null -eq $value) { return $null }
  if ($value -is [Array]) { return ($value -join ' ') }
  return $value
}

function Get-NetshPath {
  if (Test-IsWindows -and -not [string]::IsNullOrEmpty([string]$env:SystemRoot)) {
    return (Join-Path $env:SystemRoot 'System32\netsh.exe')
  }
  return 'netsh.exe'
}

function Get-W32tmPath {
  if (Test-IsWindows -and -not [string]::IsNullOrEmpty([string]$env:SystemRoot)) {
    return (Join-Path $env:SystemRoot 'System32\w32tm.exe')
  }
  return 'w32tm.exe'
}

function Invoke-W32tm {
  $w32args = @($args)
  $exe = Get-W32tmPath
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $lines = @(& $exe @w32args 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
  if ($null -eq $code) { $code = 1 }
  $text = ''
  if ($lines.Count -gt 0) { $text = ($lines -join "`n") }
  return @{ Code = $code; Text = $text }
}

function Remove-ChronoFirewall {
  foreach ($ruleName in @('chronosync-ntp-in', 'chronosync-ntp-out')) {
    if ($script:DryRun) {
      Write-Line "[dry-run] netsh advfirewall firewall delete rule name=$ruleName"
      continue
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & (Get-NetshPath) advfirewall firewall delete rule "name=$ruleName" | Out-Null
    } finally {
      $ErrorActionPreference = $prev
    }
  }
}

function Add-ServerFirewall {
  $remote = (Get-ServerCidrText).Replace(' ', ',')
  if ($script:DryRun) {
    Write-Line "[dry-run] netsh advfirewall firewall add rule name=chronosync-ntp-in dir=in action=allow protocol=UDP localport=123 remoteip=$remote"
    return
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $netsh = Get-NetshPath
    & $netsh advfirewall firewall delete rule 'name=chronosync-ntp-in' | Out-Null
    & $netsh advfirewall firewall add rule 'name=chronosync-ntp-in' 'dir=in' 'action=allow' 'protocol=UDP' 'localport=123' "remoteip=$remote" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Line 'Предупреждение: не удалось добавить правило фаервола udp/123. Если входящие соединения запрещены, откройте порт вручную.'
    } else {
      Write-Line 'Фаервол: входящий udp/123 разрешён для частных сетей.'
    }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Add-ClientFirewall {
  if (-not (Test-ValidIpv4 $script:Server)) {
    Write-Line 'Фаервол: адрес сервера не IPv4, отдельное исходящее правило udp/123 не добавлено.'
    return
  }
  if ($script:DryRun) {
    Write-Line "[dry-run] netsh advfirewall firewall add rule name=chronosync-ntp-out dir=out action=allow protocol=UDP remoteport=123 remoteip=$($script:Server)"
    return
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $netsh = Get-NetshPath
    & $netsh advfirewall firewall delete rule 'name=chronosync-ntp-out' | Out-Null
    & $netsh advfirewall firewall add rule 'name=chronosync-ntp-out' 'dir=out' 'action=allow' 'protocol=UDP' 'remoteport=123' "remoteip=$($script:Server)" | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Line 'Предупреждение: не удалось добавить исходящее правило udp/123.'
    } else {
      Write-Line "Фаервол: исходящий udp/123 к $($script:Server) разрешён."
    }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Set-TimeServiceStartMode([string]$Mode) {
  if ($script:DryRun) {
    Write-Line "[dry-run] Set-Service W32Time -StartupType $Mode"
    return
  }
  try {
    Set-Service -Name 'W32Time' -StartupType $Mode -ErrorAction Stop
  } catch {
    $start = 3
    if ($Mode -eq 'Automatic') { $start = 2 }
    elseif ($Mode -eq 'Disabled') { $start = 4 }
    if (Test-Path -LiteralPath $script:RegDrive) {
      Set-ItemProperty -LiteralPath $script:RegDrive -Name 'Start' -Value $start -Type DWord
    }
  }
}

function Stop-TimeService {
  if ($script:DryRun) {
    Write-Line '[dry-run] Stop-Service W32Time'
    return
  }
  $svc = $null
  try { $svc = Get-Service -Name 'W32Time' -ErrorAction Stop } catch { return }
  if ($svc.Status -eq 'Stopped') { return }
  Stop-Service -Name 'W32Time' -Force -ErrorAction SilentlyContinue
  try {
    $svc.Refresh()
    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
  } catch {
  }
}

function Start-TimeService {
  if ($script:DryRun) {
    Write-Line '[dry-run] Start-Service W32Time'
    return $true
  }
  $svc = $null
  try { $svc = Get-Service -Name 'W32Time' -ErrorAction Stop } catch { $svc = $null }
  if ($null -eq $svc) {
    Invoke-W32tm '/register' | Out-Null
  }
  Set-TimeServiceStartMode 'Automatic'
  try {
    Start-Service -Name 'W32Time' -ErrorAction Stop
    return $true
  } catch {
    Invoke-W32tm '/register' | Out-Null
    Set-TimeServiceStartMode 'Automatic'
    try {
      Start-Service -Name 'W32Time' -ErrorAction Stop
      return $true
    } catch {
      return $false
    }
  }
}

function Update-W32Config {
  if ($script:DryRun) {
    Write-Line '[dry-run] w32tm /config /update'
    return
  }
  Invoke-W32tm '/config' '/update' | Out-Null
}

function Get-W32ServiceState {
  if (-not (Test-IsWindows)) { return 'missing' }
  try {
    $svc = Get-Service -Name 'W32Time' -ErrorAction Stop
  } catch {
    return 'missing'
  }
  if ($svc.Status -eq 'Running') { return 'active' }
  return 'inactive'
}

function Test-Udp123 {
  $netstat = 'netstat.exe'
  if (Test-IsWindows -and -not [string]::IsNullOrEmpty([string]$env:SystemRoot)) {
    $netstat = Join-Path $env:SystemRoot 'System32\netstat.exe'
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $lines = @(& $netstat -an -p udp 2>&1 | ForEach-Object { "$_" })
  } finally {
    $ErrorActionPreference = $prev
  }
  foreach ($line in $lines) {
    if ($line -match ':123(\s|$)') { return $true }
  }
  return $false
}

function Wait-ServerReady {
  if ($script:DryRun) {
    Write-Line '[dry-run] проверка, что сервер времени слушает udp/123'
    return $true
  }
  $i = 0
  while ($i -lt 45) {
    if ((Get-W32ServiceState) -eq 'active' -and (Test-Udp123)) { return $true }
    Start-Sleep -Seconds 1
    $i++
  }
  return $false
}

function Wait-ClientReady {
  if ($script:DryRun) {
    Write-Line "[dry-run] проверка синхронизации с $($script:Server)"
    return $true
  }
  $i = 0
  while ($i -lt 20) {
    if (($i % 4) -eq 0) { Invoke-W32tm '/resync' '/force' | Out-Null }
    $query = Invoke-W32tm '/query' '/source'
    if ($query.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$query.Text)) {
      $first = (($query.Text -split "`n")[0]).Trim().Trim("`r")
      $src = (($first -split ',')[0]).Trim()
      if ($src -ieq $script:Server) { return $true }
    }
    Start-Sleep -Seconds 1
    $i++
  }
  return $false
}

function Get-TargetLocalTime {
  if ($script:NormKind -eq 'local') { return $script:NormLocal }
  return $script:NormDto.ToLocalTime().DateTime
}

function Get-LocalStamp {
  $now = [DateTimeOffset]::Now
  return ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f $now.LocalDateTime, $now.ToString('zzz'))
}

function Get-UtcStamp {
  $utc = [DateTimeOffset]::UtcNow
  return ('{0:yyyy-MM-dd HH:mm:ss} UTC' -f $utc.UtcDateTime)
}

function Get-UnixNow {
  return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Set-DeviceClock {
  if ([string]::IsNullOrEmpty($script:NormSpec)) { return $false }
  if ($script:DryRun) {
    Write-Line "[dry-run] Set-Date $($script:NormSpec)"
    Write-Line '[dry-run] системные часы Windows обновляют RTC'
    return $true
  }
  try {
    Set-Date -Date (Get-TargetLocalTime) | Out-Null
  } catch {
    return $false
  }
  Write-Line ("Время устройства (локальное): {0}" -f (Get-LocalStamp))
  Write-Line ("Время устройства (UTC): {0}" -f (Get-UtcStamp))
  Write-Line 'Системное время установлено, RTC обновляет Windows.'
  return $true
}

function Write-StateFile {
  $lines = @(
    "mode=$($script:Action)"
    "engine=$($script:Engine)"
    "server=$($script:Server)"
    "allow=$($script:Allow)"
    "server_sync=$($script:ServerSync)"
    "upstreams=$(Get-UpstreamCsv)"
  )
  if ($script:DryRun) {
    Write-Line "[dry-run] запись $script:StateDir\state"
    foreach ($line in $lines) { Write-Line $line }
    return
  }
  $dir = $script:StateDir
  if (-not [string]::IsNullOrEmpty([string]$env:ProgramData)) {
    $dir = Join-Path $env:ProgramData 'chronosync'
  }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $dest = Join-Path $dir 'state'
  $tmp = "$dest.tmp.$PID"
  $text = ($lines -join "`r`n") + "`r`n"
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [IO.File]::WriteAllText($tmp, $text, $utf8)
  Move-Item -LiteralPath $tmp -Destination $dest -Force
}

function Backup-W32Time {
  $destShown = "$($script:StateDir)\W32Time.bak.reg"
  if ($script:DryRun) {
    Write-Line "[dry-run] резервная копия $script:RegBase -> $destShown"
    return
  }
  $dest = $destShown
  $dir = $script:StateDir
  if (-not [string]::IsNullOrEmpty([string]$env:ProgramData)) {
    $dir = Join-Path $env:ProgramData 'chronosync'
    $dest = Join-Path $dir 'W32Time.bak.reg'
  }
  if (Test-Path -LiteralPath $dest) { return }
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $reg = 'reg.exe'
  if (-not [string]::IsNullOrEmpty([string]$env:SystemRoot)) {
    $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
  }
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $reg export $script:RegBase $dest /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Line 'Предупреждение: не удалось сохранить резервную копию параметров W32Time.'
    }
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Warn-IfPolicy {
  if ($script:DryRun -or -not (Test-IsWindows)) { return }
  if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time') {
    Write-Line 'Предупреждение: найдена групповая политика W32Time (HKLM\SOFTWARE\Policies\Microsoft\W32Time). Она может перезаписать эти настройки.'
  }
}

function Show-TimeDebug {
  if ($script:DryRun) { return }
  Write-Line '--- служба W32Time ---'
  try {
    $svc = Get-Service -Name 'W32Time' -ErrorAction Stop
    Write-Line ("Status={0} StartType={1}" -f $svc.Status, $svc.StartType)
  } catch {
    Write-Line 'служба не найдена'
  }
  Write-Line '--- w32tm /query /status ---'
  $status = Invoke-W32tm '/query' '/status'
  Write-Line ([string]$status.Text)
  Write-Line '--- w32tm /query /configuration ---'
  $config = Invoke-W32tm '/query' '/configuration'
  Write-Line ([string]$config.Text)
}

function Show-BriefStatus {
  if ($script:DryRun) { return }
  $status = Invoke-W32tm '/query' '/status'
  if (-not [string]::IsNullOrWhiteSpace([string]$status.Text)) { Write-Line ([string]$status.Text) }
}

function Write-Addresses {
  if ($script:DryRun) {
    Write-Line '[dry-run] показать IPv4-адреса устройства'
    return
  }
  $found = New-Object System.Collections.Generic.List[string]
  try {
    $configs = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True')
    foreach ($config in $configs) {
      if ($null -eq $config.IPAddress) { continue }
      foreach ($ip in @($config.IPAddress)) {
        $text = [string]$ip
        if ($text -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
        if ($text.StartsWith('127.')) { continue }
        if ($text.StartsWith('169.254.')) { continue }
        if (-not $found.Contains($text)) { [void]$found.Add($text) }
      }
    }
  } catch {
  }
  if ($found.Count -eq 0) {
    Write-Line 'Не удалось определить IPv4-адреса устройства.'
    return
  }
  foreach ($ip in $found) { Write-Line $ip }
}

function Get-PeersFromRaw([string]$Raw) {
  if ([string]::IsNullOrWhiteSpace($Raw)) { return '' }
  $seen = New-Object System.Collections.Generic.List[string]
  foreach ($part in ($Raw -split '\s+')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $peer = ($part -split ',')[0].Trim()
    if ([string]::IsNullOrWhiteSpace($peer)) { continue }
    if (-not $seen.Contains($peer)) { [void]$seen.Add($peer) }
  }
  return ($seen -join ' ')
}

function Get-RoleFromValues($ServerEnabled, $ClientEnabled, $TypeName, $PeerRaw, $ServiceState) {
  $peers = Get-PeersFromRaw ([string]$PeerRaw)
  $isServer = ([string]$ServerEnabled -eq '1')
  $isClient = $false
  $upstreams = ''
  if ([string]$ClientEnabled -eq '1') {
    if (-not [string]::IsNullOrWhiteSpace($peers)) {
      $isClient = $true
      $upstreams = $peers
    } elseif ($TypeName -eq 'NT5DS' -or $TypeName -eq 'AllSync') {
      $isClient = $true
      $upstreams = [string]$TypeName
    }
  }
  return @{
    IsServer = $isServer
    IsClient = $isClient
    Upstreams = $upstreams
    State = [string]$ServiceState
  }
}

function Read-LiveRole {
  if (-not (Test-IsWindows)) {
    return (Get-RoleFromValues 0 0 '' '' 'missing')
  }
  return (Get-RoleFromValues (Get-W32Value 'TimeProviders\NtpServer' 'Enabled') (Get-W32Value 'TimeProviders\NtpClient' 'Enabled') (Get-W32Value 'Parameters' 'Type') (Get-W32Value 'Parameters' 'NtpServer') (Get-W32ServiceState))
}

function Get-SyncState($Role) {
  if ($Role.State -ne 'active') { return 'no' }
  if (-not $Role.IsClient -or [string]::IsNullOrWhiteSpace([string]$Role.Upstreams)) { return 'no' }
  if (-not (Test-IsWindows)) { return 'unknown' }
  $query = Invoke-W32tm '/query' '/source'
  if ($query.Code -ne 0 -or [string]::IsNullOrWhiteSpace([string]$query.Text)) { return 'unknown' }
  $first = (($query.Text -split "`n")[0]).Trim().Trim("`r")
  $src = (($first -split ',')[0]).Trim()
  foreach ($up in ([string]$Role.Upstreams).Split(' ')) {
    if ($src -ieq $up) { return 'yes' }
  }
  return 'no'
}

function Invoke-SetTime {
  Write-Line 'Режим: установка времени с машины установщика.'
  Backup-W32Time
  Stop-TimeService
  Set-TimeServiceStartMode 'Disabled'
  Apply-SettingRows (Get-SetTimeSettingRows)
  Remove-ChronoFirewall
  if (-not (Set-DeviceClock)) { Die 'Не удалось установить время.' }
  $script:Engine = 'none'
  $script:Server = ''
  Write-StateFile
  Write-Line 'Службы синхронизации времени выключены, чтобы они не сбросили выставленное время.'
  Write-Line 'Дальше можно сделать устройство сервером: time-sync.cmd time-server'
  Write-Line 'Или указать ему сервер: time-sync.cmd sync-from <ip>'
  Write-Ok 'mode=set-time'
}

function Invoke-TimeServer {
  Write-Line 'Режим: сервер времени.'
  Resolve-TimeServerUpstreams
  switch ($script:ServerSync) {
    'standalone' { Write-Line 'Синхронизация upstream: выкл. (автономные локальные часы).' }
    'keep' {
      if ($script:ServerUpstreamMode -eq 'domain') {
        Write-Line 'Синхронизация upstream: сохраняется синхронизация домена.'
      } else {
        Write-Line ("Синхронизация upstream: сохранённые серверы: $($script:UpstreamList -join ' ').")
      }
    }
    'upstream' { Write-Line ("Синхронизация upstream: $($script:UpstreamList -join ' ').") }
  }
  Select-Engine
  Warn-IfPolicy
  Backup-W32Time
  Stop-TimeService
  if (-not [string]::IsNullOrEmpty($script:NormSpec)) {
    if (-not (Set-DeviceClock)) { Die 'Не удалось установить время.' }
  } else {
    Write-Line 'Предупреждение: время не передано. Сервер будет раздавать текущие часы устройства.'
  }
  Apply-SettingRows (Get-ServerSettingRowsForMode)
  Remove-ChronoFirewall
  Add-ServerFirewall
  if ($script:ServerUpstreamMode -ne 'none') { Add-UpstreamClientFirewall }
  Set-TimeServiceStartMode 'Automatic'
  if (-not (Start-TimeService)) {
    Show-TimeDebug
    Die 'Не удалось запустить службу W32Time.'
  }
  Update-W32Config
  if (-not (Wait-ServerReady)) {
    Show-TimeDebug
    Die 'Служба W32Time запущена, но время не раздаётся.'
  }
  if ($script:ServerUpstreamMode -ne 'none') {
    if (Wait-HybridUpstreamReady) {
      Write-Line 'Синхронизация с upstream выполнена.'
    } else {
      Write-Line 'Предупреждение: сервер слушает udp/123, но синхронизация с upstream ещё не готова.'
      Write-Line 'Предупреждение: клиенты смогут пользоваться сервером, когда upstream станет доступен.'
    }
  }
  Write-StateFile
  Write-Line 'Сервер времени слушает udp/123.'
  if ($script:ServerSync -eq 'standalone') {
    Write-Line 'Он раздаёт локальные часы и не подстраивается по upstream.'
    Write-Line 'Повторный запуск time-server с новым временем поправляет часы.'
  } else {
    Write-Line 'Он раздаёт время в локальную сеть и подстраивается по настроенным upstream.'
  }
  Write-Line 'На остальных устройствах выполните sync-from с одним из адресов:'
  Write-Addresses
  Show-BriefStatus
  $okExtra = "sync=$($script:ServerSync)"
  $csv = Get-UpstreamCsv
  if (-not [string]::IsNullOrWhiteSpace($csv)) { $okExtra += " upstream=$csv" }
  Write-Ok "mode=time-server engine=w32time $okExtra"
}

function Wait-InternetReady {
  if ($script:DryRun) {
    Write-Line '[dry-run] проверка синхронизации с публичным NTP-пулом'
    return $true
  }
  $i = 0
  while ($i -lt 20) {
    if (($i % 4) -eq 0) { Invoke-W32tm '/resync' '/force' | Out-Null }
    $query = Invoke-W32tm '/query' '/source'
    if ($query.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$query.Text)) {
      $first = (($query.Text -split "`n")[0]).Trim().Trim("`r")
      $src = (($first -split ',')[0]).Trim()
      if ($src -notmatch '^(Local CMOS|Free-running)') { return $true }
    }
    Start-Sleep -Seconds 1
    $i++
  }
  return $false
}

function Invoke-SyncFrom {
  if ($script:ClientInternet) {
    Write-Line 'Режим: клиент публичного NTP-пула.'
    Write-Line ("Серверы: $($script:UpstreamList -join ' ').")
  } else {
    Write-Line "Режим: клиент сервера времени $($script:Server)."
  }
  Select-Engine
  Warn-IfPolicy
  Backup-W32Time
  Stop-TimeService
  if ($script:ClientInternet) {
    Apply-SettingRows (Get-InternetClientSettingRows)
  } else {
    Apply-SettingRows (Get-ClientSettingRows)
  }
  Remove-ChronoFirewall
  if ($script:ClientInternet) {
    Write-Line 'Фаервол: публичный NTP-пул, отдельное исходящее правило udp/123 не добавлено.'
  } else {
    Add-ClientFirewall
  }
  Set-TimeServiceStartMode 'Automatic'
  if (-not (Start-TimeService)) {
    Show-TimeDebug
    Die 'Не удалось запустить службу W32Time.'
  }
  Update-W32Config
  $ready = $false
  if ($script:ClientInternet) { $ready = Wait-InternetReady } else { $ready = Wait-ClientReady }
  if (-not $ready) {
    Show-TimeDebug
    if ($script:ClientInternet) {
      Die 'Не удалось синхронизироваться с публичным NTP-пулом. Проверьте исходящий udp/123.'
    }
    Die "Не удалось синхронизироваться с $($script:Server). Проверьте, что на нём выполнен time-server, открыт udp/123 и адрес доступен."
  }
  Write-StateFile
  if ($script:ClientInternet) {
    Write-Line 'Устройство синхронизируется с публичным NTP-пулом.'
    Write-Ok "mode=sync-from engine=w32time server=internet upstream=$(Get-UpstreamCsv)"
  } else {
    Write-Line "Устройство синхронизируется с $($script:Server)."
    Write-Ok "mode=sync-from engine=w32time server=$($script:Server)"
  }
  Show-BriefStatus
}

function Invoke-Check {
  $epoch = Get-UnixNow
  Write-Line ("Время устройства (локальное): {0}" -f (Get-LocalStamp))
  Write-Line ("Время устройства (UTC): {0}" -f (Get-UtcStamp))
  Write-Line "Unix-время: $epoch"
  $role = Read-LiveRole
  if ($role.IsServer) { $serverYes = 'да' } else { $serverYes = 'нет' }
  if ($role.IsClient) { $clientYes = 'да' } else { $clientYes = 'нет' }
  Write-Line "Сервер времени: $serverYes"
  Write-Line "Клиент сервера времени: $clientYes"
  if ($role.IsClient) { Write-Line "Сервер синхронизации: $($role.Upstreams)" }
  $svc = 'нет'
  if ($role.State -eq 'active') { $svc = 'W32Time (запущена)' }
  elseif ($role.State -eq 'inactive') { $svc = 'W32Time (не запущена)' }
  elseif ($role.State -eq 'unknown') { $svc = 'W32Time (состояние неизвестно)' }
  Write-Line "Служба: $svc"
  $sync = Get-SyncState $role
  $syncWord = 'нет данных'
  if ($sync -eq 'yes') { $syncWord = 'да' }
  elseif ($sync -eq 'no') { $syncWord = 'нет' }
  Write-Line "Синхронизация с внешним сервером: $syncWord"
  $roleName = 'none'
  if ($role.IsServer -and $role.IsClient) { $roleName = 'both' }
  elseif ($role.IsServer) { $roleName = 'server' }
  elseif ($role.IsClient) { $roleName = 'client' }
  $csv = '-'
  if (-not [string]::IsNullOrWhiteSpace([string]$role.Upstreams)) {
    $csv = ([string]$role.Upstreams).Replace(' ', ',')
  }
  $engineOut = 'none'
  if ($role.State -ne 'missing' -or $roleName -ne 'none') { $engineOut = 'w32time' }
  Write-Ok "mode=check role=$roleName engine=$engineOut server=$csv synced=$sync time=$epoch"
}

function Expect-Ok([string]$Name, [bool]$Ok) {
  if ($Ok) {
    Write-Line "ok $Name"
    return
  }
  [Console]::Error.WriteLine("FAIL $Name")
  $script:Fails++
}

function Expect-Fail([string]$Name, [bool]$Ok) {
  Expect-Ok $Name (-not $Ok)
}

function Check-Eq([string]$Name, [string]$Actual, [string]$Expected) {
  if ($Actual -eq $Expected) {
    Write-Line "ok $Name"
    return
  }
  [Console]::Error.WriteLine("FAIL ${Name}: [$Actual] != [$Expected]")
  $script:Fails++
}

function Invoke-SelfTest {
  $script:Fails = 0
  $script:Allow = ''
  $script:Server = '192.168.0.10'
  $script:DryRun = $true

  Expect-Ok 'epoch' (Test-ValidTime '1761307080')
  Expect-Ok 'iso' (Test-ValidTime '2026-10-24 14:18:00')
  Expect-Ok 'isoT' (Test-ValidTime '2026-10-24T14:18:00Z')
  Expect-Ok 'offset' (Test-ValidTime '2026-10-24 14:18:00+05:00')
  Expect-Ok 'ru' (Test-ValidTime '24.10.2026 14:18:00')
  Expect-Fail 'empty time' (Test-ValidTime '')
  Expect-Fail 'junk time' (Test-ValidTime 'вчера')
  Expect-Fail 'short epoch' (Test-ValidTime '123')
  Expect-Fail 'bad calendar' (ConvertTo-NormalizedTime '2026-13-40 00:00:00')

  Expect-Ok 'ipv4' (Test-ValidIpv4 '192.168.0.1')
  Expect-Fail 'octet' (Test-ValidIpv4 '192.168.0.256')
  Expect-Fail 'leading zero' (Test-ValidIpv4 '192.168.00.1')
  Expect-Ok 'zero octet' (Test-ValidIpv4 '10.0.0.0')

  Expect-Ok 'host' (Test-ValidHost '192.168.0.10')
  Expect-Ok 'name' (Test-ValidHost 'time-server.lan')
  Expect-Fail 'zero ip' (Test-ValidHost '0.0.0.0')
  Expect-Fail 'bad ip host' (Test-ValidHost '192.168.0.256')
  Expect-Fail 'flag host' (Test-ValidHost '-rf')
  Expect-Fail 'underscore' (Test-ValidHost 'bad_host')

  Check-Eq 'cidr /16' (ConvertTo-NetMaskPair '10.50.1.5/16') '10.50.0.0 255.255.0.0'
  Check-Eq 'cidr /24' (ConvertTo-NetMaskPair '192.168.5.9/24') '192.168.5.0 255.255.255.0'
  Check-Eq 'cidr /12' (ConvertTo-NetMaskPair '172.16.5.1/12') '172.16.0.0 255.240.0.0'
  Expect-Fail 'cidr /33' (Test-ValidCidr '10.1.2.3/33')
  Expect-Fail 'cidr no mask' (Test-ValidCidr '10.1.2.3')
  Check-Eq 'cidr norm' (ConvertTo-NetworkCidr '10.50.1.5/16') '10.50.0.0/16'

  if (-not (ConvertTo-NormalizedTime '24.10.2026 14:18:00')) { Die 'normalize ru' }
  Check-Eq 'ru normalize' $script:NormSpec '2026-10-24 14:18:00'
  Check-Eq 'ru kind' $script:NormKind 'local'
  if (-not (ConvertTo-NormalizedTime '1761307080')) { Die 'normalize epoch' }
  Check-Eq 'epoch spec' $script:NormSpec '@1761307080'
  Check-Eq 'epoch kind' $script:NormKind 'epoch'
  if (-not (ConvertTo-NormalizedTime '2026-10-24T14:18:00+05:00')) { Die 'normalize offset' }
  Check-Eq 'offset spec' $script:NormSpec '2026-10-24 14:18:00+05:00'
  Check-Eq 'offset kind' $script:NormKind 'absolute'

  $serverRows = Get-ServerSettingRows
  Expect-Ok 'server nosync' ($serverRows.Contains('Parameters|Type|NoSync|String'))
  Expect-Ok 'server announce' ($serverRows.Contains('Config|AnnounceFlags|5|DWord'))
  Expect-Ok 'server enabled' ($serverRows.Contains('TimeProviders\NtpServer|Enabled|1|DWord'))
  Expect-Ok 'server client off' ($serverRows.Contains('TimeProviders\NtpClient|Enabled|0|DWord'))
  Expect-Fail 'server pool' ($serverRows.Contains('pool.ntp.org'))
  Expect-Fail 'server windows' ($serverRows.Contains('time.windows.com'))
  Expect-Fail 'server peer flag' ($serverRows.Contains(',0x8'))

  $hybridRows = Get-ServerHybridSettingRows @('10.0.0.5', 'ntp.example.com')
  Expect-Ok 'hybrid type' ($hybridRows.Contains('Parameters|Type|NTP|String'))
  Expect-Ok 'hybrid peer' ($hybridRows.Contains('Parameters|NtpServer|10.0.0.5,0x8 ntp.example.com,0x8|String'))
  Expect-Ok 'hybrid client on' ($hybridRows.Contains('TimeProviders\NtpClient|Enabled|1|DWord'))
  Expect-Ok 'hybrid server on' ($hybridRows.Contains('TimeProviders\NtpServer|Enabled|1|DWord'))
  $domainRows = Get-ServerDomainHybridSettingRows
  Expect-Ok 'domain type' ($domainRows.Contains('Parameters|Type|NT5DS|String'))
  Expect-Ok 'domain client on' ($domainRows.Contains('TimeProviders\NtpClient|Enabled|1|DWord'))

  $script:UpstreamList = New-Object System.Collections.Generic.List[string]
  Add-UpstreamHostsFromCsv '10.0.0.1,ntp.example.com'
  Check-Eq 'upstream csv' (Get-UpstreamCsv) '10.0.0.1,ntp.example.com'

  $script:Allow = '10.50.1.5/16'
  $cidrs = Get-ServerCidrText
  Expect-Ok 'private 10' ($cidrs.Contains('10.0.0.0/8'))
  Expect-Ok 'private 172' ($cidrs.Contains('172.16.0.0/12'))
  Expect-Ok 'private 192' ($cidrs.Contains('192.168.0.0/16'))
  Expect-Ok 'private link' ($cidrs.Contains('169.254.0.0/16'))
  Expect-Ok 'extra allow' ($cidrs.Contains('10.50.0.0/16'))
  $script:Allow = '10.1.2.3/8'
  Expect-Fail 'dedupe allow' ((Get-ServerCidrText).Contains('10.0.0.0/8 10.0.0.0/8'))
  $script:Allow = ''

  $script:Server = '192.168.0.10'
  $clientRows = Get-ClientSettingRows
  Expect-Ok 'client type' ($clientRows.Contains('Parameters|Type|NTP|String'))
  Expect-Ok 'client peer' ($clientRows.Contains('Parameters|NtpServer|192.168.0.10,0x8|String'))
  Expect-Ok 'client phase' ($clientRows.Contains('Config|MaxPosPhaseCorrection|4294967295|DWord'))
  Expect-Ok 'client on' ($clientRows.Contains('TimeProviders\NtpClient|Enabled|1|DWord'))
  Expect-Ok 'client server off' ($clientRows.Contains('TimeProviders\NtpServer|Enabled|0|DWord'))
  Expect-Fail 'client pool' ($clientRows.Contains('pool.ntp.org'))
  Expect-Fail 'client windows' ($clientRows.Contains('time.windows.com'))
  Expect-Fail 'client reliable' ($clientRows.Contains('AnnounceFlags|5|'))

  Enable-InternetClient
  $internetRows = Get-InternetClientSettingRows
  Expect-Ok 'internet type' ($internetRows.Contains('Parameters|Type|NTP|String'))
  Expect-Ok 'internet peers' ($internetRows.Contains('Parameters|NtpServer|0.pool.ntp.org,0x8 1.pool.ntp.org,0x8 2.pool.ntp.org,0x8 3.pool.ntp.org,0x8|String'))
  Expect-Ok 'internet client on' ($internetRows.Contains('TimeProviders\NtpClient|Enabled|1|DWord'))
  Expect-Ok 'internet server off' ($internetRows.Contains('TimeProviders\NtpServer|Enabled|0|DWord'))
  Check-Eq 'internet csv' (Get-UpstreamCsv) '0.pool.ntp.org,1.pool.ntp.org,2.pool.ntp.org,3.pool.ntp.org'

  Check-Eq 'peers empty' (Get-PeersFromRaw '') ''
  Check-Eq 'peers one' (Get-PeersFromRaw '192.168.0.10,0x8') '192.168.0.10'
  Check-Eq 'peers two' (Get-PeersFromRaw 'a.example,0x8 b.example,0x2') 'a.example b.example'
  $serverRole = Get-RoleFromValues 1 0 'NoSync' '' 'active'
  Expect-Ok 'role server' ([bool]$serverRole.IsServer)
  Expect-Fail 'role server client' ([bool]$serverRole.IsClient)
  $clientRole = Get-RoleFromValues 0 1 'NTP' '192.168.0.10,0x8' 'active'
  Expect-Fail 'role client server' ([bool]$clientRole.IsServer)
  Expect-Ok 'role client' ([bool]$clientRole.IsClient)
  Check-Eq 'role client up' ([string]$clientRole.Upstreams) '192.168.0.10'
  $offRole = Get-RoleFromValues 0 0 'NTP' 'time.windows.com,0x9' 'inactive'
  Expect-Fail 'role disabled' ([bool]$offRole.IsClient)
  $domainRole = Get-RoleFromValues 0 1 'NT5DS' '' 'active'
  Expect-Ok 'role domain' ([bool]$domainRole.IsClient)
  Check-Eq 'role domain up' ([string]$domainRole.Upstreams) 'NT5DS'

  if ($script:Fails -ne 0) {
    [Console]::Error.WriteLine("self-test: FAIL $($script:Fails)")
    exit 1
  }
  Write-Line 'self-test: ok'
  exit 0
}

if ($args.Count -eq 0) {
  Show-Usage -ToError
  exit 1
}
Parse-Arguments @args
Assert-Arguments
if ($script:Action -eq 'self-test') { Invoke-SelfTest }
Assert-Admin
if ($script:Action -eq 'set-time') {
  Invoke-SetTime
} elseif ($script:Action -eq 'time-server') {
  Invoke-TimeServer
} elseif ($script:Action -eq 'sync-from') {
  Invoke-SyncFrom
} elseif ($script:Action -eq 'check') {
  Invoke-Check
} else {
  Die 'Неизвестный режим.'
}
exit 0
