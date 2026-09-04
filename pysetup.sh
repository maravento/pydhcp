#!/bin/bash
# maravento.com
#
################################################################################
#
# Installer / Uninstaller for pydhcpd
# Deploys all files to their correct system paths
# or removes them cleanly from the system.
#
# Usage:
# sudo bash pysetup.sh            Install
# sudo bash pysetup.sh --update   Update code only. Preserves user config
#                                 and backs up replaced files. Aborts if
#                                 pydhcp.env is missing -- run without
#                                 flags first.
# sudo bash pysetup.sh --remove   Uninstall
#
# LOG: pysetup.log, in the same directory this script is run from. Kept
# separate from /var/log/pydhcp.log (the daemon's operational log) so
# install, update and remove runs never mix with daily operation.
# Rewritten on each run.
#
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# REQUIREMENTS
# ------------------------------------------------------------------------------

# Source directory (where this script lives) -- needed by the logging block
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# logging
# The installer keeps its own log, separate from /var/log/pydhcp.log (the
# daemon's operational log) so install, update and remove runs never mix
# with daily operation. Rewritten on each run.
log_file="${script_dir}/pysetup.log"
{ > "$log_file"; } 2>/dev/null || true
pydhcp_log_file="/var/log/pydhcp.log"
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" | tee -a "$log_file" 2>/dev/null || true
}

# root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root -- abort"
    exit 1
fi

# prevent overlapping runs
script_lock="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$script_lock")
exec 200>"$script_lock"
if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -- abort"
    exit 1
fi

# dependencies
# Project-wide list: this installer verifies every package the deployed
# components need at runtime, not just the ones it invokes itself -- e.g.
# iputils-ping is used by pydhcpd.py when it cannot open a raw ICMP socket.
for dep_pkg in python3 iproute2 mawk passwd util-linux coreutils grep sed iputils-ping systemd findutils libc-bin zip cron curl; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: dependency $dep_pkg not installed -- abort"
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
UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

install_dir="/etc/pydhcp"
core_dir="${install_dir}/core"
service_file="/etc/systemd/system/pydhcpd.service"
init_file="/etc/init.d/pydhcpd"
daemon_owner="pydhcpd"

# ACL layout. Two groups, by who owns the list:
# - acl_base_dir holds the administrator's own lists (mac-*.txt), edited by hand.
# - acl_dhcp_dir holds pydhcp's own list (blockdhcp.txt), written by
#   pyleases.sh alone, so it lives under install_dir -- same arrangement uhm
#   uses for its own lists under /etc/uhm/acl.
# pydhcp.env itself is written with these already resolved -- it is parsed
# key=value (never sourced), so a "$VAR" inside it would be stored as that
# literal string, not as a path.
acl_base_dir="/etc/acl"
acl_mac_dir="${acl_base_dir}/mac"
acl_dhcp_dir="${install_dir}/acl"
acl_limited_file="${acl_mac_dir}/mac-limited.txt"
acl_unlimited_file="${acl_mac_dir}/mac-unlimited.txt"
acl_block_file="${acl_dhcp_dir}/blockdhcp.txt"

color_red='\033[0;31m'
color_green='\033[0;32m'
color_cyan='\033[0;36m'
color_yellow='\033[1;33m'
color_reset='\033[0m'

info() { echo -e "${color_cyan}INFO:${color_reset} $*"; log "INFO: $*"; }
success() { echo -e "${color_green}[OK]${color_reset} $*"; log "INFO: $*"; }
warn() { echo -e "${color_yellow}WARNING:${color_reset} $*"; log "WARNING: $*"; }
error() { echo -e "${color_red}ERROR:${color_reset} $*" >&2; log "ERROR: $*"; exit 1; }

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# --- Interactive prompts ------------------------------------------------------
ask_interface_number() {
    local prompt_text="$1" default_value="$2" target_var="$3" max_value="$4" user_answer
    while true; do
        read -rp " ${prompt_text} [1-${max_value}] [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] && (( user_answer >= 1 && user_answer <= max_value )); then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        warn "Invalid selection, try again"
    done
}

ask_ip() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer hint_text
    if [[ -n "$default_value" ]]; then
        hint_text="Default: $default_value"
    else
        hint_text="Default: 192.168.0.10"
    fi
    while true; do
        read -rp " ${prompt_text} [${hint_text}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_IPV4 ]]; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        warn "'$user_answer' is not a valid IP address."
    done
}

ask_netmask() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_NETMASK ]]; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        warn "'$user_answer' is not a valid netmask."
    done
}

# ref_start (optional): rejects an octet <= this value, for pool-end prompts.
ask_octet() {
    local prompt_text="$1" default_value="$2" target_var="$3" ref_start="${4:-}" user_answer
    while true; do
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_OCT ]] && (( user_answer >= 1 && user_answer <= 254 )); then
            if [[ -n "$ref_start" ]] && (( user_answer <= ref_start )); then
                warn "Pool end must be greater than pool start (${ref_start})"
                continue
            fi
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        warn "Invalid value, enter a number between 1 and 254"
    done
}

ask_dns() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_DNS ]]; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        warn "Invalid DNS format, try again"
    done
}

ask_number() {
    local prompt_text="$1" default_value="$2" target_var="$3" user_answer
    while true; do
        read -rp " ${prompt_text} [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] && (( user_answer >= 1 )); then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        warn "Invalid value, enter a positive integer"
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
    real_path=$(realpath "$source_file" 2>/dev/null) || error "cannot resolve source path -- abort"
    [[ "$real_path" == "$script_dir"/* ]] || error "source file outside the repo -- abort"
    [ -f "$real_path" ] || error "source is not a regular file -- abort"
    [ -s "$real_path" ] || error "source file is empty -- abort"
    local file_mode file_owner
    file_mode=$(stat -c '%a' "$real_path")
    file_owner=$(stat -c '%u' "$real_path")
    if (( (8#$file_mode & 8#002) != 0 )); then
        { echo -e "${color_red}ERROR:${color_reset} world-writable source file (mode $file_mode)" >&2; error "$source_file -- abort"; }
    fi
    if [[ "$file_owner" != "0" && "$file_owner" != "${SUDO_UID:-$(id -u)}" ]]; then
        { echo -e "${color_red}ERROR:${color_reset} source file owned by unexpected uid $file_owner" >&2; error "$source_file -- abort"; }
    fi
}

# Start
log "pysetup start..."

# ------------------------------------------------------------------------------
# REMOVE
# ------------------------------------------------------------------------------

if [[ "${1:-}" == "--remove" ]]; then
    echo ""
    warn "This removes pydhcp completely: $install_dir,"
    warn "the service, the init.d wrapper, the log and"
    warn "the Webmin module."
    warn "Run tools/bkstack.sh first if you want a backup."
    warn "Package dependencies are NOT removed."
    echo ""
    confirm "Proceed with uninstall? This cannot be undone." "n" \
        || { info "Aborted by user."; exit 0; }

    info "Stopping and disabling pydhcpd service..."
    systemctl stop pydhcpd 2>/dev/null || true
    systemctl disable pydhcpd 2>/dev/null || true

    info "Removing system files..."
    rm -f "$service_file"
    rm -f "$init_file"
    rm -f /etc/logrotate.d/pydhcp
    rm -f /var/log/pydhcp.log
    rm -f /etc/logrotate.d/pydhcpd
    rm -f /var/log/pydhcpd.log

    if [ -x "$install_dir/tools/bkstack.sh" ]; then
        info "Removing bkstack.sh cron entry ..."
        "$install_dir/tools/bkstack.sh" uninstall || true
    fi

    if [ -x "$install_dir/tools/pywebmin.sh" ]; then
        info "Removing Webmin module ..."
        "$install_dir/tools/pywebmin.sh" uninstall || true
    fi

    [[ "$install_dir" == "/etc/pydhcp" ]] || error "unexpected install dir: $install_dir -- abort"

    # Everything under install_dir goes, including the config and the block
    # list: uninstalling means removing the project. Only bak/ survives, and
    # tools/bkstack.sh is the way to keep a copy of anything else.
    info "Removing $install_dir ..."
    find "$install_dir" -mindepth 1 -maxdepth 1 ! -name bak -exec rm -rf {} +

    info "Removing system user and group $daemon_owner ..."
    userdel "$daemon_owner" 2>/dev/null || warn "User $daemon_owner not found or already removed"
    groupdel "$daemon_owner" 2>/dev/null || true

    systemctl daemon-reload

    success "pydhcpd has been removed from the system."
    log "pysetup done at: $(date)"
    rm -f "$pydhcp_log_file"
    exit 0
fi

# ------------------------------------------------------------------------------
# UPDATE
# ------------------------------------------------------------------------------

if [[ "${1:-}" == "--update" ]]; then
    if [ ! -d "$install_dir" ]; then
        { echo -e "${color_red}ERROR:${color_reset} no installation found in $install_dir" >&2; error "run without --update to install first -- abort"; }
    fi
    if [ ! -f "$install_dir/pydhcp.env" ]; then
        echo -e "${color_red}ERROR:${color_reset} $install_dir/pydhcp.env not found" >&2
        echo -e "${color_red}ERROR:${color_reset} it pre-dates config persistence" >&2
        error "run 'pysetup.sh --remove' then reinstall -- abort"
    fi
    if [ ! -d "$install_dir/tools" ]; then
        echo -e "${color_red}ERROR:${color_reset} $install_dir/tools not found" >&2
        echo -e "${color_red}ERROR:${color_reset} unexpected state for an existing install" >&2
        error "run 'pysetup.sh --remove' then reinstall -- abort"
    fi

    if [ -x "$install_dir/tools/bkstack.sh" ]; then
        info "Creating backup with bkstack.sh ..."
        "$install_dir/tools/bkstack.sh" || warn "backup failed, continuing -- alert"
    else
        warn "bkstack.sh not found, no backup -- alert"
    fi

    info "Stopping pydhcpd service..."
    systemctl stop pydhcpd 2>/dev/null || true

    info "Updating pydhcpd.py ..."
    verify_source "$script_dir/core/pydhcpd.py"
    cp "$script_dir/core/pydhcpd.py" "$core_dir/pydhcpd.py"
    chown root:root "$core_dir/pydhcpd.py"
    chmod 755 "$core_dir/pydhcpd.py"

    info "Updating systemd unit ..."
    verify_source "$script_dir/service/pydhcpd.service"
    cp "$script_dir/service/pydhcpd.service" "$service_file"
    chown root:root "$service_file"
    chmod 644 "$service_file"

    info "Updating init.d wrapper ..."
    verify_source "$script_dir/init.d/pydhcpd"
    cp "$script_dir/init.d/pydhcpd" "$init_file"
    chown root:root "$init_file"
    chmod 755 "$init_file"

    if [ -f "$script_dir/tools/pyleases.sh" ]; then
        info "Updating tools/pyleases.sh ..."
        verify_source "$script_dir/tools/pyleases.sh"
        cp "$script_dir/tools/pyleases.sh" "$install_dir/tools/pyleases.sh"
        chown root:root "$install_dir/tools/pyleases.sh"
        chmod 755 "$install_dir/tools/pyleases.sh"
    fi

    if [ -f "$script_dir/tools/bkstack.sh" ]; then
        info "Updating tools/bkstack.sh ..."
        verify_source "$script_dir/tools/bkstack.sh"
        cp "$script_dir/tools/bkstack.sh" "$install_dir/tools/bkstack.sh"
        chown root:root "$install_dir/tools/bkstack.sh"
        chmod 755 "$install_dir/tools/bkstack.sh"
    fi

    if [ -f "$script_dir/tools/pywebmin.sh" ]; then
        info "Updating tools/pywebmin.sh ..."
        verify_source "$script_dir/tools/pywebmin.sh"
        cp "$script_dir/tools/pywebmin.sh" "$install_dir/tools/pywebmin.sh"
        chown root:root "$install_dir/tools/pywebmin.sh"
        chmod 755 "$install_dir/tools/pywebmin.sh"
    fi

    info "Consolidating logs into $pydhcp_log_file ..."
    if [ -f /var/log/pydhcpd.log ]; then
        cat /var/log/pydhcpd.log >> "$pydhcp_log_file"
        rm -f /var/log/pydhcpd.log
    fi
    rm -f /etc/logrotate.d/pydhcpd
    [ -f "$pydhcp_log_file" ] || touch "$pydhcp_log_file"
    chown "$daemon_owner":"$daemon_owner" "$pydhcp_log_file"
    chmod 640 "$pydhcp_log_file"
    cat > /etc/logrotate.d/pydhcp << 'EOF'
/var/log/pydhcp.log {
    daily
    rotate 4
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

    systemctl daemon-reload
    if ! systemctl start pydhcpd; then
        { echo -e "${color_red}ERROR:${color_reset} pydhcpd failed to start after update" >&2; error "check it with: journalctl -u pydhcpd -n 50 -- abort"; }
    fi

    echo ""
    success "pydhcpd updated. Backups in /etc/bak"
    info "$core_dir/pydhcpd.conf unchanged"
    info "$install_dir/pydhcp.env unchanged"
    info "$core_dir/pydhcpd.leases unchanged"
    warn "WPAD/option 252 is set by WPAD_ENABLED,"
    warn "in pydhcp.env, not by editing pyleases.sh."
    warn "This update does not change it."
    echo ""
    log "pysetup done at: $(date)"
    exit 0
fi

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------

if [ -f "$core_dir/pydhcpd.py" ]; then
    echo -e "${color_red}ERROR:${color_reset} pydhcpd is already installed at $install_dir." >&2
    error "use --update or --remove instead -- abort"
fi

# Detect and select network interface
echo ""
info "Available network interfaces:"
mapfile -t iface_list < <(ip -br link show | awk '$1 != "lo" {sub(/@.*/, "", $1); print $1}')
if [[ ${#iface_list[@]} -eq 0 ]]; then
    error "no network interfaces found -- abort"
fi
for iface_index in "${!iface_list[@]}"; do
    iface_state=$(ip -br link show "${iface_list[$iface_index]}" | awk '{print $2}')
    printf " [%d] %s (%s)\n" "$((iface_index+1))" "${iface_list[$iface_index]}" "$iface_state"
done
echo ""
ask_interface_number "Select interface number" "1" iface_choice "${#iface_list[@]}"
iface_selected="${iface_list[$((iface_choice-1))]}"
info "Using interface: $iface_selected"

# DHCP server IP
echo ""
default_server_ip=$(ip -4 -br addr show "$iface_selected" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
ask_ip "Enter DHCP server IP address" "$default_server_ip" server_ip_answer
info "Server IP: $server_ip_answer"

# Netmask
echo ""
ask_netmask "Enter netmask" "255.255.255.0" netmask_answer
info "Netmask: $netmask_answer"

# Calculate network values from server_ip_answer and netmask_answer using python3
local_subnet=$(python3 -c "
import ipaddress, sys
local_network = ipaddress.IPv4Network(f'{sys.argv[1]}/{sys.argv[2]}', strict=False)
print(local_network.network_address)
" "$server_ip_answer" "$netmask_answer")
local_broadcast=$(python3 -c "
import ipaddress, sys
local_network = ipaddress.IPv4Network(f'{sys.argv[1]}/{sys.argv[2]}', strict=False)
print(local_network.broadcast_address)
" "$server_ip_answer" "$netmask_answer")
local_net_base=$(echo "$local_subnet" | cut -d. -f1-3)
info "Subnet: $local_subnet"
info "Network base: $local_net_base"
info "Broadcast: $local_broadcast"

# Pool range
echo ""
while true; do
    ask_octet "Enter pool start (last octet)" "220" pool_start_answer
    ask_octet "Enter pool end (last octet)" "235" pool_end_answer "$pool_start_answer"
    if python3 -c "
import ipaddress, sys
local_network = ipaddress.IPv4Network(f'{sys.argv[1]}/{sys.argv[2]}', strict=False)
pool_start = ipaddress.IPv4Address(f'{sys.argv[3]}.{sys.argv[4]}')
pool_end = ipaddress.IPv4Address(f'{sys.argv[3]}.{sys.argv[5]}')
sys.exit(0 if pool_start in local_network and pool_end in local_network else 1)
" "$local_subnet" "$netmask_answer" "$local_net_base" "$pool_start_answer" "$pool_end_answer"; then
        break
    fi
    { warn "pool ${local_net_base}.${pool_start_answer}-${pool_end_answer} is outside the subnet"; warn "subnet is ${local_subnet}/${netmask_answer}, try again"; }
done
info "Pool range: ${local_net_base}.${pool_start_answer} -> ${local_net_base}.${pool_end_answer}"

# Guard: server_ip_answer must never fall inside its own pool range -- pydhcpd.py
# rejects this at config load, but that only surfaces after this script has
# already created the user, directories, and systemd unit. Catching it here,
# before any of that, avoids leaving the system half-configured over a
# config mistake that could have been caught up front.
if python3 -c "
import ipaddress, sys
server_ip = ipaddress.IPv4Address(sys.argv[1])
pool_start = ipaddress.IPv4Address(sys.argv[2])
pool_end = ipaddress.IPv4Address(sys.argv[3])
print('1' if pool_start <= server_ip <= pool_end else '0')
" "$server_ip_answer" "${local_net_base}.${pool_start_answer}" "${local_net_base}.${pool_end_answer}" 2>/dev/null | grep -q '^1$'; then
    { echo -e "${color_red}ERROR:${color_reset} server IP $server_ip_answer overlaps the pool range" >&2; echo -e "${color_red}ERROR:${color_reset} pool: ${local_net_base}.${pool_start_answer}-${local_net_base}.${pool_end_answer}" >&2; error "choose a server IP outside the pool -- abort"; }
fi

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
for source_file in core/pydhcpd.py core/pydhcpd.conf service/pydhcpd.service init.d/pydhcpd; do
    [ -f "$script_dir/$source_file" ] || { echo -e "${color_red}ERROR:${color_reset} missing source file: $source_file" >&2; error "run pysetup.sh from the project directory -- abort"; }
done

# Create system group and user
if ! getent group "$daemon_owner" &>/dev/null; then
    info "Creating system group: $daemon_owner"
    groupadd --system "$daemon_owner"
else
    warn "Group $daemon_owner already exists, skipping"
fi

if ! id "$daemon_owner" &>/dev/null; then
    info "Creating system user: $daemon_owner"
    useradd --system --no-create-home --shell /bin/false --gid "$daemon_owner" --comment "Python DHCP Daemon" "$daemon_owner"
else
    warn "User $daemon_owner already exists, skipping"
fi

# Create install directory
info "Creating $install_dir ..."
mkdir -p "$install_dir"
chown root:"$daemon_owner" "$install_dir"
chmod 770 "$install_dir"
mkdir -p "$core_dir"
chown root:"$daemon_owner" "$core_dir"
chmod 770 "$core_dir"

# Deploy daemon and config files
info "Deploying pydhcpd.py ..."
verify_source "$script_dir/core/pydhcpd.py"
cp "$script_dir/core/pydhcpd.py" "$core_dir/pydhcpd.py"
chown root:root "$core_dir/pydhcpd.py"
chmod 755 "$core_dir/pydhcpd.py"

# Deploy pydhcpd.conf (preserved on update -- never overwritten)
if [ -f "$core_dir/pydhcpd.conf" ]; then
    { warn "pydhcpd.conf already exists in $install_dir"; warn "static hosts and blocked MACs kept"; warn "network parameters updated with your answers"; }
else
    info "Deploying pydhcpd.conf ..."
    verify_source "$script_dir/core/pydhcpd.conf"
    cp "$script_dir/core/pydhcpd.conf" "$core_dir/pydhcpd.conf"
fi
chown root:"$daemon_owner" "$core_dir/pydhcpd.conf"
chmod 640 "$core_dir/pydhcpd.conf"

# Create pydhcp's own ACL directories/files (preserved on update -- never
# overwritten). These lists are only consumed by the optional pyleases.sh
# tool, but are created here unconditionally so their paths can be recorded
# in pydhcp.env from the start -- not deferred until pyleases.sh first runs.
mkdir -p "$acl_mac_dir" "$acl_dhcp_dir"
chmod 700 "$acl_mac_dir" "$acl_dhcp_dir"

if [ ! -f "$acl_block_file" ]; then
    verify_source "$script_dir/acl/blockdhcp.txt"
    cp "$script_dir/acl/blockdhcp.txt" "$acl_block_file"
    chmod 600 "$acl_block_file"
    chown root:root "$acl_block_file"
fi

for source_file in "$acl_limited_file" "$acl_unlimited_file"; do
    if [ ! -f "$source_file" ]; then
        touch "$source_file"
        chmod 600 "$source_file"
        chown root:root "$source_file"
    fi
done
info "ACL directories/files present in $acl_base_dir"

# Create pydhcp.env (preserved on update -- never overwritten). Single source
# of truth for network, ACL-path and daemon-defaults values: pyleases.sh and
# any other future script read these from here instead of asking again,
# adding only their own keys if missing.
if [ -f "$install_dir/pydhcp.env" ]; then
    warn "pydhcp.env already exists, not overwritten -- skip"
    info "interface not changed, keeping the value in pydhcp.env"
else
    info "Creating pydhcp.env ..."
    cat > "$install_dir/pydhcp.env" <<ENVEOF
# =============================================================================
# PYDHCP
# /etc/pydhcp/pydhcp.env
# =============================================================================
# -- Daemon bootstrap (/etc/default/isc-dhcp-server migration) ----------------
DHCPDv4_CONF=/etc/pydhcp/core/pydhcpd.conf
DHCPDv4_BIN=/usr/bin/python3
DHCPDv4_SCRIPT=/etc/pydhcp/core/pydhcpd.py
PYDHCPD_LEASES=$core_dir/pydhcpd.leases
INTERFACESv4="$iface_selected"
DAEMON_USER="pydhcpd"
DAEMON_GROUP="pydhcpd"
# -- Network values (chosen by the administrator during install) --------------
SERVER_IP=$server_ip_answer
SERV_SUBNET=$local_subnet
SERV_BROADCAST=$local_broadcast
SERV_MASK=$netmask_answer
SERV_INI_RANGE_BLOCK=${local_net_base}.${pool_start_answer}
SERV_END_RANGE_BLOCK=${local_net_base}.${pool_end_answer}
SERV_DNS=$dns_answer
# -- ACL paths, administrator's own lists (edited by hand) --------------------
ACL_PATH=$acl_base_dir
ACL_MAC_PATH=$acl_mac_dir
ACL_MAC_LIMITED=$acl_limited_file
ACL_MAC_UNLIMITED=$acl_unlimited_file
# -- ACL paths, pydhcp's own list (written by pyleases.sh) --------------------
ACL_DHCP_PATH=$acl_dhcp_dir
ACL_BLOCK_FILE=$acl_block_file
# -- Lease timers (pyleases.sh -> pydhcpd.conf pool/subnet directives) --------
CLEANUP_INTERVAL=$cleanup_answer
AUTHORIZED_LEASE_TIME=2592000
QUARANTINE_DURATION=60
# -- Optional features (pyleases.sh -> pydhcpd.conf wpad/ping-check) ----------
WPAD_ENABLED=$wpad_detected
WPAD_PORT=$wpad_port_value
PING_CHECK_ENABLED=$ping_check_value
PING_TIMEOUT_SECONDS=1
# -- pydhcp-only features (no isc-dhcp-server equivalent) ---------------------
PING_CACHE_TTL_SECONDS=120
RATE_LIMIT_WINDOW_SECONDS=60
RATE_LIMIT_MAX=5
RESERVATION_TTL_SECONDS=30
# =============================================================================
ENVEOF
    info "Network, ACL and daemon defaults set in pydhcp.env"
fi
chown root:"$daemon_owner" "$install_dir/pydhcp.env"
chmod 640 "$install_dir/pydhcp.env"

# Apply network parameters to pydhcpd.conf
conf_tmp=$(mktemp "$install_dir/.pydhcpd.conf.XXXXXX") || error "cannot create temp file -- abort"
cp -f "$core_dir/pydhcpd.conf" "$conf_tmp"
sed -i "s|^server-identifier .*|server-identifier ${server_ip_answer};|" "$conf_tmp"
sed -i "s|subnet [0-9.]* netmask [0-9.]*|subnet ${local_subnet} netmask ${netmask_answer}|" "$conf_tmp"
sed -i "s|option routers .*;|option routers ${server_ip_answer};|" "$conf_tmp"
sed -i "s|option broadcast-address .*;|option broadcast-address ${local_broadcast};|" "$conf_tmp"
sed -i "s|range [0-9.]* [0-9.]*;|range ${local_net_base}.${pool_start_answer} ${local_net_base}.${pool_end_answer};|" "$conf_tmp"
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
    info "Creating empty pydhcpd.leases ..."
    touch "$core_dir/pydhcpd.leases"
    chown "$daemon_owner":"$daemon_owner" "$core_dir/pydhcpd.leases"
    chmod 640 "$core_dir/pydhcpd.leases"
fi

# Deploy tools
info "Creating $install_dir/tools ..."
mkdir -p "$install_dir/tools"
chown root:root "$install_dir/tools"
chmod 755 "$install_dir/tools"

for tool_script in pyleases.sh pywebmin.sh bkstack.sh; do
    if [ -f "$script_dir/tools/$tool_script" ]; then
        info "Deploying tools/$tool_script ..."
        verify_source "$script_dir/tools/$tool_script"
        cp "$script_dir/tools/$tool_script" "$install_dir/tools/$tool_script"
        chown root:root "$install_dir/tools/$tool_script"
        chmod 755 "$install_dir/tools/$tool_script"
    fi
done

if [ -x "$install_dir/tools/bkstack.sh" ]; then
    info "Registering bkstack.sh monthly cron entry ..."
    "$install_dir/tools/bkstack.sh" install || warn "cron entry not registered -- alert"
fi

# Deploy systemd service
info "Deploying systemd unit ..."
verify_source "$script_dir/service/pydhcpd.service"
cp "$script_dir/service/pydhcpd.service" "$service_file"
chown root:root "$service_file"
chmod 644 "$service_file"

# Deploy init.d wrapper
info "Deploying init.d wrapper ..."
verify_source "$script_dir/init.d/pydhcpd"
cp "$script_dir/init.d/pydhcpd" "$init_file"
chown root:root "$init_file"
chmod 755 "$init_file"

# Create log file if it does not exist, ensure correct ownership/permissions
[ -f "$pydhcp_log_file" ] || touch "$pydhcp_log_file"
chown "$daemon_owner":"$daemon_owner" "$pydhcp_log_file"
chmod 640 "$pydhcp_log_file"

# Deploy logrotate config
info "Deploying logrotate config ..."
rm -f /etc/logrotate.d/pydhcpd
cat > /etc/logrotate.d/pydhcp << 'EOF'
/var/log/pydhcp.log {
    daily
    rotate 4
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
info "Enabling and starting pydhcpd ..."
systemctl daemon-reload
systemctl enable --force pydhcpd
if ! systemctl start pydhcpd; then
    { echo -e "${color_red}ERROR:${color_reset} pydhcpd failed to start" >&2; error "check it with: journalctl -u pydhcpd -n 50 -- abort"; }
fi

echo ""
success "pydhcpd installed and running."
echo ""
info "Configuration : $core_dir/pydhcpd.conf"
info "Interface : $(grep INTERFACESv4 "$install_dir/pydhcp.env" | cut -d= -f2 | tr -d '"')"
info "Leases : $core_dir/pydhcpd.leases"
info "Logs : journalctl -u pydhcpd -f"
echo ""
info "To remove : sudo bash pysetup.sh --remove"

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "pysetup done at: $(date)"
