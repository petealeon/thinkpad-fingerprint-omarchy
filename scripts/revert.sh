#!/usr/bin/env bash
#
# revert.sh - undo install.sh
#
# Default behaviour is CONFIG-ONLY and safe:
#   * restores PAM files from the backups install.sh made (removes the
#     files it created if they did not exist before)
#   * removes the udev autosuspend rule and resets sensor power/control
#   * disables the python-validity + suspend/resume services
#
# With --full it also removes the AUR stack and installs the stock fprintd
# package (the state Omarchy's own wizard expects):
#
#   bash scripts/revert.sh --full --yes
#
# Even in --full mode, every config change is reversible; run install.sh again.
#
# DISCLAIMER: use at your own risk. See README.md. No warranty.
set -euo pipefail

SENSOR_VENDOR="06cb"
UDEV_RULE_PATH="/etc/udev/rules.d/90-fingerprint-autosuspend.rules"
BACKUP_BASE="/var/lib/fingerprint-omarchy-backup"

PRIV_CMD=(pkexec)
YAY_SUDO_ARG="--sudo=pkexec"
MODE_FULL=0
CONFIRMED=0

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
log() { printf '\033[1;34m==> \033[0m%s\n' "$*"; }
skip() { printf '  \033[1;33mskip\033[0m %s\n' "$*"; }

priv() { "${PRIV_CMD[@]}" "$@"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) MODE_FULL=1; shift ;;
        --yes|-y) CONFIRMED=1; shift ;;
        --priv=*)
            PRIV_CMD=("${1#*=}")
            if [[ ${PRIV_CMD[0]} == pkexec ]]; then
                YAY_SUDO_ARG="--sudo=pkexec"
            elif [[ ${PRIV_CMD[0]} == sudo ]]; then
                YAY_SUDO_ARG="--sudo=sudo"
            else
                die "unsupported --priv value '${PRIV_CMD[0]}'"
            fi
            shift ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) say "warning: ignoring unknown argument '$1'"; shift ;;
    esac
done

if [[ $EUID -eq 0 ]]; then
    die "do not run as root - script escalates via ${PRIV_CMD[0]} where needed."
fi
command -v "${PRIV_CMD[0]}" >/dev/null 2>&1 || die "privilege tool '${PRIV_CMD[0]}' not found (try --priv=sudo)."

NEWEST_BACKUP=$(ls -1dt "$BACKUP_BASE"/*/ 2>/dev/null | head -1 || true)
if [[ -z $NEWEST_BACKUP ]]; then
    say "no backups found under $BACKUP_BASE - will strip our PAM lines instead."
fi

GATE_LINE='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
FPR_LINE='auth      sufficient pam_fprintd.so'

strip_lines() { # strip_lines <file>  -> removes our two known lines (needs root)
    local f=$1 new
    new=$(mktemp)
    grep -vFx -e "$GATE_LINE" -e "$FPR_LINE" "$f" > "$new" || true
    priv install -o root -g root -m 0644 "$new" "$f"
    rm -f "$new"
}

# ---------------------------------------------------------------------------
# 1) PAM
# ---------------------------------------------------------------------------
log "1/3: reverting PAM configuration..."
for t in sudo polkit-1 sddm omarchy-lock-fingerprint; do
    path="/etc/pam.d/$t"
    [[ -e $path ]] || { skip "PAM /etc/pam.d/$t is absent - nothing to do."; continue; }

    restored=0
    if [[ -n $NEWEST_BACKUP ]]; then
        if [[ -e "$NEWEST_BACKUP/created/$t" ]]; then
            log "Removing $path (created by install.sh)."
            priv rm -f "$path"
            restored=1
        elif [[ -e "$NEWEST_BACKUP/orig/$t" ]]; then
            log "Restoring /etc/pam.d/$t from backup."
            priv install -o root -g root -m 0644 "$NEWEST_BACKUP/orig/$t" "$path"
            restored=1
        fi
    fi
    if [[ $restored -eq 0 ]]; then
        if grep -q 'pam_fprintd.so' "$path"; then
            log "No backup for $t - stripping our lines instead. Leaving the rest of $t intact."
            strip_lines "$path"
        else
            skip "PAM /etc/pam.d/$t has no pam_fprintd lines - untouched."
        fi
    fi
done

# ---------------------------------------------------------------------------
# 2) udev rule + power control
# ---------------------------------------------------------------------------
log "2/3: removing the USB autosuspend guard..."
if [[ -e $UDEV_RULE_PATH ]] && grep -q "06cb" "$UDEV_RULE_PATH"; then
    priv rm -f "$UDEV_RULE_PATH"
    log "Removed $UDEV_RULE_PATH. Reloading udev..."
    priv udevadm control --reload-rules >/dev/null
    priv udevadm trigger --subsystem-match=usb >/dev/null
else
    skip "udev rule absent or not ours."
fi
for d in /sys/bus/usb/devices/*/; do
    [[ -r "$d/idVendor" ]] || continue
    if [[ "$(cat "$d/idVendor" 2>/dev/null)" == "$SENSOR_VENDOR" ]]; then
        dev="${d%/}"
        cur=$(cat "$dev/power/control" 2>/dev/null || echo unknown)
        if [[ $cur == "on" ]]; then
            log "Resetting power/control to auto for $dev"
            priv sh -c "echo auto > '$dev/power/control'"
        fi
    fi
done

# ---------------------------------------------------------------------------
# 3) services
# ---------------------------------------------------------------------------
log "3/3: disabling python-validity + suspend/resume services..."
for s in python3-validity.service python3-validity-suspend-hotfix.service \
         open-fprintd-suspend.service open-fprintd-resume.service; do
    if [[ $(systemctl is-enabled "$s" 2>/dev/null) == enabled ]]; then
        priv systemctl disable --now "$s"
    else
        skip "service $s not enabled."
    fi
done
# stop the D-Bus daemon regardless (it may still be running)
priv systemctl stop open-fprintd.service python3-validity.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# --full: swap the stack back to stock fprintd
# ---------------------------------------------------------------------------
if [[ $MODE_FULL -eq 1 ]]; then
    if [[ $CONFIRMED -ne 1 ]]; then
        die "--full requires --yes (it removes python-validity/open-fprintd and installs stock fprintd)."
    fi
    log "FULL MODE: removing the AUR stack and installing stock fprintd..."
    command -v yay >/dev/null 2>&1 || die "yay not found - cannot remove AUR packages."
    say "  Removing: python-validity open-fprintd fprintd-clients-git"
    yay --noconfirm "$YAY_SUDO_ARG" -Rsu python-validity open-fprintd fprintd-clients-git
    priv pacman -S --noconfirm fprintd libfprint
    say "  Stock fprintd installed. If this is Omarchy, you can now run the normal"
    say "  wizard:  'omarchy setup security fingerprint'"
    say "  NOTE: prints stored by python-validity remain on the sensor chip and in"
    say "  /var/lib/python-validity; re-enroll with your new stack when you need prints."
fi

say ""
say "Revert complete. Config is back to pre-install state."
if [[ $MODE_FULL -eq 0 ]]; then
    say "Use '--full --yes' if you also want to go back to stock fprintd."
fi
exit 0