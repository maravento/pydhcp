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
# - Detects duplicate or conflicting entries across ACL sources and aborts
# - Safely restarts the pydhcpd service
#
# FEATURES:
# - Locking mechanism to prevent concurrent executions (flock)
# - Removes from pydhcpd.leases every client it blocks, so the IP it was
#   using is free at that same instant
# - Automatic cleanup and normalization of ACL files
# - Duplicate MAC/IP/hostname detection across mac-*.txt (active and
#   commented lines alike) with fail-safe abort -- naming the field, the
#   value and the file(s) involved; never resolved automatically
# - mac-*.txt IPs checked against the blockdhcp pool range, aborting before
#   the daemon is stopped or pydhcpd.conf is rewritten
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
# - Writes to the log path declared as LOG_FILE in pydhcp.env, shared with
# the rest of the project. It is owned by pydhcpd:pydhcpd 640 so the
# daemon, which runs as the pydhcpd account and not as root, can write
# to it; this script runs as root.
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
    log "WARNING: script $(basename "$0") is already running"
    exit 1
fi

# DEPENDENCIES
for dep in python3 gawk coreutils util-linux curl grep sed systemd; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: Required dependency not installed"
        log "ERROR: ($dep)"
        exit 1
    fi
done

# Start
log "pyleases start..."

# VALIDATION -- one variable per thing validated; use directly with =~
_UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
_UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
_UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
_UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
_UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
_UH_UINT='^(0|[1-9][0-9]*)$'
_UH_FQDN='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
_UH_MAC='^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'
_UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# IPv4 <-> integer. Callers validate with _UH_IPV4 before calling, which
# rejects leading zeros. Ranges are compared as integers, so nothing below
# assumes a particular netmask or a three-octet prefix.
_ip_to_int() {
    local a b c d
    IFS='.' read -r a b c d <<< "$1"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

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
    log "ERROR: $ENV_FILE not found"
    log "ERROR: run pysetup.sh first (creates it)"
    exit 1
fi

# Safety check before trusting this file enough to inject pyleases.sh's own
# keys into it: verify pysetup.sh's own keys are actually present.
_missing_pysetup_keys=()
for _k in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_MASK SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK SERV_DNS; do
    grep -q "^${_k}=" "$ENV_FILE" || _missing_pysetup_keys+=("$_k")
done
if (( ${#_missing_pysetup_keys[@]} > 0 )); then
    log "ERROR: $ENV_FILE is missing pysetup.sh keys"
    log "ERROR: (${_missing_pysetup_keys[*]})"
    log "ERROR: refusing to proceed, re-run pysetup.sh"
    exit 1
fi
unset _missing_pysetup_keys _k

# Inserts $2 (one or more lines) right before the file's last closing
# "# ====...====" delimiter, instead of a plain >> append -- keeps the block
# inside the PYDHCP frame instead of scattering variables past it. Falls
# back to a plain append if no delimiter line is found (older file).
insert_before_closing_delimiter() {
    local file="$1" content="$2" last_line tmp boundary
    # pydhcp's own section never has a blank line in its body -- the first
    # blank line in the file (if any) marks the boundary before anything
    # appended after it (e.g. gateproxy.sh's own custom-values block).
    # Anchor on the last "# ====" line before that boundary, not the last
    # one in the whole file, so appended blocks are never disturbed.
    boundary=$(grep -n '^$' "$file" | head -1 | cut -d: -f1)
    if [[ -n "$boundary" ]]; then
        last_line=$(head -n "$((boundary - 1))" "$file" | grep -n '^# =\{5,\}$' | tail -1 | cut -d: -f1)
    else
        last_line=$(grep -n '^# =\{5,\}$' "$file" | tail -1 | cut -d: -f1)
    fi
    if [[ -z "$last_line" ]]; then
        printf '%s\n' "$content" >> "$file"
        return
    fi
    tmp=$(mktemp)
    head -n "$((last_line - 1))" "$file" > "$tmp"
    printf '%s\n' "$content" >> "$tmp"
    tail -n "+${last_line}" "$file" >> "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Injects pyleases.sh's own keys if missing. Never touches the network keys
# above, already written by pysetup.sh. Backs up the file once, right
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
        [PYDHCPD_LEASES]="/etc/pydhcp/pydhcpd.leases"
        [CLEANUP_INTERVAL]="60"
        [AUTHORIZED_LEASE_TIME]="2592000"
        [QUARANTINE_DURATION]="60"
        [WPAD_ENABLED]="false"
        [WPAD_PORT]="18100"
        [PING_CHECK_ENABLED]="true"
        [PING_TIMEOUT_SECONDS]="1"
    )
    for key in ACL_PATH ACL_MAC_PATH ACL_DHCP_PATH ACL_MAC_PROXY ACL_MAC_UNLIMITED \
               ACL_BLOCK_FILE PYDHCPD_LEASES CLEANUP_INTERVAL AUTHORIZED_LEASE_TIME QUARANTINE_DURATION \
               WPAD_ENABLED WPAD_PORT PING_CHECK_ENABLED PING_TIMEOUT_SECONDS; do
        if ! grep -q "^${key}=" "$file"; then
            if (( ! added )); then
                cp -f "$file" "${file}.bak"
                log "INFO: backed up $file"
                log "INFO: to ${file}.bak"
            fi
            insert_before_closing_delimiter "$file" "${key}=${own_defaults[$key]}"
            added=1
        fi
    done
    (( added )) && log "INFO: added missing defaults to $file"
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
        if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
            value="${value:1:$((${#value}-2))}"
        fi
        case "$key" in
            SERVER_IP|SERV_SUBNET|SERV_BROADCAST|SERV_MASK|SERV_INI_RANGE_BLOCK|SERV_END_RANGE_BLOCK|SERV_DNS|\
            ACL_PATH|ACL_MAC_PATH|ACL_DHCP_PATH|ACL_MAC_PROXY|ACL_MAC_UNLIMITED|ACL_BLOCK_FILE|PYDHCPD_LEASES|\
            CLEANUP_INTERVAL|AUTHORIZED_LEASE_TIME|QUARANTINE_DURATION|WPAD_ENABLED|WPAD_PORT|PING_CHECK_ENABLED|\
            PING_TIMEOUT_SECONDS|DHCPDv4_CONF|DAEMON_USER|DAEMON_GROUP)
                printf -v "$key" '%s' "$value"
                ;;
            *)
                ;;
        esac
    done < "$file"
}
load_env_file "$ENV_FILE"

for _ip_var in SERVER_IP SERV_SUBNET SERV_BROADCAST SERV_INI_RANGE_BLOCK SERV_END_RANGE_BLOCK; do
    if ! [[ "${!_ip_var}" =~ $_UH_IPV4 ]]; then
        log "ERROR: $_ip_var is not a valid IPv4 address"
        log "ERROR: ('${!_ip_var}') in $ENV_FILE"
        exit 1
    fi
done
unset _ip_var
if ! [[ "$SERV_MASK" =~ $_UH_NETMASK ]]; then
    log "ERROR: SERV_MASK is not a valid netmask"
    log "ERROR: ('$SERV_MASK') in $ENV_FILE"
    exit 1
fi
if ! [[ "$SERV_DNS" =~ $_UH_DNS ]]; then
    log "ERROR: SERV_DNS is not a valid IPv4 list"
    log "ERROR: ('$SERV_DNS')"
    log "ERROR: in $ENV_FILE"
    exit 1
fi

CLEANUP_INTERVAL="${CLEANUP_INTERVAL:-60}"
if ! [[ "$CLEANUP_INTERVAL" =~ $_UH_UINT ]] || (( CLEANUP_INTERVAL == 0 )); then
    log "WARNING: CLEANUP_INTERVAL invalid"
    log "WARNING: ($CLEANUP_INTERVAL) -- using default 60"
    CLEANUP_INTERVAL=60
fi
AUTHORIZED_LEASE_TIME="${AUTHORIZED_LEASE_TIME:-2592000}"
if ! [[ "$AUTHORIZED_LEASE_TIME" =~ $_UH_UINT ]] || (( AUTHORIZED_LEASE_TIME == 0 )); then
    log "WARNING: AUTHORIZED_LEASE_TIME invalid"
    log "WARNING: ($AUTHORIZED_LEASE_TIME) -- using default 2592000"
    AUTHORIZED_LEASE_TIME=2592000
fi
QUARANTINE_DURATION="${QUARANTINE_DURATION:-60}"
if ! [[ "$QUARANTINE_DURATION" =~ $_UH_UINT ]] || (( QUARANTINE_DURATION == 0 )); then
    log "WARNING: QUARANTINE_DURATION invalid"
    log "WARNING: ($QUARANTINE_DURATION) -- using default 60"
    QUARANTINE_DURATION=60
fi
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-1}"
if ! [[ "$PING_TIMEOUT_SECONDS" =~ $_UH_UINT ]] || (( PING_TIMEOUT_SECONDS == 0 )); then
    log "WARNING: PING_TIMEOUT_SECONDS invalid"
    log "WARNING: ($PING_TIMEOUT_SECONDS) -- using default 1"
    PING_TIMEOUT_SECONDS=1
fi

# Guard: SERVER_IP must never fall inside its own block-pool range -- pydhcpd.py
# rejects this at config load, but that only surfaces after this script has
# already stopped the daemon and rewritten pydhcpd.conf. Catching it here,
# before any destructive action, avoids leaving the daemon down over a config
# mistake that could have been caught up front.
if python3 -c "
import ipaddress, sys
server = ipaddress.IPv4Address(sys.argv[1])
start = ipaddress.IPv4Address(sys.argv[2])
end = ipaddress.IPv4Address(sys.argv[3])
print('1' if start <= server <= end else '0')
" "$SERVER_IP" "$SERV_INI_RANGE_BLOCK" "$SERV_END_RANGE_BLOCK" 2>/dev/null | grep -q '^1$'; then
    log "ERROR: SERVER_IP overlaps the block-pool range"
    log "ERROR: ($SERVER_IP in $SERV_INI_RANGE_BLOCK-$SERV_END_RANGE_BLOCK)"
    log "ERROR: refusing to proceed"
    exit 1
fi

wpad_port="${WPAD_PORT:-18100}"
if ! [[ "$wpad_port" =~ $_UH_UINT ]] || (( wpad_port < 1 || wpad_port > 65535 )); then
    log "ERROR: WPAD_PORT is not a valid port"
    log "ERROR: ('$wpad_port') in $ENV_FILE"
    exit 1
fi
wpad_url="http://$SERVER_IP:$wpad_port/wpad.pac"

wpad_ready=0
if [[ "${WPAD_ENABLED:-false}" == "true" ]]; then
    if curl -fsS --noproxy '*' --max-time 5 -o /dev/null "$wpad_url"; then
        wpad_ready=1
    else
        log "WARNING: WPAD_ENABLED=true but not served:"
        log "WARNING: $wpad_url"
        log "WARNING: WPAD not activated -- set"
        log "WARNING: WPAD_ENABLED=false in $ENV_FILE"
        log "WARNING: check README"
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
        log "ERROR: pydhcpd is not running"
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
    if [ ! -f "${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}" ]; then
        log "ERROR: config file does not exist"
        log "ERROR: (${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf})"
        exit 1
    fi
    chmod 640 "${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}"
    chown root:"${DAEMON_GROUP:-pydhcpd}" "${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}"
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

# Log lines below do not carry this function's name -- they use short,
# generic phrasing instead.
dedup_acl_mac_lines() {
    local f="$1" tmp before after
    [ -f "$f" ] || return 0
    before=$(wc -l < "$f")
    tmp=$(mktemp)
    TEMP_FILES_TO_CLEAN+=("${tmp}")
    awk -F';' '
        /^a;/ {
            mac=tolower($2)
            if (mac in seen) next
            seen[mac]=1
        }
        { print }
    ' "$f" > "$tmp"
    after=$(wc -l < "$tmp")
    if (( after < before )); then
        mv "$tmp" "$f"
        chmod 600 "$f"
        log "INFO: removed $(( before - after )) duplicate lines"
        log "INFO: from $(basename "$f")"
    fi
}

validate_block_file() {
    local f="$1" n=0 line
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        [[ -z "$line" ]] && continue
        if [[ "$line" == \#* ]]; then
            # blockdhcp.txt has no comment syntax -- delete the line to unblock
            log "ERROR: malformed line $n in $(basename "$f"): $line"
            exit 1
        fi
    done < "$f"
}

verify_dhcp_service
verify_dhcp_files
verify_dhcp_config
verify_directories
initialize_empty_files
dedup_acl_mac_lines "$ACL_BLOCK_FILE"
validate_block_file "$ACL_BLOCK_FILE"
log "INFO: verification OK -- pydhcpd active, paths valid"

function is_pydhcp() {
    dhcpd="$PYDHCPD_LEASES"
    dhcp_conf="${DHCPDv4_CONF:-/etc/pydhcp/pydhcpd.conf}"
    dhcp_conf_temp=$(mktemp "/etc/pydhcp/.pydhcpd.conf.XXXXXX")
    TEMP_FILES_TO_CLEAN+=("$dhcp_conf_temp")

    # Log lines below do not carry this function's name -- they use short,
    # generic phrasing instead.
    function read_leases() {
        local temp_leases parsed=0
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
                    mac_address=$(echo "$lease_content" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' | head -1 | tr '[:upper:]' '[:lower:]')
                    ip_address=$(echo "$lease_content" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
                    host_candidate=$(echo "$lease_content" | grep -oE 'client-hostname "[^"]+"' | cut -d'"' -f2 | tr " " "_")
                    host="${host_candidate:-no_name_$(head -c100 /dev/urandom | sha1sum | head -c10)}"

                    if [[ -n "$ip_address" ]] && ! [[ "$ip_address" =~ $_UH_IPV4 ]]; then
                        log "WARNING: skipping lease with invalid IP: $ip_address"
                        ip_address=""
                    fi

                    if [[ -n "$mac_address" && -n "$ip_address" ]]; then
                        parsed=$((parsed + 1))
                        line_lease="a;$mac_address;$ip_address;$host;"

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
                            log "INFO: add $mac_address to blockdhcp"
                            log "INFO: ip=$ip_address host=${host:0:30}"
                            echo "$line_lease" >> "$ACL_BLOCK_FILE"
                        fi
                    fi
                    current_lease=""
                    lease_content=""
                fi
            fi
        done < "$dhcpd"

        local leases_kept=0
        [[ -s "$temp_leases" ]] && { leases_kept=$(grep -c '^lease ' "$temp_leases" 2>/dev/null) || true; }
        log "INFO: done (leases_kept=$leases_kept)"

        if [[ -s "$temp_leases" ]]; then
            mv -f "$temp_leases" "$dhcpd"
            chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$dhcpd"
            chmod 640 "$dhcpd"
        elif (( parsed > 0 )); then
            : > "$dhcpd"
            chown "${DAEMON_USER:-pydhcpd}":"${DAEMON_GROUP:-pydhcpd}" "$dhcpd"
            chmod 640 "$dhcpd"
        elif [[ -s "$dhcpd" ]]; then
            # Nothing was parsed at all: the file did not look like leases.
            # Truncating it here would throw away data over a parser failure.
            log "WARNING: kept 0 leases, none parsed -- untouched"
        fi
    }

    # Log lines below do not carry this function's name -- they use short,
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

        while IFS= read -r line; do
            wcstatus=$(echo "$line" | cut -d ';' -f 1)
            macsource=$(echo "$line" | cut -d ';' -f 2)
            ipsource=$(echo "$line" | cut -d ';' -f 3)
            usersource=$(echo "$line" | cut -d ';' -f 4)
            if [[ $wcstatus == "a" ]]; then
                # Validate every field before writing it into the config so an
                # ACL entry cannot inject arbitrary dhcpd directives.
                if ! [[ $macsource =~ $_UH_MAC ]]; then
                    log "WARNING: skipping entry, invalid MAC: $macsource"
                    continue
                fi
                if ! [[ "$ipsource" =~ $_UH_IPV4 ]]; then
                    log "WARNING: skipping entry, invalid IP: $ipsource"
                    continue
                fi
                if ! [[ $usersource =~ ^[A-Za-z0-9._-]{1,63}$ ]]; then
                    log "WARNING: skipping entry, invalid hostname"
                    log "WARNING: ($usersource)"
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

        {
            cut -d ';' -f 2 "$ACL_BLOCK_FILE" 2>/dev/null
            grep -h '^#a;' "$ACL_MAC_PATH"/mac-*.txt 2>/dev/null | cut -d ';' -f 2 || true
        } | grep -E "$_UH_MAC" | tr '[:upper:]' '[:lower:]' | sort -u \
          | while IFS= read -r macs; do
                printf 'subclass "blockdhcp" 1:%s;\n' "$macs" >>"$dhcp_conf_temp"
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

    # Log lines below do not carry this function's name -- they use short,
    # generic phrasing instead.
    function clean_block_list {
        local removed=0 file_temp patterns
        file_temp=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${file_temp}")
        patterns=$(mktemp)
        TEMP_FILES_TO_CLEAN+=("${patterns}")
        shopt -s nullglob
        acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
        shopt -u nullglob
        if [ ${#acl_mac_files[@]} -gt 0 ]; then
            grep -hiE '^a;[0-9a-f:]+;' "${acl_mac_files[@]}" 2>/dev/null | cut -d ";" -f2 | tr '[:upper:]' '[:lower:]' | sort -u >"$file_temp"
        else
            : >"$file_temp"
        fi

        while read -r mac_actual; do
            [ -z "$mac_actual" ] && continue
            if ! [[ "$mac_actual" =~ $_UH_MAC ]]; then
                log "WARNING: skipping malformed mac from ACL source"
                log "WARNING: ($mac_actual)"
                continue
            fi
            if grep -qiF ";${mac_actual};" "$ACL_BLOCK_FILE" 2>/dev/null; then
                log "INFO: removing $mac_actual from blockdhcp"
                log "INFO: (found in acl_mac)"
                printf ';%s;\n' "$mac_actual" >> "$patterns"
                (( removed++ )) || true
            fi
        done <"$file_temp"

        if (( removed > 0 )); then
            local _grep_rc=0 block_tmp
            block_tmp=$(mktemp)
            TEMP_FILES_TO_CLEAN+=("${block_tmp}")
            grep -viFf "$patterns" "$ACL_BLOCK_FILE" > "$block_tmp" || _grep_rc=$?
            if (( _grep_rc > 1 )); then
                log "ERROR: grep failed (rc=$_grep_rc)"
                log "ERROR: skipping update of blockdhcp"
                rm -f "$block_tmp"
            else
                chmod 600 "$block_tmp"
                mv "$block_tmp" "$ACL_BLOCK_FILE"
            fi
        fi
        rm -f "$file_temp" "$patterns"
        if (( removed > 0 )); then
            log "INFO: done (removed=$removed)"
        fi
    }

    # Log lines below do not carry this function's name -- they use short,
    # generic phrasing instead.
    function clean_acl {
        log "INFO: removing empty lines from ACL files"
        sed '/^$/d' -i "$ACL_BLOCK_FILE"
        sed '/^$/d' -i "$ACL_MAC_PROXY"
        sed '/^$/d' -i "$ACL_MAC_UNLIMITED"
    }

    function order_files_acl {
        sort -V "$ACL_BLOCK_FILE" -o "$ACL_BLOCK_FILE"
        # mac-*.txt: sorted by IP (field 3). Purely cosmetic -- update_dhcp_conf()
        # and pydhcpd.py's host{} parsing are both order-independent.
        shopt -s nullglob
        local _order_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
        shopt -u nullglob
        local _omf
        for _omf in "${_order_mac_files[@]}"; do
            sort -t';' -k3,3V "$_omf" -o "$_omf"
        done
    }

    clean_acl
    clean_block_list

    log "INFO: stopping pydhcpd"
    systemctl stop pydhcpd
    if systemctl is-active --quiet pydhcpd; then
        log "ERROR: stopping pydhcpd FAILED -- still active"
        log "ERROR: aborting before touching config/ACLs"
        exit 1
    fi
    log "INFO: stopping pydhcpd: done"
    PYDHCPD_NEEDS_RESTART=1
    log "INFO: processing leases"
    read_leases
    log "INFO: sorting ACL files"
    order_files_acl
    log "INFO: rebuilding pydhcpd.conf"
    update_dhcp_conf
    log "INFO: starting pydhcpd"
    systemctl start pydhcpd
    if ! systemctl is-active --quiet pydhcpd; then
        log "ERROR: pydhcpd failed to start after rebuild"
        log "ERROR: attempting backup config restore"
        if [ -f "${dhcp_conf}.bak" ]; then
            cp -f "${dhcp_conf}.bak" "$dhcp_conf"
            log "INFO: restored ${dhcp_conf}.bak -- retrying pydhcpd start"
            systemctl start pydhcpd
            if ! systemctl is-active --quiet pydhcpd; then
                log "ERROR: pydhcpd failed to start with backup config"
                log "ERROR: manual intervention required"
                exit 1
            else
                log "INFO: pydhcpd recovered with backup config"
            fi
        else
            log "ERROR: No backup config found"
            log "ERROR: manual intervention required"
            exit 1
        fi
    fi
    log "INFO: starting pydhcpd: done"
    PYDHCPD_NEEDS_RESTART=0
}

function duplicate() {
    local has_error=0
    shopt -s nullglob
    local acl_mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob

    if [ ${#acl_mac_files[@]} -gt 0 ]; then
        local field field_name dups dup locations
        for field in 2 3 4; do
            case $field in 2) field_name="MAC" ;; 3) field_name="IP" ;; 4) field_name="hostname" ;; esac
            if [ "$field" = 2 ]; then
                dups=$(cut -d';' -f2 "${acl_mac_files[@]}" 2>/dev/null | tr '[:upper:]' '[:lower:]' | sort | uniq -d)
            else
                dups=$(cut -d';' -f${field} "${acl_mac_files[@]}" 2>/dev/null | sort | uniq -d)
            fi
            if [[ -n "$dups" ]]; then
                while IFS= read -r dup; do
                    [[ -z "$dup" ]] && continue
                    locations=$(grep -liF ";${dup};" "${acl_mac_files[@]}" 2>/dev/null | tr '\n' ' ')
                    log "ERROR: duplicate $field_name '$dup'"
                    log "ERROR: in: $locations"
                    has_error=1
                done <<< "$dups"
            fi
        done
    fi
    if (( has_error == 0 )); then
        log "INFO: duplicate check: OK"
    fi

    shopt -s nullglob
    local mac_files=("$ACL_MAC_PATH"/mac-*.txt)
    shopt -u nullglob
    if [[ ${#mac_files[@]} -gt 0 ]]; then
        local _pool_i _pool_e _ip_n _srv_n _mask_n _net_n _bcast_n
        _pool_i=$(_ip_to_int "$SERV_INI_RANGE_BLOCK"); _pool_e=$(_ip_to_int "$SERV_END_RANGE_BLOCK")
        _srv_n=$(_ip_to_int "$SERVER_IP"); _mask_n=$(_ip_to_int "$SERV_MASK")
        _net_n=$(( $(_ip_to_int "$SERV_SUBNET") & _mask_n ))
        _bcast_n=$(( _net_n | (0xFFFFFFFF ^ _mask_n) ))
        local mac ip status
        while IFS=';' read -r status mac ip _; do
            [[ "$status" != "a" || -z "$ip" ]] && continue
            [[ "$ip" =~ $_UH_IPV4 ]] || continue
            _ip_n=$(_ip_to_int "$ip")
            if (( (_ip_n & _mask_n) != _net_n )); then
                log "ERROR: mac-*.txt IP conflict: $mac"
                log "ERROR: outside subnet ${SERV_SUBNET}/${SERV_MASK}"
                log "ERROR: move $mac inside the subnet"
                has_error=1
            elif (( _ip_n == _net_n || _ip_n == _bcast_n )); then
                log "ERROR: mac-*.txt IP conflict: $mac"
                log "ERROR: network/broadcast of ${SERV_SUBNET}/${SERV_MASK}"
                log "ERROR: move $mac to a usable address"
                has_error=1
            elif (( _ip_n == _srv_n )); then
                log "ERROR: mac-*.txt IP conflict: $mac"
                log "ERROR: same as SERVER_IP ${SERVER_IP}"
                log "ERROR: move $mac to another address"
                has_error=1
            elif (( _ip_n >= _pool_i && _ip_n <= _pool_e )); then
                log "ERROR: mac-*.txt IP conflict: $mac"
                log "ERROR: inside blockdhcp pool ${SERV_INI_RANGE_BLOCK}-${SERV_END_RANGE_BLOCK}"
                log "ERROR: move $mac outside blockdhcp"
                has_error=1
            fi
        done < <(cat "${mac_files[@]}" 2>/dev/null)
    fi

    if (( has_error == 0 )); then
        is_pydhcp
    else
        log "ERROR: ACL configuration error detected -- aborting"
        exit 1
    fi
}
duplicate

_count() { local c; c=$(grep -c '^a;' "$1" 2>/dev/null) || true; echo "${c:-0}"; }
log "INFO: blockdhcp=$(_count "$ACL_BLOCK_FILE")"
log "INFO: proxy=$(_count "$ACL_MAC_PROXY")"
log "INFO: unlimited=$(_count "$ACL_MAC_UNLIMITED")"

# End
log "pyleases done at: $(date)"
