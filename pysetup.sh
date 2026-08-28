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
# install, update and remove runs never mix with daily operation. Appended
# across runs. Not covered by logrotate; empty it by hand when needed:
# truncate -s 0 pysetup.log
#
################################################################################

set -euo pipefail

# Source directory (where this script lives) -- needed by the logging block
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# logging
# The installer keeps its own log, separate from /var/log/pydhcp.log (the
# daemon's operational log) so install, update and remove runs never mix
# with daily operation. Appended across runs, so an install can be compared
# against the updates that followed it. Not covered by logrotate; empty it
# by hand when needed: truncate -s 0 pysetup.log
LOG_FILE="${SCRIPT_DIR}/pysetup.log"
PYDHCP_LOG_FILE="/var/log/pydhcp.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$LOG_FILE" 2>/dev/null || true
}

## root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root -- abort"
    exit 1
fi

# prevent overlapping runs
SCRIPT_LOCK="/var/lock/$(basename "$0" .sh).lock"
(umask 077; : >> "$SCRIPT_LOCK")
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    log "ERROR: script $(basename "$0") is already running -- abort"
    exit 1
fi

# DEPENDENCIES
# Project-wide list: this installer verifies every package the deployed
# components need at runtime, not just the ones it invokes itself -- e.g.
# iputils-ping is used by pydhcpd.py when it cannot open a raw ICMP socket.
for dep in python3 iproute2 mawk passwd util-linux coreutils grep sed iputils-ping systemd findutils libc-bin zip cron; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: dependency $dep not installed -- abort"
        exit 1
    fi
done

# VALIDATION -- one variable per thing validated; use directly with =~
_UH_OCT='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
_UH_IPV4='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])$'
_UH_CIDR='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])/(3[0-2]|[12][0-9]|[0-9])$'
_UH_NETMASK='^(0\.0\.0\.0|128\.0\.0\.0|192\.0\.0\.0|224\.0\.0\.0|240\.0\.0\.0|248\.0\.0\.0|252\.0\.0\.0|254\.0\.0\.0|255\.0\.0\.0|255\.128\.0\.0|255\.192\.0\.0|255\.224\.0\.0|255\.240\.0\.0|255\.248\.0\.0|255\.252\.0\.0|255\.254\.0\.0|255\.255\.0\.0|255\.255\.128\.0|255\.255\.192\.0|255\.255\.224\.0|255\.255\.240\.0|255\.255\.248\.0|255\.255\.252\.0|255\.255\.254\.0|255\.255\.255\.0|255\.255\.255\.128|255\.255\.255\.192|255\.255\.255\.224|255\.255\.255\.240|255\.255\.255\.248|255\.255\.255\.252|255\.255\.255\.254|255\.255\.255\.255)$'
_UH_DNS='^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])(,(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9])\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9][0-9]|[0-9]))*$'
_UH_UINT='^(0|[1-9][0-9]*)$'
_UH_PREFIX='0.0.0.0:0 128.0.0.0:1 192.0.0.0:2 224.0.0.0:3 240.0.0.0:4 248.0.0.0:5 252.0.0.0:6 254.0.0.0:7 255.0.0.0:8 255.128.0.0:9 255.192.0.0:10 255.224.0.0:11 255.240.0.0:12 255.248.0.0:13 255.252.0.0:14 255.254.0.0:15 255.255.0.0:16 255.255.128.0:17 255.255.192.0:18 255.255.224.0:19 255.255.240.0:20 255.255.248.0:21 255.255.252.0:22 255.255.254.0:23 255.255.255.0:24 255.255.255.128:25 255.255.255.192:26 255.255.255.224:27 255.255.255.240:28 255.255.255.248:29 255.255.255.252:30 255.255.255.254:31 255.255.255.255:32'

# VARIABLES
INSTALL_DIR="/etc/pydhcp"
SERVICE_FILE="/etc/systemd/system/pydhcpd.service"
INIT_FILE="/etc/init.d/pydhcpd"
SYSTEM_USER="pydhcpd"

# ACL layout. Two groups, by who owns the list:
# - ACL_PATH holds the administrator's own lists (mac-*.txt), edited by hand.
# - ACL_DHCP_PATH holds pydhcp's own list (blockdhcp.txt), written by
#   pyleases.sh alone, so it lives under INSTALL_DIR -- same arrangement uhm
#   uses for its own lists under /etc/uhm/acl.
# pydhcp.env itself is written with these already resolved -- it is parsed
# key=value (never sourced), so a "$VAR" inside it would be stored as that
# literal string, not as a path.
ACL_PATH="/etc/acl"
ACL_MAC_PATH="${ACL_PATH}/acl_mac"
ACL_DHCP_PATH="${INSTALL_DIR}/acl"
ACL_MAC_LIMITED="${ACL_MAC_PATH}/mac-limited.txt"
ACL_MAC_UNLIMITED="${ACL_MAC_PATH}/mac-unlimited.txt"
ACL_BLOCK_FILE="${ACL_DHCP_PATH}/blockdhcp.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${CYAN}[INFO]${NC} $*"; log "INFO: $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; log "INFO: $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; log "WARNING: $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; log "ERROR: $*"; exit 1; }

# --- Interactive prompts ------------------------------------------------------
ask_interface_number() {
    local prompt="$1" default="$2" var="$3" max="$4" answer
    while true; do
        read -rp " ${prompt} [1-${max}] [Default: ${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_UINT ]] && (( answer >= 1 && answer <= max )); then
            printf -v "$var" '%s' "$answer"
            break
        fi
        warn "Invalid selection, try again"
    done
}

ask_ip() {
    local prompt="$1" default="$2" var="$3" answer hint
    if [[ -n "$default" ]]; then
        hint="Default: $default"
    else
        hint="Default: 192.168.0.10"
    fi
    while true; do
        read -rp " ${prompt} [${hint}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_IPV4 ]]; then
            printf -v "$var" '%s' "$answer"
            break
        fi
        warn "'$answer' is not a valid IP address."
    done
}

ask_netmask() {
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp " ${prompt} [Default: ${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_NETMASK ]]; then
            printf -v "$var" '%s' "$answer"
            break
        fi
        warn "'$answer' is not a valid netmask."
    done
}

# ref_start (optional): rejects an octet <= this value, for pool-end prompts.
ask_octet() {
    local prompt="$1" default="$2" var="$3" ref_start="${4:-}" answer
    while true; do
        read -rp " ${prompt} [Default: ${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_OCT ]] && (( answer >= 1 && answer <= 254 )); then
            if [[ -n "$ref_start" ]] && (( answer <= ref_start )); then
                warn "Pool end must be greater than pool start (${ref_start})"
                continue
            fi
            printf -v "$var" '%s' "$answer"
            break
        fi
        warn "Invalid value, enter a number between 1 and 254"
    done
}

ask_dns() {
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp " ${prompt} [Default: ${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_DNS ]]; then
            printf -v "$var" '%s' "$answer"
            break
        fi
        warn "Invalid DNS format, try again"
    done
}

ask_number() {
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp " ${prompt} [Default: ${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_UINT ]] && (( answer >= 1 )); then
            printf -v "$var" '%s' "$answer"
            break
        fi
        warn "Invalid value, enter a positive integer"
    done
}

ask_port() {
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp " ${prompt} [Default: ${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ $_UH_UINT ]] && (( answer >= 1 && answer <= 65535 )); then
            printf -v "$var" '%s' "$answer"
            break
        fi
        warn "Invalid port, enter a number between 1 and 65535"
    done
}

confirm() {
    # confirm "prompt" [default y|n] -- returns 0 on yes, 1 on no
    local prompt="$1" default="${2:-n}" answer hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp " ${prompt} ${hint}: " answer
    answer="${answer:-$default}"
    [[ "${answer,,}" =~ ^y(es)?$ ]]
}

# Verify that a source file is a regular, non-empty, non-world-writable file
# owned by root or the current user, and that its path is inside SCRIPT_DIR.
verify_source() {
    local f="$1"
    local real
    real=$(realpath "$f" 2>/dev/null) || error "cannot resolve source path -- abort"
    [[ "$real" == "$SCRIPT_DIR"/* ]] || error "source file outside the repo -- abort"
    [ -f "$real" ] || error "source is not a regular file -- abort"
    [ -s "$real" ] || error "source file is empty -- abort"
    local mode owner
    mode=$(stat -c '%a' "$real")
    owner=$(stat -c '%u' "$real")
    if (( (8#$mode & 8#002) != 0 )); then
        { echo -e "${RED}[ERROR]${NC} world-writable source file (mode $mode)" >&2; error "$f -- abort"; }
    fi
    if [[ "$owner" != "0" && "$owner" != "${SUDO_UID:-$(id -u)}" ]]; then
        { echo -e "${RED}[ERROR]${NC} source file owned by unexpected uid $owner" >&2; error "$f -- abort"; }
    fi
}

# Start
log "pysetup start..."

# --- UNINSTALL ---------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
    echo ""
    warn "This removes pydhcp completely: $INSTALL_DIR,"
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
    rm -f "$SERVICE_FILE"
    rm -f "$INIT_FILE"
    rm -f /etc/logrotate.d/pydhcp
    rm -f /var/log/pydhcp.log
    rm -f /etc/logrotate.d/pydhcpd
    rm -f /var/log/pydhcpd.log

    if [ -x "$INSTALL_DIR/tools/bkstack.sh" ]; then
        info "Removing bkstack.sh cron entry ..."
        "$INSTALL_DIR/tools/bkstack.sh" uninstall || true
    fi

    if [ -x "$INSTALL_DIR/tools/pywebmin.sh" ]; then
        info "Removing Webmin module ..."
        "$INSTALL_DIR/tools/pywebmin.sh" uninstall || true
    fi

    [[ "$INSTALL_DIR" == "/etc/pydhcp" ]] || error "unexpected install dir: $INSTALL_DIR -- abort"

    # Everything under INSTALL_DIR goes, including the config and the block
    # list: uninstalling means removing the project. Only bak/ survives, and
    # tools/bkstack.sh is the way to keep a copy of anything else.
    info "Removing $INSTALL_DIR ..."
    find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 ! -name bak -exec rm -rf {} +

    info "Removing system user and group $SYSTEM_USER ..."
    userdel "$SYSTEM_USER" 2>/dev/null || warn "User $SYSTEM_USER not found or already removed"
    groupdel "$SYSTEM_USER" 2>/dev/null || true

    systemctl daemon-reload

    success "pydhcpd has been removed from the system."
    log "pysetup done at: $(date)"
    rm -f "$PYDHCP_LOG_FILE"
    exit 0
fi

# --- UPDATE ------------------------------------------------------------------
if [[ "${1:-}" == "--update" ]]; then
    if [ ! -d "$INSTALL_DIR" ]; then
        { echo -e "${RED}[ERROR]${NC} no installation found in $INSTALL_DIR" >&2; error "run without --update to install first -- abort"; }
    fi
    if [ ! -f "$INSTALL_DIR/pydhcp.env" ]; then
        echo -e "${RED}[ERROR]${NC} $INSTALL_DIR/pydhcp.env not found" >&2
        echo -e "${RED}[ERROR]${NC} it pre-dates config persistence" >&2
        error "run 'pysetup.sh --remove' then reinstall -- abort"
    fi
    if [ ! -d "$INSTALL_DIR/tools" ]; then
        echo -e "${RED}[ERROR]${NC} $INSTALL_DIR/tools not found" >&2
        echo -e "${RED}[ERROR]${NC} unexpected state for an existing install" >&2
        error "run 'pysetup.sh --remove' then reinstall -- abort"
    fi

    if [ -x "$INSTALL_DIR/tools/bkstack.sh" ]; then
        info "Creating backup with bkstack.sh ..."
        "$INSTALL_DIR/tools/bkstack.sh" || warn "backup failed, continuing -- alert"
    else
        warn "bkstack.sh not found, no backup -- alert"
    fi

    info "Stopping pydhcpd service..."
    systemctl stop pydhcpd 2>/dev/null || true

    info "Updating pydhcpd.py ..."
    verify_source "$SCRIPT_DIR/pydhcpd.py"
    cp "$SCRIPT_DIR/pydhcpd.py" "$INSTALL_DIR/pydhcpd.py"
    chown root:root "$INSTALL_DIR/pydhcpd.py"
    chmod 755 "$INSTALL_DIR/pydhcpd.py"

    info "Updating systemd unit ..."
    verify_source "$SCRIPT_DIR/pydhcpd.service"
    cp "$SCRIPT_DIR/pydhcpd.service" "$SERVICE_FILE"
    chown root:root "$SERVICE_FILE"
    chmod 644 "$SERVICE_FILE"

    info "Updating init.d wrapper ..."
    verify_source "$SCRIPT_DIR/init.d/pydhcpd"
    cp "$SCRIPT_DIR/init.d/pydhcpd" "$INIT_FILE"
    chown root:root "$INIT_FILE"
    chmod 755 "$INIT_FILE"

    if [ -f "$SCRIPT_DIR/tools/pyleases.sh" ]; then
        info "Updating tools/pyleases.sh ..."
        verify_source "$SCRIPT_DIR/tools/pyleases.sh"
        cp "$SCRIPT_DIR/tools/pyleases.sh" "$INSTALL_DIR/tools/pyleases.sh"
        chown root:root "$INSTALL_DIR/tools/pyleases.sh"
        chmod 755 "$INSTALL_DIR/tools/pyleases.sh"
    fi

    if [ -f "$SCRIPT_DIR/tools/bkstack.sh" ]; then
        info "Updating tools/bkstack.sh ..."
        verify_source "$SCRIPT_DIR/tools/bkstack.sh"
        cp "$SCRIPT_DIR/tools/bkstack.sh" "$INSTALL_DIR/tools/bkstack.sh"
        chown root:root "$INSTALL_DIR/tools/bkstack.sh"
        chmod 755 "$INSTALL_DIR/tools/bkstack.sh"
    fi

    if [ -f "$SCRIPT_DIR/tools/pywebmin.sh" ]; then
        info "Updating tools/pywebmin.sh ..."
        verify_source "$SCRIPT_DIR/tools/pywebmin.sh"
        cp "$SCRIPT_DIR/tools/pywebmin.sh" "$INSTALL_DIR/tools/pywebmin.sh"
        chown root:root "$INSTALL_DIR/tools/pywebmin.sh"
        chmod 755 "$INSTALL_DIR/tools/pywebmin.sh"
    fi

    info "Consolidating logs into $PYDHCP_LOG_FILE ..."
    if [ -f /var/log/pydhcpd.log ]; then
        cat /var/log/pydhcpd.log >> "$PYDHCP_LOG_FILE"
        rm -f /var/log/pydhcpd.log
    fi
    rm -f /etc/logrotate.d/pydhcpd
    [ -f "$PYDHCP_LOG_FILE" ] || touch "$PYDHCP_LOG_FILE"
    chown "$SYSTEM_USER":"$SYSTEM_USER" "$PYDHCP_LOG_FILE"
    chmod 640 "$PYDHCP_LOG_FILE"
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
        { echo -e "${RED}[ERROR]${NC} pydhcpd failed to start after update" >&2; error "check it with: journalctl -u pydhcpd -n 50 -- abort"; }
    fi

    echo ""
    success "pydhcpd updated. Backups in /etc/bak"
    info "$INSTALL_DIR/pydhcpd.conf unchanged"
    info "$INSTALL_DIR/pydhcp.env unchanged"
    info "$INSTALL_DIR/pydhcpd.leases unchanged"
    warn "WPAD/option 252 is set by WPAD_ENABLED,"
    warn "in pydhcp.env, not by editing pyleases.sh."
    warn "This update does not change it."
    echo ""
    log "pysetup done at: $(date)"
    exit 0
fi

# --- INSTALL -----------------------------------------------------------------

if [ -f "$INSTALL_DIR/pydhcpd.py" ]; then
    echo -e "${RED}[ERROR]${NC} pydhcpd is already installed at $INSTALL_DIR." >&2
    error "use --update or --remove instead -- abort"
fi

# Detect and select network interface
echo ""
info "Available network interfaces:"
mapfile -t IFACES < <(ip -br link show | awk '$1 != "lo" {sub(/@.*/, "", $1); print $1}')
if [[ ${#IFACES[@]} -eq 0 ]]; then
    error "no network interfaces found -- abort"
fi
for i in "${!IFACES[@]}"; do
    STATE=$(ip -br link show "${IFACES[$i]}" | awk '{print $2}')
    printf " [%d] %s (%s)\n" "$((i+1))" "${IFACES[$i]}" "$STATE"
done
echo ""
ask_interface_number "Select interface number" "1" SEL "${#IFACES[@]}"
IFACE="${IFACES[$((SEL-1))]}"
info "Using interface: $IFACE"

# DHCP server IP
echo ""
DEFAULT_SERVER_IP=$(ip -4 -br addr show "$IFACE" 2>/dev/null | awk '{print $3}' | cut -d/ -f1)
ask_ip "Enter DHCP server IP address" "$DEFAULT_SERVER_IP" SERVER_IP
info "Server IP: $SERVER_IP"

# Netmask
echo ""
ask_netmask "Enter netmask" "255.255.255.0" NETMASK
info "Netmask: $NETMASK"

# Calculate network values from SERVER_IP and NETMASK using python3
SUBNET=$(python3 -c "
import ipaddress, sys
net = ipaddress.IPv4Network(f'{sys.argv[1]}/{sys.argv[2]}', strict=False)
print(net.network_address)
" "$SERVER_IP" "$NETMASK")
BROADCAST=$(python3 -c "
import ipaddress, sys
net = ipaddress.IPv4Network(f'{sys.argv[1]}/{sys.argv[2]}', strict=False)
print(net.broadcast_address)
" "$SERVER_IP" "$NETMASK")
NET_BASE=$(echo "$SUBNET" | cut -d. -f1-3)
info "Subnet: $SUBNET"
info "Network base: $NET_BASE"
info "Broadcast: $BROADCAST"

# Pool range
echo ""
while true; do
    ask_octet "Enter pool start (last octet)" "220" POOL_START
    ask_octet "Enter pool end (last octet)" "235" POOL_END "$POOL_START"
    if python3 -c "
import ipaddress, sys
net = ipaddress.IPv4Network(f'{sys.argv[1]}/{sys.argv[2]}', strict=False)
start = ipaddress.IPv4Address(f'{sys.argv[3]}.{sys.argv[4]}')
end = ipaddress.IPv4Address(f'{sys.argv[3]}.{sys.argv[5]}')
sys.exit(0 if start in net and end in net else 1)
" "$SUBNET" "$NETMASK" "$NET_BASE" "$POOL_START" "$POOL_END"; then
        break
    fi
    { warn "pool ${NET_BASE}.${POOL_START}-${POOL_END} is outside the subnet"; warn "subnet is ${SUBNET}/${NETMASK}, try again"; }
done
info "Pool range: ${NET_BASE}.${POOL_START} -> ${NET_BASE}.${POOL_END}"

# Guard: SERVER_IP must never fall inside its own pool range -- pydhcpd.py
# rejects this at config load, but that only surfaces after this script has
# already created the user, directories, and systemd unit. Catching it here,
# before any of that, avoids leaving the system half-configured over a
# config mistake that could have been caught up front.
if python3 -c "
import ipaddress, sys
server = ipaddress.IPv4Address(sys.argv[1])
start = ipaddress.IPv4Address(sys.argv[2])
end = ipaddress.IPv4Address(sys.argv[3])
print('1' if start <= server <= end else '0')
" "$SERVER_IP" "${NET_BASE}.${POOL_START}" "${NET_BASE}.${POOL_END}" 2>/dev/null | grep -q '^1$'; then
    { echo -e "${RED}[ERROR]${NC} server IP $SERVER_IP overlaps the pool range" >&2; echo -e "${RED}[ERROR]${NC} pool: ${NET_BASE}.${POOL_START}-${NET_BASE}.${POOL_END}" >&2; error "choose a server IP outside the pool -- abort"; }
fi

# DNS servers
echo ""
ask_dns "Enter DNS server(s), comma-separated" "8.8.8.8,1.1.1.1" DNS_SERVERS
info "DNS servers: $DNS_SERVERS"

# Pool lease cleanup interval
ask_number "DHCP pool lease cleanup interval in seconds" "60" CLEANUP_INTERVAL

# Optional features
WPAD_ENABLED="false"
WPAD_PORT="18100"
if dpkg -s apache2 &>/dev/null; then
    if confirm "Enable WPAD/PAC proxy auto-configuration? (requires an Apache2 VirtualHost serving wpad.pac)" "n"; then
        WPAD_ENABLED="true"
        ask_port "WPAD/PAC port" "18100" WPAD_PORT
    fi
else
    info "apache2 not installed, WPAD/PAC not offered -- skip"
fi
# ping-check matches isc-dhcp-server's own default (on unless explicitly
# disabled), so it is not prompted for -- edit PING_CHECK_ENABLED in
# pydhcp.env afterward if your environment has strict ICMP firewall rules.
PING_CHECK_ENABLED="true"

# Verify source files exist
for f in pydhcpd.py pydhcpd.conf pydhcpd.service init.d/pydhcpd; do
    [ -f "$SCRIPT_DIR/$f" ] || { echo -e "${RED}[ERROR]${NC} missing source file: $f" >&2; error "run pysetup.sh from the project directory -- abort"; }
done

# Create system group and user
if ! getent group "$SYSTEM_USER" &>/dev/null; then
    info "Creating system group: $SYSTEM_USER"
    groupadd --system "$SYSTEM_USER"
else
    warn "Group $SYSTEM_USER already exists, skipping"
fi

if ! id "$SYSTEM_USER" &>/dev/null; then
    info "Creating system user: $SYSTEM_USER"
    useradd --system --no-create-home --shell /bin/false --gid "$SYSTEM_USER" --comment "Python DHCP Daemon" "$SYSTEM_USER"
else
    warn "User $SYSTEM_USER already exists, skipping"
fi

# Create install directory
info "Creating $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"
chown root:"$SYSTEM_USER" "$INSTALL_DIR"
chmod 770 "$INSTALL_DIR"

# Deploy daemon and config files
info "Deploying pydhcpd.py ..."
verify_source "$SCRIPT_DIR/pydhcpd.py"
cp "$SCRIPT_DIR/pydhcpd.py" "$INSTALL_DIR/pydhcpd.py"
chown root:root "$INSTALL_DIR/pydhcpd.py"
chmod 755 "$INSTALL_DIR/pydhcpd.py"

# Deploy pydhcpd.conf (preserved on update -- never overwritten)
if [ -f "$INSTALL_DIR/pydhcpd.conf" ]; then
    { warn "pydhcpd.conf already exists in $INSTALL_DIR"; warn "static hosts and blocked MACs kept"; warn "network parameters updated with your answers"; }
else
    info "Deploying pydhcpd.conf ..."
    verify_source "$SCRIPT_DIR/pydhcpd.conf"
    cp "$SCRIPT_DIR/pydhcpd.conf" "$INSTALL_DIR/pydhcpd.conf"
fi
chown root:"$SYSTEM_USER" "$INSTALL_DIR/pydhcpd.conf"
chmod 640 "$INSTALL_DIR/pydhcpd.conf"

# Create pydhcp's own ACL directories/files (preserved on update -- never
# overwritten). These lists are only consumed by the optional pyleases.sh
# tool, but are created here unconditionally so their paths can be recorded
# in pydhcp.env from the start -- not deferred until pyleases.sh first runs.
mkdir -p "$ACL_MAC_PATH" "$ACL_DHCP_PATH"
chmod 700 "$ACL_MAC_PATH" "$ACL_DHCP_PATH"

if [ ! -f "$ACL_BLOCK_FILE" ]; then
    verify_source "$SCRIPT_DIR/acl/blockdhcp.txt"
    cp "$SCRIPT_DIR/acl/blockdhcp.txt" "$ACL_BLOCK_FILE"
    chmod 600 "$ACL_BLOCK_FILE"
    chown root:root "$ACL_BLOCK_FILE"
fi

for f in "$ACL_MAC_LIMITED" "$ACL_MAC_UNLIMITED"; do
    if [ ! -f "$f" ]; then
        touch "$f"
        chmod 600 "$f"
        chown root:root "$f"
    fi
done
info "ACL directories/files present in $ACL_PATH"

# Create pydhcp.env (preserved on update -- never overwritten). Single source
# of truth for network, ACL-path and daemon-defaults values: pyleases.sh and
# any other future script read these from here instead of asking again,
# adding only their own keys if missing.
if [ -f "$INSTALL_DIR/pydhcp.env" ]; then
    warn "pydhcp.env already exists, not overwritten -- skip"
    info "interface not changed, keeping the value in pydhcp.env"
else
    info "Creating pydhcp.env ..."
    cat > "$INSTALL_DIR/pydhcp.env" <<ENVEOF
# =============================================================================
# PYDHCP
# /etc/pydhcp/pydhcp.env
# =============================================================================
# -- Daemon bootstrap (/etc/default/isc-dhcp-server migration) ----------------
DHCPDv4_CONF=/etc/pydhcp/pydhcpd.conf
DHCPDv4_BIN=/usr/bin/python3
DHCPDv4_SCRIPT=/etc/pydhcp/pydhcpd.py
PYDHCPD_LEASES=$INSTALL_DIR/pydhcpd.leases
INTERFACESv4="$IFACE"
DAEMON_USER="pydhcpd"
DAEMON_GROUP="pydhcpd"
# -- Network values (chosen by the administrator during install) --------------
SERVER_IP=$SERVER_IP
SERV_SUBNET=$SUBNET
SERV_BROADCAST=$BROADCAST
SERV_MASK=$NETMASK
SERV_INI_RANGE_BLOCK=${NET_BASE}.${POOL_START}
SERV_END_RANGE_BLOCK=${NET_BASE}.${POOL_END}
SERV_DNS=$DNS_SERVERS
# -- ACL paths, administrator's own lists (edited by hand) --------------------
ACL_PATH=$ACL_PATH
ACL_MAC_PATH=$ACL_MAC_PATH
ACL_MAC_LIMITED=$ACL_MAC_LIMITED
ACL_MAC_UNLIMITED=$ACL_MAC_UNLIMITED
# -- ACL paths, pydhcp's own list (written by pyleases.sh) --------------------
ACL_DHCP_PATH=$ACL_DHCP_PATH
ACL_BLOCK_FILE=$ACL_BLOCK_FILE
# -- Lease timers (pyleases.sh -> pydhcpd.conf pool/subnet directives) --------
CLEANUP_INTERVAL=$CLEANUP_INTERVAL
AUTHORIZED_LEASE_TIME=2592000
QUARANTINE_DURATION=60
# -- Optional features (pyleases.sh -> pydhcpd.conf wpad/ping-check) ----------
WPAD_ENABLED=$WPAD_ENABLED
WPAD_PORT=$WPAD_PORT
PING_CHECK_ENABLED=$PING_CHECK_ENABLED
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
chown root:"$SYSTEM_USER" "$INSTALL_DIR/pydhcp.env"
chmod 640 "$INSTALL_DIR/pydhcp.env"

# Apply network parameters to pydhcpd.conf
CONF_TMP=$(mktemp "$INSTALL_DIR/.pydhcpd.conf.XXXXXX") || error "cannot create temp file -- abort"
cp -f "$INSTALL_DIR/pydhcpd.conf" "$CONF_TMP"
sed -i "s|^server-identifier .*|server-identifier ${SERVER_IP};|" "$CONF_TMP"
sed -i "s|subnet [0-9.]* netmask [0-9.]*|subnet ${SUBNET} netmask ${NETMASK}|" "$CONF_TMP"
sed -i "s|option routers .*;|option routers ${SERVER_IP};|" "$CONF_TMP"
sed -i "s|option broadcast-address .*;|option broadcast-address ${BROADCAST};|" "$CONF_TMP"
sed -i "s|range [0-9.]* [0-9.]*;|range ${NET_BASE}.${POOL_START} ${NET_BASE}.${POOL_END};|" "$CONF_TMP"
sed -i "s|option domain-name-servers .*;|option domain-name-servers ${DNS_SERVERS};|" "$CONF_TMP"
sed -i "s|^cleanup-interval .*|cleanup-interval ${CLEANUP_INTERVAL};|" "$CONF_TMP"
sed -i "/pool {/,/}/ s|min-lease-time .*;|min-lease-time ${CLEANUP_INTERVAL};|" "$CONF_TMP"
sed -i "/pool {/,/}/ s|default-lease-time .*;|default-lease-time ${CLEANUP_INTERVAL};|" "$CONF_TMP"
sed -i "/pool {/,/}/ s|max-lease-time .*;|max-lease-time ${CLEANUP_INTERVAL};|" "$CONF_TMP"
if [[ "$WPAD_ENABLED" == "true" ]]; then
    sed -i "s|# option wpad code 252 = text;|option wpad code 252 = text;|" "$CONF_TMP"
    sed -i "s|# option wpad \"http://SERVER_IP:18100/wpad.pac\";|option wpad \"http://${SERVER_IP}:${WPAD_PORT}/wpad.pac\";|" "$CONF_TMP"
else
    sed -i "s|# option wpad \"http://SERVER_IP:18100/wpad.pac\";|# option wpad \"http://${SERVER_IP}:${WPAD_PORT}/wpad.pac\";|" "$CONF_TMP"
fi
mv -f "$CONF_TMP" "$INSTALL_DIR/pydhcpd.conf"
info "Network parameters set in pydhcpd.conf"

# Re-apply permissions after sed edits
chown root:"$SYSTEM_USER" "$INSTALL_DIR/pydhcpd.conf"
chmod 640 "$INSTALL_DIR/pydhcpd.conf"

# Initialize empty leases file if not present
if [ ! -f "$INSTALL_DIR/pydhcpd.leases" ]; then
    info "Creating empty pydhcpd.leases ..."
    touch "$INSTALL_DIR/pydhcpd.leases"
    chown "$SYSTEM_USER":"$SYSTEM_USER" "$INSTALL_DIR/pydhcpd.leases"
    chmod 640 "$INSTALL_DIR/pydhcpd.leases"
fi

# Deploy tools
info "Creating $INSTALL_DIR/tools ..."
mkdir -p "$INSTALL_DIR/tools"
chown root:root "$INSTALL_DIR/tools"
chmod 755 "$INSTALL_DIR/tools"

for tool in pyleases.sh pywebmin.sh bkstack.sh; do
    if [ -f "$SCRIPT_DIR/tools/$tool" ]; then
        info "Deploying tools/$tool ..."
        verify_source "$SCRIPT_DIR/tools/$tool"
        cp "$SCRIPT_DIR/tools/$tool" "$INSTALL_DIR/tools/$tool"
        chown root:root "$INSTALL_DIR/tools/$tool"
        chmod 755 "$INSTALL_DIR/tools/$tool"
    fi
done

if [ -x "$INSTALL_DIR/tools/bkstack.sh" ]; then
    info "Registering bkstack.sh monthly cron entry ..."
    "$INSTALL_DIR/tools/bkstack.sh" install || warn "cron entry not registered -- alert"
fi

# Deploy systemd service
info "Deploying systemd unit ..."
verify_source "$SCRIPT_DIR/pydhcpd.service"
cp "$SCRIPT_DIR/pydhcpd.service" "$SERVICE_FILE"
chown root:root "$SERVICE_FILE"
chmod 644 "$SERVICE_FILE"

# Deploy init.d wrapper
info "Deploying init.d wrapper ..."
verify_source "$SCRIPT_DIR/init.d/pydhcpd"
cp "$SCRIPT_DIR/init.d/pydhcpd" "$INIT_FILE"
chown root:root "$INIT_FILE"
chmod 755 "$INIT_FILE"

# Create log file if it does not exist, ensure correct ownership/permissions
[ -f "$PYDHCP_LOG_FILE" ] || touch "$PYDHCP_LOG_FILE"
chown "$SYSTEM_USER":"$SYSTEM_USER" "$PYDHCP_LOG_FILE"
chmod 640 "$PYDHCP_LOG_FILE"

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
    { echo -e "${RED}[ERROR]${NC} pydhcpd failed to start" >&2; error "check it with: journalctl -u pydhcpd -n 50 -- abort"; }
fi

echo ""
success "pydhcpd installed and running."
echo ""
info "Configuration : $INSTALL_DIR/pydhcpd.conf"
info "Interface : $(grep INTERFACESv4 "$INSTALL_DIR/pydhcp.env" | cut -d= -f2 | tr -d '"')"
info "Leases : $INSTALL_DIR/pydhcpd.leases"
info "Logs : journalctl -u pydhcpd -f"
echo ""
info "To remove : sudo bash pysetup.sh --remove"
log "pysetup done at: $(date)"
