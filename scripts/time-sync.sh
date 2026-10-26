#!/bin/sh
# Синхронизация времени для устройств установщика.
#
# Платформы: NanoPi H3, NanoPi H5, RK3588, x86_64.
# ОС: Ubuntu 18.04, Ubuntu 22.04, Astra Linux 1.8 и другие Debian-совместимые
# сборки (в том числе Astra Linux 4.8), со systemd.
#
# Скрипт запускается уже на устройстве. Логин, пароль и IP — это параметры
# SSH в установщике, сюда их передавать не нужно.
#
# Время передавайте Unix-секундами с машины, где работает установщик
# (Qt: QDateTime::currentSecsSinceEpoch()), сразу перед вызовом.
# Так часовой пояс устройства не влияет на абсолютное время.
#
#   time-sync.sh set-time <время> [--backup <каталог>]
#   time-sync.sh time-server [время] [--allow a.b.c.d/nn] [--backup <каталог>]
#   time-sync.sh sync-from <ip-сервера-времени> [--backup <каталог>]
#   time-sync.sh restore <файл-сохранённых-настроек>
#   time-sync.sh check
#
# Примеры:
#   time-sync.sh set-time 1761307080
#   time-sync.sh time-server 1761307080
#   time-sync.sh sync-from 192.168.0.10
#   time-sync.sh --backup /var/lib/chronosync/backups set-time 1761307080
#   time-sync.sh restore /var/lib/chronosync/backups/client
#
# set-time только выставляет часы и выключает NTP.
# time-server выставляет часы (если время передано) и раздаёт их по udp/123
# в частные сети. В интернет сервер не ходит: источником является выставленное время.
# sync-from настраивает устройство брать время только с указанного сервера.
#
# Предпочтительно ставится chrony. Если пакета нет в репозитории — ntp.
# Если установить их нельзя, клиент может остаться на systemd-timesyncd.
# Серверу нужен chrony или ntp.
#
# Переводы строк файла — только LF.

set -eu
umask 022

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-/usr/bin:/bin}"
export PATH

DRY_RUN=0
ACTION=
REST=
ALLOW=
ALLOW_FLAG=0
ENGINE=
SERVER=
NORM_KIND=
NORM_SPEC=
UNIT=
NTP_VARIANT=ntp
POLICY_ADDED=0
TMP_FILE=
PARSE_TMP=
FAILS=0
BACKUP_DIR=
RESTORE_FILE=
BACKUP_ROLE=
BACKUP_ENGINE=
BACKUP_SERVERS=
BACKUP_DEFAULT_UPSTREAM=0
BACKUP_ALLOW=
PROBE_ROLE_ENGINE=
PROBE_ROLE_STATE=
PROBE_ROLE_SERVER=0
PROBE_ROLE_UPSTREAMS=
PROBE_ROLE_DEFAULT_UPSTREAM=0
PROBE_ROLE_NAME=

cleanup() {
  if [ -n "${TMP_FILE:-}" ] && [ -f "$TMP_FILE" ]; then
    rm -f "$TMP_FILE"
  fi
  if [ -n "${PARSE_TMP:-}" ] && [ -f "$PARSE_TMP" ]; then
    rm -f "$PARSE_TMP"
  fi
  if [ "${POLICY_ADDED:-0}" -eq 1 ]; then
    rm -f /usr/sbin/policy-rc.d
    POLICY_ADDED=0
  fi
}

trap cleanup EXIT INT TERM

log() {
  printf '%s\n' "$*"
}

die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Использование:
  time-sync.sh set-time <время>
  time-sync.sh time-server [время] [--allow a.b.c.d/nn]
  time-sync.sh sync-from <адрес-сервера-времени> [--backup <каталог>]
  time-sync.sh restore <файл-сохранённых-настроек>
  time-sync.sh check
  time-sync.sh --dry-run <режим> [аргументы]
  time-sync.sh self-test

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
  restore       восстановить настройки из файла, сохранённого через --backup

Дополнительные имена режимов: set, server, client, check, restore, время, сервер, клиент, проверка, восстановление.

--backup <каталог> перед set-time, time-server или sync-from сохраняет текущие настройки
в каталоге файлом server, client, both или none (по текущей роли), затем применяет новый режим.

Логин, пароль и IP подключения скрипт не принимает: их использует SSH установщика.
Пароль в аргументы не передавайте.

--allow добавляет одну сеть к частным диапазонам, которым сервер отдаёт время.
То же самое делает переменная CHRONOSYNC_ALLOW=a.b.c.d/nn.
CHRONOSYNC_ENGINE=chrony|ntp|timesyncd принудительно выбирает службу.
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Не найдена команда: $1"
  fi
}

parse_args() {
  DRY_RUN=0
  ACTION=
  REST=
  ALLOW=
  ALLOW_FLAG=0
  BACKUP_DIR=
  RESTORE_FILE=
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --backup)
        if [ $# -lt 2 ]; then
          die "--backup требует каталог для сохранения настроек"
        fi
        BACKUP_DIR=$2
        shift 2
        ;;
      --allow)
        if [ $# -lt 2 ]; then
          die "--allow требует сеть в виде a.b.c.d/nn"
        fi
        ALLOW=$2
        ALLOW_FLAG=1
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        die "Неизвестный параметр: $1"
        ;;
      *)
        if [ -z "$ACTION" ]; then
          ACTION=$1
        elif [ -z "$REST" ]; then
          REST=$1
        else
          REST="${REST} $1"
        fi
        shift
        ;;
    esac
  done
  while [ $# -gt 0 ]; do
    if [ -z "$ACTION" ]; then
      ACTION=$1
    elif [ -z "$REST" ]; then
      REST=$1
    else
      REST="${REST} $1"
    fi
    shift
  done

  case "$ACTION" in
    set|set-time|set_time|время)
      ACTION=set-time
      ;;
    server|time-server|time_server|ntp-server|сервер)
      ACTION=time-server
      ;;
    client|sync-from|sync_from|sync|клиент)
      ACTION=sync-from
      ;;
    check|проверка)
      ACTION=check
      ;;
    restore|восстановление)
      ACTION=restore
      ;;
    self-test)
      ACTION=self-test
      ;;
    "")
      usage >&2
      exit 1
      ;;
    *)
      die "Неизвестный режим: ${ACTION}. Допустимо: set-time, time-server, sync-from, check."
      ;;
  esac

  if [ -z "$ALLOW" ] && [ -n "${CHRONOSYNC_ALLOW:-}" ]; then
    ALLOW=${CHRONOSYNC_ALLOW}
  fi
  if [ "$ACTION" != "time-server" ]; then
    if [ "$ALLOW_FLAG" -eq 1 ]; then
      die "--allow используется только вместе с time-server"
    fi
    ALLOW=
  fi
  case "$ACTION" in
    set-time|time-server|sync-from)
      ;;
    *)
      if [ -n "$BACKUP_DIR" ]; then
        die "--backup используется только с set-time, time-server или sync-from"
      fi
      ;;
  esac
}

valid_octet() {
  local o
  o=$1
  case "$o" in
    ""|*[!0-9]*)
      return 1
      ;;
    0*)
      if [ "$o" != "0" ]; then
        return 1
      fi
      ;;
  esac
  if [ "$o" -ge 0 ] && [ "$o" -le 255 ]; then
    return 0
  fi
  return 1
}

valid_ipv4() {
  local ip o1 o2 o3 o4 extra
  ip=$1
  if ! printf '%s\n' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    return 1
  fi
  IFS=. read -r o1 o2 o3 o4 extra <<EOF || return 1
${ip}
EOF
  if [ -z "$o1" ] || [ -z "$o2" ] || [ -z "$o3" ] || [ -z "$o4" ] || [ -n "$extra" ]; then
    return 1
  fi
  valid_octet "$o1" || return 1
  valid_octet "$o2" || return 1
  valid_octet "$o3" || return 1
  valid_octet "$o4" || return 1
  return 0
}

valid_host() {
  local h
  h=$1
  if [ -z "$h" ]; then
    return 1
  fi
  case "$h" in
    -*)
      return 1
      ;;
  esac
  if printf '%s\n' "$h" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
    valid_ipv4 "$h" || return 1
    if [ "$h" = "0.0.0.0" ] || [ "$h" = "255.255.255.255" ]; then
      return 1
    fi
    return 0
  fi
  if ! printf '%s\n' "$h" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'; then
    return 1
  fi
  if [ "${#h}" -gt 253 ]; then
    return 1
  fi
  return 0
}

valid_time() {
  local t
  t=$1
  if [ -z "$t" ]; then
    return 1
  fi
  if printf '%s\n' "$t" | grep -Eq '^[0-9]{9,12}$'; then
    return 0
  fi
  if printf '%s\n' "$t" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:?[0-9]{2}|Z)?$'; then
    return 0
  fi
  if printf '%s\n' "$t" | grep -Eq '^[0-9]{2}\.[0-9]{2}\.[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
    return 0
  fi
  return 1
}

cidr_to_net_mask() {
  printf '%s\n' "$1" | awk -F'[./]' '
    NF != 5 { exit 1 }
    {
      p = $5 + 0
      if (p < 1 || p > 32) exit 1
      for (i = 1; i <= 4; i++) {
        if ($i < 0 || $i > 255) exit 1
      }
      ipnum = $1 * 16777216 + $2 * 65536 + $3 * 256 + $4
      mod = 1
      for (i = 0; i < 32 - p; i++) mod = mod * 2
      netnum = ipnum - (ipnum % mod)
      mask = 0
      for (i = 0; i < 32; i++) {
        mask = mask * 2
        if (i < p) mask = mask + 1
      }
      printf "%d.%d.%d.%d %d.%d.%d.%d\n",
        int(netnum / 16777216) % 256,
        int(netnum / 65536) % 256,
        int(netnum / 256) % 256,
        int(netnum) % 256,
        int(mask / 16777216) % 256,
        int(mask / 65536) % 256,
        int(mask / 256) % 256,
        int(mask) % 256
    }
  '
}

valid_cidr() {
  local pair
  pair=$(cidr_to_net_mask "$1" 2>/dev/null || true)
  if [ -z "$pair" ]; then
    return 1
  fi
  return 0
}

normalize_time() {
  local t clean
  t=$1
  if ! valid_time "$t"; then
    return 1
  fi
  if printf '%s\n' "$t" | grep -Eq '^[0-9]{9,12}$'; then
    NORM_KIND=epoch
    NORM_SPEC="@${t}"
    return 0
  fi
  if printf '%s\n' "$t" | grep -Eq '^[0-9]{2}\.[0-9]{2}\.[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
    clean=$(printf '%s\n' "$t" | awk -F'[. ]' '{printf "%s-%s-%s %s", $3, $2, $1, $4}')
    NORM_KIND=local
    NORM_SPEC=$clean
    return 0
  fi
  clean=$(printf '%s\n' "$t" | tr 'T' ' ')
  if printf '%s\n' "$clean" | grep -Eq 'Z$|[+-][0-9]{2}:?[0-9]{2}$'; then
    NORM_KIND=absolute
  else
    NORM_KIND=local
  fi
  NORM_SPEC=$clean
  return 0
}

prepare_time() {
  if ! normalize_time "$1"; then
    return 1
  fi
  if ! date -d "$NORM_SPEC" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

validate_args() {
  case "$ACTION" in
    set-time)
      if [ -z "$REST" ]; then
        die "Укажите время: time-sync.sh set-time <время>"
      fi
      if ! prepare_time "$REST"; then
        die "Некорректное время: ${REST}. Ожидаются Unix-секунды или дата ГГГГ-ММ-ДД ЧЧ:ММ:СС."
      fi
      ;;
    time-server)
      if [ -n "$REST" ]; then
        if ! prepare_time "$REST"; then
          die "Некорректное время: ${REST}. Ожидаются Unix-секунды или дата ГГГГ-ММ-ДД ЧЧ:ММ:СС."
        fi
      else
        NORM_KIND=
        NORM_SPEC=
      fi
      if [ -n "$ALLOW" ] && ! valid_cidr "$ALLOW"; then
        die "Некорректная сеть для --allow: ${ALLOW} (ожидается a.b.c.d/nn)"
      fi
      ;;
    sync-from)
      if [ -z "$REST" ]; then
        die "Укажите адрес сервера: time-sync.sh sync-from <ip>"
      fi
      case "$REST" in
        *" "*)
          die "Адрес сервера времени — один аргумент, без пробелов."
          ;;
        *:*)
          die "Нужен IPv4-адрес или DNS-имя. IPv6 не поддерживается: ${REST}"
          ;;
      esac
      if ! valid_host "$REST"; then
        die "Некорректный адрес сервера времени: ${REST}"
      fi
      SERVER=$REST
      ;;
    check)
      if [ -n "$REST" ]; then
        die "Режим check не принимает дополнительные аргументы."
      fi
      ;;
    restore)
      if [ -z "$REST" ]; then
        die "Укажите файл: time-sync.sh restore <файл-сохранённых-настроек>"
      fi
      case "$REST" in
        *" "*)
          die "Путь к файлу резервной копии — один аргумент, без пробелов."
          ;;
      esac
      RESTORE_FILE=$REST
      ;;
    self-test)
      ;;
  esac
  return 0
}

needs_privilege() {
  if [ "$DRY_RUN" -eq 1 ] || [ "$ACTION" = "self-test" ] || [ "$ACTION" = "check" ]; then
    return 1
  fi
  return 0
}

elevate() {
  if [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  if [ "${CHRONOSYNC_NO_SUDO:-0}" = "1" ]; then
    die "Нужны права root."
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    exec sudo -n -E -- "$0" "$@"
  fi
  die "Нужны права root. Подключайтесь по SSH пользователем root или настройте sudo без пароля."
}

have_chrony() {
  command -v chronyd >/dev/null 2>&1
}

have_ntp() {
  command -v ntpd >/dev/null 2>&1
}

have_timesyncd() {
  if [ -f /lib/systemd/system/systemd-timesyncd.service ]; then
    return 0
  fi
  if [ -f /usr/lib/systemd/system/systemd-timesyncd.service ]; then
    return 0
  fi
  return 1
}

detect_ntp_variant() {
  NTP_VARIANT=ntp
  if command -v dpkg >/dev/null 2>&1 && dpkg -s ntpsec >/dev/null 2>&1; then
    NTP_VARIANT=ntpsec
    return 0
  fi
  if [ -d /etc/ntpsec ]; then
    NTP_VARIANT=ntpsec
  fi
  return 0
}

begin_policy() {
  POLICY_ADDED=0
  if [ "$DRY_RUN" -eq 1 ] || [ -e /usr/sbin/policy-rc.d ]; then
    return 0
  fi
  if ! printf '%s\n' '#!/bin/sh' 'exit 101' > /usr/sbin/policy-rc.d; then
    return 0
  fi
  chmod 755 /usr/sbin/policy-rc.d || true
  POLICY_ADDED=1
  return 0
}

end_policy() {
  if [ "$POLICY_ADDED" -eq 1 ]; then
    rm -f /usr/sbin/policy-rc.d || true
    POLICY_ADDED=0
  fi
  return 0
}

run_timeout() {
  local secs
  secs=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  "$@"
  return $?
}

install_pkg() {
  local pkg apt_log
  pkg=$1
  if ! command -v apt-get >/dev/null 2>&1; then
    return 1
  fi
  export DEBIAN_FRONTEND=noninteractive
  begin_policy || true
  apt_log="/tmp/chronosync-apt.${pkg}.$$.log"
  log "Пробую установить пакет ${pkg}..."
  if ! run_timeout 120 apt-get update -y \
      -o Acquire::Retries=1 \
      -o Acquire::http::Timeout=15 \
      -o Acquire::https::Timeout=15 >"$apt_log" 2>&1; then
    log "Предупреждение: apt-get update не выполнен."
    if [ -f "$apt_log" ]; then
      tail -n 20 "$apt_log" || true
    fi
  fi
  if ! run_timeout 180 apt-get install -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$pkg" >"$apt_log" 2>&1; then
    log "Не удалось установить пакет ${pkg}."
    if [ -f "$apt_log" ]; then
      tail -n 30 "$apt_log" || true
    fi
    rm -f "$apt_log" || true
    end_policy
    return 1
  fi
  rm -f "$apt_log" || true
  end_policy
  hash -r 2>/dev/null || true
  log "Пакет ${pkg} установлен."
  return 0
}

ensure_engine() {
  local purpose
  purpose=$1
  if [ -n "${CHRONOSYNC_ENGINE:-}" ]; then
    case "$CHRONOSYNC_ENGINE" in
      chrony|ntp|timesyncd)
        ENGINE=$CHRONOSYNC_ENGINE
        ;;
      *)
        die "CHRONOSYNC_ENGINE должен быть chrony, ntp или timesyncd"
        ;;
    esac
    if [ "$ENGINE" = "ntp" ]; then
      detect_ntp_variant
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      case "$ENGINE" in
        chrony)
          if ! have_chrony; then
            install_pkg chrony || die "Не удалось установить chrony."
            have_chrony || die "Пакет chrony установлен, но chronyd не найден в PATH."
          fi
          ;;
        ntp)
          if ! have_ntp; then
            install_pkg ntp || install_pkg ntpsec || die "Не удалось установить ntp."
            have_ntp || die "Пакет ntp установлен, но ntpd не найден в PATH."
            detect_ntp_variant
          fi
          ;;
        timesyncd)
          have_timesyncd || die "systemd-timesyncd не установлен."
          ;;
      esac
    fi
  elif have_chrony; then
    ENGINE=chrony
  elif have_ntp; then
    ENGINE=ntp
    detect_ntp_variant
  elif [ "$DRY_RUN" -eq 1 ]; then
    ENGINE=chrony
    log "[dry-run] chrony и ntp не найдены, был бы установлен пакет chrony"
  elif install_pkg chrony && have_chrony; then
    ENGINE=chrony
  elif install_pkg ntp && have_ntp; then
    ENGINE=ntp
    detect_ntp_variant
  elif install_pkg ntpsec && have_ntp; then
    ENGINE=ntp
    detect_ntp_variant
  elif [ "$purpose" = "client" ] && have_timesyncd; then
    ENGINE=timesyncd
    log "Пакеты chrony и ntp недоступны. Используется systemd-timesyncd (только клиент)."
  else
    die "Не найден chrony или ntp, и установить пакет не удалось. На устройстве без интернета поставьте пакет chrony из локального репозитория и повторите."
  fi

  if [ "$purpose" = "server" ] && [ "$ENGINE" = "timesyncd" ]; then
    die "systemd-timesyncd не может быть сервером времени. Установите пакет chrony или ntp."
  fi
  log "Движок: ${ENGINE}"
  return 0
}

unit_exists() {
  local name
  name=$1
  if [ -f "/lib/systemd/system/${name}.service" ]; then
    return 0
  fi
  if [ -f "/usr/lib/systemd/system/${name}.service" ]; then
    return 0
  fi
  if [ -f "/etc/systemd/system/${name}.service" ]; then
    return 0
  fi
  return 1
}

select_unit() {
  local u
  UNIT=
  for u in "$@"; do
    if unit_exists "$u"; then
      UNIT=$u
      return 0
    fi
  done
  UNIT=$1
  return 0
}

choose_unit() {
  case "$ENGINE" in
    chrony)
      select_unit chrony chronyd
      ;;
    ntp)
      if [ "$NTP_VARIANT" = "ntpsec" ]; then
        select_unit ntpsec ntp ntpd
      else
        select_unit ntp ntpd
      fi
      ;;
    timesyncd)
      select_unit systemd-timesyncd
      ;;
    *)
      UNIT=
      return 1
      ;;
  esac
}

stop_unit() {
  local unit
  unit=$1
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] systemctl disable --now %s\n' "$unit"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
    return 0
  fi
  if command -v service >/dev/null 2>&1; then
    service "$unit" stop >/dev/null 2>&1 || true
  fi
  return 0
}

disable_all_time_services() {
  local unit
  for unit in systemd-timesyncd chrony chronyd ntp ntpd ntpsec; do
    stop_unit "$unit"
  done
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] timedatectl set-ntp false\n'
    printf '[dry-run] остановить chronyd и ntpd, если они ещё запущены\n'
    return 0
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp false >/dev/null 2>&1 || true
  fi
  if command -v killall >/dev/null 2>&1; then
    killall chronyd ntpd >/dev/null 2>&1 || true
  fi
  return 0
}

start_unit() {
  local unit
  unit=$1
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] systemctl unmask %s\n' "$unit"
    printf '[dry-run] systemctl enable %s\n' "$unit"
    printf '[dry-run] systemctl restart %s\n' "$unit"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl unmask "$unit" >/dev/null 2>&1 || true
    if ! systemctl enable "$unit"; then
      return 1
    fi
    if ! systemctl restart "$unit"; then
      return 1
    fi
    return 0
  fi
  if command -v service >/dev/null 2>&1; then
    if ! service "$unit" restart; then
      return 1
    fi
    if command -v update-rc.d >/dev/null 2>&1; then
      update-rc.d "$unit" enable >/dev/null 2>&1 || true
    fi
    return 0
  fi
  return 1
}

enable_timesyncd() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] systemctl unmask systemd-timesyncd\n'
    printf '[dry-run] systemctl enable systemd-timesyncd\n'
    printf '[dry-run] systemctl restart systemd-timesyncd\n'
    printf '[dry-run] timedatectl set-ntp true\n'
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl unmask systemd-timesyncd >/dev/null 2>&1 || true
    systemctl enable systemd-timesyncd || return 1
    systemctl restart systemd-timesyncd || return 1
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true >/dev/null 2>&1 || return 1
  fi
  return 0
}

sync_rtc() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] hwclock --systohc\n'
    return 0
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-local-rtc 0 >/dev/null 2>&1 || true
  fi
  if ! command -v hwclock >/dev/null 2>&1; then
    log "Предупреждение: hwclock не найден, аппаратные часы не обновлены."
    return 0
  fi
  if hwclock --systohc >/dev/null 2>&1; then
    log "Аппаратные часы (RTC) обновлены."
  else
    log "Предупреждение: не удалось записать RTC. Системное время установлено."
  fi
  sync >/dev/null 2>&1 || true
  return 0
}

set_clock() {
  if [ -z "$NORM_SPEC" ]; then
    return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] date -s %s\n' "$NORM_SPEC"
  else
    if ! date -s "$NORM_SPEC"; then
      return 1
    fi
    log "Время устройства (локальное): $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log "Время устройства (UTC): $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  fi
  sync_rtc || return 1
  return 0
}

chrony_conf_path() {
  if [ -f /etc/chrony.conf ] && [ ! -d /etc/chrony ]; then
    printf '%s\n' /etc/chrony.conf
    return 0
  fi
  if [ "$DRY_RUN" -eq 0 ]; then
    mkdir -p /etc/chrony || return 1
  fi
  printf '%s\n' /etc/chrony/chrony.conf
  return 0
}

ntp_drift_path() {
  if [ "$NTP_VARIANT" = "ntpsec" ]; then
    printf '%s\n' /var/lib/ntpsec/ntp.drift
  else
    printf '%s\n' /var/lib/ntp/ntp.drift
  fi
}

ntp_conf_path() {
  if [ "$NTP_VARIANT" = "ntpsec" ]; then
    if [ "$DRY_RUN" -eq 0 ]; then
      mkdir -p /etc/ntpsec || return 1
    fi
    printf '%s\n' /etc/ntpsec/ntp.conf
    return 0
  fi
  printf '%s\n' /etc/ntp.conf
  return 0
}

build_chrony_server_conf() {
  local base
  base=$(cat <<EOF
# chronosync-managed
# Локальный сервер времени. Внешние NTP-серверы не используются.
# local stratum заставляет chrony раздавать время без внешнего источника.
driftfile /var/lib/chrony/chrony.drift
rtcsync
makestep 1.0 3
local stratum 8
allow 10.0.0.0/8
allow 172.16.0.0/12
allow 192.168.0.0/16
allow 169.254.0.0/16
EOF
)
  if [ -n "$ALLOW" ]; then
    base="${base}
allow ${ALLOW}"
  fi
  printf '%s\n' "$base"
}

build_chrony_client_conf() {
  cat <<EOF
# chronosync-managed
# Клиент берёт время только с указанного сервера.
driftfile /var/lib/chrony/chrony.drift
rtcsync
makestep 1.0 -1
server ${SERVER} iburst
EOF
}

build_ntp_server_conf() {
  local base pair net mask drift
  drift=$(ntp_drift_path)
  base=$(cat <<EOF
# chronosync-managed
# Локальный сервер времени. Внешние NTP-серверы не используются.
driftfile ${drift}
tinker panic 0
restrict -4 default ignore
restrict -4 127.0.0.1
restrict -6 default ignore
restrict -6 ::1
restrict -4 10.0.0.0 mask 255.0.0.0 nomodify notrap
restrict -4 172.16.0.0 mask 255.240.0.0 nomodify notrap
restrict -4 192.168.0.0 mask 255.255.0.0 nomodify notrap
restrict -4 169.254.0.0 mask 255.255.0.0 nomodify notrap
server 127.127.1.0 minpoll 4 maxpoll 4
fudge 127.127.1.0 stratum 8
EOF
)
  if [ -n "$ALLOW" ]; then
    pair=$(cidr_to_net_mask "$ALLOW") || return 1
    net=${pair% *}
    mask=${pair#* }
    base="${base}
restrict -4 ${net} mask ${mask} nomodify notrap"
  fi
  printf '%s\n' "$base"
}

build_ntp_client_conf() {
  local drift
  drift=$(ntp_drift_path)
  cat <<EOF
# chronosync-managed
# Клиент берёт время только с указанного сервера.
driftfile ${drift}
tinker panic 0
restrict -4 default ignore
restrict -4 127.0.0.1
restrict -6 default ignore
restrict -6 ::1
restrict -4 ${SERVER} nomodify notrap noquery
server ${SERVER} iburst
EOF
}

build_timesyncd_conf() {
  cat <<EOF
[Time]
NTP=${SERVER}
FallbackNTP=
EOF
}

write_text() {
  local dest content dest_dir
  dest=$1
  content=$2
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] запись %s\n' "$dest"
    printf '%s\n' "$content"
    return 0
  fi
  dest_dir=$(dirname "$dest")
  mkdir -p "$dest_dir" || return 1
  if [ -f "$dest" ] && [ ! -f "${dest}.bak.chronosync" ]; then
    cp -a "$dest" "${dest}.bak.chronosync" || return 1
  fi
  TMP_FILE="${dest}.tmp.$$"
  if ! printf '%s\n' "$content" > "$TMP_FILE"; then
    return 1
  fi
  if ! mv "$TMP_FILE" "$dest"; then
    return 1
  fi
  TMP_FILE=
  chmod 644 "$dest" || return 1
  return 0
}

apply_config() {
  local role path content
  role=$1
  case "${ENGINE}:${role}" in
    chrony:server)
      path=$(chrony_conf_path) || return 1
      content=$(build_chrony_server_conf) || return 1
      ;;
    chrony:client)
      path=$(chrony_conf_path) || return 1
      content=$(build_chrony_client_conf) || return 1
      ;;
    ntp:server)
      path=$(ntp_conf_path) || return 1
      content=$(build_ntp_server_conf) || return 1
      ;;
    ntp:client)
      path=$(ntp_conf_path) || return 1
      content=$(build_ntp_client_conf) || return 1
      ;;
    timesyncd:client)
      path=/etc/systemd/timesyncd.conf.d/chronosync.conf
      content=$(build_timesyncd_conf) || return 1
      ;;
    *)
      return 1
      ;;
  esac
  write_text "$path" "$content" || return 1
  log "Конфигурация: ${path}"
  return 0
}

prepare_dirs() {
  local dir drift
  case "$ENGINE" in
    chrony)
      dir=/var/lib/chrony
      ;;
    ntp)
      drift=$(ntp_drift_path)
      dir=$(dirname "$drift")
      ;;
    *)
      return 0
      ;;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] mkdir -p %s\n' "$dir"
    return 0
  fi
  mkdir -p "$dir" || return 1
  if [ "$ENGINE" = "chrony" ]; then
    if id _chrony >/dev/null 2>&1; then
      chown _chrony "$dir" || true
    elif id chrony >/dev/null 2>&1; then
      chown chrony "$dir" || true
    fi
  elif id ntp >/dev/null 2>&1; then
    chown ntp "$dir" || true
  elif id ntpsec >/dev/null 2>&1; then
    chown ntpsec "$dir" || true
  fi
  return 0
}

write_state() {
  local content
  content=$(cat <<EOF
mode=${ACTION}
engine=${ENGINE}
server=${SERVER}
allow=${ALLOW}
EOF
)
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] запись /var/lib/chronosync/state\n'
    printf '%s\n' "$content"
    return 0
  fi
  mkdir -p /var/lib/chronosync || return 1
  TMP_FILE="/var/lib/chronosync/state.tmp.$$"
  if ! printf '%s\n' "$content" > "$TMP_FILE"; then
    return 1
  fi
  if ! mv "$TMP_FILE" /var/lib/chronosync/state; then
    return 1
  fi
  TMP_FILE=
  chmod 644 /var/lib/chronosync/state || true
  return 0
}

open_firewall() {
  local policy handled
  handled=0
  policy=
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] открыть входящий udp/123, если фаервол это блокирует\n'
    return 0
  fi
  if [ -f /etc/ufw/ufw.conf ] && grep -Eq '^ENABLED=yes' /etc/ufw/ufw.conf; then
    if command -v ufw >/dev/null 2>&1; then
      ufw allow 123/udp >/dev/null 2>&1 || true
      ufw allow out 123/udp >/dev/null 2>&1 || true
      handled=1
      log "Фаервол: ufw разрешает udp/123."
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port=123/udp --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    handled=1
    log "Фаервол: firewalld разрешает udp/123."
  fi
  if [ "$handled" -eq 0 ] && command -v iptables >/dev/null 2>&1; then
    policy=$(iptables -S INPUT 2>/dev/null | head -n 1 || true)
    case "$policy" in
      "-P INPUT DROP"|"-P INPUT REJECT")
        if ! iptables -C INPUT -p udp --dport 123 -j ACCEPT >/dev/null 2>&1; then
          iptables -I INPUT -p udp --dport 123 -j ACCEPT >/dev/null 2>&1 || true
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
          netfilter-persistent save >/dev/null 2>&1 || log "Предупреждение: правило udp/123 добавлено, но не сохранено."
        elif [ -d /etc/iptables ] && command -v iptables-save >/dev/null 2>&1; then
          iptables-save > /etc/iptables/rules.v4 2>/dev/null || log "Предупреждение: правило udp/123 действует только до перезагрузки."
        else
          log "Предупреждение: правило udp/123 добавлено в iptables только до перезагрузки."
        fi
        log "Фаервол: iptables разрешает входящий udp/123."
        ;;
      *)
        log "Входящий фильтр не запрещает соединения, отдельное правило udp/123 не нужно."
        ;;
    esac
  elif [ "$handled" -eq 0 ]; then
    log "Фаервол не обнаружен, отдельное правило udp/123 не добавлялось."
  fi
  return 0
}

chrony_csv_synced() {
  printf '%s\n' "$1" | awk -F, 'NF >= 2 && ($2 == "*" || $2 == "+" || $1 ~ /\*/) { found = 1 } END { exit (found ? 0 : 1) }'
}

chrony_tracking_ok() {
  printf '%s\n' "$1" | awk -F, 'NF >= 2 { stratum = $2 + 0; leap = $NF; if (leap == "Normal" && stratum >= 1 && stratum <= 15) found = 1 } END { exit (found ? 0 : 1) }'
}

chrony_client_synced() {
  local sources
  sources=$(LC_ALL=C chronyc -c sources 2>/dev/null || true)
  if chrony_csv_synced "$sources"; then
    return 0
  fi
  return 1
}

chrony_server_ready() {
  local tracking
  tracking=$(LC_ALL=C chronyc -c tracking 2>/dev/null || true)
  if chrony_tracking_ok "$tracking"; then
    return 0
  fi
  return 1
}

ntp_port_open() {
  if command -v ss >/dev/null 2>&1; then
    if LC_ALL=C ss -uln | grep -E ':123([[:space:]]|$)' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  if command -v netstat >/dev/null 2>&1; then
    if LC_ALL=C netstat -uln | grep -E ':123([[:space:]]|$)' >/dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  return 0
}

ntp_query() {
  if ! command -v ntpq >/dev/null 2>&1; then
    printf '%s\n' ""
    return 0
  fi
  LC_ALL=C ntpq -pnw 2>/dev/null || LC_ALL=C ntpq -pn 2>/dev/null || true
}

ntp_server_ready() {
  local out
  out=$(ntp_query)
  if printf '%s\n' "$out" | grep -F '127.127.1.0' >/dev/null 2>&1 \
      && printf '%s\n' "$out" | grep -F '*' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

ntp_client_synced() {
  local out
  out=$(ntp_query)
  if printf '%s\n' "$out" | grep -F '*' | grep -F "$SERVER" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

timesyncd_synced() {
  local value shown
  if command -v timedatectl >/dev/null 2>&1 && timedatectl show-timesync -p ServerAddress --value >/dev/null 2>&1; then
    shown=$(timedatectl show-timesync -p ServerAddress --value 2>/dev/null || true)
    value=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    if [ "$value" = "yes" ] && [ "$shown" = "$SERVER" ]; then
      return 0
    fi
    shown=$(timedatectl show-timesync -p ServerName --value 2>/dev/null || true)
    if [ "$value" = "yes" ] && [ "$shown" = "$SERVER" ]; then
      return 0
    fi
    return 1
  fi
  value=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  if [ "$value" = "yes" ]; then
    return 0
  fi
  return 1
}

verify_server() {
  local i
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] проверка, что сервер времени отвечает\n'
    return 0
  fi
  i=0
  while [ "$i" -lt 45 ]; do
    case "$ENGINE" in
      chrony)
        if chrony_server_ready && ntp_port_open; then
          return 0
        fi
        ;;
      ntp)
        if ntp_server_ready && ntp_port_open; then
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

verify_client() {
  local i limit
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] проверка синхронизации с %s\n' "$SERVER"
    return 0
  fi
  if [ "$ENGINE" = "ntp" ]; then
    limit=45
  else
    limit=30
  fi
  i=0
  while [ "$i" -lt "$limit" ]; do
    case "$ENGINE" in
      chrony)
        if chrony_client_synced; then
          LC_ALL=C chronyc makestep >/dev/null 2>&1 || true
          return 0
        fi
        ;;
      ntp)
        if ntp_client_synced; then
          return 0
        fi
        ;;
      timesyncd)
        if timesyncd_synced; then
          return 0
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

show_time_debug() {
  local unit
  unit=$1
  if command -v chronyc >/dev/null 2>&1; then
    log "--- chronyc tracking ---"
    LC_ALL=C chronyc tracking 2>&1 || true
    log "--- chronyc sources ---"
    LC_ALL=C chronyc sources -v 2>&1 || true
  fi
  if command -v ntpq >/dev/null 2>&1; then
    log "--- ntpq ---"
    LC_ALL=C ntpq -pnw 2>&1 || LC_ALL=C ntpq -pn 2>&1 || true
  fi
  if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
    log "--- systemctl status ${unit} ---"
    systemctl status "$unit" --no-pager -l 2>&1 || true
  fi
  if [ -n "$unit" ] && command -v journalctl >/dev/null 2>&1; then
    log "--- journal ${unit} ---"
    journalctl -u "$unit" -n 40 --no-pager 2>&1 || true
  fi
  return 0
}

show_brief_status() {
  if [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  case "$ENGINE" in
    chrony)
      if command -v chronyc >/dev/null 2>&1; then
        LC_ALL=C chronyc tracking || true
      fi
      ;;
    ntp)
      ntp_query || true
      ;;
    timesyncd)
      timedatectl status || true
      ;;
  esac
  return 0
}

print_addresses() {
  local addrs
  if command -v ip >/dev/null 2>&1; then
    addrs=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)
  elif command -v hostname >/dev/null 2>&1; then
    addrs=$(hostname -I 2>/dev/null | tr ' ' '\n' || true)
  else
    addrs=
  fi
  addrs=$(printf '%s\n' "$addrs" | awk 'NF {print}' || true)
  if [ -n "$addrs" ]; then
    printf '%s\n' "$addrs"
  else
    log "Не удалось определить IPv4-адреса устройства."
  fi
  return 0
}

print_ok() {
  printf 'CHRONOSYNC_OK %s\n' "$*"
}

trim_line() {
  local t
  t=$1
  while [ -n "$t" ] && [ "${t#[[:space:]]}" != "$t" ]; do
    t=${t#[[:space:]]}
  done
  while [ -n "$t" ] && [ "${t%[[:space:]]}" != "$t" ]; do
    t=${t%[[:space:]]}
  done
  TRIMMED=$t
}

add_upstream() {
  local host
  host=$1
  if [ -z "$host" ]; then
    return 0
  fi
  case " ${ROLE_UPSTREAMS} " in
    *" ${host} "*)
      return 0
      ;;
  esac
  if [ -z "$ROLE_UPSTREAMS" ]; then
    ROLE_UPSTREAMS=$host
  else
    ROLE_UPSTREAMS="${ROLE_UPSTREAMS} ${host}"
  fi
  return 0
}

add_words_upstream() {
  local rest word
  rest=$1
  trim_line "$rest"
  rest=$TRIMMED
  while [ -n "$rest" ]; do
    word=${rest%% *}
    add_upstream "$word"
    case "$rest" in
      *" "*)
        rest=${rest#* }
        trim_line "$rest"
        rest=$TRIMMED
        ;;
      *)
        rest=
        ;;
    esac
  done
  return 0
}

parse_time_config() {
  local kind line word host
  kind=$1
  ROLE_SERVER=0
  ROLE_UPSTREAMS=
  TS_NTP=
  TS_FALLBACK=
  PARSE_TMP="/tmp/chronosync-parse.$$"
  printf '%s\n' "$2" > "$PARSE_TMP" || return 1
  while IFS= read -r line; do
    line=${line%%#*}
    trim_line "$line"
    line=$TRIMMED
    if [ -z "$line" ]; then
      continue
    fi
    case "$kind" in
      timesyncd)
        case "$line" in
          NTP=*)
            TS_NTP=${line#NTP=}
            ;;
          FallbackNTP=*)
            TS_FALLBACK=${line#FallbackNTP=}
            ;;
        esac
        continue
        ;;
    esac
    word=${line%% *}
    case "$line" in
      *" "*)
        host=${line#* }
        host=${host%% *}
        ;;
      *)
        host=
        ;;
    esac
    case "$kind" in
      chrony)
        case "$word" in
          local|allow)
            ROLE_SERVER=1
            ;;
          server|pool|peer)
            add_upstream "$host"
            ;;
        esac
        ;;
      ntp)
        case "$word" in
          server|pool|peer)
            case "$host" in
              127.127.*)
                ROLE_SERVER=1
                ;;
              "")
                ;;
              *)
                add_upstream "$host"
                ;;
            esac
            ;;
          tos)
            case "$line" in
              *orphan*)
                ROLE_SERVER=1
                ;;
            esac
            ;;
        esac
        ;;
    esac
  done < "$PARSE_TMP"
  rm -f "$PARSE_TMP"
  PARSE_TMP=
  if [ "$kind" = "timesyncd" ]; then
    add_words_upstream "$TS_NTP"
    add_words_upstream "$TS_FALLBACK"
  fi
  return 0
}

append_file() {
  local chunk
  if [ ! -f "$1" ] || [ ! -r "$1" ]; then
    return 0
  fi
  chunk=$(cat "$1" 2>/dev/null || true)
  COLLECTED="${COLLECTED}
${chunk}"
  return 0
}

collect_configs() {
  local kind f
  kind=$1
  COLLECTED=
  case "$kind" in
    chrony)
      append_file /etc/chrony/chrony.conf
      append_file /etc/chrony.conf
      for f in /etc/chrony/conf.d/*.conf /etc/chrony/sources.d/*.sources; do
        append_file "$f"
      done
      ;;
    ntp)
      append_file /etc/ntp.conf
      append_file /etc/ntp/ntp.conf
      append_file /etc/ntpsec/ntp.conf
      ;;
    timesyncd)
      append_file /etc/systemd/timesyncd.conf
      for f in /etc/systemd/timesyncd.conf.d/*.conf; do
        append_file "$f"
      done
      ;;
  esac
  return 0
}

engine_service_state() {
  local unit
  ENGINE_SERVICE_STATE=missing
  if ! command -v systemctl >/dev/null 2>&1; then
    ENGINE_SERVICE_STATE=unknown
    return 0
  fi
  for unit in "$@"; do
    if unit_exists "$unit"; then
      if systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
        ENGINE_SERVICE_STATE=active
        return 0
      fi
      ENGINE_SERVICE_STATE=inactive
    fi
  done
  return 0
}

eval_engine() {
  local kind
  kind=$1
  shift
  collect_configs "$kind"
  parse_time_config "$kind" "$COLLECTED" || return 1
  engine_service_state "$@"
  if [ "$kind" = "timesyncd" ] && [ "$ENGINE_SERVICE_STATE" = "active" ] && [ -z "$ROLE_UPSTREAMS" ]; then
    ROLE_DEFAULT_UPSTREAM=1
  else
    ROLE_DEFAULT_UPSTREAM=0
  fi
  return 0
}

consider_role() {
  if [ "$CHOSEN" -eq 1 ]; then
    return 0
  fi
  if [ "$2" != "$6" ]; then
    return 0
  fi
  if [ "$6" != "active" ]; then
    if [ "$3" -eq 0 ] && [ -z "$4" ] && [ "$5" -eq 0 ]; then
      return 0
    fi
  fi
  CHOSEN=1
  ROLE_ENGINE=$1
  ROLE_STATE=$2
  ROLE_SERVER=$3
  ROLE_UPSTREAMS=$4
  ROLE_DEFAULT_UPSTREAM=$5
  return 0
}

query_sync() {
  local sources value
  SYNC_STATE=no
  if [ "$ROLE_STATE" != "active" ]; then
    return 0
  fi
  if [ -z "$ROLE_UPSTREAMS" ] && [ "$ROLE_DEFAULT_UPSTREAM" -eq 0 ]; then
    return 0
  fi
  case "$ROLE_ENGINE" in
    chrony)
      if ! command -v chronyc >/dev/null 2>&1; then
        SYNC_STATE=unknown
        return 0
      fi
      sources=$(LC_ALL=C chronyc -c sources 2>/dev/null || true)
      if [ -z "$sources" ]; then
        SYNC_STATE=unknown
        return 0
      fi
      if chrony_csv_synced "$sources"; then
        SYNC_STATE=yes
      else
        SYNC_STATE=no
      fi
      ;;
    ntp)
      sources=$(ntp_query)
      if [ -z "$sources" ]; then
        SYNC_STATE=unknown
        return 0
      fi
      if printf '%s\n' "$sources" | grep -F '*' >/dev/null 2>&1; then
        SYNC_STATE=yes
      else
        SYNC_STATE=no
      fi
      ;;
    timesyncd)
      value=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
      if [ "$value" = "yes" ]; then
        SYNC_STATE=yes
      elif [ "$value" = "no" ]; then
        SYNC_STATE=no
      else
        SYNC_STATE=unknown
      fi
      ;;
  esac
  return 0
}

probe_device_role() {
  eval_engine chrony chrony chronyd || return 1
  CY_SERVER=$ROLE_SERVER
  CY_UP=$ROLE_UPSTREAMS
  CY_STATE=$ENGINE_SERVICE_STATE
  CY_DEF=$ROLE_DEFAULT_UPSTREAM

  eval_engine ntp ntp ntpd ntpsec || return 1
  NP_SERVER=$ROLE_SERVER
  NP_UP=$ROLE_UPSTREAMS
  NP_STATE=$ENGINE_SERVICE_STATE
  NP_DEF=$ROLE_DEFAULT_UPSTREAM

  eval_engine timesyncd systemd-timesyncd || return 1
  TD_SERVER=$ROLE_SERVER
  TD_UP=$ROLE_UPSTREAMS
  TD_STATE=$ENGINE_SERVICE_STATE
  TD_DEF=$ROLE_DEFAULT_UPSTREAM

  CHOSEN=0
  ROLE_ENGINE=
  ROLE_STATE=missing
  ROLE_SERVER=0
  ROLE_UPSTREAMS=
  ROLE_DEFAULT_UPSTREAM=0
  consider_role chrony "$CY_STATE" "$CY_SERVER" "$CY_UP" "$CY_DEF" active
  consider_role ntp "$NP_STATE" "$NP_SERVER" "$NP_UP" "$NP_DEF" active
  consider_role timesyncd "$TD_STATE" "$TD_SERVER" "$TD_UP" "$TD_DEF" active
  consider_role chrony "$CY_STATE" "$CY_SERVER" "$CY_UP" "$CY_DEF" inactive
  consider_role ntp "$NP_STATE" "$NP_SERVER" "$NP_UP" "$NP_DEF" inactive
  consider_role timesyncd "$TD_STATE" "$TD_SERVER" "$TD_UP" "$TD_DEF" inactive
  consider_role chrony "$CY_STATE" "$CY_SERVER" "$CY_UP" "$CY_DEF" unknown
  consider_role ntp "$NP_STATE" "$NP_SERVER" "$NP_UP" "$NP_DEF" unknown
  consider_role timesyncd "$TD_STATE" "$TD_SERVER" "$TD_UP" "$TD_DEF" unknown

  PROBE_ROLE_ENGINE=$ROLE_ENGINE
  PROBE_ROLE_STATE=$ROLE_STATE
  PROBE_ROLE_SERVER=$ROLE_SERVER
  PROBE_ROLE_UPSTREAMS=$ROLE_UPSTREAMS
  PROBE_ROLE_DEFAULT_UPSTREAM=$ROLE_DEFAULT_UPSTREAM

  if [ "$PROBE_ROLE_SERVER" -eq 1 ] && { [ -n "$PROBE_ROLE_UPSTREAMS" ] || [ "$PROBE_ROLE_DEFAULT_UPSTREAM" -eq 1 ]; }; then
    PROBE_ROLE_NAME=both
  elif [ "$PROBE_ROLE_SERVER" -eq 1 ]; then
    PROBE_ROLE_NAME=server
  elif [ -n "$PROBE_ROLE_UPSTREAMS" ] || [ "$PROBE_ROLE_DEFAULT_UPSTREAM" -eq 1 ]; then
    PROBE_ROLE_NAME=client
  else
    PROBE_ROLE_NAME=none
  fi
  return 0
}

default_allow_cidr() {
  case "$1" in
    10.0.0.0/8|172.16.0.0/12|192.168.0.0/16|169.254.0.0/16)
      return 0
      ;;
  esac
  return 1
}

extract_extra_allow() {
  local kind line word cidr extra
  extra=
  kind=$1
  collect_configs "$kind"
  PARSE_TMP="/tmp/chronosync-allow.$$"
  printf '%s\n' "$COLLECTED" > "$PARSE_TMP" || return 0
  while IFS= read -r line; do
    line=${line%%#*}
    trim_line "$line"
    line=$TRIMMED
    if [ -z "$line" ]; then
      continue
    fi
    word=${line%% *}
    case "$kind" in
      chrony)
        if [ "$word" = "allow" ]; then
          cidr=${line#allow }
          cidr=${cidr%% *}
          if ! default_allow_cidr "$cidr"; then
            extra=$cidr
          fi
        fi
        ;;
    esac
  done < "$PARSE_TMP"
  rm -f "$PARSE_TMP"
  PARSE_TMP=
  printf '%s\n' "$extra"
  return 0
}

backup_servers_csv() {
  if [ "$PROBE_ROLE_DEFAULT_UPSTREAM" -eq 1 ]; then
    printf '%s\n' default
    return 0
  fi
  if [ -n "$PROBE_ROLE_UPSTREAMS" ]; then
    printf '%s\n' "$PROBE_ROLE_UPSTREAMS" | tr ' ' ','
    return 0
  fi
  printf '%s\n' "-"
  return 0
}

write_backup_manifest() {
  local dest role engine servers allow extra content
  dest=$1
  role=$2
  engine=$3
  servers=$4
  allow=$5
  content=$(cat <<EOF
# chronosync-backup v1
role=${role}
engine=${engine}
servers=${servers}
default_upstream=${PROBE_ROLE_DEFAULT_UPSTREAM}
allow=${allow}
service_state=${PROBE_ROLE_STATE}
EOF
)
  write_text "$dest" "$content" || return 1
  return 0
}

maybe_backup_before_change() {
  local dest servers allow extra engine_out
  if [ -z "$BACKUP_DIR" ]; then
    return 0
  fi
  if ! probe_device_role; then
    die "Не удалось определить текущие настройки времени для резервной копии."
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] mkdir -p %s\n' "$BACKUP_DIR"
  else
    mkdir -p "$BACKUP_DIR" || die "Не удалось создать каталог резервной копии: ${BACKUP_DIR}"
  fi
  dest="${BACKUP_DIR}/${PROBE_ROLE_NAME}"
  servers=$(backup_servers_csv)
  allow=
  if [ "$PROBE_ROLE_NAME" = "server" ] || [ "$PROBE_ROLE_NAME" = "both" ]; then
    if [ -f /var/lib/chronosync/state ]; then
      allow=$(read_backup_field /var/lib/chronosync/state allow)
    fi
    if [ -z "$allow" ] && [ "$PROBE_ROLE_ENGINE" = "chrony" ]; then
      allow=$(extract_extra_allow chrony)
    fi
  fi
  if [ -n "$PROBE_ROLE_ENGINE" ]; then
    engine_out=$PROBE_ROLE_ENGINE
  else
    engine_out=none
  fi
  write_backup_manifest "$dest" "$PROBE_ROLE_NAME" "$engine_out" "$servers" "$allow" \
    || die "Не удалось сохранить резервную копию: ${dest}"
  log "Резервная копия настроек (${PROBE_ROLE_NAME}): ${dest}"
  return 0
}

read_backup_field() {
  local file key line val
  file=$1
  key=$2
  val=
  while IFS= read -r line; do
    line=${line%%#*}
    trim_line "$line"
    line=$TRIMMED
    case "$line" in
      "${key}="*)
        val=${line#${key}=}
        ;;
    esac
  done < "$file"
  printf '%s\n' "$val"
}

load_backup_file() {
  local file
  file=$1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    die "Файл резервной копии не найден или недоступен: ${file}"
  fi
  BACKUP_ROLE=$(read_backup_field "$file" role)
  BACKUP_ENGINE=$(read_backup_field "$file" engine)
  BACKUP_SERVERS=$(read_backup_field "$file" servers)
  BACKUP_DEFAULT_UPSTREAM=$(read_backup_field "$file" default_upstream)
  BACKUP_ALLOW=$(read_backup_field "$file" allow)
  case "$BACKUP_ROLE" in
    server|client|both|none)
      ;;
    *)
      die "Некорректная роль в резервной копии: ${BACKUP_ROLE}"
      ;;
  esac
  case "$BACKUP_ENGINE" in
    chrony|ntp|timesyncd|none)
      ;;
    *)
      die "Некорректный движок в резервной копии: ${BACKUP_ENGINE}"
      ;;
  esac
  case "$BACKUP_DEFAULT_UPSTREAM" in
    0|1)
      ;;
    *)
      BACKUP_DEFAULT_UPSTREAM=0
      ;;
  esac
  return 0
}

first_backup_server() {
  local rest word
  rest=$1
  trim_line "$rest"
  rest=$TRIMMED
  if [ "$rest" = "-" ] || [ "$rest" = "default" ] || [ -z "$rest" ]; then
    printf '%s\n' ""
    return 0
  fi
  word=${rest%%,*}
  printf '%s\n' "$word"
  return 0
}

build_chrony_both_conf() {
  local rest word block
  block=$(cat <<EOF
# chronosync-managed
# Сервер времени с синхронизацией от указанных источников.
driftfile /var/lib/chrony/chrony.drift
rtcsync
makestep 1.0 3
local stratum 8
allow 10.0.0.0/8
allow 172.16.0.0/12
allow 192.168.0.0/16
allow 169.254.0.0/16
EOF
)
  if [ -n "$ALLOW" ]; then
    block="${block}
allow ${ALLOW}"
  fi
  rest=$1
  while [ -n "$rest" ]; do
    word=${rest%%,*}
    if [ -n "$word" ]; then
      block="${block}
server ${word} iburst"
    fi
    case "$rest" in
      *,*)
        rest=${rest#*,}
        ;;
      *)
        rest=
        ;;
    esac
  done
  printf '%s\n' "$block"
}

build_chrony_multi_client_conf() {
  local rest word block
  block=$(cat <<EOF
# chronosync-managed
# Клиент берёт время с указанных серверов.
driftfile /var/lib/chrony/chrony.drift
rtcsync
makestep 1.0 -1
EOF
)
  rest=$1
  while [ -n "$rest" ]; do
    word=${rest%%,*}
    if [ -n "$word" ]; then
      block="${block}
server ${word} iburst"
    fi
    case "$rest" in
      *,*)
        rest=${rest#*,}
        ;;
      *)
        rest=
        ;;
    esac
  done
  printf '%s\n' "$block"
}

build_timesyncd_multi_conf() {
  local rest word ntp_line
  ntp_line=
  rest=$1
  while [ -n "$rest" ]; do
    word=${rest%%,*}
    if [ -n "$word" ]; then
      if [ -z "$ntp_line" ]; then
        ntp_line=$word
      else
        ntp_line="${ntp_line} ${word}"
      fi
    fi
    case "$rest" in
      *,*)
        rest=${rest#*,}
        ;;
      *)
        rest=
        ;;
    esac
  done
  cat <<EOF
[Time]
NTP=${ntp_line}
FallbackNTP=
EOF
}

apply_restore_config() {
  local role path content
  role=$1
  case "${ENGINE}:${role}" in
    chrony:server)
      path=$(chrony_conf_path) || return 1
      content=$(build_chrony_server_conf) || return 1
      ;;
    chrony:client)
      path=$(chrony_conf_path) || return 1
      content=$(build_chrony_multi_client_conf "$BACKUP_SERVERS") || return 1
      ;;
    chrony:both)
      path=$(chrony_conf_path) || return 1
      content=$(build_chrony_both_conf "$BACKUP_SERVERS") || return 1
      ;;
    ntp:server)
      path=$(ntp_conf_path) || return 1
      content=$(build_ntp_server_conf) || return 1
      ;;
    ntp:client)
      SERVER=$(first_backup_server "$BACKUP_SERVERS")
      path=$(ntp_conf_path) || return 1
      content=$(build_ntp_client_conf) || return 1
      ;;
    ntp:both)
      SERVER=$(first_backup_server "$BACKUP_SERVERS")
      path=$(ntp_conf_path) || return 1
      content=$(build_ntp_server_conf) || return 1
      ;;
    timesyncd:client)
      path=/etc/systemd/timesyncd.conf.d/chronosync.conf
      content=$(build_timesyncd_multi_conf "$BACKUP_SERVERS") || return 1
      ;;
    *)
      return 1
      ;;
  esac
  write_text "$path" "$content" || return 1
  log "Конфигурация восстановлена: ${path}"
  return 0
}

restore_default_timesyncd() {
  local path
  path=/etc/systemd/timesyncd.conf.d/chronosync.conf
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] rm -f %s\n' "$path"
    printf '[dry-run] systemctl restart systemd-timesyncd\n'
    printf '[dry-run] timedatectl set-ntp true\n'
    return 0
  fi
  rm -f "$path" || true
  enable_timesyncd || return 1
  return 0
}

do_restore() {
  local host ok_line
  log "Режим: восстановление настроек из ${RESTORE_FILE}."
  load_backup_file "$RESTORE_FILE" || die "Не удалось прочитать резервную копию."
  ALLOW=$BACKUP_ALLOW
  case "$BACKUP_ROLE" in
    none)
      disable_all_time_services || return 1
      ENGINE=none
      ACTION=set-time
      write_state || die "Не удалось записать состояние."
      print_ok "mode=restore role=none engine=none"
      return 0
      ;;
    client)
      if [ "$BACKUP_DEFAULT_UPSTREAM" = "1" ] || [ "$BACKUP_SERVERS" = "default" ]; then
        ENGINE=timesyncd
        disable_all_time_services || return 1
        restore_default_timesyncd || die "Не удалось восстановить клиент systemd-timesyncd."
        write_state || die "Не удалось записать состояние."
        print_ok "mode=restore role=client engine=timesyncd server=default"
        return 0
      fi
      host=$(first_backup_server "$BACKUP_SERVERS")
      if [ -z "$host" ]; then
        die "В резервной копии клиента не указаны серверы синхронизации."
      fi
      SERVER=$host
      if [ -n "${CHRONOSYNC_ENGINE:-}" ]; then
        ENGINE=$CHRONOSYNC_ENGINE
      elif [ "$BACKUP_ENGINE" != "none" ]; then
        ENGINE=$BACKUP_ENGINE
      else
        ENGINE=
      fi
      ensure_engine client || die "Не удалось подготовить службу времени."
      disable_all_time_services || return 1
      apply_restore_config client || die "Не удалось восстановить конфигурацию клиента."
      prepare_dirs || die "Не удалось подготовить каталоги службы времени."
      choose_unit || die "Не удалось выбрать службу времени."
      if [ "$ENGINE" = "timesyncd" ]; then
        if ! enable_timesyncd; then
          show_time_debug "$UNIT"
          die "Не удалось запустить systemd-timesyncd."
        fi
      else
        if ! start_unit "$UNIT"; then
          show_time_debug "$UNIT"
          die "Не удалось запустить службу ${UNIT}."
        fi
      fi
      if ! verify_client; then
        show_time_debug "$UNIT"
        die "Служба запущена, но синхронизация с ${SERVER} не подтверждена."
      fi
      sync_rtc || true
      ACTION=sync-from
      write_state || die "Не удалось записать состояние."
      print_ok "mode=restore role=client engine=${ENGINE} server=${BACKUP_SERVERS}"
      return 0
      ;;
    server)
      if [ -n "${CHRONOSYNC_ENGINE:-}" ]; then
        ENGINE=$CHRONOSYNC_ENGINE
      elif [ "$BACKUP_ENGINE" != "none" ]; then
        ENGINE=$BACKUP_ENGINE
      else
        ENGINE=
      fi
      ensure_engine server || die "Не удалось подготовить службу времени."
      disable_all_time_services || return 1
      sync_rtc || true
      apply_restore_config server || die "Не удалось восстановить конфигурацию сервера."
      prepare_dirs || die "Не удалось подготовить каталоги службы времени."
      open_firewall || true
      choose_unit || die "Не удалось выбрать службу времени."
      if ! start_unit "$UNIT"; then
        show_time_debug "$UNIT"
        die "Не удалось запустить службу ${UNIT}."
      fi
      if ! verify_server; then
        show_time_debug "$UNIT"
        die "Служба ${UNIT} запущена, но сервер времени не отвечает."
      fi
      ACTION=time-server
      write_state || die "Не удалось записать состояние."
      print_ok "mode=restore role=server engine=${ENGINE}"
      return 0
      ;;
    both)
      if [ -n "${CHRONOSYNC_ENGINE:-}" ]; then
        ENGINE=$CHRONOSYNC_ENGINE
      elif [ "$BACKUP_ENGINE" != "none" ]; then
        ENGINE=$BACKUP_ENGINE
      else
        ENGINE=
      fi
      ensure_engine server || die "Не удалось подготовить службу времени."
      disable_all_time_services || return 1
      sync_rtc || true
      apply_restore_config both || die "Не удалось восстановить конфигурацию server+client."
      prepare_dirs || die "Не удалось подготовить каталоги службы времени."
      open_firewall || true
      choose_unit || die "Не удалось выбрать службу времени."
      if ! start_unit "$UNIT"; then
        show_time_debug "$UNIT"
        die "Не удалось запустить службу ${UNIT}."
      fi
      if ! verify_server; then
        show_time_debug "$UNIT"
        die "Служба ${UNIT} запущена, но сервер времени не отвечает."
      fi
      ACTION=time-server
      write_state || die "Не удалось записать состояние."
      print_ok "mode=restore role=both engine=${ENGINE} server=${BACKUP_SERVERS}"
      return 0
      ;;
  esac
  die "Не удалось восстановить настройки."
}

do_check() {
  local epoch local_time utc_time server_yes client_yes svc sync_word role_name servers_csv engine_out label
  epoch=$(date +%s)
  local_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
  utc_time=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  log "Время устройства (локальное): ${local_time}"
  log "Время устройства (UTC): ${utc_time}"
  log "Unix-время: ${epoch}"

  probe_device_role || die "Не удалось прочитать конфигурацию служб времени."
  ROLE_ENGINE=$PROBE_ROLE_ENGINE
  ROLE_STATE=$PROBE_ROLE_STATE
  ROLE_SERVER=$PROBE_ROLE_SERVER
  ROLE_UPSTREAMS=$PROBE_ROLE_UPSTREAMS
  ROLE_DEFAULT_UPSTREAM=$PROBE_ROLE_DEFAULT_UPSTREAM

  if [ "$ROLE_SERVER" -eq 1 ]; then
    server_yes=да
  else
    server_yes=нет
  fi
  if [ -n "$ROLE_UPSTREAMS" ] || [ "$ROLE_DEFAULT_UPSTREAM" -eq 1 ]; then
    client_yes=да
  else
    client_yes=нет
  fi
  log "Сервер времени: ${server_yes}"
  log "Клиент сервера времени: ${client_yes}"
  if [ "$client_yes" = "да" ]; then
    if [ "$ROLE_DEFAULT_UPSTREAM" -eq 1 ]; then
      log "Сервер синхронизации: встроенный список systemd-timesyncd"
    else
      log "Сервер синхронизации: ${ROLE_UPSTREAMS}"
    fi
  fi
  case "$ROLE_STATE" in
    active)
      label=$ROLE_ENGINE
      if [ "$ROLE_ENGINE" = "timesyncd" ]; then
        label=systemd-timesyncd
      fi
      svc="${label} (запущена)"
      ;;
    inactive)
      label=$ROLE_ENGINE
      if [ "$ROLE_ENGINE" = "timesyncd" ]; then
        label=systemd-timesyncd
      fi
      svc="${label} (не запущена)"
      ;;
    unknown)
      label=$ROLE_ENGINE
      if [ "$ROLE_ENGINE" = "timesyncd" ]; then
        label=systemd-timesyncd
      fi
      svc="${label} (состояние неизвестно)"
      ;;
    *)
      svc=нет
      ;;
  esac
  log "Служба: ${svc}"
  query_sync
  case "$SYNC_STATE" in
    yes)
      sync_word=да
      ;;
    no)
      sync_word=нет
      ;;
    *)
      sync_word="нет данных"
      ;;
  esac
  log "Синхронизация с внешним сервером: ${sync_word}"

  if [ "$server_yes" = "да" ] && [ "$client_yes" = "да" ]; then
    role_name=both
  elif [ "$server_yes" = "да" ]; then
    role_name=server
  elif [ "$client_yes" = "да" ]; then
    role_name=client
  else
    role_name=none
  fi
  if [ "$ROLE_DEFAULT_UPSTREAM" -eq 1 ]; then
    servers_csv=default
  elif [ -n "$ROLE_UPSTREAMS" ]; then
    servers_csv=$(printf '%s' "$ROLE_UPSTREAMS" | tr ' ' ',')
  else
    servers_csv=-
  fi
  if [ -n "$ROLE_ENGINE" ]; then
    engine_out=$ROLE_ENGINE
  else
    engine_out=none
  fi
  print_ok "mode=check role=${role_name} engine=${engine_out} server=${servers_csv} synced=${SYNC_STATE} time=${epoch}"
}

do_set_time() {
  log "Режим: установка времени с машины установщика."
  maybe_backup_before_change || return 1
  disable_all_time_services || return 1
  set_clock || die "Не удалось установить время."
  ENGINE=none
  write_state || die "Не удалось записать состояние."
  log "Службы синхронизации времени выключены, чтобы они не сбросили выставленное время."
  log "Дальше можно сделать устройство сервером: time-sync.sh time-server"
  log "Или указать ему сервер: time-sync.sh sync-from <ip>"
  print_ok "mode=set-time"
}

do_time_server() {
  log "Режим: сервер времени."
  maybe_backup_before_change || return 1
  ensure_engine server || die "Не удалось подготовить службу времени."
  disable_all_time_services || return 1
  if [ -n "$NORM_SPEC" ]; then
    set_clock || die "Не удалось установить время."
  else
    log "Предупреждение: время не передано. Сервер будет раздавать текущие часы устройства."
    sync_rtc || true
  fi
  apply_config server || die "Не удалось записать конфигурацию сервера времени."
  prepare_dirs || die "Не удалось подготовить каталоги службы времени."
  open_firewall || true
  choose_unit || die "Не удалось выбрать службу времени."
  if ! start_unit "$UNIT"; then
    show_time_debug "$UNIT"
    die "Не удалось запустить службу ${UNIT}."
  fi
  if ! verify_server; then
    show_time_debug "$UNIT"
    die "Служба ${UNIT} запущена, но время не раздаётся."
  fi
  write_state || die "Не удалось записать состояние."
  log "Сервер времени слушает udp/123."
  log "Он раздаёт выставленное время и не подстраивается по интернету."
  log "Повторный запуск time-server с новым временем поправляет часы."
  log "На остальных устройствах выполните sync-from с одним из адресов:"
  print_addresses
  show_brief_status || true
  print_ok "mode=time-server engine=${ENGINE}"
}

do_sync_from() {
  log "Режим: клиент сервера времени ${SERVER}."
  maybe_backup_before_change || return 1
  ensure_engine client || die "Не удалось подготовить службу времени."
  disable_all_time_services || return 1
  apply_config client || die "Не удалось записать конфигурацию клиента."
  prepare_dirs || die "Не удалось подготовить каталоги службы времени."
  choose_unit || die "Не удалось выбрать службу времени."
  if [ "$ENGINE" = "timesyncd" ]; then
    if ! enable_timesyncd; then
      show_time_debug "$UNIT"
      die "Не удалось запустить systemd-timesyncd."
    fi
  else
    if ! start_unit "$UNIT"; then
      show_time_debug "$UNIT"
      die "Не удалось запустить службу ${UNIT}."
    fi
  fi
  if ! verify_client; then
    show_time_debug "$UNIT"
    die "Не удалось синхронизироваться с ${SERVER}. Проверьте, что на нём выполнен time-server, открыт udp/123 и адрес доступен."
  fi
  sync_rtc || true
  write_state || die "Не удалось записать состояние."
  log "Устройство синхронизируется с ${SERVER}."
  show_brief_status || true
  print_ok "mode=sync-from engine=${ENGINE} server=${SERVER}"
}

expect_ok() {
  local name
  name=$1
  shift
  if "$@"; then
    printf 'ok %s\n' "$name"
    return 0
  fi
  printf 'FAIL %s\n' "$name" >&2
  FAILS=$((FAILS + 1))
  return 0
}

expect_fail() {
  local name
  name=$1
  shift
  if "$@"; then
    printf 'FAIL %s (ожидался отказ)\n' "$name" >&2
    FAILS=$((FAILS + 1))
    return 0
  fi
  printf 'ok %s\n' "$name"
  return 0
}

check_eq() {
  if [ "$2" = "$3" ]; then
    printf 'ok %s\n' "$1"
    return 0
  fi
  printf 'FAIL %s: [%s] != [%s]\n' "$1" "$2" "$3" >&2
  FAILS=$((FAILS + 1))
  return 0
}

self_test() {
  local pair conf
  FAILS=0
  ALLOW=
  SERVER=192.168.0.10
  NTP_VARIANT=ntp
  DRY_RUN=1

  expect_ok "epoch" valid_time "1761307080"
  expect_ok "iso" valid_time "2026-10-24 14:18:00"
  expect_ok "isoT" valid_time "2026-10-24T14:18:00Z"
  expect_ok "offset" valid_time "2026-10-24 14:18:00+05:00"
  expect_ok "ru" valid_time "24.10.2026 14:18:00"
  expect_fail "empty time" valid_time ""
  expect_fail "junk time" valid_time "вчера"
  expect_fail "short epoch" valid_time "123"

  expect_ok "ipv4" valid_ipv4 "192.168.0.1"
  expect_fail "octet" valid_ipv4 "192.168.0.256"
  expect_fail "leading zero" valid_ipv4 "192.168.00.1"
  expect_ok "zero octet" valid_ipv4 "10.0.0.0"

  expect_ok "host" valid_host "192.168.0.10"
  expect_ok "name" valid_host "time-server.lan"
  expect_fail "zero ip" valid_host "0.0.0.0"
  expect_fail "bad ip host" valid_host "192.168.0.256"
  expect_fail "flag host" valid_host "-rf"
  expect_fail "underscore" valid_host "bad_host"

  pair=$(cidr_to_net_mask "10.50.1.5/16" || true)
  check_eq "cidr /16" "$pair" "10.50.0.0 255.255.0.0"
  pair=$(cidr_to_net_mask "192.168.5.9/24" || true)
  check_eq "cidr /24" "$pair" "192.168.5.0 255.255.255.0"
  pair=$(cidr_to_net_mask "172.16.5.1/12" || true)
  check_eq "cidr /12" "$pair" "172.16.0.0 255.240.0.0"
  expect_fail "cidr /33" valid_cidr "10.1.2.3/33"
  expect_fail "cidr no mask" valid_cidr "10.1.2.3"

  normalize_time "24.10.2026 14:18:00" || die "normalize ru"
  check_eq "ru normalize" "$NORM_SPEC" "2026-10-24 14:18:00"
  check_eq "ru kind" "$NORM_KIND" "local"
  normalize_time "1761307080" || die "normalize epoch"
  check_eq "epoch spec" "$NORM_SPEC" "@1761307080"
  normalize_time "2026-10-24T14:18:00+05:00" || die "normalize offset"
  check_eq "offset spec" "$NORM_SPEC" "2026-10-24 14:18:00+05:00"
  check_eq "offset kind" "$NORM_KIND" "absolute"

  expect_ok "csv sync" chrony_csv_synced "^,*,192.168.0.10,2"
  expect_fail "csv unsync" chrony_csv_synced "^,?,192.168.0.10,0"
  expect_ok "track" chrony_tracking_ok "7F7F0101,8,1,0,0,0,0,0,0,0,0,0,Normal"
  expect_fail "track leap" chrony_tracking_ok "7F7F0101,0,1,0,0,0,0,0,0,0,0,0,Not synchronised"

  conf=$(build_chrony_server_conf)
  if printf '%s\n' "$conf" | grep -q '^local stratum 8'; then
    printf 'ok %s\n' "chrony local"
  else
    printf 'FAIL chrony local\n' >&2
    FAILS=$((FAILS + 1))
  fi
  if printf '%s\n' "$conf" | grep -q 'pool.ntp.org'; then
    printf 'FAIL chrony pool\n' >&2
    FAILS=$((FAILS + 1))
  else
    printf 'ok %s\n' "chrony no pool"
  fi
  conf=$(build_chrony_client_conf)
  if printf '%s\n' "$conf" | grep -q '^server 192.168.0.10 iburst'; then
    printf 'ok %s\n' "chrony client"
  else
    printf 'FAIL chrony client\n' >&2
    FAILS=$((FAILS + 1))
  fi

  ALLOW=
  SERVER=192.168.0.10
  parse_time_config chrony "$(build_chrony_server_conf)" || die "parse chrony server"
  check_eq "parse server flag" "$ROLE_SERVER" "1"
  check_eq "parse server up" "$ROLE_UPSTREAMS" ""
  parse_time_config chrony "$(build_chrony_client_conf)" || die "parse chrony client"
  check_eq "parse client flag" "$ROLE_SERVER" "0"
  check_eq "parse client up" "$ROLE_UPSTREAMS" "192.168.0.10"
  parse_time_config chrony "# server 1.2.3.4 iburst
local stratum 8"
  check_eq "parse comment flag" "$ROLE_SERVER" "1"
  check_eq "parse comment up" "$ROLE_UPSTREAMS" ""
  parse_time_config chrony "local stratum 8
server 10.0.0.5 iburst"
  check_eq "parse both flag" "$ROLE_SERVER" "1"
  check_eq "parse both up" "$ROLE_UPSTREAMS" "10.0.0.5"
  NTP_VARIANT=ntp
  ALLOW=
  parse_time_config ntp "$(build_ntp_server_conf)" || die "parse ntp server"
  check_eq "parse ntp server flag" "$ROLE_SERVER" "1"
  check_eq "parse ntp server up" "$ROLE_UPSTREAMS" ""
  SERVER=10.1.2.3
  parse_time_config ntp "$(build_ntp_client_conf)" || die "parse ntp client"
  check_eq "parse ntp client flag" "$ROLE_SERVER" "0"
  check_eq "parse ntp client up" "$ROLE_UPSTREAMS" "10.1.2.3"
  parse_time_config timesyncd "[Time]
#NTP=pool.ntp.org
NTP=192.168.1.5
FallbackNTP=10.0.0.5"
  check_eq "parse ts flag" "$ROLE_SERVER" "0"
  check_eq "parse ts up" "$ROLE_UPSTREAMS" "192.168.1.5 10.0.0.5"
  parse_time_config timesyncd "[Time]
NTP=1.1.1.1
NTP=8.8.8.8"
  check_eq "parse ts last" "$ROLE_UPSTREAMS" "8.8.8.8"

  conf=$(build_chrony_multi_client_conf "192.168.0.10,10.0.0.5")
  if printf '%s\n' "$conf" | grep -q '^server 192.168.0.10 iburst' \
      && printf '%s\n' "$conf" | grep -q '^server 10.0.0.5 iburst'; then
    printf 'ok %s\n' "multi client"
  else
    printf 'FAIL multi client\n' >&2
    FAILS=$((FAILS + 1))
  fi

  PARSE_TMP="/tmp/chronosync-selftest-backup.$$"
  printf '%s\n' "# chronosync-backup v1
role=client
engine=chrony
servers=192.168.0.10,10.0.0.5
default_upstream=0
allow=
service_state=active" > "$PARSE_TMP"
  BACKUP_ROLE=$(read_backup_field "$PARSE_TMP" role)
  BACKUP_SERVERS=$(read_backup_field "$PARSE_TMP" servers)
  check_eq "backup role" "$BACKUP_ROLE" "client"
  check_eq "backup servers" "$BACKUP_SERVERS" "192.168.0.10,10.0.0.5"
  rm -f "$PARSE_TMP"

  if [ "$FAILS" -ne 0 ]; then
    printf 'self-test: FAIL %s\n' "$FAILS" >&2
    exit 1
  fi
  printf 'self-test: ok\n'
  exit 0
}

main() {
  if [ $# -eq 0 ]; then
    usage >&2
    exit 1
  fi
  parse_args "$@"
  need_cmd date
  need_cmd awk
  need_cmd grep
  if ! date -d "@0" >/dev/null 2>&1; then
    die "Нужна GNU date из coreutils: команда date -d не работает."
  fi
  validate_args
  if needs_privilege; then
    elevate "$@"
  fi
  case "$ACTION" in
    self-test)
      self_test
      ;;
    set-time)
      do_set_time
      ;;
    time-server)
      do_time_server
      ;;
    sync-from)
      do_sync_from
      ;;
    check)
      do_check
      ;;
    restore)
      do_restore
      ;;
    *)
      die "Неизвестный режим."
      ;;
  esac
}

main "$@"
