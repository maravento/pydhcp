#!/bin/bash
# maravento.com
#
################################################################################
#
# DHCP Leases & ACL Manager (pydhcpd)
#
# DESCRIPTION:
# DHCP lease management script for pydhcpd that:
# - Parses and cleans pydhcpd.leases
# - Detects unauthorized clients and adds them to the block list
# - Dynamically rebuilds pydhcpd.conf based on ACL sources
# - Applies static MAC->IP mappings from ACL files
# - Detects duplicate entries across ACL sources: silently repairs
#   blockdhcp.txt, aborts only when mac-*.txt conflicts with itself
# - Safely restarts the pydhcpd service
#
# FEATURES:
# - Locking mechanism to prevent concurrent executions (flock)
# - Removes from pydhcpd.leases every client it blocks, so the IP it was
#   using is free at that same instant
# - normalize_acl_lists(): enforces the line format of every ACL file
#   before anything parses them. A malformed line in mac-*.txt aborts the
#   run, naming the file and the line number; in blockdhcp.txt it is
#   dropped from the file and the run continues
# - check_duplicate(): the single guard against duplicate ACL entries
#   (priority mac-*.txt > blockdhcp.txt), called at the start and end of
#   the run. mac-*.txt vs itself is fatal (fail-safe abort, naming the
#   field/value/files, never resolved automatically); blockdhcp.txt is
#   silently repaired
# - check_mac_ip_ranges(): separate guard, mac-*.txt IPs landing inside
#   the blockdhcp pool range, called alongside check_duplicate()
# - Network configuration read from pydhcp.env; aborts if pydhcp.env or its
#   network keys are missing
# - All paths, ACL files and network settings read from pydhcp.env
#
# REQUIREMENTS:
# - pydhcpd installed and running
# - ACL directories and files as defined in pydhcp.env
# - Root privileges
#
# ACL FORMAT:
# a;MAC;IP;HOSTNAME;
#
# NOTES:
# - Designed for environments enforcing DHCP-based access control
# - Incorrect ACL data may disrupt IP assignments
# - pydhcp.env must already exist -- pyleases.sh only adds its own keys
#   (ACL paths, timers, etc.) if missing, never the network ones
#
# WPAD/PAC OPTION (option 252)
# If you need WPAD/PAC for proxy auto-configuration:
# 1. Install and configure Apache2
# 2. Create virtual host on port 18100
# 3. Create wpad.pac file in Apache document root
# 4. Set WPAD_ENABLED=true in pydhcp.env
#
# NOTE on logging:
# - Writes to /var/log/pydhcp.log, a fixed path shared with the rest of the
# project. It is owned by pydhcpd:pydhcpd 640 so the
# daemon, which runs as the pydhcpd account and not as root, can write
# to it; this script runs as root.
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# path for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# logging
log_file="/var/log/pydhcp.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$log_file" 2>/dev/null || true
}

# Delimits where a new run starts in the log -- useful with heavy activity
# (dozens of MACs coming and going per run).
echo "--------------------------------------------------------------------------------" | tee -a "$log_file" 2>/dev/null || true

# root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root -- abort"
    exit 1
fi

# log file perms (as installed by pysetup.sh)
log_stat=$(stat -c '%U %G %a' "$log_file" 2>/dev/null || true)
case "$log_stat" in
    ""|"pydhcpd pydhcpd 640") ;;
    *)
        if chown pydhcpd:pydhcpd "$log_file" 2>/dev/null &&
           chmod 640 "$log_file" 2>/dev/null; then
            log "WARNING: pydhcp.log perms fixed -- alert"
        else
            log "WARNING: cannot fix pydhcp.log perms -- alert"
        fi
        ;;
esac
unset log_stat

# prevent overlapping runs
# Waits instead of failing: this script is registered in cron and restarts
# pydhcpd, so a run overlapping the previous one is expected, not a fault.
# The run already in progress does the work; this one steps aside with exit
# 0 so cron does not report a failure for a healthy condition.
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"
if ! flock -w 10 200; then
    log "INFO: another run in progress -- skip"
    log "pyleases done at: $(date)"
    exit 0
fi

# dependencies
for dep_pkg in python3 mawk coreutils util-linux curl grep sed systemd; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'
UH_FQDN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
UH_MAC_RE='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'
UH_MAC="^${UH_MAC_RE}$"
UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# start
log "pyleases start..."

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# IPv4 <-> integer. Callers validate with UH_IPV4 before calling, which
# rejects leading zeros. Ranges are compared as integers, so nothing below
# assumes a particular netmask or a three-octet prefix.
ip_to_int() {
    local octet_1 octet_2 octet_3 octet_4
    IFS='.' read -r octet_1 octet_2 octet_3 octet_4 <<< "$1"
    echo $(( (octet_1 << 24) + (octet_2 << 16) + (octet_3 << 8) + octet_4 ))
}

temp_files=()
pydhcpd_needs_restart=0
cleanup_temp() {
    local check_file
    for check_file in "${temp_files[@]+"${temp_files[@]}"}"; do
        rm -f "$check_file" 2>/dev/null
    done
    # Lockfile is NOT removed: deleting it creates a TOCTOU race
    # where two processes could flock different inodes of the same path.
    if [ "$pydhcpd_needs_restart" = "1" ]; then
        systemctl is-active --quiet pydhcpd || systemctl start pydhcpd
    fi
}
trap cleanup_temp EXIT

# ------------------------------------------------------------------------------
# ENV
# ------------------------------------------------------------------------------

env_file="/etc/pydhcp/pydhcp.env"
if [ ! -f "$env_file" ]; then
    log "ERROR: pydhcp.env not found, run pysetup.sh -- abort"
    exit 1
fi

env_owner=$(stat -c '%U' "$env_file" 2>/dev/null)
env_group=$(stat -c '%G' "$env_file" 2>/dev/null)
env_perms=$(stat -c '%a' "$env_file" 2>/dev/null)
if [[ "$env_owner" != "root" ]] || [[ "$env_group" != "pydhcpd" ]] || [[ "$env_perms" != "640" ]]; then
    if chown root:pydhcpd "$env_file" 2>/dev/null && chmod 640 "$env_file" 2>/dev/null; then
        log "WARNING: pydhcp.env perms fixed -- alert"
    else
        log "ERROR: cannot fix pydhcp.env perms -- abort"
        exit 1
    fi
fi
unset env_owner env_group env_perms

# Safety check before trusting this file enough to inject the pyleases.sh
# keys into it: verify the pysetup.sh keys are actually present.
missing_pysetup_keys=()
for required_key in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_MASK SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK SERV_DNS; do
    grep -q "^${required_key}=" "$env_file" || missing_pysetup_keys+=("$required_key")
done
if (( ${#missing_pysetup_keys[@]} > 0 )); then
    log "ERROR: pydhcp.env missing ${#missing_pysetup_keys[@]} key(s) -- abort"
    for required_key in "${missing_pysetup_keys[@]}"; do
        log "ERROR: missing key $required_key"
    done
    exit 1
fi
unset missing_pysetup_keys required_key

# Inserts $2 (one or more lines) right before the last closing
# "# ====...====" delimiter, instead of a plain >> append -- keeps the block
# inside the PYDHCP frame instead of scattering variables past it. Falls
# back to a plain append if no delimiter line is found (older file).
insert_before_closing_delimiter() {
    local conf_file="$1" file_content="$2" last_line tmp_file range_boundary
    # the pydhcp section never has a blank line in its body -- the first
    # blank line in the file (if any) marks the boundary before anything
    # appended after it (e.g. another script custom-values block).
    # Anchor on the last "# ====" line before that boundary, not the last
    # one in the whole file, so appended blocks are never disturbed.
    range_boundary=$(grep -n '^$' "$conf_file" | head -1 | cut -d: -f1 || true)
    if [[ -n "$range_boundary" ]]; then
        last_line=$(head -n "$((range_boundary - 1))" "$conf_file" | grep -n '^# =\{5,\}$' | tail -1 | cut -d: -f1 || true)
    else
        last_line=$(grep -n '^# =\{5,\}$' "$conf_file" | tail -1 | cut -d: -f1 || true)
    fi
    if [[ -z "$last_line" ]]; then
        printf '%s\n' "$file_content" >> "$conf_file"
        return
    fi
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    head -n "$((last_line - 1))" "$conf_file" > "$tmp_file"
    printf '%s\n' "$file_content" >> "$tmp_file"
    tail -n "+${last_line}" "$conf_file" >> "$tmp_file"
    cat "$tmp_file" > "$conf_file"
    rm -f "$tmp_file"
}

# Injects the pyleases.sh keys if missing. Never touches the network keys
# above, already written by pysetup.sh. Backs up the file once, right
# before the first actual change, as a fallback in case it needs to be undone.
ensure_own_keys() {
    local conf_file="$1" env_key added_count=0 bak_dir
    local -a bak_old
    declare -A own_defaults=(
        [ACL_PATH]="/etc/acl"
        [ACL_MAC_PATH]="/etc/acl/mac"
        [ACL_DHCP_PATH]="/etc/pydhcp/acl"
        [ACL_MAC_LIMITED]="/etc/acl/mac/mac-limited.txt"
        [ACL_MAC_UNLIMITED]="/etc/acl/mac/mac-unlimited.txt"
        [ACL_BLOCK_FILE]="/etc/pydhcp/acl/blockdhcp.txt"
        [PYDHCPD_LEASES]="/etc/pydhcp/core/pydhcpd.leases"
        [CLEANUP_INTERVAL]="60"
        [AUTHORIZED_LEASE_TIME]="2592000"
        [QUARANTINE_DURATION]="60"
        [WPAD_ENABLED]="false"
        [WPAD_PORT]="18100"
        [PING_CHECK_ENABLED]="true"
        [PING_TIMEOUT_SECONDS]="1"
    )
    for env_key in ACL_PATH ACL_MAC_PATH ACL_DHCP_PATH ACL_MAC_LIMITED ACL_MAC_UNLIMITED \
               ACL_BLOCK_FILE PYDHCPD_LEASES CLEANUP_INTERVAL AUTHORIZED_LEASE_TIME QUARANTINE_DURATION \
               WPAD_ENABLED WPAD_PORT PING_CHECK_ENABLED PING_TIMEOUT_SECONDS; do
        if ! grep -q "^${env_key}=" "$conf_file"; then
            if (( ! added_count )); then
                bak_dir="$(dirname "$conf_file")/bak"
                if mkdir -p "$bak_dir"; then
                    cp -f "$conf_file" "$bak_dir/$(basename "$conf_file").$(date +%Y%m%d_%H%M%S)"
                    log "INFO: backed up pydhcp.env to bak/"
                    shopt -s nullglob
                    bak_old=("$bak_dir"/pydhcp.env.*)
                    shopt -u nullglob
                    if (( ${#bak_old[@]} > 3 )); then
                        rm -f "${bak_old[@]:0:${#bak_old[@]}-3}"
                    fi
                else
                    log "ERROR: cannot create $bak_dir -- abort"
                    exit 1
                fi
            fi
            insert_before_closing_delimiter "$conf_file" "${env_key}=${own_defaults[$env_key]}"
            added_count=1
        fi
    done
    (( added_count )) && log "INFO: added missing defaults to $conf_file"
}
ensure_own_keys "$env_file"

# Load only known KEY=VALUE pairs from env_file instead of sourcing it,
# so a tampered or maliciously replaced env file cannot execute code.
load_env_file() {
    local conf_file="$1" env_line env_key env_value raw_key raw_value
    while IFS= read -r env_line || [ -n "$env_line" ]; do
        [[ "$env_line" =~ ^[[:space:]]*# ]] && continue
        [[ "$env_line" =~ ^[[:space:]]*$ ]] && continue
        env_key="${env_line%%=*}"
        env_value="${env_line#*=}"
        raw_key="$env_key" raw_value="$env_value"
        env_key="${env_key#"${env_key%%[![:space:]]*}"}"
        env_key="${env_key%"${env_key##*[![:space:]]}"}"
        env_value="${env_value#"${env_value%%[![:space:]]*}"}"
        env_value="${env_value%"${env_value##*[![:space:]]}"}"
        if [[ "$env_key" != "$raw_key" || "$env_value" != "$raw_value" ]]; then
            log "WARNING: stray whitespace fixed -- alert"
            log "WARNING: key $env_key"
        fi
        if [[ "$env_value" == \"*\" && "$env_value" == *\" && ${#env_value} -ge 2 ]]; then
            env_value="${env_value:1:$((${#env_value}-2))}"
        fi
        case "$env_key" in
            SERVER_IP|SERV_SUBNET|SERV_BROADCAST|SERV_MASK|SERV_INI_RANGE_BLOCK|SERV_END_RANGE_BLOCK|SERV_DNS|\
            ACL_PATH|ACL_MAC_PATH|ACL_DHCP_PATH|ACL_MAC_LIMITED|ACL_MAC_UNLIMITED|ACL_BLOCK_FILE|PYDHCPD_LEASES|\
            CLEANUP_INTERVAL|AUTHORIZED_LEASE_TIME|QUARANTINE_DURATION|WPAD_ENABLED|WPAD_PORT|PING_CHECK_ENABLED|\
            PING_TIMEOUT_SECONDS|DHCPDv4_CONF|DAEMON_USER|DAEMON_GROUP)
                printf -v "$env_key" '%s' "$env_value"
                ;;
            *)
                ;;
        esac
    done < "$conf_file"
}
load_env_file "$env_file"

for ip_var_name in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK; do
    if ! [[ "${!ip_var_name}" =~ $UH_IPV4 ]]; then
        log "ERROR: $ip_var_name invalid IPv4 -- abort"
        exit 1
    fi
done
unset ip_var_name
if ! [[ "$SERV_MASK" =~ $UH_NETMASK ]]; then
    log "ERROR: SERV_MASK is not a valid netmask -- abort"
    exit 1
fi
if ! [[ "$SERV_DNS" =~ $UH_DNS ]]; then
    log "ERROR: SERV_DNS invalid IPv4 list -- abort"
    exit 1
fi

CLEANUP_INTERVAL="${CLEANUP_INTERVAL:-60}"
if ! [[ "$CLEANUP_INTERVAL" =~ $UH_UINT ]] || (( CLEANUP_INTERVAL == 0 )); then
    log "WARNING: CLEANUP_INTERVAL invalid -- fallback"
    CLEANUP_INTERVAL=60
fi
AUTHORIZED_LEASE_TIME="${AUTHORIZED_LEASE_TIME:-2592000}"
if ! [[ "$AUTHORIZED_LEASE_TIME" =~ $UH_UINT ]] || (( AUTHORIZED_LEASE_TIME == 0 )); then
    log "WARNING: AUTHORIZED_LEASE_TIME invalid -- fallback"
    AUTHORIZED_LEASE_TIME=2592000
fi
QUARANTINE_DURATION="${QUARANTINE_DURATION:-60}"
if ! [[ "$QUARANTINE_DURATION" =~ $UH_UINT ]] || (( QUARANTINE_DURATION == 0 )); then
    log "WARNING: QUARANTINE_DURATION invalid -- fallback"
    QUARANTINE_DURATION=60
fi
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-1}"
if ! [[ "$PING_TIMEOUT_SECONDS" =~ $UH_UINT ]] || (( PING_TIMEOUT_SECONDS == 0 )); then
    log "WARNING: PING_TIMEOUT_SECONDS invalid -- fallback"
    PING_TIMEOUT_SECONDS=1
fi

# Guard: SERVER_IP must never fall inside its own block-pool range -- pydhcpd.py
# rejects this at config load, but that only surfaces after this script has
# already stopped the daemon and rewritten pydhcpd.conf. Catching it here,
# before any destructive action, avoids leaving the daemon down over a config
# mistake that could have been caught up front.
if python3 -c "
import ipaddress, sys
server_ip = ipaddress.IPv4Address(sys.argv[1])
pool_start = ipaddress.IPv4Address(sys.argv[2])
pool_end = ipaddress.IPv4Address(sys.argv[3])
print('1' if pool_start <= server_ip <= pool_end else '0')
" "$SERVER_IP" "$SERV_INI_RANGE_BLOCK" "$SERV_END_RANGE_BLOCK" 2>/dev/null | grep -q '^1$'; then
    log "ERROR: SERVER_IP overlaps block-pool range -- abort"
    exit 1
fi

wpad_port="${WPAD_PORT:-18100}"
if ! [[ "$wpad_port" =~ $UH_UINT ]] ||
   (( wpad_port < 1 || wpad_port > 65535 )); then
    log "WARNING: WPAD_PORT invalid -- fallback"
    wpad_port=18100
fi
wpad_url="http://$SERVER_IP:$wpad_port/wpad.pac"

wpad_ready=0
if [[ "${WPAD_ENABLED:-false}" == "true" ]]; then
    if curl -fsS --noproxy '*' --max-time 5 -o /dev/null "$wpad_url"; then
        wpad_ready=1
    else
        log "WARNING: WPAD_ENABLED=true but not served -- alert"
    fi
fi

if (( wpad_ready )); then
    wpad_header="option wpad code 252 = text;"
    wpad_subnet="option wpad \"$wpad_url\";"
else
    wpad_header="#option wpad code 252 = text;"
    wpad_subnet="#option wpad \"$wpad_url\";"
fi

if [[ "${PING_CHECK_ENABLED:-true}" == "true" ]]; then
    ping_check_line="ping-check true;"
    ping_timeout_line="ping-timeout ${PING_TIMEOUT_SECONDS:-1};"
else
    ping_check_line="ping-check false;"
    ping_timeout_line=""
fi

verify_dhcp_service() {
    if ! systemctl is-active --quiet pydhcpd; then
        log "ERROR: pydhcpd is not running -- abort"
        exit 1
    fi
}

verify_dhcp_files() {
    mkdir -p /etc/pydhcp
    chown root:"${DAEMON_GROUP:-pydhcpd}" /etc/pydhcp
    chmod 770 /etc/pydhcp
    if [ ! -f "$PYDHCPD_LEASES" ]; then
        touch "$PYDHCPD_LEASES"
    fi
    chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$PYDHCPD_LEASES"
    chmod 640 "$PYDHCPD_LEASES"
}

verify_dhcp_config() {
    if [ ! -f "${DHCPDv4_CONF:-/etc/pydhcp/core/pydhcpd.conf}" ]; then
        log "ERROR: config file not found -- abort"
        exit 1
    fi
    chmod 640 "${DHCPDv4_CONF:-/etc/pydhcp/core/pydhcpd.conf}"
    chown root:"${DAEMON_GROUP:-pydhcpd}" "${DHCPDv4_CONF:-/etc/pydhcp/core/pydhcpd.conf}"
}

verify_directories() {
    for check_dir in "$ACL_MAC_PATH" "$ACL_DHCP_PATH"; do
        if [ ! -d "$check_dir" ]; then
            log "ERROR: ACL directory missing -- abort"
            exit 1
        fi
    done
}

ensure_acl_lists() {
    local check_file file_owner file_perms
    for check_file in "$@"; do
        if [ ! -f "$check_file" ]; then
            touch "$check_file"
            chmod 600 "$check_file"
            chown root:root "$check_file"
            continue
        fi
        file_owner=$(stat -c '%U' "$check_file" 2>/dev/null)
        file_perms=$(stat -c '%a' "$check_file" 2>/dev/null)
        if [[ "$file_owner" != "root" ]] || [[ "$file_perms" != "600" ]]; then
            if chown root:root "$check_file" 2>/dev/null && chmod 600 "$check_file" 2>/dev/null; then
                log "WARNING: $(basename "$check_file") perms fixed -- alert"
            else
                log "ERROR: cannot fix $(basename "$check_file") perms -- abort"
                exit 1
            fi
        fi
    done
}

initialize_empty_files() {
    shopt -s nullglob
    local mac_lists=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    ensure_acl_lists "$ACL_BLOCK_FILE" "$ACL_MAC_LIMITED" "$ACL_MAC_UNLIMITED" \
        "${mac_lists[@]+"${mac_lists[@]}"}"
}

# DUPLICATE GUARD
# Aborts if the same MAC is listed in more than one ACL file
# check_duplicate() is the single guard against duplicate ACL entries. Called
# twice: right after initialize_empty_files (precondition -- catches a
# manually-edited/corrupt file before anything touches it) and again at the
# very end of the script (postcondition -- catches a bug in the processing
# done in between). Priority order: mac-*.txt (admin-owned, fatal on
# conflict) > blockdhcp.txt (owned by pydhcp itself, loses against mac-*.txt).
# No other function in this script does duplicate detection/removal.

# Silent self-defense: removes any active line from $1 whose MAC (field 2)
# either repeats within $1 itself or is already claimed by a higher-priority
# source among $2.. -- one pass, both checks share the same "seen" set.
dedup_mac_vs() {
    local acl_file="$1" acl_label="$2"; shift 2
    [ -f "$acl_file" ] || return 0
    local other_macs=""
    if (( $# > 0 )); then
        other_macs=$( { grep -hE '^#?a;' "$@" 2>/dev/null || true; } | awk -F';' '{print tolower($2)}' | sort -u )
    fi
    local tmp_file dropped_count mac_addr
    tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${tmp_file}")
    dropped_count=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("${dropped_count}")
    awk -F';' -v others="$other_macs" -v outfile="$tmp_file" -v dropfile="$dropped_count" '
        BEGIN {
            n = split(others, arr, "\n")
            for (i = 1; i <= n; i++) if (arr[i] != "") seen[arr[i]] = 1
        }
        {
            if ($0 ~ /^a;/) {
                mac = tolower($2)
                if (mac in seen) { print mac >> dropfile; next }
                seen[mac] = 1
            }
            print >> outfile
        }
    ' "$acl_file"
    if [[ -s "$dropped_count" ]]; then
        if mv "$tmp_file" "$acl_file"; then
            chmod 600 "$acl_file"
            while IFS= read -r mac_addr; do
                log "INFO: dup MAC $mac_addr removed ($acl_label)"
            done < "$dropped_count"
        else
            while IFS= read -r mac_addr; do
                log "WARNING: dup MAC '$mac_addr' write failed -- alert"
            done < "$dropped_count"
        fi
    fi
    rm -f "$tmp_file" "$dropped_count"
}

function check_duplicate() {
    # -- mac-*.txt vs itself: fatal, admin must fix by hand ------------------
    shopt -s nullglob
    local acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if (( ${#acl_mac_files[@]} > 0 )); then
        local field_count field_name dup_macs dup_mac has_error=0
        for field_count in 2 3 4; do
            case $field_count in 2) field_name="MAC" ;; 3) field_name="IP" ;; 4) field_name="hostname" ;; esac
            if [ "$field_count" = 2 ]; then
                dup_macs=$(cut -d';' -f2 "${acl_mac_files[@]}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
            else
                dup_macs=$(cut -d';' -f${field_count} "${acl_mac_files[@]}" 2>/dev/null | sort | uniq -d)
            fi
            if [[ -n "$dup_macs" ]]; then
                while IFS= read -r dup_mac; do
                    [[ -z "$dup_mac" ]] && continue
                    log "ERROR: duplicate $field_name ${dup_mac:0:20}"
                    has_error=1
                done <<< "$dup_macs"
            fi
        done
        if (( has_error )); then
            log "ERROR: mac-*.txt duplicate entry -- abort"
            exit 1
        fi
    fi

    # -- blockdhcp.txt vs itself and vs mac-*.txt (MAC only) ------------------
    dedup_mac_vs "$ACL_BLOCK_FILE" "blockdhcp.txt" "${acl_mac_files[@]}"
}

# IP RANGE GUARD
# Aborts if the configured ranges overlap or fall outside the subnet
# mac-*.txt IPs are administrator-assigned, with no dedicated range in
# pydhcp.env -- only SERV_INI_RANGE_BLOCK/SERV_END_RANGE_BLOCK (the
# blockdhcp pool) is defined there. A mac-*.txt IP landing inside it is
# always a misconfiguration. Unrelated to duplicate detection -- kept as
# its own guard, called alongside check_duplicate but never merged into it.
function check_mac_ip_ranges() {
    shopt -s nullglob
    local mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    [[ ${#mac_files[@]} -eq 0 ]] && return
    local pool_start_int pool_end_int client_ip_int server_ip_int netmask_int network_int broadcast_int has_error=0
    pool_start_int=$(ip_to_int "$SERV_INI_RANGE_BLOCK"); pool_end_int=$(ip_to_int "$SERV_END_RANGE_BLOCK")
    server_ip_int=$(ip_to_int "$SERVER_IP"); netmask_int=$(ip_to_int "$SERV_MASK")
    network_int=$(( $(ip_to_int "$SERV_SUBNET") & netmask_int ))
    broadcast_int=$(( network_int | (0xFFFFFFFF ^ netmask_int) ))
    local mac_addr client_ip acl_status
    while IFS=';' read -r acl_status mac_addr client_ip _; do
        [[ "$acl_status" != "a" || -z "$client_ip" ]] && continue
        [[ "$client_ip" =~ $UH_IPV4 ]] || continue
        client_ip_int=$(ip_to_int "$client_ip")
        if (( (client_ip_int & netmask_int) != network_int )); then
            log "ERROR: $mac_addr: IP outside subnet"
            has_error=1
        elif (( client_ip_int == network_int || client_ip_int == broadcast_int )); then
            log "ERROR: $mac_addr: IP is net/broadcast"
            has_error=1
        elif (( client_ip_int == server_ip_int )); then
            log "ERROR: $mac_addr: IP same as SERVER_IP"
            has_error=1
        elif (( client_ip_int >= pool_start_int && client_ip_int <= pool_end_int )); then
            log "ERROR: $mac_addr: IP inside blockdhcp pool"
            has_error=1
        fi
    done < <(cat "${mac_files[@]}" 2>/dev/null)
    if (( has_error )); then
        log "ERROR: mac-*.txt IP conflict -- abort"
        exit 1
    fi
}

# Normalizes every ACL list file before any parsing happens, then enforces
# the exact line format for that file. mac-*.txt belongs to the administrator,
# so a malformed line there aborts the run, naming the file and the line.
# blockdhcp.txt is written by this script alone and is self-healing -- a
# malformed line is dropped and the run continues, so one bad entry never
# stops the whole reload. This is line format only; repeated MAC/IP/hostname
# values are a separate concern, handled by check_duplicate().
#
# mac-*.txt / blockdhcp.txt: 4 fields, no epoch.
normalize_acl_file() {
    local acl_file="$1" line_pattern="${2:-}" validate_ip="${3:-1}" on_bad="${4:-abort}"
    local line_number=0 acl_line malformed_ip line_error tmp_file dropped_count=0

    [ -f "$acl_file" ] || return 0

    # Remove blank (now-empty) lines.
    sed -i '/^$/d' "$acl_file"

    if [[ -n "$line_pattern" ]]; then
        tmp_file=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
        temp_files+=("$tmp_file")
        while IFS= read -r acl_line || [ -n "$acl_line" ]; do
            line_number=$((line_number + 1))
            line_error=""
            if ! [[ "$acl_line" =~ $line_pattern ]]; then
                line_error="malformed line $line_number"
            elif [[ "$validate_ip" == "1" ]]; then
                malformed_ip="$(printf '%s' "$acl_line" | cut -d';' -f3)"
                if [[ -n "$malformed_ip" ]] && ! [[ "$malformed_ip" =~ $UH_IPV4 ]]; then
                    line_error="invalid IP on line $line_number"
                fi
            fi
            if [[ -z "$line_error" ]]; then
                printf '%s\n' "$acl_line" >> "$tmp_file"
                continue
            fi
            if [[ "$on_bad" == "abort" ]]; then
                log "ERROR: $line_error in $(basename "$acl_file") -- abort"
                exit 1
            fi
            log "INFO: $line_error in $(basename "$acl_file") -- skip"
            dropped_count=$((dropped_count + 1))
        done < "$acl_file"
        if (( dropped_count > 0 )); then
            mv -f "$tmp_file" "$acl_file"
            chmod 600 "$acl_file"
            chown root:root "$acl_file"
        else
            rm -f "$tmp_file"
        fi
    fi

    # Ensure a trailing newline. tail -c1 grabs the last byte;
    # command substitution strips a trailing \n from its output, so
    # a non-empty result here means the last byte was NOT a newline.
    if [ -s "$acl_file" ] && [ -n "$(tail -c1 "$acl_file" 2>/dev/null)" ]; then
        log "INFO: adding trailing newline to $(basename "$acl_file")"
        printf '\n' >> "$acl_file"
    fi
}

normalize_acl_lists() {
    local mac_files=() check_file
    local mac_re="$UH_MAC_RE"
    local ip_re='[0-9.]+'
    local host_re='[A-Za-z0-9._-]{1,63}'
    # Fixed-address list: "#" is a valid way to deactivate an entry.
    local commentable_no_epoch_pattern="^#?a;${mac_re};${ip_re};${host_re};$"
    # blockdhcp.txt: no "#" variant -- a leading "#" is malformed there.
    local strict_no_epoch_pattern="^a;${mac_re};${ip_re};${host_re};$"

    shopt -s nullglob
    mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    for check_file in "${mac_files[@]}"; do
        normalize_acl_file "$check_file" "$commentable_no_epoch_pattern"
    done
    normalize_acl_file "$ACL_BLOCK_FILE" "$strict_no_epoch_pattern" 1 drop
}

verify_dhcp_service
verify_dhcp_files
verify_dhcp_config
verify_directories
initialize_empty_files
normalize_acl_lists
check_duplicate
check_mac_ip_ranges
log "INFO: verification OK, pydhcpd active and paths valid"

function is_pydhcp() {
    leases_file="$PYDHCPD_LEASES"
    dhcp_conf="${DHCPDv4_CONF:-/etc/pydhcp/core/pydhcpd.conf}"
    dhcp_conf_temp=$(mktemp "/etc/pydhcp/.pydhcpd.conf.XXXXXX") || { log "ERROR: cannot create temp file in /etc/pydhcp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
    temp_files+=("$dhcp_conf_temp")

    # Log lines below do not carry the function name -- they use short,
    # generic phrasing instead.
    function read_leases() {
        # grep returns exit 1 on no-match, which is legitimate here and must
        # not abort the script. Disable pipefail for the duration of this
        # function and restore it on return -- restore only if it was
        # actually on before (a plain "set -o pipefail" would wrongly
        # re-enable it for a caller that had it off).
        local pipefail_was_on=0
        [[ "$(set +o | grep -c 'set -o pipefail')" == "1" ]] && pipefail_was_on=1
        set +o pipefail

        local temp_leases parsed_line=0
        temp_leases=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
        temp_files+=("$temp_leases")
        local current_lease="" lease_content=""

        while IFS= read -r acl_line; do
            if echo "$acl_line" | grep -qE '^lease [0-9,.]+ {$'; then
                current_lease="$acl_line"
                lease_content="$acl_line"$'\n'
                continue
            fi

            if [ -n "$current_lease" ]; then
                lease_content+="$acl_line"$'\n'
            fi

            if echo "$acl_line" | grep -q '^}$'; then
                if [ -n "$current_lease" ]; then
                    mac_address=$(echo "$lease_content" | grep -oE "$UH_MAC_RE" | head -1 | tr '[:upper:]' '[:lower:]')
                    ip_address=$(echo "$lease_content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                    host_candidate=$(echo "$lease_content" | grep -oE 'client-hostname "[^"]+"' | cut -d'"' -f2 | tr " " "_")
                    client_name="${host_candidate:-no_name_$(head -c100 /dev/urandom | sha1sum | head -c10)}"

                    if [[ -n "$ip_address" ]] && ! [[ "$ip_address" =~ $UH_IPV4 ]]; then
                        log "INFO: invalid lease IP $ip_address -- skip"
                        ip_address=""
                    fi

                    if [[ -n "$mac_address" && -n "$ip_address" ]]; then
                        parsed_line=$((parsed_line + 1))
                        line_lease="a;$mac_address;$ip_address;$client_name;"

                        shopt -s nullglob
                        acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
                        shopt -u nullglob
                        if [ ${#acl_mac_files[@]} -gt 0 ] && grep -qi "^a;${mac_address};" "${acl_mac_files[@]}" 2>/dev/null; then
                            log "INFO: $mac_address authoritative (ip=$ip_address)"
                            echo "$lease_content" >> "$temp_leases"
                        elif [ ${#acl_mac_files[@]} -gt 0 ] && grep -qi "^#a;${mac_address};" "${acl_mac_files[@]}" 2>/dev/null; then
                            log "INFO: $mac_address deactivated (lease discarded)"
                        elif grep -qi "^a;${mac_address};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                            log "INFO: $mac_address blocked (lease discarded)"
                        else
                            log "INFO: $mac_address blocked, hostname=${client_name:0:20}"
                            echo "$line_lease" >> "$ACL_BLOCK_FILE"
                        fi
                    fi
                    current_lease=""
                    lease_content=""
                fi
            fi
        done < "$leases_file"

        local leases_kept=0
        [[ -s "$temp_leases" ]] && { leases_kept=$(grep -c '^lease ' "$temp_leases" 2>/dev/null) || true; }
        log "INFO: done (leases_kept=$leases_kept)"

        if [[ -s "$temp_leases" ]]; then
            mv -f "$temp_leases" "$leases_file"
            chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$leases_file"
            chmod 640 "$leases_file"
        elif (( parsed_line > 0 )); then
            : > "$leases_file"
            chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$leases_file"
            chmod 640 "$leases_file"
        elif [[ -s "$leases_file" ]]; then
            # Nothing was parsed at all: the file did not look like leases.
            # Truncating it here would throw away data over a parser failure.
            log "WARNING: pydhcpd.leases unreadable, file untouched -- alert"
        fi

        # Restore pipefail to whatever it was before entering this function.
        # Explicit "if" + "return 0" so the function success does not
        # depend on the pipefail_was_on value being truthy.
        if (( pipefail_was_on )); then
            set -o pipefail
        fi
        return 0
    }

    # Log lines below do not carry the function name -- they use short,
    # generic phrasing instead.
    function update_dhcp_conf {
        echo "# pydhcpd Configuration
authoritative;
cleanup-interval $CLEANUP_INTERVAL;
abandon-lease-time ${QUARANTINE_DURATION:-60};
$wpad_header
server-identifier $SERVER_IP;
deny duplicates;
deny declines;
$ping_check_line
$ping_timeout_line
" >"$dhcp_conf_temp"

        shopt -s nullglob
        acl_files=("$ACL_MAC_PATH"/mac-*.txt)
        shopt -u nullglob
        if [ ${#acl_files[@]} -gt 0 ]; then
            acl_sources=$(cat "${acl_files[@]}")
        else
            acl_sources=""
        fi

        while IFS= read -r acl_line; do
            acl_status=$(echo "$acl_line" | cut -d ';' -f 1)
            mac_source=$(echo "$acl_line" | cut -d ';' -f 2)
            ip_source=$(echo "$acl_line" | cut -d ';' -f 3)
            user_source=$(echo "$acl_line" | cut -d ';' -f 4)
            if [[ $acl_status == "a" ]]; then
                # Validate every field before writing it into the config so an
                # ACL entry cannot inject arbitrary dhcpd directives.
                if ! [[ $mac_source =~ $UH_MAC ]]; then
                    log "INFO: invalid MAC $mac_source -- skip"
                    continue
                fi
                if ! [[ "$ip_source" =~ $UH_IPV4 ]]; then
                    log "INFO: invalid IP $ip_source -- skip"
                    continue
                fi
                if ! [[ $user_source =~ ^[A-Za-z0-9._-]{1,63}$ ]]; then
                    log "INFO: invalid hostname ${user_source:0:20} -- skip"
                    continue
                fi
                echo "
host $user_source {
    hardware ethernet $mac_source;
    fixed-address $ip_source;
}" >>"$dhcp_conf_temp"
            fi
        done <<< "$acl_sources"

        echo '
class "blockdhcp" {
    match pick-first-value (option dhcp-client-identifier, hardware);
}' >>"$dhcp_conf_temp"

        {
            cut -d ';' -f 2 "$ACL_BLOCK_FILE" 2>/dev/null
            grep -h '^#a;' "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null | cut -d ';' -f 2 || true
        } | grep -E "$UH_MAC" | tr '[:upper:]' '[:lower:]' | sort -u \
          | while IFS= read -r mac_list; do
                printf 'subclass "blockdhcp" 1:%s;\n' "$mac_list" >>"$dhcp_conf_temp"
            done || true

        echo "" >>"$dhcp_conf_temp"

        echo "subnet $SERV_SUBNET netmask $SERV_MASK {
    $wpad_subnet
    option routers $SERVER_IP;
    option broadcast-address $SERV_BROADCAST;
    option domain-name-servers $SERV_DNS;
    min-lease-time $AUTHORIZED_LEASE_TIME;
    default-lease-time $AUTHORIZED_LEASE_TIME;
    max-lease-time $AUTHORIZED_LEASE_TIME;
    # Pool for unknown clients only — a blocked MAC gets no IP at all, and
    # authorized hosts use the fixed-address reservations above
    pool {
        min-lease-time $CLEANUP_INTERVAL;
        default-lease-time $CLEANUP_INTERVAL;
        max-lease-time $CLEANUP_INTERVAL;
        deny members of \"blockdhcp\";
        range $SERV_INI_RANGE_BLOCK $SERV_END_RANGE_BLOCK;
    }
}" >>"$dhcp_conf_temp"

        # Keep a backup of the previous config in case the new one is faulty.
        [ -f "$dhcp_conf" ] && cp -f "$dhcp_conf" "${dhcp_conf}.bak"
        mv -f "$dhcp_conf_temp" "$dhcp_conf"
        chown root:"${DAEMON_GROUP:-pydhcpd}" "$dhcp_conf"
        chmod 640 "$dhcp_conf"
    }

    # Log lines below do not carry the function name -- they use short,
    # generic phrasing instead.
    function clean_block_list {
        local removed_count=0 file_temp line_patterns
        file_temp=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
        temp_files+=("${file_temp}")
        line_patterns=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
        temp_files+=("${line_patterns}")
        shopt -s nullglob
        acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
        shopt -u nullglob
        if [ ${#acl_mac_files[@]} -gt 0 ]; then
            { grep -hiE '^a;[0-9a-f:]+;' "${acl_mac_files[@]}" 2>/dev/null || true; } | cut -d ";" -f2 | tr '[:upper:]' '[:lower:]' | sort -u >"$file_temp"
        else
            : >"$file_temp"
        fi

        while read -r mac_actual; do
            [ -z "$mac_actual" ] && continue
            if ! [[ "$mac_actual" =~ $UH_MAC ]]; then
                log "INFO: malformed ACL mac $mac_actual -- skip"
                continue
            fi
            if grep -qiF ";${mac_actual};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                log "INFO: removing $mac_actual from blockdhcp (mac)"
                printf ';%s;\n' "$mac_actual" >> "$line_patterns"
                (( removed_count++ )) || true
            fi
        done <"$file_temp"

        if (( removed_count > 0 )); then
            local grep_rc=0 block_tmp
            block_tmp=$(mktemp) || { log "ERROR: cannot create temp file in /tmp"; log "ERROR: check free space, read-only mount, immutable -- abort"; exit 1; }
            temp_files+=("${block_tmp}")
            grep -viFf "$line_patterns" "$ACL_BLOCK_FILE" > "$block_tmp" || grep_rc=$?
            if (( grep_rc > 1 )); then
                log "WARNING: grep failed (rc=$grep_rc) -- alert"
                rm -f "$block_tmp"
            else
                chmod 600 "$block_tmp"
                mv "$block_tmp" "$ACL_BLOCK_FILE"
            fi
        fi
        rm -f "$file_temp" "$line_patterns"
        if (( removed_count > 0 )); then
            log "INFO: done (removed=$removed_count)"
        fi
    }

    # Log lines below do not carry the function name -- they use short,
    # generic phrasing instead.
    function clean_acl {
        log "INFO: removing empty lines from ACL files"
        sed '/^$/d' -i "$ACL_BLOCK_FILE"
        sed '/^$/d' -i "$ACL_MAC_LIMITED"
        sed '/^$/d' -i "$ACL_MAC_UNLIMITED"
    }

    function order_files_acl {
        sort -V "$ACL_BLOCK_FILE" -o "$ACL_BLOCK_FILE"
        # mac-*.txt: sorted by IP (field 3). Purely cosmetic -- update_dhcp_conf()
        # and the pydhcpd.py host{} parsing are both order-independent.
        shopt -s nullglob
        local order_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
        shopt -u nullglob
        local normalize_file
        for normalize_file in "${order_mac_files[@]}"; do
            sort -t';' -k3,3V "$normalize_file" -o "$normalize_file"
        done
    }

    clean_acl
    clean_block_list

    log "INFO: stopping pydhcpd"
    systemctl stop pydhcpd
    if systemctl is-active --quiet pydhcpd; then
        log "ERROR: pydhcpd still active, stop failed -- abort"
        exit 1
    fi
    log "INFO: stopping pydhcpd: done"
    pydhcpd_needs_restart=1
    log "INFO: processing leases"
    read_leases
    log "INFO: sorting ACL files"
    order_files_acl
    log "INFO: rebuilding pydhcpd.conf"
    update_dhcp_conf
    log "INFO: starting pydhcpd"
    systemctl start pydhcpd
    if ! systemctl is-active --quiet pydhcpd; then
        log "WARNING: pydhcpd failed to start after rebuild -- fallback"
        if [ -f "${dhcp_conf}.bak" ]; then
            cp -f "${dhcp_conf}.bak" "$dhcp_conf"
            log "INFO: restored backup config, retrying start"
            systemctl start pydhcpd
            if ! systemctl is-active --quiet pydhcpd; then
                log "ERROR: pydhcpd failed to start with backup config -- abort"
                exit 1
            else
                log "INFO: pydhcpd recovered with backup config"
            fi
        else
            log "ERROR: no backup config found -- abort"
            exit 1
        fi
    fi
    log "INFO: starting pydhcpd: done"
    pydhcpd_needs_restart=0
}

is_pydhcp

check_duplicate
check_mac_ip_ranges

count_active() { local active_count=0; active_count=$(grep -c '^a;' "$1" 2>/dev/null) || active_count=0; echo "$active_count"; }
log "INFO: blockdhcp=$(count_active "$ACL_BLOCK_FILE")"
log "INFO: limited=$(count_active "$ACL_MAC_LIMITED")"
log "INFO: unlimited=$(count_active "$ACL_MAC_UNLIMITED")"

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "pyleases done at: $(date)"
