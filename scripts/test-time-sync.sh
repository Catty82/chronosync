#!/bin/sh
# Проверка time-sync.sh без изменения часов системы.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
SCRIPT="${ROOT}/time-sync.sh"
FAIL=0
LAST_OUT=

export CHRONOSYNC_NO_SUDO=1
unset CHRONOSYNC_ENGINE || true
unset CHRONOSYNC_ALLOW || true

if [ ! -f "$SCRIPT" ]; then
  printf 'Нет файла %s\n' "$SCRIPT" >&2
  exit 1
fi

run_case() {
  name=$1
  expected=$2
  shift 2
  set +e
  LAST_OUT=$("$@" 2>&1)
  rc=$?
  set -e
  if [ "$rc" -ne "$expected" ]; then
    printf 'FAIL %s (код %s, ожидался %s)\n' "$name" "$rc" "$expected" >&2
    printf '%s\n' "$LAST_OUT" >&2
    FAIL=1
    return 0
  fi
  printf 'OK %s\n' "$name"
}

assert_contains() {
  name=$1
  needle=$2
  if ! printf '%s\n' "$LAST_OUT" | grep -F -q -- "$needle"; then
    printf 'FAIL %s: нет строки: %s\n' "$name" "$needle" >&2
    printf '%s\n' "$LAST_OUT" >&2
    FAIL=1
    return 0
  fi
  printf 'OK %s\n' "$name"
}

assert_not_contains() {
  name=$1
  needle=$2
  if printf '%s\n' "$LAST_OUT" | grep -F -q -- "$needle"; then
    printf 'FAIL %s: лишняя строка: %s\n' "$name" "$needle" >&2
    printf '%s\n' "$LAST_OUT" >&2
    FAIL=1
    return 0
  fi
  printf 'OK %s\n' "$name"
}

if grep -q "$(printf '\r')" "$SCRIPT"; then
  printf 'FAIL CRLF в time-sync.sh\n' >&2
  FAIL=1
else
  printf 'OK LF\n'
fi

run_case "dash -n" 0 dash -n "$SCRIPT"
if command -v bash >/dev/null 2>&1; then
  run_case "bash -n" 0 bash -n "$SCRIPT"
fi

run_case "self-test dash" 0 dash "$SCRIPT" self-test
if command -v bash >/dev/null 2>&1; then
  run_case "self-test bash" 0 bash "$SCRIPT" self-test
fi

run_case "help" 0 dash "$SCRIPT" --help
assert_contains "help sync-from" "sync-from"
assert_not_contains "help ok" "CHRONOSYNC_OK"

run_case "no args" 1 dash "$SCRIPT"
assert_not_contains "no args ok" "CHRONOSYNC_OK"

run_case "bad mode" 1 dash "$SCRIPT" --dry-run frobnicate
assert_not_contains "bad mode ok" "CHRONOSYNC_OK"

run_case "set without time" 1 dash "$SCRIPT" --dry-run set-time
run_case "bad time" 1 dash "$SCRIPT" --dry-run set-time "2026-13-40 00:00:00"
run_case "bad host" 1 dash "$SCRIPT" --dry-run sync-from "192.168.0.256"
run_case "ipv6" 1 dash "$SCRIPT" --dry-run sync-from "2001:db8::1"
assert_contains "ipv6 msg" "IPv6"
run_case "flag host" 1 dash "$SCRIPT" --dry-run sync-from -- -rf
run_case "allow on set" 1 dash "$SCRIPT" --dry-run set-time --allow 10.1.0.0/16 1761307080
run_case "two hosts" 1 dash "$SCRIPT" --dry-run sync-from 192.168.0.10 extra

before=$(date +%s)
run_case "dry set epoch" 0 dash "$SCRIPT" --dry-run set-time 1761307080
after=$(date +%s)
delta=$((after - before))
if [ "$delta" -lt 0 ]; then
  delta=$((-delta))
fi
if [ "$delta" -gt 30 ]; then
  printf 'FAIL часы системы изменились на %s с\n' "$delta" >&2
  FAIL=1
else
  printf 'OK clock unchanged\n'
fi
assert_contains "dry set date" "[dry-run] date -s @1761307080"
assert_contains "dry set ok" "CHRONOSYNC_OK mode=set-time"
assert_contains "dry set ntp off" "Службы синхронизации времени выключены"

run_case "dry set wall" 0 dash "$SCRIPT" --dry-run set-time 2026-10-24 14:18:00+05:00
assert_contains "wall spec" "[dry-run] date -s 2026-10-24 14:18:00+05:00"

run_case "dry set ru" 0 dash "$SCRIPT" --dry-run время "24.10.2026 14:18:00"
assert_contains "ru spec" "[dry-run] date -s 2026-10-24 14:18:00"

run_case "dry server" 0 env CHRONOSYNC_ENGINE=chrony dash "$SCRIPT" --dry-run time-server 1761307080
assert_contains "server local" "local stratum 8"
assert_contains "server allow" "allow 192.168.0.0/16"
assert_contains "server ok" "CHRONOSYNC_OK mode=time-server engine=chrony"
assert_contains "server unit" "[dry-run] systemctl enable chrony"
assert_not_contains "server pool" "pool.ntp.org"
if printf '%s\n' "$LAST_OUT" | grep -Eq '^server '; then
  printf 'FAIL server upstream directive\n' >&2
  FAIL=1
else
  printf 'OK server upstream\n'
fi

run_case "dry server no time" 0 env CHRONOSYNC_ENGINE=chrony dash "$SCRIPT" --dry-run сервер
assert_contains "warn no time" "время не передано"
assert_not_contains "no date" "[dry-run] date -s"

run_case "dry allow" 0 env CHRONOSYNC_ENGINE=chrony dash "$SCRIPT" --dry-run time-server --allow 10.50.1.5/16 1761307080
assert_contains "extra allow" "allow 10.50.1.5/16"

run_case "dry ntp server" 0 env CHRONOSYNC_ENGINE=ntp dash "$SCRIPT" --dry-run time-server --allow 10.50.1.5/16
assert_contains "ntp local" "server 127.127.1.0 minpoll 4 maxpoll 4"
assert_contains "ntp ignore" "restrict -4 default ignore"
assert_contains "ntp extra" "restrict -4 10.50.0.0 mask 255.255.0.0 nomodify notrap"
assert_contains "ntp ok" "CHRONOSYNC_OK mode=time-server engine=ntp"
assert_not_contains "ntp pool" "pool.ntp.org"

run_case "dry client" 0 env CHRONOSYNC_ENGINE=chrony dash "$SCRIPT" --dry-run sync-from 192.168.0.10
assert_contains "client server" "server 192.168.0.10 iburst"
assert_contains "client ok" "CHRONOSYNC_OK mode=sync-from engine=chrony server=192.168.0.10"
assert_not_contains "client local" "local stratum"
assert_not_contains "client pool" "pool.ntp.org"

run_case "dry client alias" 0 env CHRONOSYNC_ENGINE=chrony dash "$SCRIPT" --dry-run клиент time-server.lan
assert_contains "alias server" "server time-server.lan iburst"

run_case "dry ntp client" 0 env CHRONOSYNC_ENGINE=ntp dash "$SCRIPT" --dry-run sync-from 10.1.2.3
assert_contains "ntp client restrict" "restrict -4 10.1.2.3 nomodify notrap noquery"
assert_contains "ntp client server" "server 10.1.2.3 iburst"

run_case "dry timesyncd client" 0 env CHRONOSYNC_ENGINE=timesyncd dash "$SCRIPT" --dry-run sync-from 192.168.1.5
assert_contains "timesyncd ntp" "NTP=192.168.1.5"
assert_contains "timesyncd file" "/etc/systemd/timesyncd.conf.d/chronosync.conf"
assert_contains "timesyncd ok" "CHRONOSYNC_OK mode=sync-from engine=timesyncd server=192.168.1.5"

run_case "timesyncd server" 1 env CHRONOSYNC_ENGINE=timesyncd dash "$SCRIPT" --dry-run time-server 1761307080
assert_contains "timesyncd refuse" "systemd-timesyncd не может быть сервером"
assert_not_contains "timesyncd server ok" "CHRONOSYNC_OK"

run_case "bad engine" 1 env CHRONOSYNC_ENGINE=openntpd dash "$SCRIPT" --dry-run time-server
assert_not_contains "bad engine ok" "CHRONOSYNC_OK"

if [ "$FAIL" -ne 0 ]; then
  printf 'Тесты не прошли\n' >&2
  exit 1
fi
printf 'Все проверки прошли\n'
