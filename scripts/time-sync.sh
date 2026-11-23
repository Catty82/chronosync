#!/bin/sh
# Time synchronization for installer devices.
#
# Platforms: NanoPi H3, NanoPi H5, RK3588, x86_64.
# OS: Ubuntu 18.04, Ubuntu 22.04, Astra Linux 1.8, and other Debian-compatible
# systems (including Astra Linux 4.8) with systemd.
#
# The script runs on the device. Login, password, and IP are SSH parameters
# of the installer and are not passed here.
#
# Pass time as Unix seconds from the machine running the installer
# (Qt: QDateTime::currentSecsSinceEpoch()), immediately before the call.
# The device time zone then does not affect the absolute time.
#
#   time-sync.sh set-time <time> [--backup <directory>]
#   time-sync.sh time-server [time] [--standalone | --keep-upstream | --upstream <host>[,<host>...]]
#                             [--allow a.b.c.d/nn] [--backup <directory>]
#   time-sync.sh sync-from <time-server-ip> [--backup <directory>]
#   time-sync.sh restore <saved-settings-file>
#   time-sync.sh check
#
# Examples:
#   time-sync.sh set-time 1761307080
#   time-sync.sh time-server 1761307080
#   time-sync.sh time-server --keep-upstream --backup time-sync-settings
#   time-sync.sh time-server --upstream 10.0.0.1,pool.ntp.org
#   time-sync.sh sync-from 192.168.0.10
#   time-sync.sh --backup /var/lib/chronosync/backups set-time 1761307080
#   time-sync.sh restore /var/lib/chronosync/backups/client
#
# set-time only sets the clock and turns NTP off.
# After set-time, run the role again: time-server to publish this clock,
# or sync-from to follow a server. Until then the device does not distribute
# time and does not follow a server. sync-from replaces a manual client clock
# with the server clock.
# time-server sets the clock (when a time is given) and serves it on udp/123
# to private networks. By default (--standalone) it does not follow an upstream.
# --keep-upstream keeps the upstream servers already configured on the device.
# --upstream sets one or more upstream NTP servers (comma-separated or repeated).
# sync-from makes the device follow only the given server.
#
# chrony is preferred. If that package is missing from the repository, ntp is used.
# If neither can be installed, a client may stay on systemd-timesyncd.
# A server needs chrony or ntp.
#
# File line endings must be LF only.

set -eu
umask 022

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-/usr/bin:/bin}"
export PATH

DRY_RUN=0
ACTION=
REST=
ALLOW=
ALLOW_FLAG=0
SERVER_SYNC=standalone
SERVER_SYNC_SET=0
UPSTREAM_LIST=
SERVER_UPSTREAM_CSV=
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
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  time-sync.sh set-time <time>
  time-sync.sh time-server [time] [--standalone | --keep-upstream | --upstream <host>]
  time-sync.sh sync-from <time-server-address> [--backup <directory>]
  time-sync.sh restore <saved-settings-file>
  time-sync.sh check
  time-sync.sh --dry-run <mode> [arguments]
  time-sync.sh self-test

Time:
  1761307080                         Unix seconds, preferred
  2026-10-24 14:18:00+05:00          absolute time with a numeric offset
  2026-10-24 14:18:00Z               UTC
  2026-10-24 14:18:00                device local time
  24.10.2026 14:18:00                device local time

Modes:
  set-time      set the clock and turn synchronization off
  time-server   make this device a time server (udp/123)
  sync-from     follow a server configured with time-server
  check         show the time, server role, and upstream server address
  restore       restore settings from a file saved with --backup

time-server sync (pick one; default is --standalone):
  --standalone      local clock only, no upstream (installer default)
  --keep-upstream   keep upstream NTP servers already on the device
  --upstream <host> follow upstream host(s); comma-separated or repeat the flag

Examples:
  time-sync.sh time-server 1761307080
  time-sync.sh time-server --keep-upstream --backup time-sync-settings
  time-sync.sh time-server --upstream 10.0.0.1,pool.ntp.org
  time-sync.sh sync-from 192.168.0.10

set-time only sets the clock and turns synchronization off.
After set-time, run the role again:
  time-sync.sh time-server              publish this clock to clients
  time-sync.sh sync-from <address>      follow a time server again
Until then the device does not distribute time and does not follow a server.
sync-from replaces a manual client clock with the server clock.

Also accepted: set, server, client, check, restore, время, сервер, клиент, проверка, восстановление.

--backup <directory> saves the current settings before set-time, time-server, or sync-from.
The file is named server, client, both, or none (the current role). The new mode is applied after that.

The script does not take the SSH login, password, or address. The installer uses those.
Do not pass a password as an argument.

--allow adds one network to the private ranges the server answers.
CHRONOSYNC_ALLOW=a.b.c.d/nn does the same.
CHRONOSYNC_SERVER_SYNC=standalone|keep|upstream selects the time-server sync mode.
CHRONOSYNC_UPSTREAM=host1,host2 sets upstreams (implies --upstream).
CHRONOSYNC_ENGINE=chrony|ntp|timesyncd forces the service.
EOF
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Command not found: $1"
  fi
}

set_server_sync_mode() {
  local mode
  mode=$1
  if [ "$SERVER_SYNC_SET" -eq 1 ] && [ "$SERVER_SYNC" != "$mode" ]; then
    die "Use only one of --standalone, --keep-upstream, or --upstream for time-server."
  fi
  SERVER_SYNC=$mode
  SERVER_SYNC_SET=1
  return 0
}

add_upstream_host() {
  local host
  host=$1
  trim_line "$host"
  host=$TRIMMED
  if [ -z "$host" ]; then
    return 0
  fi
  case "$host" in
    *:*)
      die "An IPv4 address or DNS name is required for --upstream. IPv6 is not supported: ${host}"
      ;;
  esac
  if ! valid_host "$host"; then
    die "Invalid upstream address: ${host}"
  fi
  case " ${UPSTREAM_LIST} " in
    *" ${host} "*)
      return 0
      ;;
  esac
  if [ -z "$UPSTREAM_LIST" ]; then
    UPSTREAM_LIST=$host
  else
    UPSTREAM_LIST="${UPSTREAM_LIST} ${host}"
  fi
  return 0
}

add_upstream_list_from_csv() {
  local rest word
  rest=$1
  trim_line "$rest"
  rest=$TRIMMED
  while [ -n "$rest" ]; do
    case "$rest" in
      *,*)
        word=${rest%%,*}
        rest=${rest#*,}
        ;;
      *)
        word=$rest
        rest=
        ;;
    esac
    trim_line "$word"
    add_upstream_host "$TRIMMED"
  done
  return 0
}

apply_chronosync_upstream_env() {
  if [ -n "${CHRONOSYNC_UPSTREAM:-}" ]; then
    set_server_sync_mode upstream
    add_upstream_list_from_csv "${CHRONOSYNC_UPSTREAM}"
  fi
  case "${CHRONOSYNC_SERVER_SYNC:-}" in
    "")
      ;;
    standalone|keep|upstream)
      set_server_sync_mode "${CHRONOSYNC_SERVER_SYNC}"
      ;;
    *)
      die "CHRONOSYNC_SERVER_SYNC must be standalone, keep, or upstream."
      ;;
  esac
  return 0
}

parse_time_server_option() {
  local opt arg
  opt=$1
  arg=$2
  case "$opt" in
    --standalone)
      set_server_sync_mode standalone
      return 0
      ;;
    --keep-upstream)
      set_server_sync_mode keep
      return 0
      ;;
    --upstream)
      if [ -z "$arg" ]; then
        die "--upstream requires an NTP server address (IPv4 or DNS name)."
      fi
      set_server_sync_mode upstream
      add_upstream_list_from_csv "$arg"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

parse_time_server_rest() {
  local rest word time_rest consumed
  time_rest=
  rest=$REST
  trim_line "$rest"
  rest=$TRIMMED
  while [ -n "$rest" ]; do
  case "$rest" in
    *" "*)
      word=${rest%% *}
      rest=${rest#* }
      trim_line "$rest"
      rest=$TRIMMED
      ;;
    *)
      word=$rest
      rest=
      ;;
  esac
    consumed=0
    case "$word" in
      --standalone|--keep-upstream)
        parse_time_server_option "$word" ""
        consumed=1
        ;;
      --upstream)
        case "$rest" in
          "")
            die "--upstream requires an NTP server address (IPv4 or DNS name)."
            ;;
          *" "*)
            arg=${rest%% *}
            rest=${rest#* }
            trim_line "$rest"
            rest=$TRIMMED
            ;;
          *)
            arg=$rest
            rest=
            ;;
        esac
        parse_time_server_option --upstream "$arg"
        consumed=1
        ;;
      --)
        if [ -n "$rest" ]; then
          time_rest="${time_rest} ${rest}"
        fi
        rest=
        break
        ;;
      -*)
        die "Unknown option for time-server: ${word}"
        ;;
      *)
        time_rest="${time_rest} ${word}"
        ;;
    esac
  done
  trim_line "$time_rest"
  REST=$TRIMMED
  return 0
}

parse_args() {
  DRY_RUN=0
  ACTION=
  REST=
  ALLOW=
  ALLOW_FLAG=0
  SERVER_SYNC=standalone
  SERVER_SYNC_SET=0
  UPSTREAM_LIST=
  SERVER_UPSTREAM_CSV=
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
          die "--backup requires a directory for the saved settings"
        fi
        BACKUP_DIR=$2
        shift 2
        ;;
      --allow)
        if [ $# -lt 2 ]; then
          die "--allow requires a network as a.b.c.d/nn"
        fi
        ALLOW=$2
        ALLOW_FLAG=1
        shift 2
        ;;
      --standalone|--keep-upstream)
        parse_time_server_option "$1" ""
        shift
        ;;
      --upstream)
        if [ $# -lt 2 ]; then
          die "--upstream requires an NTP server address (IPv4 or DNS name)."
        fi
        parse_time_server_option --upstream "$2"
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
        die "Unknown option: $1"
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
      die "Unknown mode: ${ACTION}. Expected set-time, time-server, sync-from, check, or restore."
      ;;
  esac

  if [ -z "$ALLOW" ] && [ -n "${CHRONOSYNC_ALLOW:-}" ]; then
    ALLOW=${CHRONOSYNC_ALLOW}
  fi
  if [ "$ACTION" != "time-server" ]; then
    if [ "$ALLOW_FLAG" -eq 1 ]; then
      die "--allow is only valid with time-server"
    fi
    ALLOW=
    if [ "$SERVER_SYNC_SET" -eq 1 ]; then
      die "--standalone, --keep-upstream, and --upstream are only valid with time-server"
    fi
    SERVER_SYNC=standalone
    UPSTREAM_LIST=
  fi
  apply_chronosync_upstream_env
  case "$ACTION" in
    set-time|time-server|sync-from)
      ;;
    *)
      if [ -n "$BACKUP_DIR" ]; then
        die "--backup is only valid with set-time, time-server, or sync-from"
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
        die "Specify a time: time-sync.sh set-time <time>"
      fi
      if ! prepare_time "$REST"; then
        die "Invalid time: ${REST}. Expected Unix seconds or a date YYYY-MM-DD HH:MM:SS."
      fi
      ;;
    time-server)
      parse_time_server_rest
      if [ "$SERVER_SYNC" = "upstream" ] && [ -z "$UPSTREAM_LIST" ]; then
        die "No upstream server was specified. Use --upstream <host> or CHRONOSYNC_UPSTREAM."
      fi
      if [ -n "$REST" ]; then
        if ! prepare_time "$REST"; then
          die "Invalid time: ${REST}. Expected Unix seconds or a date YYYY-MM-DD HH:MM:SS."
        fi
      else
        NORM_KIND=
        NORM_SPEC=
      fi
      if [ -n "$ALLOW" ] && ! valid_cidr "$ALLOW"; then
        die "Invalid network for --allow: ${ALLOW} (expected a.b.c.d/nn)"
      fi
      ;;
    sync-from)
      if [ -z "$REST" ]; then
        die "Specify a server address: time-sync.sh sync-from <ip>"
      fi
      case "$REST" in
        *" "*)
          die "The time server address must be a single argument, with no spaces."
          ;;
        *:*)
          die "An IPv4 address or DNS name is required. IPv6 is not supported: ${REST}"
          ;;
      esac
      if ! valid_host "$REST"; then
        die "Invalid time server address: ${REST}"
      fi
      SERVER=$REST
      ;;
    check)
      if [ -n "$REST" ]; then
        die "check does not take extra arguments."
      fi
      ;;
    restore)
      if [ -z "$REST" ]; then
        die "Specify a file: time-sync.sh restore <saved-settings-file>"
      fi
      case "$REST" in
        *" "*)
          die "The backup file path must be a single argument, with no spaces."
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
    die "Root is required."
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    exec sudo -n -E -- "$0" "$@"
  fi
  die "Root is required. Connect over SSH as root, or configure passwordless sudo."
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
  log "Trying to install package ${pkg}..."
  if ! run_timeout 120 apt-get update -y \
      -o Acquire::Retries=1 \
      -o Acquire::http::Timeout=15 \
      -o Acquire::https::Timeout=15 >"$apt_log" 2>&1; then
    log "Warning: apt-get update failed."
    if [ -f "$apt_log" ]; then
      tail -n 20 "$apt_log" || true
    fi
  fi
  if ! run_timeout 180 apt-get install -y \
      -o Dpkg::Options::=--force-confdef \
      -o Dpkg::Options::=--force-confold \
      "$pkg" >"$apt_log" 2>&1; then
    log "Failed to install package ${pkg}."
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
  log "Package ${pkg} installed."
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
        die "CHRONOSYNC_ENGINE must be chrony, ntp, or timesyncd"
        ;;
    esac
    if [ "$ENGINE" = "ntp" ]; then
      detect_ntp_variant
    fi
    if [ "$DRY_RUN" -eq 0 ]; then
      case "$ENGINE" in
        chrony)
          if ! have_chrony; then
            install_pkg chrony || die "Failed to install chrony."
            have_chrony || die "The chrony package is installed, but chronyd is not in PATH."
          fi
          ;;
        ntp)
          if ! have_ntp; then
            install_pkg ntp || install_pkg ntpsec || die "Failed to install ntp."
            have_ntp || die "The ntp package is installed, but ntpd is not in PATH."
            detect_ntp_variant
          fi
          ;;
        timesyncd)
          have_timesyncd || die "systemd-timesyncd is not installed."
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
    log "[dry-run] chrony and ntp were not found; the chrony package would be installed"
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
    log "The chrony and ntp packages are unavailable. Using systemd-timesyncd (client only)."
  else
    die "chrony or ntp was not found, and the package could not be installed. On a device without Internet, install chrony from a local repository and retry."
  fi

  if [ "$purpose" = "server" ] && [ "$ENGINE" = "timesyncd" ]; then
    die "systemd-timesyncd cannot be a time server. Install chrony or ntp."
  fi
  log "Engine: ${ENGINE}"
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
    printf '[dry-run] stop chronyd and ntpd if they are still running\n'
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
    log "Warning: hwclock was not found; the hardware clock was not updated."
    return 0
  fi
  if hwclock --systohc >/dev/null 2>&1; then
    log "Hardware clock (RTC) updated."
  else
    log "Warning: failed to write the RTC. The system clock was set."
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
    log "Device time (local): $(date '+%Y-%m-%d %H:%M:%S %Z')"
    log "Device time (UTC): $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
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
# Local time server. External NTP servers are not used.
# local stratum makes chrony serve time without an external source.
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
# The client follows only the configured server.
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
# Local time server. External NTP servers are not used.
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

build_ntp_both_conf() {
  local rest word host block extra drift
  drift=$(ntp_drift_path)
  block=$(build_ntp_server_conf) || return 1
  extra=
  rest=$1
  trim_line "$rest"
  rest=$TRIMMED
  while [ -n "$rest" ]; do
    case "$rest" in
      *,*)
        word=${rest%%,*}
        rest=${rest#*,}
        ;;
      *)
        word=$rest
        rest=
        ;;
    esac
    trim_line "$word"
    host=$TRIMMED
    if [ -z "$host" ]; then
      continue
    fi
    extra="${extra}
server ${host} iburst
restrict -4 ${host} nomodify notrap noquery"
  done
  if [ -n "$extra" ]; then
    printf '%s\n%s\n' "$block" "$extra"
  else
    printf '%s\n' "$block"
  fi
  return 0
}

build_ntp_client_conf() {
  local drift
  drift=$(ntp_drift_path)
  cat <<EOF
# chronosync-managed
# The client follows only the configured server.
driftfile ${drift}
tinker panic 0
step 0.128 0
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
    printf '[dry-run] write %s\n' "$dest"
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
    chrony:both)
      path=$(chrony_conf_path) || return 1
      content=$(build_chrony_both_conf "$SERVER_UPSTREAM_CSV") || return 1
      ;;
    chrony:client)
      path=$(chrony_conf_path) || return 1
      content=$(build_chrony_client_conf) || return 1
      ;;
    ntp:server)
      path=$(ntp_conf_path) || return 1
      content=$(build_ntp_server_conf) || return 1
      ;;
    ntp:both)
      path=$(ntp_conf_path) || return 1
      content=$(build_ntp_both_conf "$SERVER_UPSTREAM_CSV") || return 1
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
  log "Configuration: ${path}"
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

upstreams_to_csv() {
  if [ -z "$UPSTREAM_LIST" ]; then
    printf '%s\n' ""
    return 0
  fi
  printf '%s\n' "$UPSTREAM_LIST" | tr ' ' ','
  return 0
}

scan_config_upstreams() {
  local kind
  UPSTREAM_LIST=
  for kind in chrony ntp timesyncd; do
    collect_configs "$kind"
    parse_time_config "$kind" "$COLLECTED" || continue
    add_words_upstream "$ROLE_UPSTREAMS"
    if [ "$kind" = timesyncd ]; then
      add_words_upstream "$TS_NTP"
      add_words_upstream "$TS_FALLBACK"
    fi
  done
  return 0
}

resolve_time_server_upstreams() {
  SERVER_UPSTREAM_CSV=
  case "$SERVER_SYNC" in
    standalone)
      UPSTREAM_LIST=
      return 0
      ;;
    keep)
      scan_config_upstreams
      if [ -z "$UPSTREAM_LIST" ]; then
        log "Warning: no upstream NTP servers were found in the current configuration."
        log "Warning: continuing as a standalone time server."
        SERVER_SYNC=standalone
      fi
      ;;
    upstream)
      ;;
    *)
      die "Internal error: unknown server sync mode: ${SERVER_SYNC}"
      ;;
  esac
  if [ -n "$UPSTREAM_LIST" ]; then
    SERVER_UPSTREAM_CSV=$(upstreams_to_csv)
  fi
  return 0
}

time_server_config_role() {
  if [ -n "$SERVER_UPSTREAM_CSV" ]; then
    printf '%s\n' both
  else
    printf '%s\n' server
  fi
  return 0
}

verify_upstream_sync() {
  local i limit
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] check synchronization with upstream time server(s)\n'
    return 0
  fi
  if [ -z "$SERVER_UPSTREAM_CSV" ]; then
    return 0
  fi
  limit=30
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
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

write_state() {
  local content upstream_csv
  upstream_csv=$(upstreams_to_csv)
  content=$(cat <<EOF
mode=${ACTION}
engine=${ENGINE}
server=${SERVER}
allow=${ALLOW}
server_sync=${SERVER_SYNC}
upstreams=${upstream_csv}
EOF
)
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] write /var/lib/chronosync/state\n'
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
    printf '[dry-run] open inbound udp/123 if a firewall blocks it\n'
    return 0
  fi
  if [ -f /etc/ufw/ufw.conf ] && grep -Eq '^ENABLED=yes' /etc/ufw/ufw.conf; then
    if command -v ufw >/dev/null 2>&1; then
      ufw allow 123/udp >/dev/null 2>&1 || true
      ufw allow out 123/udp >/dev/null 2>&1 || true
      handled=1
      log "Firewall: ufw allows udp/123."
    fi
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --add-port=123/udp --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    handled=1
    log "Firewall: firewalld allows udp/123."
  fi
  if [ "$handled" -eq 0 ] && command -v iptables >/dev/null 2>&1; then
    policy=$(iptables -S INPUT 2>/dev/null | head -n 1 || true)
    case "$policy" in
      "-P INPUT DROP"|"-P INPUT REJECT")
        if ! iptables -C INPUT -p udp --dport 123 -j ACCEPT >/dev/null 2>&1; then
          iptables -I INPUT -p udp --dport 123 -j ACCEPT >/dev/null 2>&1 || true
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
          netfilter-persistent save >/dev/null 2>&1 || log "Warning: the udp/123 rule was added but not saved."
        elif [ -d /etc/iptables ] && command -v iptables-save >/dev/null 2>&1; then
          iptables-save > /etc/iptables/rules.v4 2>/dev/null || log "Warning: the udp/123 rule lasts only until reboot."
        else
          log "Warning: the iptables udp/123 rule lasts only until reboot."
        fi
        log "Firewall: iptables allows inbound udp/123."
        ;;
      *)
        log "The inbound filter does not block connections, so a separate udp/123 rule is not needed."
        ;;
    esac
  elif [ "$handled" -eq 0 ]; then
    log "No firewall was found, so no extra udp/123 rule was added."
  fi
  return 0
}

chrony_csv_synced() {
  printf '%s\n' "$1" | awk -F, 'NF >= 2 && ($2 == "*" || $2 == "+" || $1 ~ /\*/) { found = 1 } END { exit (found ? 0 : 1) }'
}

chrony_tracking_ok() {
  # chrony 4.x CSV ends with the leap word "Normal".
  # chrony 3.x (for example 3.5) prints that leap code as 0.
  # Human-readable "chronyc tracking" uses "Leap status : Normal" on both.
  printf '%s\n' "$1" | awk '
    function trim(v) {
      gsub(/^[ \t\r]+|[ \t\r]+$/, "", v)
      return v
    }
    function leap_ok(v) {
      v = trim(v)
      return v == "Normal" || v == "normal" || v == "0"
    }
    function known_leap(v) {
      v = trim(v)
      return v == "Normal" || v == "normal" || v == "0" || v == "1" || v == "2" || v == "3" ||
        v == "Not synchronised" || v == "Insert second" || v == "Delete second"
    }
    BEGIN { found = 0; stratum = -1; leap_good = 0 }
    /^Stratum[[:space:]]*:/ { stratum = $NF + 0 }
    /^Leap status[[:space:]]*:/ { if (leap_ok($NF)) leap_good = 1 }
    index($0, ",") > 0 {
      n = split($0, f, ",")
      if (n >= 2) {
        csv_stratum = f[2] + 0
        leap = f[n]
        if (!leap_ok(leap) && n > 2 && !known_leap(leap)) leap = f[n - 1]
        if (csv_stratum >= 1 && csv_stratum <= 15 && leap_ok(leap)) found = 1
      }
    }
    END {
      if (stratum >= 1 && stratum <= 15 && leap_good) found = 1
      exit (found ? 0 : 1)
    }
  '
}

chrony_local_reference() {
  printf '%s\n' "$1" | grep -E -q '7F7F0101|127\.127\.1\.1'
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
  local tracking csv
  tracking=$(LC_ALL=C chronyc tracking 2>/dev/null || true)
  if chrony_tracking_ok "$tracking"; then
    return 0
  fi
  csv=$(LC_ALL=C chronyc -c tracking 2>/dev/null || true)
  if chrony_tracking_ok "$csv"; then
    return 0
  fi
  return 1
}

ntp_port_open() {
  local dump
  dump=
  if command -v ss >/dev/null 2>&1; then
    dump=$(LC_ALL=C ss -uln 2>/dev/null || true)
    dump="${dump}
$(LC_ALL=C ss -ul 2>/dev/null || true)"
  elif command -v netstat >/dev/null 2>&1; then
    dump=$(LC_ALL=C netstat -uln 2>/dev/null || true)
  else
    return 0
  fi
  if printf '%s\n' "$dump" | grep -E -q ':123([[:space:]]|$)|:ntp([[:space:]]|$)'; then
    return 0
  fi
  return 1
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
  local i tracking
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] check that the time server answers\n'
    return 0
  fi
  i=0
  while [ "$i" -lt 45 ]; do
    case "$ENGINE" in
      chrony)
        if chrony_server_ready; then
          if ntp_port_open; then
            return 0
          fi
          tracking=$(LC_ALL=C chronyc tracking 2>/dev/null || true)
          if chrony_local_reference "$tracking"; then
            log "Warning: udp/123 was not listed by ss or netstat, but chrony is serving its local clock."
            return 0
          fi
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
    printf '[dry-run] check synchronization with %s\n' "$SERVER"
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
    log "Could not determine the device IPv4 addresses."
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
    die "Could not read the current time settings for the backup."
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[dry-run] mkdir -p %s\n' "$BACKUP_DIR"
  else
    mkdir -p "$BACKUP_DIR" || die "Could not create the backup directory: ${BACKUP_DIR}"
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
    || die "Could not save the backup: ${dest}"
  log "Saved time settings (${PROBE_ROLE_NAME}): ${dest}"
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
    die "Backup file not found or not readable: ${file}"
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
      die "Invalid role in the backup: ${BACKUP_ROLE}"
      ;;
  esac
  case "$BACKUP_ENGINE" in
    chrony|ntp|timesyncd|none)
      ;;
    *)
      die "Invalid engine in the backup: ${BACKUP_ENGINE}"
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
# Time server that also synchronizes from the listed sources.
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
# The client follows the listed servers.
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
      path=$(ntp_conf_path) || return 1
      content=$(build_ntp_both_conf "$BACKUP_SERVERS") || return 1
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
  log "Configuration restored: ${path}"
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
  log "Mode: restore settings from ${RESTORE_FILE}."
  load_backup_file "$RESTORE_FILE" || die "Could not read the backup."
  ALLOW=$BACKUP_ALLOW
  case "$BACKUP_ROLE" in
    none)
      disable_all_time_services || return 1
      ENGINE=none
      ACTION=set-time
      write_state || die "Could not write state."
      print_ok "mode=restore role=none engine=none"
      return 0
      ;;
    client)
      if [ "$BACKUP_DEFAULT_UPSTREAM" = "1" ] || [ "$BACKUP_SERVERS" = "default" ]; then
        ENGINE=timesyncd
        disable_all_time_services || return 1
        restore_default_timesyncd || die "Could not restore the systemd-timesyncd client."
        write_state || die "Could not write state."
        print_ok "mode=restore role=client engine=timesyncd server=default"
        return 0
      fi
      host=$(first_backup_server "$BACKUP_SERVERS")
      if [ -z "$host" ]; then
        die "The client backup does not list synchronization servers."
      fi
      SERVER=$host
      if [ -n "${CHRONOSYNC_ENGINE:-}" ]; then
        ENGINE=$CHRONOSYNC_ENGINE
      elif [ "$BACKUP_ENGINE" != "none" ]; then
        ENGINE=$BACKUP_ENGINE
      else
        ENGINE=
      fi
      ensure_engine client || die "Could not prepare the time service."
      disable_all_time_services || return 1
      apply_restore_config client || die "Could not restore the client configuration."
      prepare_dirs || die "Could not prepare time-service directories."
      choose_unit || die "Could not select the time service."
      if [ "$ENGINE" = "timesyncd" ]; then
        if ! enable_timesyncd; then
          show_time_debug "$UNIT"
          die "Could not start systemd-timesyncd."
        fi
      else
        if ! start_unit "$UNIT"; then
          show_time_debug "$UNIT"
          die "Could not start service ${UNIT}."
        fi
      fi
      if ! verify_client; then
        show_time_debug "$UNIT"
        die "The service is running, but synchronization with ${SERVER} was not confirmed."
      fi
      sync_rtc || true
      ACTION=sync-from
      write_state || die "Could not write state."
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
      ensure_engine server || die "Could not prepare the time service."
      disable_all_time_services || return 1
      sync_rtc || true
      apply_restore_config server || die "Could not restore the server configuration."
      prepare_dirs || die "Could not prepare time-service directories."
      open_firewall || true
      choose_unit || die "Could not select the time service."
      if ! start_unit "$UNIT"; then
        show_time_debug "$UNIT"
        die "Could not start service ${UNIT}."
      fi
      if ! verify_server; then
        show_time_debug "$UNIT"
        die "Service ${UNIT} is running, but the time server is not answering."
      fi
      ACTION=time-server
      write_state || die "Could not write state."
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
      ensure_engine server || die "Could not prepare the time service."
      disable_all_time_services || return 1
      sync_rtc || true
      apply_restore_config both || die "Could not restore the server+client configuration."
      prepare_dirs || die "Could not prepare time-service directories."
      open_firewall || true
      choose_unit || die "Could not select the time service."
      if ! start_unit "$UNIT"; then
        show_time_debug "$UNIT"
        die "Could not start service ${UNIT}."
      fi
      if ! verify_server; then
        show_time_debug "$UNIT"
        die "Service ${UNIT} is running, but the time server is not answering."
      fi
      ACTION=time-server
      write_state || die "Could not write state."
      print_ok "mode=restore role=both engine=${ENGINE} server=${BACKUP_SERVERS}"
      return 0
      ;;
  esac
  die "Could not restore the settings."
}

serving_status() {
  SERVING=no
  if [ "$1" -eq 1 ] && [ "$2" = "active" ]; then
    SERVING=yes
  elif [ "$1" -eq 1 ] && [ "$2" = "unknown" ]; then
    SERVING=unknown
  fi
  return 0
}

do_check() {
  local epoch local_time utc_time server_yes client_yes svc sync_word role_name servers_csv engine_out label
  epoch=$(date +%s)
  local_time=$(date '+%Y-%m-%d %H:%M:%S %Z')
  utc_time=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  log "Device time (local): ${local_time}"
  log "Device time (UTC): ${utc_time}"
  log "Unix time: ${epoch}"

  probe_device_role || die "Could not read the time-service configuration."
  ROLE_ENGINE=$PROBE_ROLE_ENGINE
  ROLE_STATE=$PROBE_ROLE_STATE
  ROLE_SERVER=$PROBE_ROLE_SERVER
  ROLE_UPSTREAMS=$PROBE_ROLE_UPSTREAMS
  ROLE_DEFAULT_UPSTREAM=$PROBE_ROLE_DEFAULT_UPSTREAM

  serving_status "$ROLE_SERVER" "$ROLE_STATE"
  if [ "$SERVING" = "yes" ]; then
    server_yes=yes
  elif [ "$SERVING" = "unknown" ]; then
    server_yes=unknown
  else
    server_yes=no
  fi
  if [ -n "$ROLE_UPSTREAMS" ] || [ "$ROLE_DEFAULT_UPSTREAM" -eq 1 ]; then
    client_yes=yes
  else
    client_yes=no
  fi
  label=$ROLE_ENGINE
  if [ "$ROLE_ENGINE" = "timesyncd" ]; then
    label=systemd-timesyncd
  fi
  if [ -z "$label" ]; then
    label="time service"
  fi
  log "Time server: ${server_yes}"
  log "Serving time: ${SERVING}"
  if [ "$ROLE_SERVER" -eq 1 ] && [ "$ROLE_STATE" != "active" ]; then
    if [ "$ROLE_STATE" = "unknown" ]; then
      log "Not distributing time: ${label} is configured as a server, but the service state is unknown."
    else
      log "Not distributing time: ${label} is configured as a server, but it is not running."
    fi
  fi
  log "Time client: ${client_yes}"
  if [ "$client_yes" = "yes" ]; then
    if [ "$ROLE_DEFAULT_UPSTREAM" -eq 1 ]; then
      log "Synchronization server: systemd-timesyncd built-in list"
    else
      log "Synchronization server: ${ROLE_UPSTREAMS}"
    fi
  fi
  case "$ROLE_STATE" in
    active)
      svc="${label} (running)"
      ;;
    inactive)
      svc="${label} (not running)"
      ;;
    unknown)
      svc="${label} (state unknown)"
      ;;
    *)
      svc=none
      ;;
  esac
  log "Service: ${svc}"
  query_sync
  case "$SYNC_STATE" in
    yes)
      sync_word=yes
      ;;
    no)
      sync_word=no
      ;;
    *)
      sync_word="no data"
      ;;
  esac
  log "Synchronized to an external server: ${sync_word}"

  if [ "$ROLE_SERVER" -eq 1 ] && [ "$client_yes" = "yes" ]; then
    role_name=both
  elif [ "$ROLE_SERVER" -eq 1 ]; then
    role_name=server
  elif [ "$client_yes" = "yes" ]; then
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
  print_ok "mode=check role=${role_name} serving=${SERVING} engine=${engine_out} server=${servers_csv} synced=${SYNC_STATE} time=${epoch}"
}

do_set_time() {
  log "Mode: set the clock from the installer machine."
  maybe_backup_before_change || return 1
  disable_all_time_services || return 1
  set_clock || die "Could not set the time."
  ENGINE=none
  write_state || die "Could not write state."
  log "Time synchronization services are off so they do not overwrite the clock."
  log "Clients keep the previous time until this device serves again."
  log "To publish this time, run: time-sync.sh time-server"
  log "Or point this device at a server: time-sync.sh sync-from <ip>"
  print_ok "mode=set-time"
}

do_time_server() {
  local config_role ok_extra
  log "Mode: time server."
  maybe_backup_before_change || return 1
  resolve_time_server_upstreams
  config_role=$(time_server_config_role)
  case "$SERVER_SYNC" in
    standalone)
      log "Upstream sync: off (standalone local clock)."
      ;;
    keep)
      log "Upstream sync: keeping configured server(s): $(printf '%s' "$SERVER_UPSTREAM_CSV" | tr ',' ' ')."
      ;;
    upstream)
      log "Upstream sync: $(printf '%s' "$SERVER_UPSTREAM_CSV" | tr ',' ' ')."
      ;;
  esac
  ensure_engine server || die "Could not prepare the time service."
  disable_all_time_services || return 1
  if [ -n "$NORM_SPEC" ]; then
    set_clock || die "Could not set the time."
  else
    log "Warning: no time was given. The server will serve the current device clock."
    sync_rtc || true
  fi
  apply_config "$config_role" || die "Could not write the time server configuration."
  prepare_dirs || die "Could not prepare time-service directories."
  open_firewall || true
  choose_unit || die "Could not select the time service."
  if ! start_unit "$UNIT"; then
    show_time_debug "$UNIT"
    die "Could not start service ${UNIT}."
  fi
  if ! verify_server; then
    show_time_debug "$UNIT"
    die "Service ${UNIT} is running, but it is not serving time."
  fi
  if [ "$config_role" = "both" ]; then
    if verify_upstream_sync; then
      sync_rtc || true
    else
      log "Warning: the time server is listening, but upstream synchronization is not ready yet."
      log "Warning: clients may still use this server once the upstream link becomes available."
    fi
  fi
  write_state || die "Could not write state."
  log "The time server is listening on udp/123."
  case "$SERVER_SYNC" in
    standalone)
      log "It serves the local clock and does not follow upstream servers."
      log "Run time-server again with a new time to correct the clock."
      ;;
    keep|upstream)
      log "It serves time to the local network and follows the configured upstream server(s)."
      ;;
  esac
  log "On the other devices, run sync-from with one of these addresses:"
  print_addresses
  show_brief_status || true
  ok_extra="sync=${SERVER_SYNC}"
  if [ -n "$SERVER_UPSTREAM_CSV" ]; then
    ok_extra="${ok_extra} upstream=${SERVER_UPSTREAM_CSV}"
  fi
  print_ok "mode=time-server engine=${ENGINE} ${ok_extra}"
}

do_sync_from() {
  log "Mode: client of time server ${SERVER}."
  maybe_backup_before_change || return 1
  ensure_engine client || die "Could not prepare the time service."
  disable_all_time_services || return 1
  apply_config client || die "Could not write the client configuration."
  prepare_dirs || die "Could not prepare time-service directories."
  choose_unit || die "Could not select the time service."
  if [ "$ENGINE" = "timesyncd" ]; then
    if ! enable_timesyncd; then
      show_time_debug "$UNIT"
      die "Could not start systemd-timesyncd."
    fi
  else
    if ! start_unit "$UNIT"; then
      show_time_debug "$UNIT"
      die "Could not start service ${UNIT}."
    fi
  fi
  if ! verify_client; then
    show_time_debug "$UNIT"
    die "Could not synchronize with ${SERVER}. Check that time-server was run there, udp/123 is open, and the address is reachable."
  fi
  sync_rtc || true
  write_state || die "Could not write state."
  log "The device is synchronizing with ${SERVER}."
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
    printf 'FAIL %s (expected failure)\n' "$name" >&2
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
  expect_fail "junk time" valid_time "yesterday"
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
  expect_ok "track leap 0" chrony_tracking_ok "7F7F0101,8,1,0,0,0,0,0,0,0,0,0,0"
  serving_status 1 active
  check_eq "serving active" "$SERVING" "yes"
  serving_status 1 inactive
  check_eq "serving stopped" "$SERVING" "no"
  serving_status 0 active
  check_eq "serving client" "$SERVING" "no"
  serving_status 1 unknown
  check_eq "serving unknown" "$SERVING" "unknown"

  expect_ok "track text" chrony_tracking_ok "$(printf '%s\n' 'Reference ID    : 7F7F0101 ()' 'Stratum         : 8' 'Leap status     : Normal')"
  expect_fail "track leap" chrony_tracking_ok "7F7F0101,0,1,0,0,0,0,0,0,0,0,0,Not synchronised"
  expect_fail "track text unsync" chrony_tracking_ok "$(printf '%s\n' 'Stratum         : 0' 'Leap status     : Not synchronised')"

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

  conf=$(build_chrony_both_conf "10.0.0.5,ntp.example.com")
  if printf '%s\n' "$conf" | grep -q '^local stratum 8' \
      && printf '%s\n' "$conf" | grep -q '^server 10.0.0.5 iburst' \
      && printf '%s\n' "$conf" | grep -q '^server ntp.example.com iburst'; then
    printf 'ok %s\n' "chrony both"
  else
    printf 'FAIL chrony both\n' >&2
    FAILS=$((FAILS + 1))
  fi

  conf=$(build_ntp_both_conf "10.0.0.5,ntp.example.com")
  if printf '%s\n' "$conf" | grep -q '^server 127.127.1.0 minpoll 4 maxpoll 4' \
      && printf '%s\n' "$conf" | grep -q '^server 10.0.0.5 iburst' \
      && printf '%s\n' "$conf" | grep -q '^restrict -4 10.0.0.5 nomodify notrap noquery'; then
    printf 'ok %s\n' "ntp both"
  else
    printf 'FAIL ntp both\n' >&2
    FAILS=$((FAILS + 1))
  fi

  UPSTREAM_LIST=
  SERVER_SYNC=standalone
  SERVER_SYNC_SET=0
  add_upstream_list_from_csv "10.0.0.1,ntp.example.com"
  check_eq "upstream parse" "$UPSTREAM_LIST" "10.0.0.1 ntp.example.com"

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
    die "GNU date from coreutils is required: date -d does not work."
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
      die "Unknown mode."
      ;;
  esac
}

main "$@"
