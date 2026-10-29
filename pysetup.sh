#!/bin/bash
# maravento.com
#
################################################################################
#
# pysetup -- pydhcp installer / updater
# FILE: pysetup.sh
#
# USAGE:
# sudo bash pysetup.sh --install      Install
# sudo bash pysetup.sh --update       Update code only (preserves user config)
# sudo bash pysetup.sh --uninstall    Uninstall
# sudo bash pysetup.sh --status       Report service, port, config and log
# sudo bash pysetup.sh                Interactive menu
# sudo bash pysetup.sh -h             Show usage
#
# LOG: pysetup.log, in the directory containing this script
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# Source directory (where this script lives) -- needed by the logging block
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# root check
if [ "$(id -u)" != "0" ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') ERROR: This script must be run as root -abort" >&2
    exit 1
fi

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
# Project-wide list: this installer verifies every package the deployed
# components need at runtime, not just the ones it invokes itself -- e.g.
# iputils-ping is used by pydhcpd.py when it cannot open a raw ICMP socket.
for dep_pkg in python3 iproute2 passwd util-linux coreutils grep sed iputils-ping systemd findutils libc-bin zip cron curl logrotate; do
    if [[ "$(dpkg-query -W -f='${Status}' "$dep_pkg" 2>/dev/null)" != *"ok installed"* ]]; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
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

# ACL layout. Two groups, by who owns the list, both under acl_base_dir:
# - acl_mac_dir holds the administrator's own lists (mac-*.txt), edited by hand.
# - acl_dhcp_dir holds pydhcp's own list (blockdhcp.txt), written by
#   pyleases.sh alone.
# acl_base_dir stays outside install_dir because access control lists are never
# removed by any installer: --uninstall leaves /etc/acl untouched.
# pydhcp.env itself is written with these already resolved -- it is parsed
# key=value (never sourced), so a "$VAR" inside it would be stored as that
# literal string, not as a path.
acl_base_dir="/etc/acl"
acl_mac_dir="${acl_base_dir}/mac"
acl_dhcp_dir="${acl_base_dir}/dhcp"
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
        active|reloading|activating|deactivating) update_services+=("$unit") ;;
        inactive|failed) ;;
        *) update_error "unexpected service state: $unit ($state)" ;;
    esac
    update_stopped_services+=("$unit")
    systemctl stop "$unit" || update_error "cannot stop service: $unit"
    state=$(systemctl show -p ActiveState --value "$unit") || update_error "cannot inspect stopped: $unit"
    [ "$state" = inactive ] || {
        log "ERROR: $unit state: $state"
        update_error "$unit did not stop"
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
            log "ERROR: src and dst: $compared_file"
            update_error "src and dst do not match"
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
            log "ERROR: $unit state: $state"
            update_error "$unit did not start"
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
    log "INFO: $acl_path perms fixed -fixed"
}

# INTERACTIVE PROMPTS
# Each one asks for a value, validates it and repeats until it is correct
ask_dns() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_DNS ]]; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "Invalid DNS format, try again -retry"
    done
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
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] && uh_fits "$user_answer" && (( user_answer >= 1 )); then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "Invalid value, enter a positive integer -retry"
    done
}

confirm() {
    # confirm "prompt" [default y|n] -- returns 0 on yes, 1 on no
    local prompt_text="$1" default_value="${2:-n}" user_answer hint_text
    [[ "$default_value" == "y" ]] && hint_text="[Y/n]" || hint_text="[y/N]"
    read -rp " ${prompt_text} ${hint_text}: " user_answer
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
    local proto="$1" port="$2" role="$3"
    if [ -n "$(ss -lnH "-${proto,,}" "sport = :$port" 2>/dev/null)" ]; then
        err "${proto^^} port $port in use by another $role"
        abort "stop that service before installing -abort"
    fi
}

# IFACES
# List network interfaces other than loopback
list_ifaces() {
    ip -br link show 2>/dev/null | awk '$1 != "lo" {sub(/@.*/, "", $1); printf "%s %s\n", $1, ($2 == "UP") ? "UP" : "DOWN"}'
}

# IPV4 INTERFACES
# Offer only interfaces with an active link and configured global IPv4
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

# LAN SELECTION
# Select an existing interface and one of its configured IPv4 addresses
choose_lan_interface() {
    local preset_iface="${1:-}"
    local iface_name iface_choice iface_index iface_addrs iface_state
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
        log "ERROR: LAN must be an active interface with IPv4 -abort"
        exit 1
    fi
    (( ${#lan_candidates[@]} > 0 )) || {
        log "ERROR: no LAN interface available -abort"
        exit 1
    }
    if (( ${#lan_candidates[@]} == 1 )); then
        lan_iface_answer="${lan_candidates[0]}"
        return 0
    fi
    echo "Available LAN interfaces:"
    for iface_index in "${!lan_candidates[@]}"; do
        iface_name="${lan_candidates[$iface_index]}"
        iface_state=$(ip -br link show "$iface_name" | awk '{print $2}')
        iface_addrs=$(ip -4 -o addr show dev "$iface_name" scope global | awk '{print $4}' | paste -sd' ')
        printf ' [%d] %s (%s, %s)\n' "$((iface_index + 1))" "$iface_name" "$iface_state" "${iface_addrs:-no IPv4}"
    done
    while true; do
        read -r -p "Select LAN Interface [1-${#lan_candidates[@]}]: " iface_choice || {
            log "ERROR: cannot read LAN interface selection -abort"
            exit 1
        }
        if [[ "$iface_choice" =~ $UH_UINT ]] && [ "${#iface_choice}" -le 5 ] \
           && [ "$iface_choice" -ge 1 ] && [ "$iface_choice" -le "${#lan_candidates[@]}" ]; then
            lan_iface_answer="${lan_candidates[$((iface_choice - 1))]}"
            return 0
        fi
        log "INFO: invalid LAN interface selection -retry"
    done
}

read_lan_ipv4() {
    local selected_iface="$1" preset_ip="${2:-}" ipv4_choice ipv4_index candidate_cidr
    local -a lan_addresses=()
    mapfile -t lan_addresses < <(ip -4 -o addr show dev "$selected_iface" scope global | awk '{print $4}')
    (( ${#lan_addresses[@]} > 0 )) || {
        log "ERROR: LAN '$selected_iface' has no IPv4 address -abort"
        exit 1
    }
    for candidate_cidr in "${lan_addresses[@]}"; do
        [[ "$candidate_cidr" =~ $UH_CIDR ]] || {
            log "ERROR: LAN '$selected_iface' has invalid IPv4/prefix -abort"
            exit 1
        }
    done
    if [ -n "$preset_ip" ]; then
        for candidate_cidr in "${lan_addresses[@]}"; do
            if [ "${candidate_cidr%/*}" = "$preset_ip" ]; then
                lan_cidr_answer="$candidate_cidr"
                return 0
            fi
        done
        log "ERROR: requested IPv4 is not configured on LAN -abort"
        exit 1
    fi
    if (( ${#lan_addresses[@]} == 1 )); then
        lan_cidr_answer="${lan_addresses[0]}"
        return 0
    fi
    echo "IPv4 addresses on LAN '$selected_iface':"
    for ipv4_index in "${!lan_addresses[@]}"; do
        printf ' [%d] %s\n' "$((ipv4_index + 1))" "${lan_addresses[$ipv4_index]}"
    done
    while true; do
        read -r -p "Select LAN IPv4 number: " ipv4_choice || {
            log "ERROR: cannot read LAN IPv4 selection -abort"
            exit 1
        }
        if [[ "$ipv4_choice" =~ $UH_UINT ]] && [ "${#ipv4_choice}" -le 5 ] \
           && [ "$ipv4_choice" -ge 1 ] && [ "$ipv4_choice" -le "${#lan_addresses[@]}" ]; then
            lan_cidr_answer="${lan_addresses[$((ipv4_choice - 1))]}"
            return 0
        fi
        log "INFO: invalid LAN IPv4 selection -retry"
    done
}

# ------------------------------------------------------------------------------
# REMOVE
# ------------------------------------------------------------------------------

do_uninstall() {
    echo ""
    echo "This removes pydhcp completely from $install_dir"
    echo "The service, init.d wrapper, log and Webmin module are also removed"
    echo "A backup is taken with tools/pybk.sh before anything is removed"
    echo "/etc/bak is NOT touched"
    echo "Package dependencies are NOT removed"
    echo ""
    confirm "Proceed with uninstall? This cannot be undone." "n" \
        || {
            info "Aborted by user"
            log "EVENT: pysetup done"
            exit 0
        }

    echo ""
    echo "Final confirmation required"
    echo "Type word YES (uppercase) to remove pydhcp:"
    echo ""
    read -rp " > " confirm_answer
    if [[ "$confirm_answer" != "YES" ]]; then
        info "Aborted by user"
        log "EVENT: pysetup done"
        exit 0
    fi
    echo ""

    if [ -x "$install_dir/tools/pybk.sh" ]; then
        if "$install_dir/tools/pybk.sh"; then
            info "backup taken with pybk.sh"
        else
            abort "pybk.sh: backup failed -abort"
        fi
    else
        abort "pybk.sh: missing or not executable -abort"
    fi

    log "EVENT: Stopping and disabling pydhcpd service..."
    systemctl stop pydhcpd 2>/dev/null || true
    systemctl disable pydhcpd 2>/dev/null || true

    log "EVENT: Removing system files..."
    rm -f "$service_file"
    rm -f "$init_file"
    rm -f /etc/logrotate.d/pydhcp && info "Removed /etc/logrotate.d/pydhcp"
    rm -f /var/log/pydhcp.log
    rm -f /etc/logrotate.d/pydhcpd && info "Removed /etc/logrotate.d/pydhcpd"
    rm -f /var/log/pydhcpd.log

    rm -f /etc/cron.d/pydhcp /etc/cron.d/pydhcp.update-disabled
    if [ -x "$install_dir/tools/pybk.sh" ]; then
        "$install_dir/tools/pybk.sh" --uninstall || true
    fi

    if [ -x "$install_dir/tools/pywebmin.sh" ]; then
        log "EVENT: Removing Webmin module ..."
        "$install_dir/tools/pywebmin.sh" --uninstall || true
    fi

    [[ "$install_dir" == "/etc/pydhcp" ]] || abort "unexpected install dir: $install_dir -abort"

    # Everything under install_dir goes, including the config: uninstalling
    # means removing the project. The ACL lists are not here: they live under
    # /etc/acl, which no installer ever removes. tools/pybk.sh is the way to
    # keep a copy of the config, and it writes to /etc/bak.
    log "EVENT: Removing $install_dir ..."
    rm -rf "$install_dir"

    log "EVENT: Removing system user and group $daemon_owner ..."
    userdel "$daemon_owner" 2>/dev/null || warn "cannot remove user $daemon_owner -alert"
    groupdel "$daemon_owner" 2>/dev/null || true

    systemctl daemon-reload

    info "pydhcpd has been removed from system"
    rm -f "$pydhcp_log_file"
}

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

do_update() {
    [ -d "$install_dir" ] && [ -f "$install_dir/pydhcp.env" ] \
        || abort "pydhcp is not installed -abort"
    update_reset /etc/cron.d/pydhcp
    local file
    for file in core/pydhcpd.py service/pydhcpd.service init.d/pydhcpd tools/pydhcpenv.sh tools/pyleases.sh tools/pybk.sh tools/pywebmin.sh; do
        verify_source "$script_dir/$file"
    done
    update_file "$script_dir/core/pydhcpd.py" "$core_dir/pydhcpd.py" 755 root:root
    update_file "$script_dir/service/pydhcpd.service" "$service_file" 644 root:root
    update_file "$script_dir/init.d/pydhcpd" "$init_file" 755 root:root
    for file in pydhcpenv.sh pyleases.sh pybk.sh pywebmin.sh; do
        local mode=755
        [ "$file" != pydhcpenv.sh ] || mode=644
        update_file "$script_dir/tools/$file" "$install_dir/tools/$file" "$mode" root:root
    done
    update_target /etc/logrotate.d/pydhcp
    update_target "$pydhcp_log_file" 640
    update_target "$update_cron_file"
    update_target "${update_cron_file}.lock" 600
    update_preflight
    update_backup "$install_dir/tools/pybk.sh"
    update_begin
    update_stop_service pydhcpd
    update_wait_jobs
    update_apply
    if [ -f /var/log/pydhcpd.log ]; then
        cat /var/log/pydhcpd.log >> "$pydhcp_log_file" || update_error "cannot consolidate pydhcp log"
        rm -f /var/log/pydhcpd.log || update_error "cannot remove old pydhcp log"
    fi
    install -d -m 755 -o root -g root /etc/logrotate.d || update_error "cannot prepare logrotate directory"
    if ! cat > /etc/logrotate.d/pydhcp <<'PY_ROTATE'
/var/log/pydhcp.log {
    daily
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
    if [ -f "$core_dir/pydhcpd.py" ]; then
        err "pydhcpd is already installed at $install_dir"
        abort "use --update or --uninstall instead -abort"
    fi

    check_conflicts "DHCP server" isc-dhcp-server kea-dhcp4-server udhcpd
    check_port udp 67 "DHCP server"
    warn_overlap "dhcp" dnsmasq

    # Detect and select network interface
    choose_lan_interface "${PYDHCP_LAN_IFACE:-}"
    iface_selected="$lan_iface_answer"
    read_lan_ipv4 "$iface_selected" "${PYDHCP_SERVER_IP:-}"
    server_ip_answer="${lan_cidr_answer%/*}"
    mapfile -t network_values < <(python3 -c '
import ipaddress, sys
net = ipaddress.IPv4Interface(sys.argv[1]).network
print(net.netmask)
print(net.network_address)
print(net.broadcast_address)
' "$lan_cidr_answer")
    [ "${#network_values[@]}" -eq 3 ] || abort "cannot calculate LAN network -abort"
    netmask_answer="${network_values[0]}"
    local_subnet="${network_values[1]}"
    local_broadcast="${network_values[2]}"
    info "LAN IPv4: $lan_cidr_answer"

    # POOL
    # Use full addresses and preserve the daemon's pool size and network guards
    mapfile -t pool_defaults < <(python3 -c '
import ipaddress, sys
iface = ipaddress.IPv4Interface(sys.argv[1])
net = iface.network
base = int(net.network_address)
last = int(net.broadcast_address) - 1
server = int(iface.ip)
first = base + 1
if last < first or net.prefixlen >= 31:
    sys.exit(1)
start = min(base + 220, last)
end = min(base + 235, last)
if start <= server <= end:
    if server > first:
        end = server - 1
        start = max(first, end - 15)
    else:
        start = server + 1
        end = min(last, start + 15)
if start > end:
    sys.exit(1)
print(ipaddress.IPv4Address(start))
print(ipaddress.IPv4Address(end))
' "$lan_cidr_answer")
    [ "${#pool_defaults[@]}" -eq 2 ] || abort "LAN has no usable DHCP pool -abort"
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
        if python3 -c '
import ipaddress, sys
net = ipaddress.IPv4Interface(sys.argv[1]).network
server = ipaddress.IPv4Interface(sys.argv[1]).ip
start, end = map(ipaddress.IPv4Address, sys.argv[2:])
valid = start in net and end in net and start <= end
valid = valid and net.network_address < start and end < net.broadcast_address
valid = valid and not start <= server <= end and int(end) - int(start) < 65536
sys.exit(0 if valid else 1)
' "$lan_cidr_answer" "$pool_start_answer" "$pool_end_answer"; then
            break
        fi
        info "invalid pool: subnet, server, order or size -retry"
    done
    info "Pool range: $pool_start_answer -> $pool_end_answer"

    # DNS servers
    echo ""
    ask_dns "Enter DNS server(s), comma-separated" "8.8.8.8,1.1.1.1" dns_answer
    info "DNS servers: $dns_answer"

    # Pool lease cleanup interval
    ask_number "DHCP pool lease cleanup interval in seconds" "60" cleanup_answer

    # Optional features
    wpad_port_value="18100"
    # Same check pyleases.sh repeats on every reload -- but this is the only time
    # it ever runs for an admin who manages pydhcpd.conf by hand and never
    # invokes pyleases.sh afterward. No need to ask: if something is already
    # serving wpad.pac on the default port, WPAD is enabled; otherwise it isn't.
    if curl -fsS --noproxy '*' --max-time 5 -o /dev/null "http://${server_ip_answer}:${wpad_port_value}/wpad.pac"; then
        wpad_detected="true"
        info "wpad.pac detected on port $wpad_port_value -- WPAD enabled"
    else
        wpad_detected="false"
        info "wpad.pac not detected on port $wpad_port_value -- WPAD not enabled"
    fi
    # ping-check matches isc-dhcp-server's own default (on unless explicitly
    # disabled), so it is not prompted for -- edit PING_CHECK_ENABLED in
    # pydhcp.env afterward if your environment has strict ICMP firewall rules.
    ping_check_value="true"

    # Verify source files exist
    for source_file in core/pydhcpd.py core/pydhcpd.conf service/pydhcpd.service init.d/pydhcpd tools/pydhcpenv.sh; do
        [ -f "$script_dir/$source_file" ] || { err "missing source file: $source_file"; abort "run pysetup.sh from the project directory -abort"; }
    done

    # Create system group and user
    if ! getent group "$daemon_owner" &>/dev/null; then
        groupadd --system "$daemon_owner"
        info "created group $daemon_owner"
    else
        info "Group $daemon_owner already exists -skip"
    fi

    if ! id "$daemon_owner" &>/dev/null; then
        useradd --system --no-create-home --shell /bin/false --gid "$daemon_owner" --comment "Python DHCP Daemon" "$daemon_owner"
        info "created user $daemon_owner"
    else
        info "User $daemon_owner already exists -skip"
    fi

    # Create install directory
    mkdir -p "$install_dir"
    chown root:"$daemon_owner" "$install_dir"
    chmod 770 "$install_dir"
    mkdir -p "$core_dir"
    chown root:"$daemon_owner" "$core_dir"
    chmod 770 "$core_dir"

    # Deploy daemon and config files
    verify_source "$script_dir/core/pydhcpd.py"
    cp "$script_dir/core/pydhcpd.py" "$core_dir/pydhcpd.py"
    info "updated pydhcpd.py"
    chown root:root "$core_dir/pydhcpd.py"
    chmod 755 "$core_dir/pydhcpd.py"

    # Deploy pydhcpd.conf (preserved on update -- never overwritten)
    if [ -f "$core_dir/pydhcpd.conf" ]; then
        { info "pydhcpd.conf already exists in $install_dir"; info "static hosts and blocked MACs kept"; info "network parameters updated with your answers"; }
    else
        verify_source "$script_dir/core/pydhcpd.conf"
        cp "$script_dir/core/pydhcpd.conf" "$core_dir/pydhcpd.conf"
        info "updated pydhcpd.conf"
    fi
    chown root:"$daemon_owner" "$core_dir/pydhcpd.conf"
    chmod 640 "$core_dir/pydhcpd.conf"

    # Create pydhcp's own ACL directories/files (preserved on update -- never
    # overwritten). These lists are only consumed by the optional pyleases.sh
    # tool, but are created here unconditionally so their paths can be recorded
    # in pydhcp.env from the start -- not deferred until pyleases.sh first runs.
    acl_prepare "$acl_base_dir" 755 644
    acl_prepare "$acl_mac_dir" 700 600 "$acl_limited_file" "$acl_unlimited_file"
    acl_prepare "$acl_dhcp_dir" 700 600 "$acl_block_file"
    info "ACL directories/files present in $acl_base_dir"

    # Create pydhcp.env (preserved on update -- never overwritten). Single source
    # of truth for network, ACL-path and daemon-defaults values: pyleases.sh and
    # any other future script read these from here instead of asking again,
    # adding only their own keys if missing.
    if [ -f "$install_dir/pydhcp.env" ]; then
        info "pydhcp.env already exists, not overwritten -skip"
        info "interface not changed, keeping value in pydhcp.env"
    else
        log "EVENT: Creating pydhcp.env ..."
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

# ACL
ACL_PATH=$acl_base_dir
ACL_MAC_PATH=$acl_mac_dir
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
WPAD_ENABLED=$wpad_detected
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
    cp -f "$core_dir/pydhcpd.conf" "$conf_tmp"
    sed -i "s|^server-identifier .*|server-identifier ${server_ip_answer};|" "$conf_tmp"
    sed -i "s|subnet [0-9.]* netmask [0-9.]*|subnet ${local_subnet} netmask ${netmask_answer}|" "$conf_tmp"
    sed -i "s|option routers .*;|option routers ${server_ip_answer};|" "$conf_tmp"
    sed -i "s|option broadcast-address .*;|option broadcast-address ${local_broadcast};|" "$conf_tmp"
    sed -i "s|range [0-9.]* [0-9.]*;|range $pool_start_answer $pool_end_answer;|" "$conf_tmp"
    sed -i "s|option domain-name-servers .*;|option domain-name-servers ${dns_answer};|" "$conf_tmp"
    sed -i "s|^cleanup-interval .*|cleanup-interval ${cleanup_answer};|" "$conf_tmp"
    sed -i "/pool {/,/}/ s|min-lease-time .*;|min-lease-time ${cleanup_answer};|" "$conf_tmp"
    sed -i "/pool {/,/}/ s|default-lease-time .*;|default-lease-time ${cleanup_answer};|" "$conf_tmp"
    sed -i "/pool {/,/}/ s|max-lease-time .*;|max-lease-time ${cleanup_answer};|" "$conf_tmp"
    if [[ "$wpad_detected" == "true" ]]; then
        sed -i "s|# option wpad code 252 = text;|option wpad code 252 = text;|" "$conf_tmp"
        sed -i "s|# option wpad \"http://SERVER_IP:18100/wpad.pac\";|option wpad \"http://${server_ip_answer}:${wpad_port_value}/wpad.pac\";|" "$conf_tmp"
    else
        sed -i "s|# option wpad \"http://SERVER_IP:18100/wpad.pac\";|# option wpad \"http://${server_ip_answer}:${wpad_port_value}/wpad.pac\";|" "$conf_tmp"
    fi
    mv -f "$conf_tmp" "$core_dir/pydhcpd.conf"
    info "Network parameters set in pydhcpd.conf"

    # Re-apply permissions after sed edits
    chown root:"$daemon_owner" "$core_dir/pydhcpd.conf"
    chmod 640 "$core_dir/pydhcpd.conf"

    # Initialize empty leases file if not present
    if [ ! -f "$core_dir/pydhcpd.leases" ]; then
        log "EVENT: Creating empty pydhcpd.leases ..."
        touch "$core_dir/pydhcpd.leases"
        chown "$daemon_owner":"$daemon_owner" "$core_dir/pydhcpd.leases"
        chmod 640 "$core_dir/pydhcpd.leases"
    fi

    # Deploy tools
    mkdir -p "$install_dir/tools"
    chown root:root "$install_dir/tools"
    chmod 755 "$install_dir/tools"

    verify_source "$script_dir/tools/pydhcpenv.sh"
    install -m 644 -o root -g root "$script_dir/tools/pydhcpenv.sh" "$install_dir/tools/pydhcpenv.sh"
    info "updated tools/pydhcpenv.sh"

    for tool_script in pyleases.sh pywebmin.sh pybk.sh; do
        if [ -f "$script_dir/tools/$tool_script" ]; then
            verify_source "$script_dir/tools/$tool_script"
            cp "$script_dir/tools/$tool_script" "$install_dir/tools/$tool_script"
            info "updated tools/$tool_script"
            chown root:root "$install_dir/tools/$tool_script"
            chmod 755 "$install_dir/tools/$tool_script"
        fi
    done

    register_project_cron || abort "cannot write pydhcp cron -abort"

    # Deploy systemd service
    verify_source "$script_dir/service/pydhcpd.service"
    cp "$script_dir/service/pydhcpd.service" "$service_file"
    info "updated pydhcpd.service"
    chown root:root "$service_file"
    chmod 644 "$service_file"

    # Deploy init.d wrapper
    verify_source "$script_dir/init.d/pydhcpd"
    cp "$script_dir/init.d/pydhcpd" "$init_file"
    info "updated init.d/pydhcpd"
    chown root:root "$init_file"
    chmod 755 "$init_file"

    # Create log file if it does not exist, ensure correct ownership/permissions
    [ -f "$pydhcp_log_file" ] || touch "$pydhcp_log_file"
    chown "$daemon_owner":"$daemon_owner" "$pydhcp_log_file"
    chmod 640 "$pydhcp_log_file"

    # Deploy logrotate config
    rm -f /etc/logrotate.d/pydhcpd
    cat > /etc/logrotate.d/pydhcp << 'EOF'
/var/log/pydhcp.log {
    daily
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
    chmod 644 /etc/logrotate.d/pydhcp
    chown root:root /etc/logrotate.d/pydhcp

    # Enable and start service
    info "updated /etc/logrotate.d/pydhcp"
    log "EVENT: Enabling and starting pydhcpd ..."
    systemctl daemon-reload
    systemctl enable --force pydhcpd
    if ! systemctl start pydhcpd; then
        { err "pydhcpd failed to start"; abort "check it with: journalctl -u pydhcpd -n 50 -abort"; }
    fi

    info "pydhcpd installed and running"
    info "Configuration : $core_dir/pydhcpd.conf"
    info "Interface : $(grep INTERFACESv4 "$install_dir/pydhcp.env" | cut -d= -f2 | tr -d '"')"
    info "Leases : $core_dir/pydhcpd.leases"
    info "Logs : journalctl -u pydhcpd -f"
    info "To remove : sudo bash pysetup.sh --uninstall"
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
    if ss -uln 2>/dev/null | grep -qE ":67[[:space:]]"; then
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

# ------------------------------------------------------------------------------
# ACTIONS
# ------------------------------------------------------------------------------

# Run the action given on the command line, or fall back to the menu
log "EVENT: pysetup start..."

case "${1:-}" in
    --install) do_install ;;
    --update) do_update ;;
    --uninstall) do_uninstall ;;
    --status) do_status ;;
    "") show_menu ;;
    -h|--help) usage ;;
    *)
        err "invalid option -abort"
        usage
        exit 1
        ;;
esac

log "EVENT: pysetup done"
