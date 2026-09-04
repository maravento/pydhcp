#!/bin/bash
# maravento.com
#
################################################################################
#
# bkstack - configuration backup for pydhcp and uhm
#
# DESCRIPTION:
# Creates one compressed archive with everything both projects own: their
# install trees, the ACL lists they share, their systemd units, the init.d
# wrapper, the logrotate config and the Webmin modules. Paths that do not
# exist are skipped with a notice, so the same script works whether uhm is
# installed or only pydhcp is.
#
# This is the single backup mechanism for both projects: pysetup.sh,
# uhmsetup.sh and the Webmin modules call it instead of copying files on
# their own, so there is one archive format and one place to look.
#
# Run it by hand before applying changes, or let the monthly cron entry
# do it. Restore by unzipping the archive over / -- the archive stores
# absolute paths.
#
# USAGE:
# sudo bash bkstack.sh            Create a backup now
# sudo bash bkstack.sh install    Register the @monthly cron entry
# sudo bash bkstack.sh uninstall  Remove the cron entry (keeps archives)
#
# OUTPUT:
# /etc/bak/pydhcp/bkstack_<YYYYMMDD_HHMM>.zip
#
# Kept outside /etc/pydhcp and /etc/uhm on purpose: an uninstall of either
# project never touches it.
#
# EXIT CODES:
# 0 - Archive created
# 1 - Not root, already running, missing dependency, nothing to back up,
#     or the archive could not be written
#
# LOG: /var/log/pydhcp.log (shared with the rest of the project)
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

# root check
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root -- abort" >&2
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
for dep_pkg in zip coreutils util-linux cron; do
    if ! dpkg -s "$dep_pkg" &>/dev/null; then
        log "ERROR: missing dependency '$dep_pkg' -- abort"
        exit 1
    fi
done

# ------------------------------------------------------------------------------
# VARIABLES
# ------------------------------------------------------------------------------

backup_dir="/etc/bak/pydhcp"
backup_zip="${backup_dir}/bkstack_$(date +%Y%m%d_%H%M).zip"
installed_path="/etc/pydhcp/tools/$(basename "$0")"

# ------------------------------------------------------------------------------
# FUNCTIONS
# ------------------------------------------------------------------------------

# Monthly is the floor, not a recommendation: it exists so an untouched
# system still has a recent copy. Run it by hand before any change.
register_cron() {
    # Deploy self first, like uhmwatch.sh: the cron entry must point at a
    # path that exists, whether this ran from the repo or from its final
    # location.
    local script_path
    script_path="$(readlink -f "$0")"
    if [ "$script_path" != "$installed_path" ]; then
        if ! mkdir -p "$(dirname "$installed_path")"; then
            log "ERROR: cannot create $(dirname "$installed_path") -- abort"
            exit 1
        fi
        install -m 755 -o root -g root "$script_path" "$installed_path"
        log "INFO: deployed to $installed_path"
    fi

    local cron_entry="@monthly $installed_path"
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || true)
    if echo "$current_crontab" | grep -vE '^\s*#' | grep -qF "$installed_path"; then
        log "INFO: cron entry already present -- skip"
    else
        { printf '%s\n%s\n' "$current_crontab" "$cron_entry"; } | crontab -
        log "INFO: cron entry registered, runs @monthly"
        log "INFO: $installed_path"
    fi
}

deregister_cron() {
    if crontab -l 2>/dev/null | grep -qF "$installed_path"; then
        crontab -l 2>/dev/null | grep -vF "$installed_path" | crontab -
        log "INFO: cron entry removed, archives kept"
    else
        log "INFO: no cron entry to remove -- skip"
    fi
}

case "${1:-}" in
    install)
        register_cron
        exit 0
        ;;
    uninstall)
        deregister_cron
        exit 0
        ;;
    "")
        ;;
    *)
        log "ERROR: unknown action '$1' -- abort"
        log "ERROR: use no argument, 'install' or 'uninstall'"
        exit 1
        ;;
esac

# Start
log "bkstack start..."

# ------------------------------------------------------------------------------
# BACKUP
# ------------------------------------------------------------------------------

if ! mkdir -p "$backup_dir"; then
    log "ERROR: cannot create $backup_dir -- abort"
    exit 1
fi

# Everything the two projects own. Anything installed outside their own
# trees is listed explicitly, so a restore brings back a working system.
backup_list=()
for backup_item in \
    /etc/uhm \
    /etc/pydhcp \
    /etc/acl \
    /etc/systemd/system/uhmd.service \
    /etc/systemd/system/uhmalert.service \
    /etc/systemd/system/pydhcpd.service \
    /etc/init.d/pydhcpd \
    /etc/logrotate.d/uhm \
    /etc/logrotate.d/pydhcp \
    /etc/webmin/uhm \
    /etc/webmin/pydhcp \
    /usr/share/webmin/uhm \
    /usr/share/webmin/pydhcp
do
    if [ -e "$backup_item" ]; then
        backup_list+=("$backup_item")
    else
        log "INFO: $backup_item not present -- skip"
    fi
done

if (( ${#backup_list[@]} == 0 )); then
    log "ERROR: none of the expected paths exist"
    log "ERROR: is pydhcp installed? -- abort"
    exit 1
fi

if zip -r -q "$backup_zip" "${backup_list[@]}"; then
    chmod 600 "$backup_zip"
    log "INFO: backup written to $backup_zip"

    # keep only the last 3
    old_backups=("$backup_dir"/bkstack_*.zip)
    if (( ${#old_backups[@]} > 3 )); then
        printf '%s\n' "${old_backups[@]}" | sort | head -n -3 | xargs -r rm -f
    fi
else
    rm -f "$backup_zip"
    log "ERROR: cannot write the archive"
    log "ERROR: $backup_zip"
    log "ERROR: check free space and permissions -- abort"
    exit 1
fi

# ------------------------------------------------------------------------------
# END
# ------------------------------------------------------------------------------

log "bkstack done at: $(date)"
