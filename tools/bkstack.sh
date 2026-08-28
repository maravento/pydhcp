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
# /etc/bak/bkstack_<YYYYMMDD_HHMM>.zip
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

# PATH for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# logging
log_file="/var/log/pydhcp.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}

## root check
if [ "$(id -u)" != "0" ]; then
    echo "ERROR: This script must be run as root -- abort" >&2
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
for dep in zip coreutils util-linux cron; do
    if ! dpkg -s "$dep" &>/dev/null; then
        log "ERROR: missing dependency '$dep' -- abort"
        exit 1
    fi
done

BACKUP_DIR="/etc/bak"
ARCHIVE="${BACKUP_DIR}/bkstack_$(date +%Y%m%d_%H%M).zip"
TARGET="/etc/pydhcp/tools/$(basename "$0")"

# Monthly is the floor, not a recommendation: it exists so an untouched
# system still has a recent copy. Run it by hand before any change.
register_cron() {
    # Deploy self first, like uhmwatch.sh: the cron entry must point at a
    # path that exists, whether this ran from the repo or from its final
    # location.
    local self
    self="$(readlink -f "$0")"
    if [ "$self" != "$TARGET" ]; then
        if ! mkdir -p "$(dirname "$TARGET")"; then
            log "ERROR: cannot create $(dirname "$TARGET") -- abort"
            exit 1
        fi
        install -m 755 -o root -g root "$self" "$TARGET"
        log "INFO: deployed to $TARGET"
    fi

    local cron_entry="@monthly $TARGET"
    local current
    current=$(crontab -l 2>/dev/null || true)
    if echo "$current" | grep -vE '^\s*#' | grep -qF "$TARGET"; then
        log "INFO: cron entry already present -- skip"
    else
        { printf '%s\n%s\n' "$current" "$cron_entry"; } | crontab -
        log "INFO: cron entry registered, runs @monthly"
        log "INFO: $TARGET"
    fi
}

deregister_cron() {
    if crontab -l 2>/dev/null | grep -qF "$TARGET"; then
        crontab -l 2>/dev/null | grep -vF "$TARGET" | crontab -
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

if ! mkdir -p "$BACKUP_DIR"; then
    log "ERROR: cannot create $BACKUP_DIR -- abort"
    exit 1
fi

# Everything the two projects own. Anything installed outside their own
# trees is listed explicitly, so a restore brings back a working system.
paths=()
for p in \
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
    if [ -e "$p" ]; then
        paths+=("$p")
    else
        log "INFO: $p not present -- skip"
    fi
done

if (( ${#paths[@]} == 0 )); then
    log "ERROR: none of the expected paths exist"
    log "ERROR: is pydhcp installed? -- abort"
    exit 1
fi

if zip -r -q "$ARCHIVE" "${paths[@]}"; then
    chmod 600 "$ARCHIVE"
    log "INFO: backup written to $ARCHIVE"
else
    rm -f "$ARCHIVE"
    log "ERROR: cannot write the archive"
    log "ERROR: $ARCHIVE"
    log "ERROR: check free space and permissions -- abort"
    exit 1
fi

# End
log "bkstack done at: $(date)"
