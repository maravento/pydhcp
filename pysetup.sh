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
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: dependency '$dep_pkg' is not installed -abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

# validation -- one variable per thing validated; use directly with =~
UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
UH_UINT='^(0|[1-9][0-9]*)$'

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

info() { log "INFO: $*"; }
warn() { log "WARNING: $*"; }
err()  { log "ERROR: $*"; }
abort() { err "$*"; exit 1; }

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# INTERACTIVE PROMPTS
# Each one asks for a value, validates it and repeats until it is correct
ask_interface_number() {
    local prompt_text="$1" default_value="$2" target_var="$3" max_value="$4" user_answer
    while true; do
        read -rp " ${prompt_text} [1-${max_value}] [Default: ${default_value}]: " user_answer
        user_answer="${user_answer:-$default_value}"
        if [[ "$user_answer" =~ $UH_UINT ]] \
           && [ "${#user_answer}" -le "${#max_value}" ] \
           && [ "$user_answer" -ge 1 ] && [ "$user_answer" -le "$max_value" ]; then
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "Invalid selection, try again -retry"
    done
}

list_interfaces() {
    local iface_index iface_state iface_ip
    for iface_index in "${!iface_list[@]}"; do
        iface_state=$(ip -br link show "${iface_list[$iface_index]}" | awk '{print $2}')
        iface_ip=$(ip -4 -o addr show dev "${iface_list[$iface_index]}" 2>/dev/null | awk '{print $4}' | paste -sd' ')
        printf " [%d] %s (%s, %s)\n" "$((iface_index+1))" "${iface_list[$iface_index]}" "$iface_state" "${iface_ip:-no IPv4}"
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
        info "'$user_answer' is not a valid netmask -retry"
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
                info "Pool end must be greater than pool start (${ref_start}) -retry"
                continue
            fi
            printf -v "$target_var" '%s' "$user_answer"
            break
        fi
        info "Invalid value, enter a number between 1 and 254 -retry"
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
        info "Invalid DNS format, try again -retry"
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
            log "pysetup done at: $(date '+%Y-%m-%d %H:%M:%S')"
            exit 0
        }

    echo ""
    echo "Final confirmation required"
    echo "Type word YES (uppercase) to remove pydhcp:"
    echo ""
    read -rp " > " confirm_answer
    if [[ "$confirm_answer" != "YES" ]]; then
        info "Aborted by user"
        log "pysetup done at: $(date '+%Y-%m-%d %H:%M:%S')"
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

    log "Stopping and disabling pydhcpd service..."
    systemctl stop pydhcpd 2>/dev/null || true
    systemctl disable pydhcpd 2>/dev/null || true

    log "Removing system files..."
    rm -f "$service_file"
    rm -f "$init_file"
    rm -f /etc/logrotate.d/pydhcp
    rm -f /var/log/pydhcp.log
    rm -f /etc/logrotate.d/pydhcpd
    rm -f /var/log/pydhcpd.log

    if [ -x "$install_dir/tools/pybk.sh" ]; then
        "$install_dir/tools/pybk.sh" --uninstall || true
    fi

    if [ -x "$install_dir/tools/pywebmin.sh" ]; then
        log "Removing Webmin module ..."
        "$install_dir/tools/pywebmin.sh" --uninstall || true
    fi

    [[ "$install_dir" == "/etc/pydhcp" ]] || abort "unexpected install dir: $install_dir -abort"

    # Everything under install_dir goes, including the config and the block
    # list: uninstalling means removing the project. tools/pybk.sh is the
    # way to keep a copy, and it writes to /etc/bak, outside this directory.
    log "Removing $install_dir ..."
    rm -rf "$install_dir"

    log "Removing system user and group $daemon_owner ..."
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
    if [ ! -d "$install_dir" ]; then
        { err "no installation found in $install_dir"; abort "use --install to install first -abort"; }
    fi
    if [ ! -f "$install_dir/pydhcp.env" ]; then
        err "pydhcp.env not found, pre-dates config persistence"
        abort "run 'pysetup.sh --uninstall' then reinstall -abort"
    fi
    if [ ! -d "$install_dir/tools" ]; then
        err "$install_dir/tools not found (unexpected state)"
        abort "run 'pysetup.sh --uninstall' then reinstall -abort"
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

    systemctl stop pydhcpd 2>/dev/null || true
    info "pydhcpd stopped for update"

    verify_source "$script_dir/core/pydhcpd.py"
    cp "$script_dir/core/pydhcpd.py" "$core_dir/pydhcpd.py"
    chown root:root "$core_dir/pydhcpd.py"
    chmod 755 "$core_dir/pydhcpd.py"
    info "updated core/pydhcpd.py"

    verify_source "$script_dir/service/pydhcpd.service"
    cp "$script_dir/service/pydhcpd.service" "$service_file"
    chown root:root "$service_file"
    chmod 644 "$service_file"
    info "updated pydhcpd.service"

    verify_source "$script_dir/init.d/pydhcpd"
    cp "$script_dir/init.d/pydhcpd" "$init_file"
    chown root:root "$init_file"
    chmod 755 "$init_file"
    info "updated init.d/pydhcpd"

    verify_source "$script_dir/tools/pydhcpenv.sh"
    install -m 644 -o root -g root "$script_dir/tools/pydhcpenv.sh" "$install_dir/tools/pydhcpenv.sh"
    info "updated tools/pydhcpenv.sh"

    if [ -f "$script_dir/tools/pyleases.sh" ]; then
        verify_source "$script_dir/tools/pyleases.sh"
        cp "$script_dir/tools/pyleases.sh" "$install_dir/tools/pyleases.sh"
        chown root:root "$install_dir/tools/pyleases.sh"
        chmod 755 "$install_dir/tools/pyleases.sh"
        info "updated tools/pyleases.sh"
    fi

    if [ -f "$script_dir/tools/pybk.sh" ]; then
        verify_source "$script_dir/tools/pybk.sh"
        cp "$script_dir/tools/pybk.sh" "$install_dir/tools/pybk.sh"
        chown root:root "$install_dir/tools/pybk.sh"
        chmod 755 "$install_dir/tools/pybk.sh"
        info "updated tools/pybk.sh"
    fi

    if [ -f "$script_dir/tools/pywebmin.sh" ]; then
        verify_source "$script_dir/tools/pywebmin.sh"
        cp "$script_dir/tools/pywebmin.sh" "$install_dir/tools/pywebmin.sh"
        chown root:root "$install_dir/tools/pywebmin.sh"
        chmod 755 "$install_dir/tools/pywebmin.sh"
        info "updated tools/pywebmin.sh"
    fi

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
    info "updated /etc/logrotate.d/pydhcp"
    info "logs consolidated into $pydhcp_log_file"

    systemctl daemon-reload
    if ! systemctl start pydhcpd; then
        { err "pydhcpd failed to start after update"; abort "check it with: journalctl -u pydhcpd -n 50 -abort"; }
    fi

    info "pydhcpd updated. Backups in /etc/bak"
    info "$core_dir/pydhcpd.conf unchanged"
    info "$install_dir/pydhcp.env unchanged"
    info "$core_dir/pydhcpd.leases unchanged"
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
    echo ""
    info "Available network interfaces:"
    mapfile -t iface_list < <(ip -br link show | awk '$1 != "lo" {sub(/@.*/, "", $1); print $1}')
    if [[ ${#iface_list[@]} -eq 0 ]]; then
        abort "no network interfaces found -abort"
    fi

    # LAN interface -- a wrapper installer that already resolved it (e.g. uhm)
    # can supply it directly, so pydhcp does not ask again for the same value.
    if [ -n "${PYDHCP_LAN_IFACE:-}" ]; then
        ip link show "$PYDHCP_LAN_IFACE" &>/dev/null \
            || abort "PYDHCP_LAN_IFACE='$PYDHCP_LAN_IFACE' not found -abort"
        iface_selected="$PYDHCP_LAN_IFACE"
        info "Using interface: $iface_selected (from caller)"
    else
        list_interfaces
        echo ""
        ask_interface_number "Select LAN interface number" "1" iface_choice "${#iface_list[@]}"
        iface_selected="${iface_list[$((iface_choice-1))]}"
        info "Using interface: $iface_selected"
    fi

    # DHCP server IP -- derived directly from the interface already chosen
    # above (it was listed with its IP in "Available network interfaces"),
    # so there's no need to ask for it again.
    echo ""
    mapfile -t iface_ips < <(ip -4 -o addr show dev "$iface_selected" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    case "${#iface_ips[@]}" in
        0)
            abort "interface has no IPv4 address -abort"
            ;;
        1)
            server_ip_answer="${iface_ips[0]}"
            info "Server IP: $server_ip_answer (from $iface_selected)"
            ;;
        *)
            echo " Interface '$iface_selected' has multiple IPv4 addresses:"
            select server_ip_answer in "${iface_ips[@]}"; do
                [ -n "$server_ip_answer" ] && break
            done
            info "Server IP: $server_ip_answer"
            ;;
    esac

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
        info "DHCP pool ${local_net_base}.${pool_start_answer}-${local_net_base}.${pool_end_answer}"
        info "DHCP pool is outside the selected subnet -retry"
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
        err "DHCP pool ${local_net_base}.${pool_start_answer}-${local_net_base}.${pool_end_answer}"
        abort "Invalid DHCP pool: SERVER_IP is inside -abort"
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

    # WAN interface -- asked last and in its own block, so a wrapper installer can
    # supply it without shifting the questions above. pydhcp does not use this
    # value: it is recorded in pydhcp.env for the projects that do.
    echo ""
    if [ -n "${PYDHCP_WAN_IFACE:-}" ]; then
        ip link show "$PYDHCP_WAN_IFACE" &>/dev/null \
            || abort "PYDHCP_WAN_IFACE='$PYDHCP_WAN_IFACE' not found -abort"
        wan_iface_answer="$PYDHCP_WAN_IFACE"
        info "WAN interface: $wan_iface_answer (from caller)"
    else
        info "WAN interface (one facing internet):"
        list_interfaces
        echo ""
        wan_default=1
        wan_detected=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
        for iface_index in "${!iface_list[@]}"; do
            if [[ "${iface_list[$iface_index]}" == "$wan_detected" ]]; then
                wan_default=$((iface_index+1))
                break
            fi
        done
        unset iface_index
        ask_interface_number "Select WAN interface number" "$wan_default" wan_choice "${#iface_list[@]}"
        wan_iface_answer="${iface_list[$((wan_choice-1))]}"
        info "WAN interface: $wan_iface_answer"
    fi

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
    mkdir -p "$acl_mac_dir" "$acl_dhcp_dir"
    chmod 700 "$acl_mac_dir" "$acl_dhcp_dir"

    for source_file in "$acl_block_file" "$acl_limited_file" "$acl_unlimited_file"; do
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
        info "pydhcp.env already exists, not overwritten -skip"
        info "interface not changed, keeping value in pydhcp.env"
    else
        log "Creating pydhcp.env ..."
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
SERV_INI_RANGE_BLOCK=${local_net_base}.${pool_start_answer}
SERV_END_RANGE_BLOCK=${local_net_base}.${pool_end_answer}
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
BACKUP_DIR=/etc/bak/pydhcp
# =============================================================================

# =============================================================================
# WAN
# =============================================================================
WAN_IFACE=$wan_iface_answer
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
        log "Creating empty pydhcpd.leases ..."
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

    if [ -x "$install_dir/tools/pybk.sh" ]; then
        "$install_dir/tools/pybk.sh" --install || warn "pybk.sh: monthly backup setup failed -alert"
    fi

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
    log "Enabling and starting pydhcpd ..."
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
        echo "WAN iface : $(grep '^WAN_IFACE=' "$install_dir/pydhcp.env" | cut -d= -f2-)"
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
log "pysetup start..."

case "${1:-}" in
    --install) do_install ;;
    --update) do_update ;;
    --uninstall) do_uninstall ;;
    --status) do_status ;;
    "") show_menu ;;
    -h|--help) usage ;;
    *)
        err "unknown option $1 -abort"
        usage
        exit 1
        ;;
esac

log "pysetup done at: $(date '+%Y-%m-%d %H:%M:%S')"
