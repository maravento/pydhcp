#!/bin/bash
# maravento.com
#
################################################################################
#
# DHCP Leases & ACL Manager (pydhcpd)
#
# DESCRIPTION:
# DHCP lease management script for pydhcpd that:
# - Parses and cleans /etc/pydhcp/pydhcpd.leases
# - Detects unauthorized clients and adds them to the block list
# - Dynamically rebuilds /etc/pydhcp/pydhcpd.conf based on ACL sources
# - Applies static MAC->IP mappings from ACL files
# - Removes duplicates and enforces consistency across data sources
# - Safely restarts the pydhcpd service
#
# FEATURES:
# - Locking mechanism to prevent concurrent executions (flock)
# - Lease filtering and selective persistence
# - Automatic cleanup and normalization of ACL files
# - Duplicate detection with fail-safe abort
# - Network configuration read from pydhcp.env (created by pyinstall.sh --
#   pyleases.sh never asks for it; aborts if pydhcp.env or its network keys
#   are missing)
# - All paths, ACL files and network settings read from pydhcp.env
#
# REQUIREMENTS:
# - pydhcpd installed and running
# - ACL directories and files as defined in pydhcp.env
# - Root privileges
# - python3 (required by pydhcpd itself; checked here as a precondition)
#
# ACL FORMAT:
# a;MAC;IP;HOSTNAME;
#
# NOTES:
# - Designed for environments enforcing DHCP-based access control
# - Incorrect ACL data may disrupt IP assignments
# - pydhcp.env must already exist (created by pyinstall.sh) -- pyleases.sh
#   only adds its own keys (ACL paths, timers, etc.) if missing, never the
#   network ones
#
# WPAD/PAC OPTION (option 252)
# If you need WPAD/PAC for proxy auto-configuration:
# 1. Install and configure Apache2
# 2. Create virtual host on port 18100
# 3. Create wpad.pac file in Apache document root
# 4. Set WPAD_ENABLED=true in /etc/pydhcp/pydhcp.env
#
# NOTE on logging:
# - Writes to /var/log/pydhcp.log, a separate log from the daemon's
# /var/log/pydhcpd.log. The log file and its rotation config
# (/etc/logrotate.d/pydhcp) are created by pyinstall.sh.
#
################################################################################

set -uo pipefail

# PATH for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# logging
log_file="/var/log/pydhcp.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}

# Delimits where a new run starts in the log -- useful with heavy activity
# (dozens of MACs coming and going per run).
echo "--------------------------------------------------------------------------------" | tee -a "$log_file" 2>/dev/null || true

## root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root"
    exit 1
fi

# prevent overlapping runs
SCRIPT_LOCK="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$SCRIPT_LOCK")
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    log "Script $(basename "$0") is already running"
    exit 1
fi

# LOCAL USER detection
detect_local_user() {
    local uid_min uid_max
    local user uid best_user="" best_uid=999999

    uid_min=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null)
    uid_max=$(awk '/^UID_MAX/{print $2}' /etc/login.defs 2>/dev/null)
    uid_min=${uid_min:-1000}
    uid_max=${uid_max:-60000}

    while IFS=: read -r user _ uid _ _ _ shell; do
        [ "$user" = "root" ] && continue
        [ -z "$uid" ] && continue
        [ "$uid" -lt "$uid_min" ] && continue
        [ "$uid" -gt "$uid_max" ] && continue

        case "$shell" in
            */false|*/nologin) continue ;;
        esac

        id -nG "$user" 2>/dev/null | grep -qw sudo || continue

        if [ "$uid" -lt "$best_uid" ]; then
            best_uid="$uid"
            best_user="$user"
        fi
    done </etc/passwd

    [ -n "$best_user" ] || return 1
    echo "$best_user"
}

if ! local_user=$(detect_local_user); then
    log "ERROR: No valid local user found. Create one with sudo access."
    exit 1
fi
log "Using local user: $local_user"

# Start
log "pyleases start..."

TEMP_FILES_TO_CLEAN=()
PYDHCPD_NEEDS_RESTART=0
cleanup_temp() {
    for f in "${TEMP_FILES_TO_CLEAN[@]}"; do
        rm -f "$f" 2>/dev/null
    done
    # Lockfile is NOT removed: deleting it creates a TOCTOU race
    # where two processes could flock different inodes of the same path.
    if [ "$PYDHCPD_NEEDS_RESTART" = "1" ]; then
        systemctl is-active --quiet pydhcpd || systemctl start pydhcpd
    fi
}
trap cleanup_temp EXIT

ENV_FILE="/etc/pydhcp/pydhcp.env"
if [ ! -f "$ENV_FILE" ]; then
    log "ERROR: $ENV_FILE not found. Run pyinstall.sh first (a fresh install creates it)."
    exit 1
fi

# Safety check before trusting this file enough to inject pyleases.sh's own
# keys into it: verify pyinstall.sh's own keys are actually present.
_missing_pyinstall_keys=()
for _k in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_MASK SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK SERV_DNS; do
    grep -q "^${_k}=" "$ENV_FILE" || _missing_pyinstall_keys+=("$_k")
done
if (( ${#_missing_pyinstall_keys[@]} > 0 )); then
    log "ERROR: $ENV_FILE is missing pyinstall.sh's own keys: ${_missing_pyinstall_keys[*]} -- refusing to proceed. Re-run pyinstall.sh (or restore $ENV_FILE from backup)."
    exit 1
fi
unset _missing_pyinstall_keys _k

# Injects pyleases.sh's own keys if missing. Never touches the network keys
# above, already written by pyinstall.sh. Backs up the file once, right
# before the first actual change, as a fallback in case it needs to be undone.
ensure_own_keys() {
    local file="$1" key added=0
    declare -A own_defaults=(
        [ACL_PATH]="/etc/acl"
        [ACL_MAC_PATH]="/etc/acl/acl_mac"
        [ACL_DHCP_PATH]="/etc/acl/acl_dhcp"
        [ACL_MAC_PROXY]="/etc/acl/acl_mac/mac-proxy.txt"
        [ACL_MAC_UNLIMITED]="/etc/acl/acl_mac/mac-unlimited.txt"
        [ACL_BLOCK_FILE]="/etc/acl/acl_dhcp/blockdhcp.txt"
        [CLEANUP_INTERVAL]="60"
        [AUTHORIZED_LEASE_TIME]="2592000"
        [WPAD_ENABLED]="false"
        [PING_CHECK_ENABLED]="true"
    )
    for key in ACL_PATH ACL_MAC_PATH ACL_DHCP_PATH ACL_MAC_PROXY ACL_MAC_UNLIMITED \
               ACL_BLOCK_FILE CLEANUP_INTERVAL AUTHORIZED_LEASE_TIME WPAD_ENABLED PING_CHECK_ENABLED; do
        if ! grep -q "^${key}=" "$file"; then
            if (( ! added )); then
                cp -f "$file" "${file}.bak"
                log "Backed up $file to ${file}.bak before adding missing keys"
            fi
            echo "${key}=${own_defaults[$key]}" >> "$file"
            added=1
        fi
    done
    (( added )) && log "Added missing pyleases.sh default(s) to $file"
}
ensure_own_keys "$ENV_FILE"

# Load only known KEY=VALUE pairs from ENV_FILE instead of sourcing it,
# so a tampered or maliciously replaced env file cannot execute code.
load_env_file() {
    local file="$1" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
            SERVER_IP|SERV_SUBNET|SERV_BROADCAST|SERV_MASK|SERV_INI_RANGE_BLOCK|SERV_END_RANGE_BLOCK|SERV_DNS|\
            ACL_PATH|ACL_MAC_PATH|ACL_DHCP_PATH|ACL_MAC_PROXY|ACL_MAC_UNLIMITED|ACL_BLOCK_FILE|\
            CLEANUP_INTERVAL|AUTHORIZED_LEASE_TIME|WPAD_ENABLED|PING_CHECK_ENABLED)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                ;;
        esac
    done < "$file"
}
load_env_file "$ENV_FILE"

if [[ "${WPAD_ENABLED:-false}" == "true" ]]; then
    wpad_header="option wpad code 252 = text;"
    wpad_subnet="option wpad \"http://$SERVER_IP:18100/wpad.pac\";"
else
    wpad_header="#option wpad code 252 = text;"
    wpad_subnet="#option wpad \"http://$SERVER_IP:18100/wpad.pac\";"
fi

if [[ "${PING_CHECK_ENABLED:-true}" == "true" ]]; then
    ping_check_line="ping-check true;"
else
    ping_check_line="ping-check false;"
fi

_notify() {
    local user="$1"; shift
    [ -z "$user" ] && return 0
    local uid
    uid=$(id -u "$user")
    local bus="unix:path=/run/user/${uid}/bus"
    local xdg_runtime="/run/user/${uid}"

    local session_id
    session_id=$(loginctl show-user "$user" 2>/dev/null | awk -F'[= ]' '/^Sessions=/{print $2}')

    local session_type
    session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || echo "x11")

    if [[ "$session_type" == "wayland" ]]; then
        sudo -u "$user" \
            DBUS_SESSION_BUS_ADDRESS="$bus" \
            WAYLAND_DISPLAY=wayland-1 \
            XDG_RUNTIME_DIR="$xdg_runtime" \
            notify-send "$@" 2>/dev/null || true
    else
        local display
        display=$(loginctl show-session "$session_id" -p Display --value 2>/dev/null)
        sudo -u "$user" \
            DISPLAY="${display:-:0}" \
            DBUS_SESSION_BUS_ADDRESS="$bus" \
            XDG_RUNTIME_DIR="$xdg_runtime" \
            notify-send "$@" 2>/dev/null || true
    fi
}

verify_dhcp_service() {
    if ! command -v python3 &>/dev/null; then
        log "ERROR: python3 is not installed (required by pydhcpd / pyleases.sh)"
        exit 1
    fi
    if ! systemctl is-active --quiet pydhcpd; then
        log "ERROR: pydhcpd is not running"
        exit 1
    fi
}

verify_dhcp_files() {
    mkdir -p /etc/pydhcp
    chown root:pydhcpd /etc/pydhcp
    chmod 770 /etc/pydhcp
    if [ ! -f /etc/pydhcp/pydhcpd.leases ]; then
        touch /etc/pydhcp/pydhcpd.leases
    fi
    chown pydhcpd:pydhcpd /etc/pydhcp/pydhcpd.leases
    chmod 640 /etc/pydhcp/pydhcpd.leases
}

verify_dhcp_config() {
    if [ ! -f "/etc/pydhcp/pydhcpd.conf" ]; then
        log "ERROR: /etc/pydhcp/pydhcpd.conf does not exist"
        exit 1
    fi
    chmod 640 "/etc/pydhcp/pydhcpd.conf"
    chown root:pydhcpd "/etc/pydhcp/pydhcpd.conf"
}

verify_directories() {
    for dir in "$ACL_MAC_PATH" "$ACL_DHCP_PATH"; do
        if [ ! -d "$dir" ]; then
            log "ERROR: Directory $dir does not exist"
            exit 1
        fi
    done
}

initialize_empty_files() {
    if [ ! -f "$ACL_BLOCK_FILE" ]; then
        touch "$ACL_BLOCK_FILE"
        chmod 600 "$ACL_BLOCK_FILE"
        chown root:root "$ACL_BLOCK_FILE"
    fi
    for file in "$ACL_MAC_PROXY" "$ACL_MAC_UNLIMITED"; do
        if [ ! -f "$file" ]; then
            touch "$file"
            chmod 600 "$file"
            chown root:root "$file"
        fi
    done
}

verify_dhcp_service
verify_dhcp_files
verify_dhcp_config
verify_directories
initialize_empty_files
log "Verification OK -- pydhcpd active, paths valid"

function is_pydhcp() {
    dhcpd=/etc/pydhcp/pydhcpd.leases
    dhcp_conf="/etc/pydhcp/pydhcpd.conf"
    dhcp_conf_temp=$(mktemp "/etc/pydhcp/.pydhcpd.conf.XXXXXX")
    TEMP_FILES_TO_CLEAN+=("$dhcp_conf_temp")

    function read_leases() {
        local temp_leases
        temp_leases=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("$temp_leases")
        local current_lease="" lease_content=""

        while IFS= read -r line; do
            if echo "$line" | grep -qE '^lease [0-9,.]+ {$'; then
                current_lease="$line"
                lease_content="$line"$'\n'
                continue
            fi

            if [ -n "$current_lease" ]; then
                lease_content+="$line"$'\n'
            fi

            if echo "$line" | grep -q '^}$'; then
                if [ -n "$current_lease" ]; then
                    mac_address=$(echo "$lease_content" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1 | tr 'A-F' 'a-f')
                    ip_address=$(echo "$lease_content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                    host_candidate=$(echo "$lease_content" | grep -oE 'client-hostname "[^"]+"' | cut -d'"' -f2 | tr " " "_")
                    host="${host_candidate:-no_name_$(head -c100 /dev/urandom | sha1sum | head -c10)}"

                    if [[ -n "$mac_address" && -n "$ip_address" ]]; then
                        line_lease="a;$mac_address;$ip_address;$host;"

                        shopt -s nullglob
                        acl_mac_files=("$ACL_MAC_PATH"/mac-*)
                        shopt -u nullglob
                        if [ ${#acl_mac_files[@]} -eq 0 ] || ! grep -qi "^a;${mac_address};" "${acl_mac_files[@]}" 2>/dev/null; then
                            if ! grep -qi "^a;${mac_address};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                                log "read_leases: $mac_address -> unknown -> blockdhcp (ip=$ip_address host=$host)"
                                echo "$line_lease" >> "$ACL_BLOCK_FILE"
                                echo "$lease_content" >> "$temp_leases"
                            else
                                log "read_leases: $mac_address -> blocked (lease discarded)"
                            fi
                        else
                            log "read_leases: $mac_address -> authoritative (ip=$ip_address)"
                            echo "$lease_content" >> "$temp_leases"
                        fi
                    fi
                    current_lease=""
                    lease_content=""
                fi
            fi
        done < "$dhcpd"

        local leases_kept=0
        [[ -s "$temp_leases" ]] && { leases_kept=$(grep -c '^lease ' "$temp_leases" 2>/dev/null) || true; }
        log "read_leases: done (leases_kept=$leases_kept)"

        if [[ -s "$temp_leases" ]]; then
            mv -f "$temp_leases" "$dhcpd"
            chown pydhcpd:pydhcpd "$dhcpd"
            chmod 640 "$dhcpd"
        elif [[ -s "$dhcpd" ]]; then
            # Parser kept nothing but the source file was not empty: this can
            # mean every lease was genuinely blocked, but it can just as
            # easily mean the parser failed to recognize the format. Either
            # way, silently truncating a non-empty leases file is worse than
            # leaving stale data for pydhcpd's own expiry to clean up.
            log "read_leases: WARNING -- kept 0 leases but $dhcpd was not empty; leaving it untouched to avoid data loss"
        else
            : > "$dhcpd"
            chown pydhcpd:pydhcpd "$dhcpd"
            chmod 640 "$dhcpd"
        fi
    }

    function update_dhcp_conf {
        echo "# pydhcpd Configuration
authoritative;
cleanup-interval $CLEANUP_INTERVAL;
$wpad_header
server-identifier $SERVER_IP;
deny duplicates;
one-lease-per-client true;
deny declines;
$ping_check_line
        " >"$dhcp_conf_temp"

        shopt -s nullglob
        acl_files=("$ACL_MAC_PATH"/mac-*)
        shopt -u nullglob
        if [ ${#acl_files[@]} -gt 0 ]; then
            acl_sources=$(cat "${acl_files[@]}")
        else
            acl_sources=""
        fi

        while IFS= read -r line; do
            wcstatus=$(echo "$line" | cut -d ';' -f 1)
            macsource=$(echo "$line" | cut -d ';' -f 2)
            ipsource=$(echo "$line" | cut -d ';' -f 3)
            usersource=$(echo "$line" | cut -d ';' -f 4)
            if [[ $wcstatus == "a" ]]; then
                # Validate every field before writing it into the config so an
                # ACL entry cannot inject arbitrary dhcpd directives.
                if ! [[ $macsource =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
                    log "update_dhcp_conf: skipping entry, invalid MAC: $macsource"
                    continue
                fi
                if ! [[ $ipsource =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                    log "update_dhcp_conf: skipping entry, invalid IP: $ipsource"
                    continue
                fi
                if ! [[ $usersource =~ ^[A-Za-z0-9._-]{1,63}$ ]]; then
                    log "update_dhcp_conf: skipping entry, invalid hostname: $usersource"
                    continue
                fi
                echo "
    host $usersource {
    hardware ethernet $macsource;
    fixed-address $ipsource;
                }" >>"$dhcp_conf_temp"
            fi
        done <<< "$acl_sources"

        echo '
class "blockdhcp" {
     match pick-first-value (option dhcp-client-identifier, hardware);
        }' >>"$dhcp_conf_temp"

        while IFS= read -r line; do
            macs=$(echo "$line" | cut -d ';' -f 2)
            if echo "$macs" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'; then
                printf ' subclass "blockdhcp" 1:%s;\n' "$macs" >>"$dhcp_conf_temp"
            fi
        done < "$ACL_BLOCK_FILE"

        echo "" >>"$dhcp_conf_temp"

        echo "subnet $SERV_SUBNET netmask $SERV_MASK {
    $wpad_subnet
    option routers $SERVER_IP;
    option broadcast-address $SERV_BROADCAST;
    #option domain-name \"example.org\";
    option domain-name-servers $SERV_DNS;
    min-lease-time $AUTHORIZED_LEASE_TIME;
    default-lease-time $AUTHORIZED_LEASE_TIME;
    max-lease-time $AUTHORIZED_LEASE_TIME;
    pool {
        min-lease-time $CLEANUP_INTERVAL;
        default-lease-time $CLEANUP_INTERVAL;
        max-lease-time $CLEANUP_INTERVAL;
        deny members of \"blockdhcp\";
        range $SERV_INI_RANGE_BLOCK $SERV_END_RANGE_BLOCK;
    }
}
        " >>"$dhcp_conf_temp"

        # Keep a backup of the previous config in case the new one is faulty.
        [ -f "$dhcp_conf" ] && cp -f "$dhcp_conf" "${dhcp_conf}.bak"
        mv -f "$dhcp_conf_temp" "$dhcp_conf"
        chown root:pydhcpd "$dhcp_conf"
        chmod 640 "$dhcp_conf"
    }

    function clean_block_list {
        local removed=0 file_temp patterns
        file_temp=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${file_temp}")
        patterns=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${patterns}")
        shopt -s nullglob
        acl_mac_files=("$ACL_MAC_PATH"/mac-*)
        shopt -u nullglob
        if [ ${#acl_mac_files[@]} -gt 0 ]; then
            grep -hiE ';[0-9a-f:]+;' "${acl_mac_files[@]}" 2>/dev/null | cut -d ";" -f2 | tr '[:upper:]' '[:lower:]' | sort -u >"$file_temp"
        else
            : >"$file_temp"
        fi

        while read -r mac_actual; do
            [ -z "$mac_actual" ] && continue
            if grep -qF ";${mac_actual};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                log "clean_block_list: removing $mac_actual from blockdhcp (found in acl_mac)"
                printf ';%s;\n' "$mac_actual" >> "$patterns"
                (( removed++ )) || true
            fi
        done <"$file_temp"

        if (( removed > 0 )); then
            local _grep_rc=0 block_tmp
            block_tmp=$(mktemp)
            TEMP_FILES_TO_CLEAN+=("${block_tmp}")
            grep -vFf "$patterns" "$ACL_BLOCK_FILE" > "$block_tmp" || _grep_rc=$?
            if (( _grep_rc > 1 )); then
                log "ERROR: clean_block_list: grep failed (rc=$_grep_rc) -- skipping update of blockdhcp"
                rm -f "$block_tmp"
            else
                chmod 600 "$block_tmp"
                mv "$block_tmp" "$ACL_BLOCK_FILE"
            fi
        fi
        rm -f "$file_temp" "$patterns"
        if (( removed > 0 )); then
            log "clean_block_list: done (removed=$removed)"
        fi
    }

    function clean_proxy_list {
        local removed=0 patterns
        patterns=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${patterns}")
        awk -F';' 'NF>=2 && $2!="" {print ";"tolower($2)";"}' "$ACL_MAC_UNLIMITED" | sort -u > "$patterns"

        while IFS= read -r pat; do
            local mac_actual="${pat//;/}"
            if grep -qiF "$pat" "$ACL_MAC_PROXY" 2>/dev/null; then
                log "clean_proxy_list: removing $mac_actual from mac-proxy (found in mac-unlimited)"
                (( removed++ )) || true
            fi
        done < "$patterns"

        if (( removed > 0 )); then
            local file_temp
            file_temp=$(mktemp)
            TEMP_FILES_TO_CLEAN+=("${file_temp}")
            local _grep_rc=0
            grep -viFf "$patterns" "$ACL_MAC_PROXY" > "$file_temp" || _grep_rc=$?
            if (( _grep_rc > 1 )); then
                log "ERROR: clean_proxy_list: grep failed (rc=$_grep_rc) -- skipping update of mac-proxy"
                rm -f "$file_temp"
            else
                mv "$file_temp" "$ACL_MAC_PROXY"
            fi
        fi
        rm -f "$patterns"
        if (( removed > 0 )); then
            log "clean_proxy_list: done (removed=$removed)"
        fi
    }

    function clean_acl {
        log "clean_acl: removing empty lines from ACL files"
        sed '/^$/d' -i "$ACL_BLOCK_FILE"
        sed '/^$/d' -i "$ACL_MAC_PROXY"
        sed '/^$/d' -i "$ACL_MAC_UNLIMITED"
    }

    function order_files_acl {
        sort -V "$ACL_BLOCK_FILE" -o "$ACL_BLOCK_FILE"
    }

    clean_acl
    clean_block_list
    clean_proxy_list

    log "Stopping pydhcpd"
    systemctl stop pydhcpd
    if systemctl is-active --quiet pydhcpd; then
        log "ERROR: Stopping pydhcpd FAILED -- still active, aborting before touching config/ACLs"
        _notify "$local_user" "Warning: Abort" "pydhcpd did not stop, aborting. $(date)" -i error
        exit 1
    fi
    log "Stopping pydhcpd: done"
    PYDHCPD_NEEDS_RESTART=1
    log "Processing leases"
    read_leases
    log "Sorting ACL files"
    order_files_acl
    log "Rebuilding pydhcpd.conf"
    update_dhcp_conf
    log "Starting pydhcpd"
    systemctl start pydhcpd
    if ! systemctl is-active --quiet pydhcpd; then
        log "ERROR: Starting pydhcpd FAILED -- check 'systemctl status pydhcpd'"
        _notify "$local_user" "Warning: Abort" "pydhcpd did not start after reload. $(date)" -i error
        exit 1
    fi
    log "Starting pydhcpd: done"
    PYDHCPD_NEEDS_RESTART=0
}

function duplicate() {
    aclall=$(
        shopt -s nullglob
        acl_mac_files=("$ACL_MAC_PATH"/mac-*)
        shopt -u nullglob
        if [ ${#acl_mac_files[@]} -gt 0 ]; then
            for field in 2 3 4; do
                awk -F';' '/^a;/' "${acl_mac_files[@]}" 2>/dev/null \
                    | cut -d\; -f${field} | sort | uniq -d
            done
        fi
    )
    if [ "${aclall}" == "" ]; then
        log "Duplicate check: OK"
        is_pydhcp
    else
        log "ERROR: Duplicate data detected: $aclall"
        log "Duplicate Data: $aclall"
        _notify "$local_user" "Warning: Abort" "Duplicate: $aclall. $(date)" -i error
        exit 1
    fi
}
duplicate

_count() { local c; c=$(grep -c '^a;' "$1" 2>/dev/null) || true; echo "${c:-0}"; }
log "Summary: blockdhcp=$(_count "$ACL_BLOCK_FILE") | proxy=$(_count "$ACL_MAC_PROXY") | unlimited=$(_count "$ACL_MAC_UNLIMITED")"

# End
log "pyleases done at: $(date)"
