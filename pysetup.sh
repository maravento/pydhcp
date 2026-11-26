#!/bin/bash
# maravento.com
#
################################################################################
#
# pysetup -- pydhcp installer / updater
# FILE: pysetup.sh
#
# USAGE:
# COMMAND                           ACTION
# sudo bash pysetup.sh --install    Install
# sudo bash pysetup.sh --update     Update code only (preserves user config)
# sudo bash pysetup.sh --uninstall  Uninstall
# sudo bash pysetup.sh --status     Report service, port, config and log
# sudo bash pysetup.sh              Interactive menu
# sudo bash pysetup.sh -h           Show usage
# sudo bash pysetup.sh --help       Show usage
#
# LOG: pysetup.log, in the directory containing this script
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# root check
if [ "$(id -u)" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

# Source directory (where this script lives) -- needed by the logging block
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<USAGE_END
Usage: sudo bash $(basename "$0") [OPTION]

  --install      Install pydhcp. Aborts if already installed
  --update       Update code only, preserving the user configuration
  --uninstall    Remove pydhcp, with two confirmations up front
  --status       Report the service, the port, the configuration and the log
  -h, --help     Show this message

Without arguments it opens the interactive menu.
USAGE_END
}

# Help exits before logging
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

check_requirements() {
    local network_command
    for network_command in ip timeout awk python3; do
        command -v "$network_command" >/dev/null 2>&1 \
            || abort "network command '$network_command' missing -abort"
    done
    case "$1" in
        install)
            # Verify source files exist
            for source_file in core/pydhcpd.py core/pydhcpd.conf conf/forward.conf service/pydhcp-dns.service service/pydhcp-dns.path service/pydhcp-dns.timer service/pydhcpd.service init.d/pydhcpd tools/pydhcpenv.sh core/pydns.py; do
                [ -f "$script_dir/$source_file" ] || { err "[1/2] missing source file: $source_file"; abort "[2/2] run it from the project directory -abort"; }
            done
            if [ -f "$core_dir/pydhcpd.py" ]; then
                abort "pydhcp installed; use --update | --uninstall -abort"
            fi
            check_conflicts "DNS server" bind9 pdns-recursor

            check_conflicts "DHCP server" isc-dhcp-server kea-dhcp4-server udhcpd
            check_port udp 67 "DHCP server"
            warn_overlap "dhcp" dnsmasq
            warn_wpad_port

            check_ipv4_interfaces
            check_internet
            lan_change_requested=false
            choose_lan_interface "${PYDHCP_LAN_IFACE:-}"
            iface_selected="$lan_iface_answer"
            read_lan_ipv4 "$iface_selected" "${PYDHCP_SERVER_IP:-}"
            if [[ -t 0 && -z "${PYDHCP_LAN_IFACE:-}${PYDHCP_SERVER_IP:-}" ]]; then
                select_pydhcp_lan_settings "$iface_selected"
            else
                check_static_lan "$iface_selected" "${lan_cidr_answer%/*}"
            fi
            return 0
            ;;
        update)
            [ -d "$install_dir" ] && [ -f "$install_dir/pydhcp.env" ] \
                || abort "pydhcp is not installed -abort"
            verify_source "$script_dir/tools/pydhcpenv.sh"
            source "$script_dir/tools/pydhcpenv.sh"
            local INTERFACESv4="" SERVER_IP=""
            load_pydhcp_env "$install_dir/pydhcp.env" 'INTERFACESv4 SERVER_IP'
            check_static_lan "$INTERFACESv4" "$SERVER_IP"
            choose_lan_interface "$INTERFACESv4"
            ;;
    esac
    check_ipv4_interfaces
    local package
    for package in "${apt_deps[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
            | grep -q "ok installed"; then
            check_internet
            break
        fi
    done
}

check_wpad_requirements() {
    if [ -n "${PYDHCP_SQUID_PORT:-}" ]; then
        local squid_status=0
        detect_squid_port "$1" >/dev/null || squid_status=$?
        [ "$squid_status" -ne 3 ] || abort "PYDHCP_SQUID_PORT is not a valid port -abort"
    fi
    check_conflicts "web server" nginx lighttpd caddy
    verify_source "$script_dir/conf/wpad.conf"
    check_port tcp "$wpad_port_value" "WPAD server"

}

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock") || {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: cannot open $(basename "$script_lock") -abort" >&2
    exit 1
}
exec 200>"$script_lock"
if ! flock -n 200; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: script $(basename "$0") is already running -abort" >&2
    exit 1
fi

# logging
# The installer keeps its own log, separate from /var/log/pydhcp.log (the
# daemon's operational log) so install, update and remove runs never mix
# with daily operation. Rewritten on each run.
log_file="${script_dir}/pysetup.log"
{ > "$log_file"; } 2>/dev/null || true
pydhcp_log_file="/var/log/pydhcp.log"
log() {
    local msg="$(date '+%Y-%m-%d %H:%M:%S') $1"
    echo "$msg" >> "$log_file" 2>/dev/null || true
    if [[ "$1" == ERROR:* ]]; then echo "$msg" >&2; else echo "$msg"; fi
}

# dependencies
# Project-wide list: every package the deployed components need at runtime,
# not just the ones this installer invokes -- e.g. iputils-ping is used by
# pydhcpd.py when it cannot open a raw ICMP socket. Installed by
# install_deps in --install and --update.
apt_deps=(python3-yaml python3 iproute2 passwd util-linux coreutils grep sed iputils-ping systemd findutils libc-bin zip cron curl logrotate perl ncurses-bin unbound openssl diffutils)

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation - one variable per thing validated; use directly with =~
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_FQDN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'
UH_UINT='^(0|[1-9][0-9]*)$'

# validation - signed integer only; use directly with =~
UH_SINT='^(0|-?[1-9][0-9]*)$'
UH_MAX=9223372036854775807
UH_MIN=-9223372036854775808

install_dir="/etc/pydhcp"
core_dir="${install_dir}/core"
service_file="/etc/systemd/system/pydhcpd.service"
init_file="/etc/init.d/pydhcpd"
daemon_owner="pydhcpd"

wpad_port_value="18800"
wpad_root="/var/www/wpad"
wpad_vhost_dest="/etc/apache2/sites-available/wpad.conf"
wpad_vhost_enabled="/etc/apache2/sites-enabled/wpad.conf"
apache_ports="/etc/apache2/ports.conf"

# ACL layout. Two groups, by who owns the list:
# - acl_mac_dir holds the administrator's own lists (mac-*.txt), edited by hand.
# - acl_dhcp_dir holds pydhcp's own list (blockdhcp.txt), written by
#   pyleases.sh alone.
# Uninstall preserves both ACL locations.
# pydhcp.env itself is written with these already resolved -- it is parsed
# key=value (never sourced), so a "$VAR" inside it would be stored as that
# literal string, not as a path.
acl_base_dir="/etc/acl"
acl_mac_dir="$acl_base_dir"
acl_dhcp_dir="$install_dir/acl"
acl_limited_file="${acl_mac_dir}/mac-limited.txt"
acl_unlimited_file="${acl_mac_dir}/mac-unlimited.txt"
acl_block_file="${acl_dhcp_dir}/blockdhcp.txt"

info() { log "INFO: $*"; }
warn() { log "WARNING: $*"; }
err()  { log "ERROR: $*"; }
abort() { err "$*"; exit 1; }

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

retry_cmd() {
    [ "$#" -ge 2 ] || return 2
    local retry_label="$1" retry_attempt retry_status
    shift
    for retry_attempt in 1 2 3; do
        if "$@"; then
            return 0
        else
            retry_status=$?
        fi
        [ "$retry_attempt" -lt 3 ] || return "$retry_status"
        if declare -F log >/dev/null; then
            log "INFO: $retry_label: retry $((retry_attempt + 1))/3" >&2
        else
            printf '%s INFO: %s: retry %s/3\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$retry_label" \
                "$((retry_attempt + 1))" >&2
        fi
        sleep 5
    done
}

# OWNER AND MODE
# Sets owner and mode on the opened file, never through a symlink: the
# pydhcpd group can write /etc/pydhcp, so a path can be swapped for a link.
# Usage: fix_dhcp_file <path> <owner> <group> <mode> [report] [directory]
fix_dhcp_file() {
    local fix_result
    if ! fix_result=$(python3 -I - "$1" "$2" "$3" "$4" "${6:-file}" <<'PY'
import grp, os, pwd, stat, sys
path, owner, group = sys.argv[1:4]
mode = int(sys.argv[4], 8)
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    sys.exit(1)
try:
    st = os.fstat(fd)
    valid = stat.S_ISDIR(st.st_mode) if sys.argv[5] == "directory" else (
        stat.S_ISREG(st.st_mode) and st.st_nlink == 1)
    if not valid:
        sys.exit(1)
    uid, gid = pwd.getpwnam(owner).pw_uid, grp.getgrnam(group).gr_gid
    current = (st.st_uid, st.st_gid, stat.S_IMODE(st.st_mode))
    changed = current != (uid, gid, mode)
    if changed:
        os.fchown(fd, uid, gid)
        os.fchmod(fd, mode)
finally:
    os.close(fd)
if changed:
    print("changed")
PY
    ); then
        abort "cannot set owner and mode of $(basename "$1") -abort"
    fi
    if [[ "${5:-}" == report && "$fix_result" == changed ]]; then
        info "$(basename "$1") perms fixed -fixed"
    fi
}

repair_install_permissions() {
    local path
    fix_dhcp_file "$install_dir" root "$daemon_owner" 1770 report directory
    fix_dhcp_file "$core_dir" root "$daemon_owner" 1770 report directory
    for path in "$install_dir/tools" /etc/unbound/unbound.conf.d; do
        fix_dhcp_file "$path" root root 755 report directory
    done
    fix_dhcp_file "$install_dir/pydhcp.env" root "$daemon_owner" 640 report
    fix_dhcp_file "$core_dir/pydhcpd.conf" root "$daemon_owner" 640 report
    fix_dhcp_file "$core_dir/pydhcpd.leases" \
        "$daemon_owner" "$daemon_owner" 640 report
    for path in /etc/unbound/unbound.conf.d/forward.conf \
        /etc/default/unbound; do
        fix_dhcp_file "$path" root root 644 report
    done
    if [ -e /var/lib/pydhcp-dns ] || [ -L /var/lib/pydhcp-dns ]; then
        fix_dhcp_file /var/lib/pydhcp-dns root root 700 report directory
        for path in /var/lib/pydhcp-dns/records.json \
            /var/lib/pydhcp-dns/publish.lock; do
            if [ -e "$path" ] || [ -L "$path" ]; then
                fix_dhcp_file "$path" root root 600 report
            fi
        done
    fi
}

# UPDATE CHECKS
update_error() {
    if declare -F err >/dev/null; then
        err "$* -abort"
    else
        log "ERROR: $* -abort"
    fi
    exit 1
}

update_reset() {
    update_cron_file="$1"
    update_files=()
    update_jobs=()
    update_services=()
    update_stopped_services=()
    update_copying=0
    update_cron_paused=0
    update_cron_existed=0
    update_cron_already_paused=0
}

update_file() {
    update_files+=("$1" "$2" "$3" "$4")
    case "$2" in *.sh|*.py|*.pl) update_jobs+=("$2") ;; esac
}

update_target() {
    update_files+=("" "$1" "${2:-644}" "${3:-root:root}")
}

update_preflight() {
    command -v python3 >/dev/null 2>&1 || update_error "python3 is required for update checks"
    local check_message
    if check_message=$(python3 - "${update_files[@]}" <<'UPDATE_PY'
import array, errno, fcntl, os, stat, sys, tempfile
items = [sys.argv[i:i + 4] for i in range(1, len(sys.argv), 4)]
space, probes = {}, set()
def fail(message):
    print(message)
    raise SystemExit(1)
def flags(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            value = array.array('L', [0])
            try:
                fcntl.ioctl(fd, 0x80086601, value, True)
            except OSError as exc:
                if exc.errno not in (errno.ENOTTY, errno.EOPNOTSUPP, errno.EINVAL):
                    raise
            else:
                if value[0] & 0x30:
                    protection = []
                    if value[0] & 0x10:
                        protection.append('immutable')
                    if value[0] & 0x20:
                        protection.append('append-only')
                    fail(os.path.basename(path) + ' is ' + ' and '.join(protection))
        finally:
            os.close(fd)
    except OSError as exc:
        fail(exc.strerror.lower() + ': ' + os.path.basename(path))
for source, target, mode, owner in items:
    if source:
        try:
            st = os.lstat(source)
            if not stat.S_ISREG(st.st_mode):
                fail('source is not a file: ' + os.path.basename(source))
            with open(source, 'rb') as stream:
                stream.read(1)
        except OSError as exc:
            fail('cannot read source: ' + os.path.basename(source))
for source, target, mode, owner in items:
    target = os.path.abspath(target)
    directory = mode.startswith('d')
    try:
        parent = target if directory else os.path.dirname(target)
        if os.path.lexists(target):
            st = os.lstat(target)
            if (directory and not stat.S_ISDIR(st.st_mode)) or (not directory and not stat.S_ISREG(st.st_mode)):
                fail(('dst is not a folder: ' if directory else 'dst is not a file: ') + os.path.basename(target))
            flags(target)
            if not directory:
                fd = os.open(target, os.O_WRONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(fd)
        while not os.path.exists(parent):
            if os.path.lexists(parent):
                fail('folder is a symbolic link: ' + parent)
            parent = os.path.dirname(parent)
        if not os.path.isdir(parent):
            fail('not a folder: ' + parent)
        current = parent
        while current != '/':
            if os.path.islink(current):
                fail('folder is a symbolic link: ' + current)
            flags(current)
            current = os.path.dirname(current)
        fs = os.statvfs(parent)
        if fs.f_flag & os.ST_RDONLY:
            fail('filesystem is read-only: ' + parent)
        if parent not in probes:
            fd, probe = tempfile.mkstemp(prefix='update-check-', dir=parent)
            try:
                os.write(fd, b'update check\n')
                os.fsync(fd)
            finally:
                os.close(fd)
                os.unlink(probe)
            probes.add(parent)
        device = os.stat(parent).st_dev
        required = os.stat(source).st_size if source else 4096
        needed, available, label = space.get(device, (0, fs.f_bavail * fs.f_frsize, parent))
        space[device] = (needed + required + 4096, available, label)
        if fs.f_favail == 0:
            fail('no free inodes for dst: ' + os.path.basename(target))
    except OSError as exc:
        fail('cannot write dst: ' + os.path.basename(target))
for needed, available, label in space.values():
    if available < needed:
        fail('not enough space to update: ' + label)
UPDATE_PY
    ); then
        :
    else
        update_error "$check_message"
    fi
}

update_backup() {
    [ -f "$1" ] && [ -r "$1" ] || update_error "backup script not readable: $(basename "$1")"
    bash "$1" || update_error "backup failed: $(basename "$1")"
}

update_begin() {
    export UPDATE_CRON_OWNER="$$"
    trap 'update_cleanup "$?"' EXIT
    local disabled="${update_cron_file}.update-disabled"
    [ ! -L "${update_cron_file}.lock" ] || update_error "invalid cron lock: $update_cron_file"
    (umask 077; : >> "${update_cron_file}.lock") || update_error "cannot open cron lock: $update_cron_file"
    exec 203>"${update_cron_file}.lock" || update_error "cannot open cron lock: $update_cron_file"
    flock -n 203 || update_error "cron file is being changed: $(basename "$update_cron_file")"
    if [ -e "$disabled" ] || [ -L "$disabled" ]; then
        [ -f "$disabled" ] && [ ! -L "$disabled" ] || update_error "invalid paused cron: $(basename "$disabled")"
        [ ! -e "$update_cron_file" ] || update_error "both active and paused cron exist: $(basename "$update_cron_file")"
        update_cron_already_paused=1
        update_cron_paused=1
    elif [ -e "$update_cron_file" ]; then
        mv -T -- "$update_cron_file" "$disabled" || update_error "cannot pause cron: $update_cron_file"
        update_cron_existed=1
        update_cron_paused=1
    else
        (umask 077; set -C; : > "$disabled") || update_error "cannot pause cron: $update_cron_file"
        update_cron_paused=1
    fi
    exec 203>&-
}

update_pids() {
    python3 - "$1" <<'UPDATE_PIDS'
import os, sys
wanted = os.path.realpath(sys.argv[1])
for entry in os.scandir('/proc'):
    if not entry.name.isdigit() or int(entry.name) == os.getpid():
        continue
    try:
        with open(entry.path + '/cmdline', 'rb') as stream:
            args = [os.fsdecode(value) for value in stream.read().split(b'\0') if value]
        if args and any(os.path.realpath(value) == wanted for value in args if value.startswith('/')):
            print(entry.name)
    except (OSError, ValueError):
        continue
UPDATE_PIDS
}

update_wait() {
    local script="$1" pids attempt
    for attempt in {1..30}; do
        pids=$(update_pids "$script") || update_error "cannot inspect processes: $(basename "$script")"
        [ -z "$pids" ] && return 0
        sleep 1
    done
    update_error "process still running: $(basename "$script")"
}

update_stop_service() {
    local unit="$1" state load_state
    load_state=$(systemctl show -p LoadState --value "$unit") || update_error "cannot inspect service: $unit"
    [ "$load_state" != not-found ] || return 0
    state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect service: $unit"
    case "$state" in
        active|reloading|activating|deactivating)
            [ "$unit" = pydhcp-dns.service ] || update_services+=("$unit") ;;
        inactive|failed) ;;
        *)
            err "[1/2] $unit state: $state"
            update_error "[2/2] unexpected service state"
            ;;
    esac
    update_stopped_services+=("$unit")
    systemctl stop "$unit" || update_error "cannot stop service: $unit"
    state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect stopped: $unit"
    [ "$state" = inactive ] || {
        err "[1/2] $unit state: $state"
        update_error "[2/2] $unit did not stop"
    }
}

update_wait_jobs() {
    local script unit state
    for script in "${update_jobs[@]}"; do
        update_wait "$script"
    done
    for unit in "${update_stopped_services[@]}"; do
        state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect stopped: $unit"
        [ "$state" = inactive ] || update_error "service restarted in update: $unit"
    done
}

update_apply() {
    update_preflight
    update_copying=1
    local i source target mode owner
    for ((i=0; i<${#update_files[@]}; i+=4)); do
        source="${update_files[i]}"
        target="${update_files[i+1]}"
        mode="${update_files[i+2]}"
        owner="${update_files[i+3]}"
        if [[ "$mode" == d* ]]; then
            install -d -m "${mode#d}" -o "${owner%:*}" -g "${owner#*:}" -- "$target" \
                || update_error "cannot prepare directory: $target"
            continue
        fi
        if [ -z "$source" ]; then
            if [ ! -d "$(dirname "$target")" ]; then
                install -d -m 755 -o root -g root -- "$(dirname "$target")" \
                    || update_error "cannot prepare destination parent: $(basename "$target")"
            fi
            continue
        fi
        install -D -m "$mode" -o "${owner%:*}" -g "${owner#*:}" -- "$source" "$target" \
            || update_error "cannot replace file: $(basename "$target")"
        cmp -s -- "$source" "$target" || {
            local compared_file
            compared_file=$(basename "$target")
            if (( ${#compared_file} <= 19 )); then
                update_error "src and dst do not match: $compared_file"
            fi
            err "[1/2] src and dst: $compared_file"
            update_error "[2/2] src and dst do not match"
        }
        info "updated $(basename "$target")"
    done
}

update_resume() {
    local unit state
    for unit in "${update_services[@]}"; do
        systemctl start "$unit" || update_error "cannot start service: $unit"
        state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect started: $unit"
        [ "$state" = active ] || {
            err "[1/2] $unit state: $state"
            update_error "[2/2] $unit did not start"
        }
    done
}

update_finish() {
    update_resume
    rm -f -- "${update_cron_file}.update-disabled" || update_error "cannot finish cron update: $(basename "$update_cron_file")"
    trap - EXIT
    unset UPDATE_CRON_OWNER
}

update_cleanup() {
    local status="$1" unit
    trap - EXIT
    if (( update_copying == 0 )); then
        for unit in "${update_services[@]}"; do
            systemctl start "$unit" || warn "cannot resume $unit -alert"
        done
        if (( update_cron_paused && ! update_cron_already_paused )); then
            if (( update_cron_existed )); then
                mv -T -- "${update_cron_file}.update-disabled" "$update_cron_file" \
                    || warn "cannot restore paused cron -alert"
            else
                rm -f -- "${update_cron_file}.update-disabled" || warn "cannot clear paused cron -alert"
            fi
        fi
    else
        if rm -f -- "$update_cron_file"; then
            warn "update failed; cron remains disabled -alert"
        else
            warn "cannot keep project cron paused -alert"
        fi
        for unit in "${update_services[@]}"; do
            systemctl stop "$unit" || warn "cannot keep $unit stopped -alert"
        done
    fi
    (( status != 0 )) || status=1
    exit "$status"
}

# CRON FILE
# Publish the complete project schedule after preparing it successfully.
cron_d_write() (
    local cron_file="/etc/cron.d/pydhcp"
    local cron_tmp

    [ "$#" -gt 0 ] || return 1
    [ ! -L "${cron_file}.lock" ] || return 1
    (umask 077; : >> "${cron_file}.lock") || return 1
    exec 201>"${cron_file}.lock" || return 1
    flock -x 201 || return 1
    if [ -e "${cron_file}.update-disabled" ] && [ "${UPDATE_CRON_OWNER:-}" != "$$" ]; then
        return 1
    fi
    [ ! -L "$cron_file" ] || return 1
    [ ! -e "$cron_file" ] || [ -f "$cron_file" ] || return 1

    cron_tmp=$(mktemp "${cron_file}.XXXXXX") || return 1
    trap 'rm -f -- "$cron_tmp"' EXIT
    {
        printf '%s\n' '# Managed by the project installer; manual changes are replaced.'
        printf '%s\n' 'SHELL=/bin/bash' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        printf '%s\n' "$@"
    } > "$cron_tmp" || return 1
    chmod 644 "$cron_tmp" && chown root:root "$cron_tmp" || return 1
    mv -fT -- "$cron_tmp" "$cron_file" || return 1
)

# PROJECT SCHEDULE
# Publish all tasks defined by this project
register_project_cron() {
    cron_d_write "@monthly root $install_dir/tools/pybk.sh"
}

# ACL PREPARATION
# Canonical block -- copied byte for byte into every script that creates a
# directory or a list under /etc/acl. Prepare /etc/acl first, then only the
# subdirectory and the lists this script needs. Never recursive.
# Usage: acl_prepare <dir> <dir_mode> <file_mode> [file ...]
acl_prepare() {
    local acl_dir="$1" dir_mode="$2" file_mode="$3" acl_file
    shift 3

    # mkdir without -p fails when the directory already exists, so a success
    # means this run created it and no concurrent run did.
    if mkdir -m "$dir_mode" -- "$acl_dir" 2>/dev/null; then
        if ! chown root:root -- "$acl_dir"; then
            log "ERROR: cannot set owner of $acl_dir -abort"
            exit 1
        fi
        log "WARNING: created ACL directory $acl_dir -alert"
    elif [ -d "$acl_dir" ] && [ ! -L "$acl_dir" ]; then
        acl_fix_perms "$acl_dir" "$dir_mode"
    else
        log "ERROR: $acl_dir is not a regular directory -abort"
        exit 1
    fi

    for acl_file in "$@"; do
        # Checked before the redirection: noclobber only protects regular
        # files, and opening a FIFO for writing blocks until a reader shows up.
        if [ -L "$acl_file" ] || { [ -e "$acl_file" ] && [ ! -f "$acl_file" ]; }; then
            log "ERROR: $(basename "$acl_file") is not a regular file -abort"
            exit 1
        fi
        # noclobber makes the redirection fail when the file already exists,
        # and umask 077 keeps the new file closed until chmod sets its mode.
        if (set -C; umask 077; : > "$acl_file") 2>/dev/null; then
            if ! { chmod "$file_mode" -- "$acl_file" \
                && chown root:root -- "$acl_file"; }; then
                log "ERROR: cannot set perms of $(basename "$acl_file") -abort"
                exit 1
            fi
            log "WARNING: created empty $(basename "$acl_file") -alert"
        elif [ -f "$acl_file" ] && [ ! -L "$acl_file" ]; then
            acl_fix_perms "$acl_file" "$file_mode"
        else
            log "ERROR: $(basename "$acl_file") is not a regular file -abort"
            exit 1
        fi
    done
}

# Repairs mode and owner of an existing ACL object, per Autorreparación
acl_fix_perms() {
    local acl_path="$1" want_mode="$2" cur_mode cur_owner
    cur_mode=$(stat -c '%a' -- "$acl_path" 2>/dev/null) || {
        log "ERROR: cannot stat $acl_path -abort"; exit 1; }
    cur_owner=$(stat -c '%U:%G' -- "$acl_path" 2>/dev/null) || {
        log "ERROR: cannot stat $acl_path -abort"; exit 1; }
    [[ "$cur_mode" == "$want_mode" && "$cur_owner" == "root:root" ]] && return 0
    if ! { chmod "$want_mode" -- "$acl_path" \
        && chown root:root -- "$acl_path"; }; then
        log "ERROR: cannot fix $(basename "$acl_path") perms -abort"
        exit 1
    fi
    log "INFO: $(basename "$acl_path") perms fixed -fixed"
}

# INTERACTIVE PROMPTS
# Each one asks for a value, validates it and repeats until it is correct
# dns primary
is_dns1() {
    local dns1
    read -r -p "Enter DNS1 (e.g. 1.1.1.2): " dns1 \
        || abort "cannot read the primary DNS answer -abort"
    dns_new1="${dns1:-1.1.1.2}"
    [[ "$dns_new1" =~ $UH_IPV4 ]]
}

# dns secondary
is_dns2() {
    local dns2
    read -r -p "Enter DNS2 (e.g. 1.0.0.2): " dns2 \
        || abort "cannot read the secondary DNS answer -abort"
    dns_new2="${dns2:-1.0.0.2}"
    [[ "$dns_new2" =~ $UH_IPV4 ]]
}

# validation - integer is representable as a signed 64-bit value
uh_fits() {
    local value="${1-}" limit
    [[ "$value" =~ $UH_SINT ]] || return 1
    if [[ "${value:0:1}" == - ]]; then
        limit="${UH_MIN#-}"
        value="${value#-}"
    else
        limit="$UH_MAX"
    fi
    (( ${#value} < ${#limit} )) && return 0
    (( ${#value} > ${#limit} )) && return 1
    [[ "$value" > "$limit" ]] && return 1
    return 0
}

ask_number() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp "${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] && uh_fits "$user_answer" && (( user_answer >= 1 && user_answer < 4294967296 )); then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "Invalid value, enter 1 to 4294967295 -retry"
    done
}

confirm() {
    # confirm "prompt" [default y|n] -- returns 0 on yes, 1 on no
    local prompt_text="$1" default_value="${2:-n}" user_answer hint_text
    [[ "$default_value" == "y" ]] && hint_text="[Y/n]" || hint_text="[y/N]"
    read -rp "${prompt_text} ${hint_text}: " user_answer || return 1
    user_answer="${user_answer:-$default_value}"
    [[ "${user_answer,,}" =~ ^y(es)?$ ]]
}

# Verify that a source file is a regular, non-empty, non-world-writable file
# owned by root or the current user, and that its path is inside script_dir.
verify_source() {
    local source_file="$1"
    local real_path
    real_path=$(realpath "$source_file" 2>/dev/null) || abort "$(basename "$source_file"): cannot resolve source path -abort"
    [[ "$real_path" == "$script_dir"/* ]] || abort "$(basename "$source_file"): source is outside the repo -abort"
    [ -f "$real_path" ] || abort "$(basename "$real_path"): not a regular file -abort"
    [ -s "$real_path" ] || abort "$(basename "$real_path"): source file is empty -abort"
    local file_mode file_owner
    file_mode=$(stat -c '%a' "$real_path")
    file_owner=$(stat -c '%u' "$real_path")
    if (( (8#$file_mode & 8#002) != 0 )); then
        abort "$(basename "$real_path"): others can write -abort"
    fi
    if [[ "$file_owner" != "0" && "$file_owner" != "${SUDO_UID:-$(id -u)}" ]]; then
        abort "$(basename "$real_path"): owner UID $file_owner rejected -abort"
    fi
}

# conflicting packages
check_conflicts() {
    local role="$1"; shift
    local found=()
    for dep_pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null | grep -q "ok installed"; then
            found+=("$dep_pkg")
        fi
    done
    if [ "${#found[@]}" -gt 0 ]; then
        for dep_pkg in "${found[@]}"; do
            warn "conflicting $role: $dep_pkg -alert"
        done
        abort "remove them with apt purge -abort"
    fi
}

# overlapping packages
warn_overlap() {
    local feature="$1"; shift
    local dep_pkg
    for dep_pkg in "$@"; do
        if dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null | grep -q "ok installed"; then
            warn "$dep_pkg installed, keep its $feature disabled -alert"
        fi
    done
}

# port in use
check_port() {
    local proto="$1" port="$2" role="$3" port_listeners
    if ! port_listeners=$(python3 - "${proto,,}" "$port" <<'PY'
import subprocess
import sys

try:
    result = subprocess.run(
        ["ss", "-lnH", f"--{sys.argv[1]}", f"sport = :{sys.argv[2]}"],
        capture_output=True,
        text=True,
    )
except OSError:
    sys.exit(1)
if result.returncode != 0 or result.stderr.strip():
    sys.exit(1)
sys.stdout.write(result.stdout)
PY
    ); then
        err "[1/2] cannot check ${proto^^} port $port"
        abort "[2/2] fix the ss query before installing -abort"
    fi
    if [ -n "$port_listeners" ]; then
        err "[1/2] ${proto^^} port $port in use by another $role"
        abort "[2/2] stop that service before installing -abort"
    fi
}

query_port_listeners() {
    local port_error
    port_error=$(ss -lnH "--$1" "sport = :$2" 2>&1 >&3) || return 1
    [[ "$port_error" != *[![:space:]]* ]]
} 3>&1

# WPAD
# Removes the Apache virtualhost, the PAC file and the Listen line of the port
remove_wpad() {
    local port="$1"
    a2dissite -q wpad.conf &>/dev/null || true
    rm -f "$wpad_vhost_enabled" "$wpad_vhost_dest"
    rm -rf "$wpad_root"
    if [ -f "$apache_ports" ]; then
        sed -i -E "/^Listen [^[:space:]]*:${port}\$/d; /^Listen ${port}\$/d" "$apache_ports"
    fi
    if dpkg-query -W -f='${Status}' apache2 2>/dev/null | grep -q "ok installed" \
       && apache2ctl configtest &>/dev/null; then
        systemctl reload apache2 &>/dev/null || true
    fi
}

wpad_failed() {
    if ! remove_wpad "$wpad_port_value"; then
        warn "cannot remove incomplete WPAD deployment -alert"
    fi
    abort "$1 -abort"
}

# Squid detection for the PAC. Three conditions, all required:
#   1. squid is installed (dpkg status "ok installed")
#   2. squid is running (systemd unit active)
#   3. a port is detected and squid listens on it, on all addresses or on the
#      LAN address, so that clients can reach it
# Prints the port and returns 0 when all three hold. Returns 1 when Squid is
# not installed, 2 when it is installed but not running or not reachable on
# the LAN address, and 3 when PYDHCP_SQUID_PORT is not a valid port.
# PYDHCP_SQUID_PORT only replaces the port read from squid.conf (condition 3);
# conditions 1 and 2 are still checked.
# Usage: detect_squid_port <server_ip>
detect_squid_port() {
    local server_ip="$1" pkg installed=0 port="${PYDHCP_SQUID_PORT:-}" addr
    for pkg in squid squid-openssl squid3; do
        if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" == *"ok installed"* ]]; then
            installed=1
        fi
    done
    (( installed )) || return 1
    if [ -n "$port" ]; then
        { [[ "$port" =~ $UH_UINT ]] && uh_fits "$port" \
            && (( port >= 1 && port <= 65535 )); } || return 3
    fi
    systemctl is-active --quiet squid 2>/dev/null || return 2
    if [ -z "$port" ]; then
        # first explicit proxy port; intercept/tproxy ports do not serve a PAC client
        port=$(awk '$1=="http_port" && $0 !~ /intercept|tproxy/ {print $2; exit}' \
            /etc/squid/squid.conf 2>/dev/null) || port=""
        port="${port##*:}"
        port="${port:-3128}"
        { [[ "$port" =~ $UH_UINT ]] && uh_fits "$port" \
            && (( port >= 1 && port <= 65535 )); } || return 2
    fi
    while read -r addr; do
        case "$addr" in
            "*:${port}"|"0.0.0.0:${port}"|"[::]:${port}"|"${server_ip}:${port}")
                printf '%s\n' "$port"
                return 0
                ;;
        esac
    done < <(ss -lntH "sport = :$port" 2>/dev/null | awk '{print $4}')
    return 2
}

# Writes wpad.pac from what is installed: PROXY server_ip:port when Squid is
# listening, a plain DIRECT otherwise. Used by install.
# Usage: write_pac <server_ip> <lan_subnet> <lan_mask>
write_pac() {
    local server_ip="$1" lan_subnet="$2" lan_mask="$3" squid_port rc=0
    local pac_file="${wpad_root}/wpad.pac"
    squid_port=$(detect_squid_port "$server_ip") || rc=$?
    case "$rc" in
        0)
            info "squid on port $squid_port; PAC proxy ${server_ip}:${squid_port}"
            cat > "$pac_file" <<EOF || return 1
function FindProxyForURL(url, host) {
    if (isPlainHostName(host) || shExpMatch(host, "127.*"))
        return "DIRECT";
    if (isInNet(host, "${lan_subnet}", "${lan_mask}"))
        return "DIRECT";
    return "PROXY ${server_ip}:${squid_port}; DIRECT";
}
EOF
            ;;
        1|2|3)
            if [ "$rc" = 3 ]; then
                abort "PYDHCP_SQUID_PORT is not a valid port -abort"
            elif [ "$rc" = 2 ]; then
                warn "squid unreachable, PAC returns DIRECT -alert"
            else
                info "squid not found, PAC returns DIRECT"
            fi
            cat > "$pac_file" <<EOF || return 1
function FindProxyForURL(url, host) {
    return "DIRECT";
}
EOF
            ;;
    esac
    chown www-data:www-data "$pac_file" && chmod 644 "$pac_file"
}

# Deploys the WPAD/PAC server: Apache virtualhost, PAC file and Listen line.
# Sets wpad_enabled_value to true only when the PAC answers.
deploy_wpad() {
    local server_ip="$1" lan_subnet="$2" lan_mask="$3"

    wpad_enabled_value="false"
    local apache_pkg missing_apache_packages=()
    for apache_pkg in apache2 apache2-bin apache2-data apache2-doc apache2-utils; do
        if ! dpkg-query -W -f='${Status}' "$apache_pkg" 2>/dev/null | grep -q "ok installed"; then
            missing_apache_packages+=("$apache_pkg")
        fi
    done
    if (( ${#missing_apache_packages[@]} > 0 )); then
        command -v apt-get >/dev/null 2>&1 || abort "apt-get is required to install Apache -abort"
        check_ipv4_interfaces
        check_internet
        retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_apache_packages[@]}" \
            || abort "cannot install Apache packages -abort"
    fi
    for apache_pkg in apache2 apache2-bin apache2-data apache2-doc apache2-utils; do
        dpkg-query -W -f='${Status}' "$apache_pkg" 2>/dev/null | grep -q "ok installed" \
            || abort "$apache_pkg is not installed -abort"
    done
    # apache2-doc breaks after apache2 installs or upgrades; reinstall it always
    command -v apt >/dev/null 2>&1 || abort "apt is required to reinstall apache2-doc -abort"
    check_ipv4_interfaces
    check_internet
    retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt -qq install -y --reinstall apache2-doc \
        || abort "cannot reinstall apache2-doc -abort"

    a2enmod -q alias mime || abort "cannot enable Apache WPAD modules -abort"
    systemctl enable apache2 || abort "cannot enable apache2 -abort"

    install -d -m 755 -o www-data -g www-data "$wpad_root" \
        || wpad_failed "cannot create $wpad_root"
    write_pac "$server_ip" "$lan_subnet" "$lan_mask" \
        || wpad_failed "cannot write wpad.pac"
    chown -R www-data:www-data "$wpad_root" \
        && chmod 644 "$wpad_root/wpad.pac" \
        || wpad_failed "cannot set wpad.pac permissions"

    install -m 644 -o root -g root "$script_dir/conf/wpad.conf" "$wpad_vhost_dest" \
        || wpad_failed "cannot install wpad.conf"
    sed -i -E "s|^<VirtualHost \*:[0-9]+>|<VirtualHost *:${wpad_port_value}>|" "$wpad_vhost_dest" \
        || wpad_failed "cannot set the wpad.conf port"

    { grep -qxF "Listen ${server_ip}:${wpad_port_value}" "$apache_ports" \
        || grep -qxF "Listen ${wpad_port_value}" "$apache_ports" \
        || echo "Listen ${server_ip}:${wpad_port_value}" >> "$apache_ports"; } \
        || wpad_failed "cannot write Apache ports.conf"

    a2ensite -q wpad.conf &>/dev/null \
        || wpad_failed "cannot enable the wpad.conf site"
    apache2ctl configtest &>/dev/null \
        || wpad_failed "apache2 configtest failed"
    if systemctl is-active --quiet apache2; then
        systemctl reload apache2 || wpad_failed "cannot reload apache2"
    else
        systemctl start apache2 || wpad_failed "cannot start apache2"
    fi

    if ! wpad_http_code=$(curl -fsS --noproxy '*' --max-time 5 -o /dev/null --write-out '%{http_code}' "http://${server_ip}:${wpad_port_value}/wpad.pac") \
       || [ "$wpad_http_code" != 200 ]; then
        wpad_failed "wpad.pac is not served"
    fi

    wpad_enabled_value="true"
    info "PAC at http://${server_ip}:${wpad_port_value}/wpad.pac"
}

# Warns before the WPAD question when its port is not free. Never aborts.
warn_wpad_port() {
    local port_listeners
    if ! port_listeners=$(query_port_listeners tcp "$wpad_port_value"); then
        warn "cannot check TCP port $wpad_port_value for WPAD -alert"
        return 0
    fi
    if [ -n "$port_listeners" ]; then
        warn "TCP port $wpad_port_value is in use; WPAD needs it free -alert"
    fi
}

# check ipv4 interfaces
list_ifaces() {
    ip -br link show 2>/dev/null | awk '$1 != "lo" {sub(/@.*/, "", $1); printf "%s %s\n", $1, ($2 == "UP") ? "UP" : "DOWN"}'
}

list_ipv4_ifaces() {
    local iface state
    while read -r iface state; do
        [ "$state" = UP ] || continue
        if ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
            | awk '$4 != "" {found=1} END {exit !found}'; then
            printf '%s\n' "$iface"
        fi
    done < <(list_ifaces)
}

check_ipv4_interfaces() {
    local max_attempts=24 attempt=1

    while (( attempt <= max_attempts )); do
        if [ -n "$(list_ipv4_ifaces)" ]; then
            return 0
        fi
        if (( attempt == 1 )); then
            log "INFO: waiting for an interface with IPv4..."
        fi
        attempt=$((attempt + 1))
        sleep 5
    done

    log "ERROR: no interface with IPv4 -abort"
    exit 1
}

# check internet
check_internet() {
    local max_attempts=24 attempt=1

    while (( attempt <= max_attempts )); do
        if getent hosts www.google.com >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt == 1 )); then
            log "INFO: waiting for internet..."
        fi
        attempt=$((attempt + 1))
        sleep 5
    done

    log "ERROR: no internet connection -abort"
    exit 1
}

# DEPENDENCIES
# Install the missing packages of apt_deps
install_deps() {
    if ! command -v awk >/dev/null 2>&1; then
        abort "awk is not installed -abort"
    fi
    local dep_pkg missing_pkgs=()
    (( $# > 0 )) || set -- "${apt_deps[@]}"
    for dep_pkg in "$@"; do
        [[ "$(dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null)" == *"ok installed"* ]] || missing_pkgs+=("$dep_pkg")
    done
    (( ${#missing_pkgs[@]} == 0 )) && return 0
    check_ipv4_interfaces
    check_internet
    retry_cmd "install packages" env DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "${missing_pkgs[@]}" \
        || { for dep_pkg in "${missing_pkgs[@]}"; do warn "cannot install $dep_pkg -alert"; done; abort "install them with apt, then re-run -abort"; }
    for dep_pkg in "${missing_pkgs[@]}"; do info "installed $dep_pkg"; done
}

# LAN SELECTION
# Select an existing interface and one of its configured IPv4 addresses
choose_lan_interface() {
    local preset_iface="${1:-}"
    local iface_name iface_choice iface_index iface_state
    local -a lan_candidates=()
    while IFS= read -r iface_name; do
        lan_candidates+=("$iface_name")
    done < <(list_ipv4_ifaces)
    if [ -n "$preset_iface" ]; then
        for iface_name in "${lan_candidates[@]}"; do
            if [ "$preset_iface" = "$iface_name" ]; then
                lan_iface_answer="$preset_iface"
                return 0
            fi
        done
        abort "LAN must be an active interface with IPv4 -abort"
    fi
    (( ${#lan_candidates[@]} > 0 )) || {
        abort "no LAN interface available -abort"
    }
    echo "Available LAN interfaces:"
    for iface_index in "${!lan_candidates[@]}"; do
        iface_name="${lan_candidates[$iface_index]}"
        iface_state=$(ip -br link show "$iface_name" | awk '{print $2}')
        printf ' [%d] %s (%s)\n' "$((iface_index + 1))" "$iface_name" "$iface_state"
        describe_lan_ipv4 "$iface_name"
    done
    while true; do
        read -r -p "Select LAN Interface [1-${#lan_candidates[@]}]: " iface_choice || {
            abort "cannot read LAN interface selection -abort"
        }
        if [[ "$iface_choice" =~ $UH_UINT ]] && [ "${#iface_choice}" -le 5 ] \
           && [ "$iface_choice" -ge 1 ] && [ "$iface_choice" -le "${#lan_candidates[@]}" ]; then
            lan_iface_answer="${lan_candidates[$((iface_choice - 1))]}"
            return 0
        fi
        info "invalid LAN interface selection -retry"
    done
}

# check persistent static IPv4
static_ipv4_query() {
    LC_ALL=C PAGER=cat SYSTEMD_PAGER=cat timeout -k 1s 3s "$@" </dev/null 2>/dev/null
}

keyfile_has_ipv4() {
    local file="$1" uuid="$2" cidr="$3"
    local line section='' saved_uuid='' method='' value key found=1
    [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            \[*\]) section="$line" ;;
            *=*)
                key="${line%%=*}"
                value="${line#*=}"
                case "$section:$key" in
                    '[connection]:uuid') saved_uuid="$value" ;;
                    '[ipv4]:method') method="$value" ;;
                    '[ipv4]:address'*)
                        if [[ "$key" =~ ^address[0-9]+$ && "${value%%,*}" == "$cidr" ]]; then
                            found=0
                        fi
                        ;;
                esac
                ;;
        esac
    done < "$file"
    [[ "$saved_uuid" == "$uuid" && ( "$method" == manual || "$method" == auto ) ]] &&
        return "$found"
    return 1
}

netplan_has_ipv4() (
    local id="$1" cidr="$2" uuid="${3:-}"
    local kind path entries key value runtime netplan_root dir profile_uuid
    local -a root_args=()
    [[ "$id" =~ ^[[:alnum:]_.-]+$ ]] || return 1
    id=${id//./\\.}
    for runtime in /run/netplan/*.yaml; do
        [[ -e "$runtime" || -L "$runtime" ]] || continue
        [[ -n "$uuid" ]] || return 1
        netplan_root=$(mktemp -d /tmp/static-ipv4.XXXXXXXX) || return 1
        trap 'rm -rf -- "$netplan_root"' EXIT
        for dir in /etc /lib /usr/lib; do
            [[ -d "$dir/netplan" ]] || continue
            mkdir -p -- "$netplan_root$dir" || return 1
            ln -s -- "$dir/netplan" "$netplan_root$dir/netplan" || return 1
        done
        root_args=(--root-dir "$netplan_root")
        break
    done
    for kind in ethernets wifis bridges bonds vlans; do
        path="$kind.$id"
        if [[ -n "$uuid" ]]; then
            profile_uuid=$(static_ipv4_query netplan get "${root_args[@]}" "$path.networkmanager.uuid") || continue
            profile_uuid=${profile_uuid//\"/}
            [[ "$profile_uuid" == null || -z "$profile_uuid" || "$profile_uuid" == "$uuid" ]] || continue
        fi
        entries=$(static_ipv4_query netplan get "${root_args[@]}" "$path.addresses") || entries=
        while read -r key value; do
            if [[ "$key" == - && "${value//\"/}" == "$cidr" ]]; then
                return 0
            fi
        done <<< "$entries"

        [[ -n "$uuid" && "$profile_uuid" == "$uuid" ]] || continue
        entries=$(static_ipv4_query netplan get "${root_args[@]}" "$path.networkmanager.passthrough") || continue
        while read -r key value; do
            value="${value//\"/}"
            if [[ "$key" =~ ^ipv4[.]address[0-9]+:$ && "${value%%,*}" == "$cidr" ]]; then
                return 0
            fi
        done <<< "$entries"
    done
    return 1
)

netplan_profile_id() {
    local LC_ALL=C
    local file="$1" uuid="$2" ssid encoded='' char escaped index
    ssid=$(static_ipv4_query nmcli --escape no -g 802-11-wireless.ssid connection show uuid "$uuid") || ssid=
    for (( index=0; index<${#ssid}; index++ )); do
        char=${ssid:index:1}
        if [[ "$char" =~ [a-zA-Z0-9._~-] || "$char" > $'\177' ]]; then
            encoded+="$char"
        else
            printf -v escaped '%%%02X' "'$char"
            encoded+="$escaped"
        fi
    done
    if [[ -n "$encoded" ]]; then
        file=${file%"-$encoded"}
    fi
    printf '%s' "$file"
}

has_persistent_ipv4() {
    local iface="$1" cidr="$2" uuid addresses profiles key file status
    uuid=$(static_ipv4_query nmcli -g GENERAL.CON-UUID device show "$iface") || uuid=
    if [[ -n "$uuid" && "$uuid" != -- ]]; then
        addresses=$(static_ipv4_query nmcli -g ipv4.addresses connection show uuid "$uuid") || return 1
        [[ ",${addresses// /}," == *",$cidr,"* ]] || return 1

        profiles=$(static_ipv4_query nmcli -t --escape no -f UUID,FILENAME connection show) || return 1
        while IFS=: read -r key file; do
            [[ "$key" == "$uuid" ]] || continue
            case "$file" in
                /etc/NetworkManager/system-connections/*)
                    keyfile_has_ipv4 "$file" "$uuid" "$cidr"
                    return "$?"
                    ;;
                /run/NetworkManager/system-connections/netplan-*.nmconnection)
                    file="${file##*/netplan-}"
                    file=$(netplan_profile_id "${file%.nmconnection}" "$uuid")
                    netplan_has_ipv4 "$file" "$cidr" "$uuid"
                    return "$?"
                    ;;
            esac
        done <<< "$profiles"
        return 1
    fi

    status=$(static_ipv4_query networkctl --no-pager status "$iface") || return 1
    while read -r key file; do
        if [[ "$key $file" =~ ^Network\ File:\ /run/systemd/network/10-netplan-(.+)[.]network$ ]]; then
            netplan_has_ipv4 "${BASH_REMATCH[1]}" "$cidr"
            return "$?"
        fi
    done <<< "$status"
    pydhcp_networkd_has_ipv4 "$iface" "$cidr"
}

lan_ipv4_condition() {
    local iface="$1" address="$2" addresses cidr flags
    if addresses=$(static_ipv4_query ip -4 -o addr show dev "$iface" scope global); then
        while read -r _ _ _ cidr flags; do
            [[ "${cidr%/*}" == "$address" && "$cidr" == */* ]] || continue
            if [[ " $flags " == *" dynamic "* ]]; then
                printf 'dynamic'
                return 0
            fi
            if has_persistent_ipv4 "$iface" "$cidr"; then
                printf 'static'
                return 0
            fi
            break
        done <<< "$addresses"
    fi
    printf 'unverified'
}

check_static_lan() {
    case "$(lan_ipv4_condition "$1" "$2")" in
        static) return 0 ;;
        dynamic)
            err "[1/2] LAN $1: $2 uses DHCP"
            err "[2/2] configure a static LAN IPv4 -abort"
            ;;
        *)
            err "[1/2] LAN $1: $2"
            err "[2/2] cannot verify persistent static IPv4 -abort"
            ;;
    esac
    exit 1
}
describe_lan_ipv4() {
    local cidr
    while read -r cidr; do
        printf '      %s (%s)\n' "$cidr" \
            "$(lan_ipv4_condition "$1" "${cidr%/*}")"
    done < <(ip -4 -o addr show dev "$1" scope global | awk '{print $4}')
}

# Prepare the selected LAN before deploying PyDHCP.
pydhcp_ipv4_number() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%u\n' "$(( (a << 24) | (b << 16) | (c << 8) | d ))"
}

pydhcp_ipv4_address() {
    local address="$1"
    printf '%d.%d.%d.%d\n' "$((address >> 24))" "$((address >> 16 & 255))" \
        "$((address >> 8 & 255))" "$((address & 255))"
}

pydhcp_lan_mask() {
    pydhcp_ipv4_address "$(( (0xffffffff << (32 - $1)) & 0xffffffff ))"
}

pydhcp_lan_prefix() {
    local mask="$1" prefix
    [[ "$mask" =~ $UH_IPV4 ]] || return 1
    for ((prefix=0; prefix<=30; prefix++)); do
        if [[ "$(pydhcp_lan_mask "$prefix")" == "$mask" ]]; then
            printf '%s\n' "$prefix"
            return 0
        fi
    done
    return 1
}

pydhcp_lan_host() {
    local address="$1" cidr="$2" ip network mask
    [[ "$address" =~ $UH_IPV4 ]] || return 1
    ip=$(pydhcp_ipv4_number "$address")
    network=$(pydhcp_ipv4_number "${cidr%/*}")
    mask=$(( (0xffffffff << (32 - ${cidr#*/})) & 0xffffffff ))
    (( (ip & mask) == (network & mask) && (ip & ~mask) != 0 &&
       (ip & ~mask) != (0xffffffff ^ mask) ))
}

pydhcp_lan_default_route() {
    local iface="$1" routes
    routes=$(static_ipv4_query ip -4 -o route show default dev "$iface") || return 1
    [[ "$routes" != *$'\n'* ]] || return 1
    lan_gateway=''
    lan_metric=''
    if [[ -n "$routes" ]]; then
        [[ "$routes" =~ [[:space:]]via[[:space:]]([^[:space:]]+) ]] || return 1
        lan_gateway="${BASH_REMATCH[1]}"
        [[ "$lan_gateway" =~ $UH_IPV4 ]] || return 1
        if [[ "$routes" =~ [[:space:]]metric[[:space:]]([0-9]+) ]]; then
            lan_metric="${BASH_REMATCH[1]}"
        else
            lan_metric=0
        fi
    fi
}

select_pydhcp_lan_settings() {
    local iface="$1" condition mask address prefix answer
    local lan_gateway lan_metric
    lan_original_cidr="$lan_cidr_answer"
    condition=$(lan_ipv4_condition "$iface" "${lan_original_cidr%/*}")
    mask=$(pydhcp_lan_mask "${lan_original_cidr#*/}")
    pydhcp_lan_default_route "$iface" || abort "cannot identify the LAN default route -abort"
    case "$condition" in
        static)
            printf 'LAN %s: IPv4 %s, mask %s, gateway %s\n' \
                "$iface" "${lan_original_cidr%/*}" "$mask" "${lan_gateway:-none}"
            if (( ${lan_original_cidr#*/} < 31 )) &&
                pydhcp_lan_host "${lan_original_cidr%/*}" "$lan_original_cidr"; then
                while true; do
                    read -r -p 'Keep the LAN IPv4 settings? [Y/n]: ' answer \
                        || abort "cannot read LAN confirmation -abort"
                    case "$answer" in
                        ''|y|Y) return 0 ;;
                        n|N) break ;;
                        *) info "answer y or n -retry" ;;
                    esac
                done
            fi
            ;;
        dynamic) ;;
        *) abort "cannot verify current LAN IPv4 -abort" ;;
    esac
    while true; do
        read -r -p 'Enter static LAN IPv4: ' address || abort "cannot read LAN IPv4 -abort"
        read -r -p "Enter LAN netmask [$mask]: " answer || abort "cannot read LAN mask -abort"
        prefix=$(pydhcp_lan_prefix "${answer:-$mask}") || prefix=
        if [[ -n "$prefix" ]] && pydhcp_lan_host "$address" "$address/$prefix"; then
            lan_cidr_answer="$address/$prefix"
            lan_change_requested=true
            return 0
        fi
        info "invalid LAN IPv4 or netmask -retry"
    done
}

pydhcp_lan_origin() {
    local iface="$1" status file kind id definition match mac expected_mac
    lan_backend=''
    lan_uuid=$(static_ipv4_query nmcli -g GENERAL.CON-UUID device show "$iface") || lan_uuid=
    if [[ -n "$lan_uuid" && "$lan_uuid" != -- ]]; then
        status=$(static_ipv4_query nmcli -g GENERAL.STATE device show "$iface") || return 1
        [[ "$status" == '100 (connected)' ]] || return 1
        file=$(static_ipv4_query nmcli -t --escape no -f UUID,FILENAME connection show |
            awk -v uuid="$lan_uuid" 'index($0, uuid ":") == 1 {print substr($0, length(uuid) + 2)}') || return 1
        case "$file" in
            /etc/NetworkManager/system-connections/*)
                [[ -f "$file" && ! -L "$file" ]] || return 1
                match=$(static_ipv4_query nmcli -g connection.interface-name connection show uuid "$lan_uuid") || return 1
                [[ "$match" == "$iface" ]] || return 1
                lan_backend=nm
                lan_origin="$file"
                return 0
                ;;
            /run/NetworkManager/system-connections/netplan-*.nmconnection)
                lan_backend=netplan-nm
                id="${file##*/netplan-}"
                id=$(netplan_profile_id "${id%.nmconnection}" "$lan_uuid")
                ;;
            *) return 1 ;;
        esac
    else
        status=$(static_ipv4_query networkctl --no-pager status "$iface") || return 1
        file=$(awk '/^[[:space:]]*Network File: / {print $3}' <<< "$status")
        case "$file" in
            /run/systemd/network/10-netplan-*.network)
                lan_backend=netplan-networkd
                id="${file##*/10-netplan-}"
                id="${id%.network}"
                ;;
            /etc/systemd/network/*.network)
                pydhcp_networkd_file "$iface" "$file" || return 1
                lan_backend=networkd
                lan_origin="$file"
                return 0
                ;;
            *) return 1 ;;
        esac
    fi

    [[ "$id" =~ ^[[:alnum:]_.-]+$ ]] || return 1
    id=${id//./\\.}
    for kind in ethernets wifis bridges bonds vlans; do
        definition=$(static_ipv4_query netplan get "$kind.$id") || return 1
        [[ -n "$definition" && "$definition" != null ]] || continue
        match=$(static_ipv4_query netplan get "$kind.$id.match") || return 1
        if [[ -z "$match" || "$match" == null || "$match" == '{}' ]]; then
            [[ "$id" == "${iface//./\\.}" ]] || return 1
        else
            expected_mac=$(static_ipv4_query netplan get "$kind.$id.match.macaddress") || return 1
            expected_mac=${expected_mac//\"/}
            mac=$(static_ipv4_query ip -br link show "$iface" | awk '{print $3}') || return 1
            match=$(static_ipv4_query netplan get "$kind.$id.match.name") || return 1
            match=${match//\"/}
            [[ "$match" == "$iface" || ( -n "$mac" && "${expected_mac,,}" == "${mac,,}" ) ]] || return 1
        fi
        lan_origin="$kind.$id"
        return 0
    done
    return 1
}

pydhcp_lan_reload() {
    local iface="$1"
    case "$lan_backend" in
        netplan-*) timeout -k 2s 20s netplan generate || return 1 ;;
    esac
    case "$lan_backend" in
        nm|netplan-nm)
            timeout -k 2s 20s nmcli connection reload &&
                timeout -k 2s 20s nmcli --wait 15 connection up uuid "$lan_uuid" ifname "$iface"
            ;;
        networkd|netplan-networkd)
            timeout -k 2s 20s networkctl reload &&
                timeout -k 2s 20s networkctl reconfigure "$iface"
            ;;
    esac
}

pydhcp_lan_stage_netplan() {
    local stage="$1" old="$2" new="$3"
    local dir file raw key value gateway existing_routes address_list= dns_csv
    for file in /run/netplan/*.yaml; do
        [[ ! -e "$file" && ! -L "$file" ]] || return 1
    done
    mkdir -p "$stage/etc/netplan" || return 1
    for file in /etc/netplan/*.yaml; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ -f "$file" && ! -L "$file" ]] || return 1
        cp -p -- "$file" "$stage/etc/netplan/" || return 1
    done
    for dir in /lib /usr/lib; do
        [[ -d "$dir/netplan" ]] || continue
        mkdir -p "$stage$dir/netplan" || return 1
        for file in "$dir/netplan/"*.yaml; do
            [[ -f "$file" ]] || continue
            cp -- "$file" "$stage$dir/netplan/" || return 1
        done
    done
    raw=$(static_ipv4_query netplan get "$lan_origin.networkmanager.passthrough") || return 1
    if [[ "$raw" =~ (^|$'\n')ipv4\.(address[0-9]+|method|gateway|route[0-9]+): ]]; then
        return 1
    fi
    raw=$(static_ipv4_query netplan get "$lan_origin.addresses") || return 1
    if [[ "$raw" != null && -n "$raw" && "$raw" != '[]' ]]; then
        while read -r key value; do
            value=${value//\"/}
            [[ "$key" == - && "$value" =~ ^[0-9a-fA-F.:]+/[0-9]+$ ]] || return 1
            [[ "$value" == "$old" || "$value" == "$new" ]] || address_list+="$value, "
        done <<< "$raw"
        timeout -k 1s 8s netplan set --root-dir "$stage" "$lan_origin.addresses=null" || return 1
    fi
    timeout -k 1s 8s netplan set --root-dir "$stage" "$lan_origin.addresses=[$address_list$new]" &&
        timeout -k 1s 8s netplan set --root-dir "$stage" "$lan_origin.dhcp4=false" || return 1

    if [[ -n "$lan_gateway" ]]; then
        gateway=$(static_ipv4_query netplan get "$lan_origin.gateway4") || return 1
        gateway=${gateway//\"/}
        existing_routes=$(static_ipv4_query netplan get "$lan_origin.routes") || return 1
        if [[ "$gateway" != null && -n "$gateway" ]]; then
            if [[ "$gateway" != "$lan_gateway" ]]; then
                timeout -k 1s 8s netplan set --root-dir "$stage" "$lan_origin.gateway4=$lan_gateway" || return 1
            fi
        elif grep -Eq '(to: (-?default|0\.0\.0\.0/0)|^- to: ("default"|"0\.0\.0\.0/0"))$' <<< "$existing_routes"; then
            [[ "$lan_gateway" == "$lan_previous_gateway" ]] || return 1
        else
            timeout -k 1s 8s netplan set --root-dir "$stage" \
                "$lan_origin.routes=[{to: default, via: $lan_gateway, metric: $lan_metric}]" || return 1
        fi
    fi
    if (( ${#lan_dns[@]} )); then
        printf -v dns_csv '%s, ' "${lan_dns[@]}"
        timeout -k 1s 8s netplan set --root-dir "$stage" \
            "$lan_origin.nameservers.addresses=[${dns_csv%, }]" || return 1
    fi
}

pydhcp_lan_is_active() {
    [[ "$(static_ipv4_query ip -br link show "$1" | awk '{print $2}')" == UP ]] &&
        static_ipv4_query ip -4 -o addr show dev "$1" scope global |
        awk -v address="$2" '$4 == address {found=1} END {exit !found}'
}

apply_pydhcp_lan() (
    local iface="$1" old="$2" new="$3" temp file base current addresses address dns_raw
    local lan_backend lan_origin lan_uuid lan_gateway lan_metric lan_previous_gateway
    local committed=false changed=false mode old_condition
    local -a modified=() lan_dns=() options=()
    pydhcp_lan_is_active "$iface" "$old" || abort "LAN settings changed during setup -abort"
    old_condition=$(lan_ipv4_condition "$iface" "${old%/*}")
    [[ "$old_condition" == static || "$old_condition" == dynamic ]] \
        || abort "cannot verify current LAN IPv4 -abort"
    pydhcp_lan_origin "$iface" || abort "cannot identify a supported LAN configuration -abort"
    pydhcp_lan_default_route "$iface" || abort "cannot identify the LAN default route -abort"
    lan_previous_gateway="$lan_gateway"
    if [[ -n "$lan_gateway" ]]; then
        while [[ "$lan_gateway" == "${new%/*}" ]] || ! pydhcp_lan_host "$lan_gateway" "$new"; do
            read -r -p 'Enter LAN gateway for the new subnet: ' lan_gateway \
                || abort "cannot read LAN gateway -abort"
        done
    fi
    if [[ "$lan_backend" == *nm ]]; then
        dns_raw=$(static_ipv4_query nmcli -g IP4.DNS device show "$iface") || dns_raw=
    else
        dns_raw=$(static_ipv4_query resolvectl dns "$iface") || dns_raw=
        dns_raw=${dns_raw#*:}
    fi
    for address in $dns_raw; do
        if [[ "$address" =~ $UH_IPV4 ]]; then
            lan_dns+=("$address")
        fi
    done
    if [[ -n "$lan_gateway" ]] && (( ${#lan_dns[@]} == 0 )); then
        while true; do
            read -r -p 'Enter LAN DNS IPv4 [keep system resolver]: ' address \
                || abort "cannot read LAN DNS -abort"
            [[ -n "$address" ]] || break
            if [[ "$address" =~ $UH_IPV4 ]]; then
                lan_dns+=("$address")
                break
            fi
            info "invalid DNS IPv4 -retry"
        done
    fi
    current=$(static_ipv4_query ip -4 -o addr show scope global) || abort "cannot read IPv4 addresses -abort"
    if awk -v iface="$iface" -v address="${new%/*}" \
        '{split($4, ip, "/")} $2 != iface && ip[1] == address {found=1} END {exit !found}' <<< "$current"; then
        abort "requested IPv4 is active on another interface -abort"
    fi

    temp=$(mktemp -d /tmp/pydhcp-lan.XXXXXXXX) || abort "cannot stage LAN configuration -abort"
    restore_pydhcp_lan() {
        local status=$? target attempt restore_ok=true
        trap - EXIT
        trap '' HUP INT TERM
        if "$changed" && ! "$committed"; then
            for target in "${modified[@]}"; do
                base="${target##*/}"
                if [[ -f "$temp/before/$base" ]]; then
                    cp -p -- "$temp/before/$base" "$target" || restore_ok=false
                else
                    rm -f -- "$target" || restore_ok=false
                fi
            done
            if pydhcp_lan_reload "$iface" >/dev/null; then
                for (( attempt=1; attempt<=12; attempt++ )); do
                    if pydhcp_lan_is_active "$iface" "$old" &&
                        [[ "$(lan_ipv4_condition "$iface" "${old%/*}")" == "$old_condition" ]]; then
                        break
                    fi
                    sleep 1
                done
                (( attempt <= 12 )) || restore_ok=false
            else
                restore_ok=false
            fi
            if "$restore_ok"; then
                info "previous LAN configuration restored -fixed"
            else
                err "[1/2] cannot restore LAN configuration"
                err "[2/2] backup at $temp -abort"
                exit 1
            fi
        fi
        rm -rf -- "$temp"
        exit "$status"
    }
    trap restore_pydhcp_lan EXIT
    trap 'exit 1' HUP INT TERM
    mkdir "$temp/before" || abort "cannot prepare LAN backup -abort"

    if [[ "$lan_backend" == nm ]]; then
        cp -p -- "$lan_origin" "$temp/before/" || abort "cannot back up LAN profile -abort"
        addresses=$(static_ipv4_query nmcli -g ipv4.addresses connection show uuid "$lan_uuid") \
            || abort "cannot read LAN profile addresses -abort"
        addresses=${addresses// /}
        local -a profile_addresses=()
        IFS=, read -r -a profile_addresses <<< "$addresses"
        addresses="$new"
        for address in "${profile_addresses[@]}"; do
            [[ -z "$address" || "$address" == "$old" || "$address" == "$new" ]] || addresses+=",$address"
        done
        options=(ipv4.method manual ipv4.addresses "$addresses")
        if [[ -n "$lan_gateway" ]]; then
            options+=(ipv4.gateway "$lan_gateway" ipv4.route-metric "$lan_metric")
        fi
        for address in "${lan_dns[@]}"; do options+=(+ipv4.dns "$address"); done
        timeout -k 2s 20s nmcli --offline connection modify "${options[@]}" \
            < "$lan_origin" > "$temp/staged-profile" || abort "cannot stage the LAN profile -abort"
        keyfile_has_ipv4 "$temp/staged-profile" "$lan_uuid" "$new" \
            || abort "cannot validate the staged LAN profile -abort"
        modified+=("$lan_origin")
        changed=true
        install -m 600 -- "$temp/staged-profile" "$lan_origin" \
            || abort "cannot publish the LAN profile -abort"
    elif [[ "$lan_backend" == networkd ]]; then
        cp -p -- "$lan_origin" "$temp/before/" || abort "cannot back up the LAN file -abort"
        pydhcp_stage_networkd "$lan_origin" "$old" "$new" > "$temp/staged-profile" \
            || abort "cannot stage the networkd LAN file -abort"
        modified+=("$lan_origin")
        changed=true
        cp -- "$temp/staged-profile" "$lan_origin" || abort "cannot write the LAN file -abort"
    else
        pydhcp_lan_stage_netplan "$temp/staged" "$old" "$new" \
            || abort "cannot stage the selected LAN definition -abort"
        for file in /etc/netplan/*.yaml "$temp"/staged/etc/netplan/*.yaml; do
            [[ -f "$file" ]] || continue
            base="${file##*/}"
            [[ ! -L "/etc/netplan/$base" ]] || abort "LAN YAML is a symbolic link -abort"
            if [[ -f "$temp/before/$base" ]]; then continue; fi
            if cmp -s "/etc/netplan/$base" "$temp/staged/etc/netplan/$base"; then continue; fi
            if [[ -f "/etc/netplan/$base" ]]; then
                cp -p -- "/etc/netplan/$base" "$temp/before/$base" \
                    || abort "cannot back up Netplan LAN configuration -abort"
            fi
            modified+=("/etc/netplan/$base")
        done
        changed=true
        for file in "${modified[@]}"; do
            base="${file##*/}"
            if [[ -f "$temp/staged/etc/netplan/$base" ]]; then
                install -m 600 -- "$temp/staged/etc/netplan/$base" "$file" \
                    || abort "cannot publish the LAN YAML -abort"
            else
                rm -f -- "$file" || abort "cannot remove obsolete LAN YAML -abort"
            fi
        done
    fi

    pydhcp_lan_reload "$iface" >/dev/null || abort "cannot apply LAN configuration -abort"
    pydhcp_lan_gateway_matches() {
        [[ -z "$lan_gateway" ]] || static_ipv4_query ip -4 route show default dev "$iface" |
            awk -v gateway="$lan_gateway" '$1 == "default" && $2 == "via" && $3 == gateway {found=1} END {exit !found}'
    }
    for (( mode=1; mode<=12; mode++ )); do
        if pydhcp_lan_is_active "$iface" "$new" && pydhcp_lan_gateway_matches &&
            [[ "$(lan_ipv4_condition "$iface" "${new%/*}")" == static ]]; then
            break
        fi
        sleep 1
    done
    (( mode <= 12 )) || abort "configured LAN IPv4 could not be verified -abort"
    check_internet || exit 1
    committed=true
)

pydhcp_networkd_file() {
    local iface="$1" file="$2" path base suffix
    [[ -f "$file" && ! -L "$file" ]] || return 1
    base="${file##*/}"
    for path in /etc/systemd/network /run/systemd/network /usr/lib/systemd/network; do
        for suffix in "$path/$base.d/"*.conf "$path/network.d/"*.conf; do
            [[ ! -e "$suffix" && ! -L "$suffix" ]] || return 1
        done
    done
    awk -v iface="$iface" '
        /^[[:space:]]*\[/ { section=$0; gsub(/[[:space:]]/, "", section) }
        section == "[Match]" && /^[[:space:]]*Name[[:space:]]*=/ {
            name=$0
            sub(/^[^=]*=[[:space:]]*/, "", name)
            sub(/[[:space:]]*$/, "", name)
            if(name == iface) matched++
            else failed=1
        }
        END {exit (failed || matched != 1)}
    ' "$file"
}

pydhcp_networkd_has_ipv4() {
    local iface="$1" cidr="$2" file status
    status=$(static_ipv4_query networkctl --no-pager status "$iface") || return 1
    file=$(awk '/^[[:space:]]*Network File: / {print $3}' <<< "$status")
    [[ "$file" == /etc/systemd/network/*.network ]] || return 1
    pydhcp_networkd_file "$iface" "$file" || return 1
    awk -v cidr="$cidr" '
        /^[[:space:]]*\[/ { section=$0; gsub(/[[:space:]]/, "", section) }
        (section == "[Network]" || section == "[Address]") && /^[[:space:]]*Address[[:space:]]*=/ {
            value=$0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            if (value == "") found=0
            else if (value == cidr) found=1
        }
        END {exit !found}
    ' "$file"
}

pydhcp_stage_networkd() {
    local file="$1" old="$2" new="$3"
    awk -v old="$old" -v new="$new" -v gateway="$lan_gateway" \
        -v previous="$lan_previous_gateway" -v metric="$lan_metric" -v dns="${lan_dns[*]}" '
        function finish_network() {
            print "DHCP=" (dhcp ~ /^(yes|true|on|1|ipv6)$/ ? "ipv6" : "no")
            print "Address=" new
            if (dns != "") print "DNS=" dns
        }
        /^[[:space:]]*\[/ {
            if (section == "[Network]") finish_network()
            section=$0
            gsub(/[[:space:]]/, "", section)
            if (section == "[Network]") networks++
            if (section == "[Route]") routes++
            print
            next
        }
        {
            value=$0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
        }
        section == "[Network]" && /^[[:space:]]*DHCP[[:space:]]*=/ { dhcp=value; next }
        section == "[Network]" && /^[[:space:]]*Address[[:space:]]*=/ && (value == old || value == new) { next }
        section == "[Address]" && /^[[:space:]]*Address[[:space:]]*=/ && value == old && old != new { failed=1 }
        section == "[Network]" && /^[[:space:]]*Gateway[[:space:]]*=/ && value == previous {
            if (gateway != "") print "Gateway=" gateway
            direct_gateway=1
            next
        }
        { print }
        END {
            if (section == "[Network]") finish_network()
            if (failed || networks != 1 || (routes && gateway != previous)) exit 1
            if (gateway != "" && !direct_gateway && !routes) {
                print ""
                print "[Route]"
                print "Destination=0.0.0.0/0"
                print "Gateway=" gateway
                print "Metric=" metric
            }
        }
    ' "$file"
}

read_lan_ipv4() {
    local selected_iface="$1" preset_ip="${2:-}" ipv4_choice ipv4_index candidate_cidr
    local -a lan_addresses=()
    mapfile -t lan_addresses < <(ip -4 -o addr show dev "$selected_iface" scope global | awk '{print $4}')
    (( ${#lan_addresses[@]} > 0 )) || {
        abort "LAN '$selected_iface' has no IPv4 address -abort"
    }
    for candidate_cidr in "${lan_addresses[@]}"; do
        [[ "$candidate_cidr" =~ $UH_CIDR ]] || {
            abort "LAN '$selected_iface' has invalid IPv4/prefix -abort"
        }
    done
    if [ -n "$preset_ip" ]; then
        for candidate_cidr in "${lan_addresses[@]}"; do
            if [ "${candidate_cidr%/*}" = "$preset_ip" ]; then
                lan_cidr_answer="$candidate_cidr"
                return 0
            fi
        done
        abort "requested IPv4 is not configured on LAN -abort"
    fi
    if (( ${#lan_addresses[@]} == 1 )); then
        lan_cidr_answer="${lan_addresses[0]}"
        return 0
    fi
    echo "IPv4 addresses on LAN '$selected_iface':"
    for ipv4_index in "${!lan_addresses[@]}"; do
        printf ' [%d] %s (%s)\n' "$((ipv4_index + 1))" \
            "${lan_addresses[$ipv4_index]}" \
            "$(lan_ipv4_condition "$selected_iface" \
                "${lan_addresses[$ipv4_index]%/*}")"
    done
    while true; do
        read -r -p "Select LAN IPv4 number: " ipv4_choice || {
            abort "cannot read LAN IPv4 selection -abort"
        }
        if [[ "$ipv4_choice" =~ $UH_UINT ]] && [ "${#ipv4_choice}" -le 5 ] \
           && [ "$ipv4_choice" -ge 1 ] && [ "$ipv4_choice" -le "${#lan_addresses[@]}" ]; then
            lan_cidr_answer="${lan_addresses[$((ipv4_choice - 1))]}"
            return 0
        fi
        info "invalid LAN IPv4 selection -retry"
    done
}

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------

do_uninstall() {
    echo "This removes pydhcp completely from $install_dir"
    echo "The service, init.d wrapper, log and Webmin module are also removed"
    echo "Existing WPAD/PAC files and its Listen line are removed regardless of WPAD_ENABLED"
    echo "A backup is taken with tools/pybk.sh before anything is removed"
    echo "/etc/bak is NOT touched"
    echo "Package dependencies are NOT removed"
    confirm "Proceed with uninstall? This cannot be undone." "n" \
        || {
            info "Aborted by user"
            log "INFO: pysetup done"
            exit 0
        }

    echo "Final confirmation required"
    read -rp "Type word YES (uppercase) to remove pydhcp: " confirm_answer
    if [[ "$confirm_answer" != "YES" ]]; then
        info "Aborted by user"
        log "INFO: pysetup done"
        exit 0
    fi

    if [ -x "$install_dir/tools/pybk.sh" ]; then
        if "$install_dir/tools/pybk.sh"; then
            info "backup taken with pybk.sh"
        else
            abort "pybk.sh: backup failed -abort"
        fi
    else
        abort "pybk.sh: missing or not executable -abort"
    fi

    systemctl stop pydhcp-dns.path pydhcp-dns.timer pydhcp-dns.service 2>/dev/null || true
    systemctl disable pydhcp-dns.path pydhcp-dns.timer 2>/dev/null || true
    if [ -f "$install_dir/.unbound-reused" ]; then
        # Reused Unbound: put back its files and its enabled/active state
        local unbound_file unbound_enabled unbound_active
        unbound_enabled=$(sed -n 's/^enabled=//p' "$install_dir/.unbound-reused")
        unbound_active=$(sed -n 's/^active=//p' "$install_dir/.unbound-reused")
        for unbound_file in /etc/unbound/unbound.conf.d/forward.conf /etc/default/unbound; do
            if [ -f "${unbound_file}.bak" ]; then
                mv -f -- "${unbound_file}.bak" "$unbound_file" \
                    || warn "cannot restore $(basename "$unbound_file") -alert"
            else
                rm -f -- "$unbound_file"
            fi
        done
        if [ "$unbound_enabled" = enabled ]; then
            systemctl enable unbound 2>/dev/null || warn "cannot enable reused Unbound -alert"
        else
            systemctl disable unbound 2>/dev/null || true
        fi
        if [ "$unbound_active" = active ]; then
            systemctl restart unbound 2>/dev/null || warn "cannot restart reused Unbound -alert"
        else
            systemctl stop unbound 2>/dev/null || true
        fi
    else
        systemctl stop unbound 2>/dev/null || true
        systemctl disable unbound 2>/dev/null || true
        rm -f /etc/unbound/unbound.conf.d/forward.conf
    fi
    rm -f -- /etc/unbound/unbound.conf.d/forward.conf.pydns.bak
    rm -f /etc/systemd/system/pydhcp-dns.{service,path,timer}
    rm -rf -- /var/lib/pydhcp-dns
    systemctl stop pydhcpd 2>/dev/null || true
    systemctl disable pydhcpd 2>/dev/null || true
    info "stopped and disabled pydhcpd"

    rm -f "$service_file"
    rm -f "$init_file"
    rm -f /etc/logrotate.d/pydhcp && info "Removed /etc/logrotate.d/pydhcp"
    rm -f -- "$pydhcp_log_file" "$pydhcp_log_file".*
    info "removed system files"

    rm -f /etc/cron.d/pydhcp /etc/cron.d/pydhcp.update-disabled

    if [ -x "$install_dir/tools/pywebmin.sh" ] && [ -d /usr/share/webmin/pydhcp ]; then
        "$install_dir/tools/pywebmin.sh" --uninstall && info "removed Webmin module"
    fi

    remove_wpad "$wpad_port_value"

    [[ "$install_dir" == "/etc/pydhcp" ]] || abort "unexpected install dir: $install_dir -abort"

    # Remove the project and keep its ACL directory.
    find "$install_dir" -mindepth 1 -maxdepth 1 ! -path "$acl_dhcp_dir" -exec rm -rf -- {} + \
        && info "removed $install_dir"

    if userdel "$daemon_owner" 2>/dev/null; then
        info "removed user and group $daemon_owner"
    else
        warn "cannot remove user $daemon_owner -alert"
    fi
    groupdel "$daemon_owner" 2>/dev/null || true

    systemctl daemon-reload

    info "pydhcpd has been removed from system"
    rm -f "$pydhcp_log_file"
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

do_update() {
    check_requirements update
    [ -f /etc/unbound/unbound.conf.d/forward.conf ] \
        && grep -q '^SERV_DOMAIN=' "$install_dir/pydhcp.env" \
        || abort "DNS setup missing; reinstall pydhcp -abort"
    install_deps
    update_reset /etc/cron.d/pydhcp
    local file
    for file in core/pydhcpd.py service/pydhcpd.service init.d/pydhcpd tools/pydhcpenv.sh tools/pyleases.sh tools/pybk.sh tools/pywebmin.sh core/pydns.py service/pydhcp-dns.service service/pydhcp-dns.path service/pydhcp-dns.timer; do
        verify_source "$script_dir/$file"
    done
    update_file "$script_dir/core/pydhcpd.py" "$core_dir/pydhcpd.py" 755 root:root
    update_file "$script_dir/core/pydns.py" "$core_dir/pydns.py" 750 root:root
    update_file "$script_dir/service/pydhcpd.service" "$service_file" 644 root:root
    update_file "$script_dir/init.d/pydhcpd" "$init_file" 750 root:root
    for file in pydhcpenv.sh pyleases.sh pybk.sh pywebmin.sh; do
        local mode=750
        [ "$file" != pydhcpenv.sh ] || mode=644
        update_file "$script_dir/tools/$file" "$install_dir/tools/$file" "$mode" root:root
    done
    for file in pydhcp-dns.service pydhcp-dns.path pydhcp-dns.timer; do
        update_file "$script_dir/service/$file" "/etc/systemd/system/$file" 644 root:root
    done
    update_target /etc/logrotate.d/pydhcp
    update_target "$pydhcp_log_file" 640
    update_target "$update_cron_file"
    update_target "${update_cron_file}.lock" 600
    update_preflight
    update_backup "$script_dir/tools/pybk.sh"
    # Restore missing Unbound remote-control credentials.
    local unbound_credential
    local unbound_credentials=(
        /etc/unbound/unbound_server.key
        /etc/unbound/unbound_server.pem
        /etc/unbound/unbound_control.key
        /etc/unbound/unbound_control.pem
    )

    for unbound_credential in "${unbound_credentials[@]}"; do
        if [ ! -s "$unbound_credential" ]; then
            info "Unbound control keys missing, running setup"
            unbound-control-setup \
                || update_error "cannot prepare Unbound control certificates"
            break
        fi
    done

    for unbound_credential in "${unbound_credentials[@]}"; do
        [ -s "$unbound_credential" ] || {
            err "[1/2] $(basename "$unbound_credential")"
            update_error "[2/2] Unbound control credential missing"
        }
    done
    update_begin
    update_stop_service pydhcp-dns.path
    update_stop_service pydhcp-dns.timer
    update_stop_service pydhcp-dns.service
    update_stop_service pydhcpd
    update_wait_jobs
    update_apply
    repair_install_permissions
    # Repair the ACL directory modes set by --install; lists are never rewritten
    acl_prepare "$acl_mac_dir" 700 600 "$acl_limited_file" "$acl_unlimited_file"
    acl_prepare "$acl_dhcp_dir" 700 600 "$acl_block_file"
    install -d -m 755 -o root -g root /etc/logrotate.d || update_error "cannot prepare logrotate directory"
    if ! cat > /etc/logrotate.d/pydhcp <<'PY_ROTATE'
/var/log/pydhcp.log {
    weekly
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 pydhcpd pydhcpd
    postrotate
        systemctl reload pydhcpd > /dev/null 2>&1 || true
    endscript
}
PY_ROTATE
    then
        update_error "cannot write pydhcp logrotate"
    fi
    chown root:root /etc/logrotate.d/pydhcp && chmod 644 /etc/logrotate.d/pydhcp \
        || update_error "cannot set pydhcp logrotate permissions"
    touch "$pydhcp_log_file" && chown "$daemon_owner:$daemon_owner" "$pydhcp_log_file" && chmod 640 "$pydhcp_log_file" \
        || update_error "cannot set pydhcp log permissions"
    systemctl daemon-reload || update_error "cannot reload systemd configuration"
    register_project_cron || update_error "cannot regenerate pydhcp cron"
    update_finish
    info "pydhcpd updated"
}

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

do_install() {
    check_requirements install

    local existing_config unbound_reused=false
    local -a existing_configs=() wpad_configs=() script_packages=()
    if [ "$(dpkg-query -W -f='${db:Status-Status}' unbound 2>/dev/null)" = installed ]; then
        unbound_reused=true
    fi
    for existing_config in /etc/unbound/unbound.conf.d/forward.conf /etc/default/unbound \
        /etc/logrotate.d/pydhcp /etc/cron.d/pydhcp "$service_file" "$init_file" \
        /etc/systemd/system/pydhcp-dns.{service,path,timer}; do
        [ ! -f "$existing_config" ] || existing_configs+=("$existing_config")
    done
    if "$unbound_reused" || (( ${#existing_configs[@]} > 0 )); then
        if (( ${#existing_configs[@]} > 0 )); then
            printf '%s\n' "Existing configurations to change:" "${existing_configs[@]}"
        fi
        echo "Unbound local control will be configured. Unbound will be enabled and restarted."
        if ! confirm "Continue with Unbound and PyDHCP configuration?" "y"; then
            info "Aborted by user"
            log "INFO: pysetup done"
            exit 0
        fi
    fi

    local lan_prefix server_number mask_number network_number broadcast_number
    [[ "$lan_cidr_answer" =~ $UH_CIDR ]] || abort "cannot calculate LAN network -abort"
    server_ip_answer="${lan_cidr_answer%/*}"
    lan_prefix="${lan_cidr_answer#*/}"
    netmask_answer=$(pydhcp_lan_mask "$lan_prefix")
    server_number=$(pydhcp_ipv4_number "$server_ip_answer")
    mask_number=$(pydhcp_ipv4_number "$netmask_answer")
    network_number=$(( server_number & mask_number ))
    broadcast_number=$(( network_number | (0xffffffff ^ mask_number) ))
    local_subnet=$(pydhcp_ipv4_address "$network_number")
    local_broadcast=$(pydhcp_ipv4_address "$broadcast_number")
    info "LAN IPv4: $lan_cidr_answer"

    # POOL
    # Use full addresses and preserve the daemon's pool size and network guards
    local pool_first pool_last pool_start pool_end start_number end_number
    local -a pool_defaults
    (( lan_prefix < 31 )) || abort "LAN has no usable DHCP pool -abort"
    pool_first=$(( network_number + 1 ))
    pool_last=$(( broadcast_number - 1 ))
    pool_start=$(( network_number + 220 ))
    pool_end=$(( network_number + 235 ))
    (( pool_start <= pool_last )) || pool_start=$pool_last
    (( pool_end <= pool_last )) || pool_end=$pool_last
    if (( pool_start <= server_number && server_number <= pool_end )); then
        if (( server_number > pool_first )); then
            pool_end=$(( server_number - 1 ))
            pool_start=$(( pool_end - 15 ))
            (( pool_start >= pool_first )) || pool_start=$pool_first
        else
            pool_start=$(( server_number + 1 ))
            pool_end=$(( pool_start + 15 ))
            (( pool_end <= pool_last )) || pool_end=$pool_last
        fi
    fi
    (( pool_start <= pool_end )) || abort "LAN has no usable DHCP pool -abort"
    pool_defaults=("$(pydhcp_ipv4_address "$pool_start")" "$(pydhcp_ipv4_address "$pool_end")")
    while true; do
        read -r -p "Enter pool start [${pool_defaults[0]}]: " pool_start_answer \
            || abort "cannot read pool start -abort"
        pool_start_answer="${pool_start_answer:-${pool_defaults[0]}}"
        read -r -p "Enter pool end [${pool_defaults[1]}]: " pool_end_answer \
            || abort "cannot read pool end -abort"
        pool_end_answer="${pool_end_answer:-${pool_defaults[1]}}"
        if ! [[ "$pool_start_answer" =~ $UH_IPV4 ]] || ! [[ "$pool_end_answer" =~ $UH_IPV4 ]]; then
            info "invalid pool IPv4 address -retry"
            continue
        fi
        start_number=$(pydhcp_ipv4_number "$pool_start_answer")
        end_number=$(pydhcp_ipv4_number "$pool_end_answer")
        if (( network_number < start_number && start_number <= end_number &&
              end_number < broadcast_number && end_number - start_number < 65536 &&
              (server_number < start_number || server_number > end_number) )); then
            break
        fi
        info "invalid pool: subnet, server, order or size -retry"
    done
    info "Pool range: $pool_start_answer -> $pool_end_answer"

    # DNS upstreams and local DHCP domain
    until is_dns1; do info "Invalid DNS format, try again -retry"; done
    until is_dns2; do info "Invalid DNS format, try again -retry"; done
    dns_answer="$server_ip_answer"
    info "DNS servers: $dns_answer"
    while true; do
        read -r -p "Enter local domain [home.arpa]: " domain_answer \
            || abort "cannot read local domain -abort"
        domain_answer="${domain_answer:-home.arpa}"
        if [[ "$domain_answer" =~ $UH_FQDN ]] && (( ${#domain_answer} <= 253 )); then
            domain_answer="${domain_answer,,}"
            break
        fi
        info "invalid local domain -retry"
    done

    # Pool lease cleanup interval
    ask_number "DHCP pool lease cleanup interval in seconds" "60" cleanup_answer

    # Optional features
    wpad_enabled_value="false"
    local wpad_requested=false
    if confirm "Deploy WPAD/PAC on port $wpad_port_value (DHCP option 252)?" "y"; then
        check_wpad_requirements "$server_ip_answer"
        wpad_requested=true
        for existing_config in "$apache_ports" "$wpad_vhost_dest" "$wpad_root/wpad.pac"; do
            [ ! -f "$existing_config" ] || wpad_configs+=("$existing_config")
        done
        if (( ${#wpad_configs[@]} > 0 )); then
            printf '%s\n' "Existing configurations to change:" "${wpad_configs[@]}"
            echo "Apache will be configured for WPAD and started or reloaded."
            if ! confirm "Replace existing Apache configurations for WPAD?" "y"; then
                info "Aborted by user"
                log "INFO: pysetup done"
                exit 0
            fi
        fi
    fi

    if "$lan_change_requested"; then
        apply_pydhcp_lan "$iface_selected" "$lan_original_cidr" "$lan_cidr_answer"
    else
        check_static_lan "$iface_selected" "$server_ip_answer"
    fi

    for existing_config in "${existing_configs[@]}" "${wpad_configs[@]}"; do
        [ -f "${existing_config}.bak" ] || cp -p -- "$existing_config" "${existing_config}.bak" \
            || abort "cannot back up $(basename "$existing_config") -abort"
    done
    if "$unbound_reused"; then
        mkdir -p "$install_dir" \
            && printf 'enabled=%s\nactive=%s\n' \
                "$(systemctl is-enabled unbound 2>/dev/null || true)" \
                "$(systemctl is-active unbound 2>/dev/null || true)" \
                > "$install_dir/.unbound-reused" \
            || abort "cannot record Unbound state -abort"
    fi
    local dep_pkg
    for dep_pkg in "${apt_deps[@]}"; do
        [ "$dep_pkg" = unbound ] || script_packages+=("$dep_pkg")
    done
    install_deps "${script_packages[@]}"
    install_deps unbound
    if "$wpad_requested"; then
        deploy_wpad "$server_ip_answer" "$local_subnet" "$netmask_answer"
    fi
    # ping-check matches isc-dhcp-server's own default (on unless explicitly
    # disabled), so it is not prompted for -- edit PING_CHECK_ENABLED in
    # pydhcp.env afterward if your environment has strict ICMP firewall rules.
    ping_check_value="true"

    # Create system group and user
    if ! getent group "$daemon_owner" &>/dev/null; then
        groupadd --system "$daemon_owner" || abort "cannot create group $daemon_owner -abort"
        info "created group $daemon_owner"
    else
        info "Group $daemon_owner already exists -skip"
    fi

    if ! id "$daemon_owner" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false --gid "$daemon_owner" --comment "Python DHCP Daemon" "$daemon_owner" \
            || abort "cannot create user $daemon_owner -abort"
        info "created user $daemon_owner"
    else
        info "User $daemon_owner already exists -skip"
    fi

    # Create install directory
    mkdir -p "$install_dir" \
        && chown root:"$daemon_owner" "$install_dir" \
        && chmod 1770 "$install_dir" \
        || abort "cannot prepare $install_dir -abort"
    mkdir -p "$core_dir" \
        && chown root:"$daemon_owner" "$core_dir" \
        && chmod 1770 "$core_dir" \
        || abort "cannot prepare $core_dir -abort"

    # Deploy daemon and config files
    verify_source "$script_dir/core/pydhcpd.py"
    cp "$script_dir/core/pydhcpd.py" "$core_dir/pydhcpd.py" \
        || abort "cannot install pydhcpd.py -abort"
    info "updated pydhcpd.py"
    chown root:root "$core_dir/pydhcpd.py" \
        && chmod 755 "$core_dir/pydhcpd.py" \
        || abort "cannot install pydhcpd.py -abort"

    # Deploy pydhcpd.conf (preserved on update -- never overwritten)
    if [ -f "$core_dir/pydhcpd.conf" ]; then
        info "pydhcpd.conf kept -skip"
    else
        verify_source "$script_dir/core/pydhcpd.conf"
        conf_tmp=$(mktemp "$core_dir/.pydhcpd.conf.XXXXXX") || abort "cannot create temp file -abort"
        cp "$script_dir/core/pydhcpd.conf" "$conf_tmp" && mv -fT -- "$conf_tmp" "$core_dir/pydhcpd.conf" \
            || { rm -f -- "$conf_tmp"; abort "cannot install pydhcpd.conf -abort"; }
        info "updated pydhcpd.conf"
    fi
    fix_dhcp_file "$core_dir/pydhcpd.conf" root "$daemon_owner" 640

    # Create pydhcp's own ACL directories/files (preserved on update -- never
    # overwritten). These lists are only consumed by the optional pyleases.sh
    # tool, but are created here unconditionally so their paths can be recorded
    # in pydhcp.env from the start -- not deferred until pyleases.sh first runs.
    acl_prepare "$acl_mac_dir" 700 600 "$acl_limited_file" "$acl_unlimited_file"
    acl_prepare "$acl_dhcp_dir" 700 600 "$acl_block_file"
    info "ACL files present in $acl_mac_dir and $acl_dhcp_dir"

    # Create pydhcp.env (preserved on update -- never overwritten). Single source
    # of truth for network, ACL-path and daemon-defaults values: pyleases.sh and
    # any other future script read these from here instead of asking again,
    # adding only their own keys if missing.
    if [ -f "$install_dir/pydhcp.env" ]; then
        info "pydhcp.env kept, interface unchanged -skip"
    else
        cat > "$install_dir/pydhcp.env" <<ENVEOF
# =============================================================================
# PYDHCP
# /etc/pydhcp/pydhcp.env
# =============================================================================

# Daemon
DHCPDv4_CONF=/etc/pydhcp/core/pydhcpd.conf
DHCPDv4_BIN=/usr/bin/python3
DHCPDv4_SCRIPT=/etc/pydhcp/core/pydhcpd.py
PYDHCPD_LEASES=$core_dir/pydhcpd.leases
INTERFACESv4=$iface_selected
DAEMON_USER=pydhcpd
DAEMON_GROUP=pydhcpd

# Network
SERVER_IP=$server_ip_answer
SERV_SUBNET=$local_subnet
SERV_BROADCAST=$local_broadcast
SERV_MASK=$netmask_answer
SERV_INI_RANGE_BLOCK=$pool_start_answer
SERV_END_RANGE_BLOCK=$pool_end_answer
SERV_DNS=$dns_answer
SERV_DOMAIN=$domain_answer

# ACL
ACL_PATH=$acl_base_dir
ACL_MAC_LIMITED=$acl_limited_file
ACL_MAC_UNLIMITED=$acl_unlimited_file

# DHCP ACL
ACL_DHCP_PATH=$acl_dhcp_dir
ACL_BLOCK_FILE=$acl_block_file

# Leases
CLEANUP_INTERVAL=$cleanup_answer
AUTHORIZED_LEASE_TIME=2592000
QUARANTINE_DURATION=60

# Features
WPAD_ENABLED=$wpad_enabled_value
WPAD_PORT=$wpad_port_value
PING_CHECK_ENABLED=$ping_check_value
PING_TIMEOUT_SECONDS=1

# Performance
PING_CACHE_TTL_SECONDS=120
RATE_LIMIT_WINDOW_SECONDS=60
RATE_LIMIT_MAX=5
RESERVATION_TTL_SECONDS=30

# Backup
# Changing these defaults is not recommended
BACKUP_DIR=/etc/bak/pydhcp
# =============================================================================

ENVEOF
        info "Network, ACL and daemon defaults set in pydhcp.env"
    fi
    chown root:"$daemon_owner" "$install_dir/pydhcp.env"
    chmod 640 "$install_dir/pydhcp.env"

    # Apply network parameters to pydhcpd.conf
    conf_tmp=$(mktemp "$install_dir/.pydhcpd.conf.XXXXXX") || abort "cannot create temp file -abort"
    cp -f "$core_dir/pydhcpd.conf" "$conf_tmp" \
        || abort "cannot copy pydhcpd.conf -abort"
    sed -i "s|^server-identifier .*|server-identifier ${server_ip_answer};|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "s|subnet [0-9.]* netmask [0-9.]*|subnet ${local_subnet} netmask ${netmask_answer}|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "s|option routers .*;|option routers ${server_ip_answer};|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "s|option broadcast-address .*;|option broadcast-address ${local_broadcast};|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "s|range [0-9.]* [0-9.]*;|range $pool_start_answer $pool_end_answer;|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "s|option domain-name-servers .*;|option domain-name-servers ${dns_answer};|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "s|option domain-name \".*\";|option domain-name \"${domain_answer}\";|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "s|^cleanup-interval .*|cleanup-interval ${cleanup_answer};|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "/pool {/,/}/ s|min-lease-time .*;|min-lease-time ${cleanup_answer};|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "/pool {/,/}/ s|default-lease-time .*;|default-lease-time ${cleanup_answer};|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    sed -i "/pool {/,/}/ s|max-lease-time .*;|max-lease-time ${cleanup_answer};|" "$conf_tmp" \
        || abort "cannot edit pydhcpd.conf -abort"
    if [[ "$wpad_enabled_value" == "true" ]]; then
        sed -i "s|# option wpad code 252 = text;|option wpad code 252 = text;|" "$conf_tmp" \
            || abort "cannot edit pydhcpd.conf -abort"
        sed -i "s|# option wpad \"http://SERVER_IP:[0-9]*/wpad.pac\";|option wpad \"http://${server_ip_answer}:${wpad_port_value}/wpad.pac\";|" "$conf_tmp" \
            || abort "cannot edit pydhcpd.conf -abort"
    else
        sed -i "s|# option wpad \"http://SERVER_IP:[0-9]*/wpad.pac\";|# option wpad \"http://${server_ip_answer}:${wpad_port_value}/wpad.pac\";|" "$conf_tmp" \
            || abort "cannot edit pydhcpd.conf -abort"
    fi
    if ! mv -fT -- "$conf_tmp" "$core_dir/pydhcpd.conf"; then
        rm -f -- "$conf_tmp"
        abort "cannot replace pydhcpd.conf -abort"
    fi
    info "Network parameters set in pydhcpd.conf"

    # Re-apply permissions after sed edits
    fix_dhcp_file "$core_dir/pydhcpd.conf" root "$daemon_owner" 640

    # Initialize empty leases file if not present
    if [ ! -f "$core_dir/pydhcpd.leases" ]; then
        (set -C; umask 077; : > "$core_dir/pydhcpd.leases") 2>/dev/null \
            || abort "cannot create pydhcpd.leases -abort"
        fix_dhcp_file "$core_dir/pydhcpd.leases" "$daemon_owner" "$daemon_owner" 640
        info "created empty pydhcpd.leases"
    fi

    # DNS
    # Configure the DNS resolver
    install -d -m 755 -o root -g root /etc/unbound/unbound.conf.d
    local forward_config
    forward_config=$(
        sed -z 's/\r\n\?/\n/g' "$script_dir/conf/forward.conf" |
            sed -e "s|192\.168\.0\.10|$server_ip_answer|g" \
                -e "s|192\.168\.0\.0/24|$local_subnet/$lan_prefix|g" \
                -e "s|home\.arpa|$domain_answer|g" \
                -e "/^    forward-addr: 1\.1\.1\.2$/ { s|1\.1\.1\.2|$dns_new1|; b; }" \
                -e "s|^    forward-addr: 1\.0\.0\.2$|    forward-addr: $dns_new2|" &&
        printf '.'
    ) || abort "cannot write forward.conf -abort"
    printf '%s' "${forward_config%.}" > /etc/unbound/unbound.conf.d/forward.conf \
        || abort "cannot write forward.conf -abort"
    fix_dhcp_file /etc/unbound/unbound.conf.d/forward.conf root root 644 report
    tee /etc/default/unbound >/dev/null <<'DNS_DEFAULTS' || abort "cannot write /etc/default/unbound -abort"
DAEMON_OPTS=""
DNS_DEFAULTS
    fix_dhcp_file /etc/default/unbound root root 644 report
    unbound-control-setup || abort "cannot prepare unbound control -abort"
    unbound-checkconf || abort "unbound config check failed -abort"
    systemctl daemon-reload \
        && systemctl enable --now unbound \
        || abort "cannot enable unbound -abort"
    systemctl restart unbound || abort "cannot start unbound -abort"

    install -m 750 -o root -g root "$script_dir/core/pydns.py" "$core_dir/pydns.py" \
        || abort "cannot install pydns.py -abort"

    # Deploy tools
    mkdir -p "$install_dir/tools" \
        && chown root:root "$install_dir/tools" \
        && chmod 755 "$install_dir/tools" \
        || abort "cannot prepare $install_dir/tools -abort"

    verify_source "$script_dir/tools/pydhcpenv.sh"
    install -m 644 -o root -g root "$script_dir/tools/pydhcpenv.sh" "$install_dir/tools/pydhcpenv.sh" \
        || abort "cannot install pydhcpenv.sh -abort"
    info "updated tools/pydhcpenv.sh"

    for tool_script in pyleases.sh pywebmin.sh pybk.sh; do
        if [ -f "$script_dir/tools/$tool_script" ]; then
            verify_source "$script_dir/tools/$tool_script"
            cp "$script_dir/tools/$tool_script" "$install_dir/tools/$tool_script" \
                || abort "cannot install $tool_script -abort"
            info "updated tools/$tool_script"
            chown root:root "$install_dir/tools/$tool_script" \
                && chmod 750 "$install_dir/tools/$tool_script" \
                || abort "cannot install $tool_script -abort"
        fi
    done

    register_project_cron || abort "cannot write pydhcp cron -abort"

    # Deploy systemd service
    verify_source "$script_dir/service/pydhcpd.service"
    cp "$script_dir/service/pydhcpd.service" "$service_file" \
        || abort "cannot install pydhcpd.service -abort"
    info "updated pydhcpd.service"
    chown root:root "$service_file" \
        && chmod 644 "$service_file" \
        || abort "cannot install pydhcpd.service -abort"

    for dns_unit in pydhcp-dns.service pydhcp-dns.path pydhcp-dns.timer; do
        install -m 644 -o root -g root "$script_dir/service/$dns_unit" \
            "/etc/systemd/system/$dns_unit" \
            || abort "cannot install $dns_unit -abort"
    done

    # Deploy init.d wrapper
    verify_source "$script_dir/init.d/pydhcpd"
    cp "$script_dir/init.d/pydhcpd" "$init_file" \
        || abort "cannot install init.d/pydhcpd -abort"
    info "updated init.d/pydhcpd"
    chown root:root "$init_file" \
        && chmod 750 "$init_file" \
        || abort "cannot install init.d/pydhcpd -abort"

    # Create log file if it does not exist, ensure correct ownership/permissions
    { [ -f "$pydhcp_log_file" ] || touch "$pydhcp_log_file"; } \
        && chown "$daemon_owner":"$daemon_owner" "$pydhcp_log_file" \
        && chmod 640 "$pydhcp_log_file" \
        || abort "cannot prepare pydhcp.log -abort"

    # Deploy logrotate config
    cat > /etc/logrotate.d/pydhcp << 'EOF' || abort "cannot write logrotate config -abort"
/var/log/pydhcp.log {
    weekly
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 640 pydhcpd pydhcpd
    postrotate
        systemctl reload pydhcpd > /dev/null 2>&1 || true
    endscript
}
EOF
    chmod 644 /etc/logrotate.d/pydhcp \
        && chown root:root /etc/logrotate.d/pydhcp \
        || abort "cannot write logrotate config -abort"

    repair_install_permissions

    # Enable and start service
    info "updated /etc/logrotate.d/pydhcp"
    systemctl daemon-reload \
        && systemctl enable --force pydhcpd \
        || abort "cannot enable pydhcpd -abort"
    systemctl start pydhcpd || true
    sleep 1
    if ! systemctl is-active --quiet pydhcpd; then
        { err "[1/2] pydhcpd failed to start"; abort "[2/2] see: journalctl -u pydhcpd -n 50 -abort"; }
    fi

    systemctl enable --now pydhcp-dns.path pydhcp-dns.timer \
        || abort "cannot enable pydhcp-dns timer -abort"
    systemctl start pydhcp-dns.service || abort "cannot publish DNS names -abort"
    info "pydhcpd installed and running"
    echo "Configuration : $core_dir/pydhcpd.conf"
    echo "Interface : $(grep INTERFACESv4 "$install_dir/pydhcp.env" | cut -d= -f2 | tr -d '"')"
    echo "Leases : $core_dir/pydhcpd.leases"
}

# ------------------------------------------------------------------------------
# STATUS
# ------------------------------------------------------------------------------

do_status() {
    echo ""
    echo "=== pydhcpd Service ==="
    if [[ ! -f "$service_file" ]]; then
        echo "pydhcpd: NOT INSTALLED"
    elif systemctl is-active --quiet pydhcpd; then
        echo "pydhcpd: RUNNING"
    else
        echo "pydhcpd: STOPPED"
    fi

    echo ""
    echo "=== DHCP Port ==="
    local port_listeners
    if ! port_listeners=$(query_port_listeners udp 67); then
        echo ":67/udp UNKNOWN"
    elif [ -n "$port_listeners" ]; then
        echo ":67/udp OPEN"
    else
        echo ":67/udp CLOSED"
    fi

    echo ""
    echo "=== Config ==="
    if [[ -f "$install_dir/pydhcp.env" ]]; then
        echo "Interface : $(grep '^INTERFACESv4=' "$install_dir/pydhcp.env" | cut -d= -f2-)"
    else
        echo "$install_dir/pydhcp.env not found"
    fi

    echo ""
    echo "=== Log ==="
    if [[ -f "$pydhcp_log_file" ]]; then
        echo "$pydhcp_log_file (last 10):"
        tail -10 "$pydhcp_log_file" | sed 's/^/ /'
    else
        echo "$pydhcp_log_file not found"
    fi
    echo ""
}

# ------------------------------------------------------------------------------
# MENU
# ------------------------------------------------------------------------------

# Interactive menu shown when the script runs without arguments
show_menu() {
    local menu_option
    while true; do
        echo ""
        echo "pydhcp installer"
        echo "----------------"
        echo "1) Install"
        echo "2) Update"
        echo "3) Uninstall"
        echo "4) Status"
        echo "5) Exit"
        echo ""
        read -p "Select option [5]: " menu_option
        menu_option="${menu_option:-5}"
        case "$menu_option" in
            1) do_install; break ;;
            2) do_update; break ;;
            3) do_uninstall; break ;;
            4) do_status; break ;;
            5) break ;;
            *) info "invalid option -retry" ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

# Run the action given on the command line, or fall back to the menu
log "INFO: pysetup start..."

case "${1:-}" in
    --install) do_install ;;
    --update) do_update ;;
    --uninstall) do_uninstall ;;
    --status) do_status ;;
    "") show_menu ;;
    *)
        err "invalid option -abort"
        usage
        exit 1
        ;;
esac

log "INFO: pysetup done"

