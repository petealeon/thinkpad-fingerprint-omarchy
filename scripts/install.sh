#!/usr/bin/env bash
#
# install.sh - apply the python-validity + open-fprintd fingerprint stack
#
# Target hardware: Synaptics/Validity "Metallica MIS" 06cb:009a and similar
# match-on-chip readers that upstream libfprint cannot drive.
#
# Everything here mirrors a fix that was applied and verified end-to-end on a
# ThinkPad T480s running Omarchy (see README.md). The script is idempotent:
# safe to re-run, and it backs up every file it touches.
#
# Usage:
#   bash scripts/install.sh                 apply everything (interactive polkit prompts)
#   bash scripts/install.sh --check          status only, changes nothing
#   bash scripts/install.sh --enroll         also run fprintd-enroll at the end
#   bash scripts/install.sh --priv=sudo      use sudo instead of pkexec for root steps
#   bash scripts/install.sh --force          continue even if no 06cb sensor is seen
#
# Run as a normal (non-root) user. Root steps go through pkexec (polkit dialog)
# or sudo, depending on --priv.
#
# DISCLAIMER: use at your own risk. See README.md. No warranty.
set -euo pipefail

SENSOR_VENDOR="06cb"
SENSOR_ID="009a"
UDEV_RULE_PATH="/etc/udev/rules.d/90-fingerprint-autosuspend.rules"
BACKUP_BASE="/var/lib/fingerprint-omarchy-backup"
PAM_SUPPORTED=(sudo polkit-1 sddm omarchy-lock-fingerprint)

PRIV_CMD=(pkexec)
YAY_SUDO_ARG="--sudo=pkexec"
MODE_APPLY=1
MODE_ENROLL=0
FORCE=0

usage() {
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
log() { printf '\033[1;34m==> \033[0m%s\n' "$*"; }
skip() { printf '  \033[1;33mskip\033[0m %s\n' "$*"; }

priv() { "${PRIV_CMD[@]}" "$@"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) MODE_APPLY=0; shift ;;
        --enroll) MODE_ENROLL=1; shift ;;
        --force) FORCE=1; shift ;;
        --priv=*)
            PRIV_CMD=("${1#*=}")
            if [[ ${PRIV_CMD[0]} == pkexec ]]; then
                YAY_SUDO_ARG="--sudo=pkexec"
            elif [[ ${PRIV_CMD[0]} == sudo ]]; then
                YAY_SUDO_ARG="--sudo=sudo"
            else
                die "unsupported --priv value '${PRIV_CMD[0]}' (use pkexec or sudo)"
            fi
            shift ;;
        -h|--help) usage ;;
        *) say "warning: ignoring unknown argument '$1'"; shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    die "do not run as root - the AUR step (yay) refuses to run as root. Script will escalate where needed."
fi

if [[ ${MODE_APPLY} -eq 1 ]] && ! command -v "${PRIV_CMD[0]}" >/dev/null 2>&1; then
    die "privilege tool '${PRIV_CMD[0]}' not found (try --priv=sudo)."
fi

# ---------------------------------------------------------------------------
# Sensor detection
# ---------------------------------------------------------------------------
sensor_state() {
    if ! command -v lsusb >/dev/null 2>&1; then return 4; fi
    local out
    out=$(lsusb 2>/dev/null || true)
    if grep -q "ID ${SENSOR_VENDOR}:${SENSOR_ID} " <<< "$out"; then return 0; fi        # exact
    if grep -qi "ID ${SENSOR_VENDOR}:" <<< "$out"; then return 1; fi                     # other validity
    if grep -qiE 'synaptics|validity|fingerprint' <<< "$out"; then return 2; fi          # maybe fingerprint
    return 3                                                                             # none found
}

log "Checking for a Synaptics/Validity fingerprint reader..."
ss=0
sensor_state || ss=$?
case $ss in
    0) log "Found exact sensor ${SENSOR_VENDOR}:${SENSOR_ID}." ;;
    1) log "Found a different Validity (${SENSOR_VENDOR}:*) device - may work, continuing." ;;
    2) log "Found a fingerprint-ish device but not a 06cb:* one - attempting anyway." ;;
    3)
        if [[ $FORCE -eq 1 ]]; then
            log "No 06cb sensor found, but --force was given - continuing."
        else
            die "No Synaptics/Validity sensor found. This guide targets 06cb:${SENSOR_ID}."
        fi
        ;;
    4) die "'lsusb' is not installed (part of usbutils) - install it, then re-run." ;;
esac

# ---------------------------------------------------------------------------
# --check mode (or early gates)
# ---------------------------------------------------------------------------
installed_ok=0
if pacman -Q python-validity >/dev/null 2>&1 && pacman -Q open-fprintd >/dev/null 2>&1; then
    installed_ok=1
fi

if [[ ${MODE_APPLY} -eq 0 ]]; then
    log "CHECK MODE - nothing will be changed. Current state:"
    [[ $installed_ok -eq 1 ]] && say "  python-validity stack: installed" || say "  python-validity stack: NOT installed"
    [[ -e $UDEV_RULE_PATH ]] && say "  udev rule: present" || say "  udev rule: absent"
    for t in "${PAM_SUPPORTED[@]}"; do
        if [[ -f /etc/pam.d/$t ]] && grep -q 'pam_fprintd.so' "/etc/pam.d/$t"; then
            say "  PAM $t: configured"
        else
            say "  PAM $t: not configured"
        fi
    done
    for s in python3-validity.service python3-validity-suspend-hotfix.service \
             open-fprintd-suspend.service open-fprintd-resume.service; do
        [[ $(systemctl is-enabled "$s" 2>/dev/null) == enabled ]] \
            && say "  service $s: enabled" || say "  service $s: NOT enabled"
    done
    say ""
    [[ $installed_ok -eq 1 && -e $UDEV_RULE_PATH && $(systemctl is-enabled python3-validity.service 2>/dev/null) == enabled ]] \
        && say "Looks fully applied. Run 'bash scripts/diagnose.sh' for a deeper check." || :
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 1: remove stock fprintd / libfprint-git
# ---------------------------------------------------------------------------
log "Step 1/5: removing stock fprintd + libfprint-git if present..."

required_by() { # required_by <pkg> -> prints "None" or the list
    pacman -Qi "$1" 2>/dev/null | sed -n 's/^Required By[[:space:]]*: //p'
}

if pacman -Q fprintd >/dev/null 2>&1; then
    rb=$(required_by fprintd)
    if [[ -n ${rb// } && $rb != "None" ]]; then
        die "fprintd is required by: $rb - refusing to remove it. Resolve that first."
    fi
    log "Removing stock fprintd..."
    priv pacman -R --noconfirm fprintd
else
    skip "stock fprintd already absent."
fi

if pacman -Q libfprint-git >/dev/null 2>&1; then
    rb=$(required_by libfprint-git)
    if [[ -n ${rb// } && $rb != "None" ]]; then
        skip "libfprint-git is required by: $rb - leaving it in place."
    else
        log "Removing libfprint-git..."
        priv pacman -Rdd --noconfirm libfprint-git
    fi
else
    skip "libfprint-git not installed."
fi

# ---------------------------------------------------------------------------
# Step 2: install the python-validity stack from the AUR
# ---------------------------------------------------------------------------
log "Step 2/5: installing python-validity + open-fprintd + fprintd-clients from AUR..."

if [[ $installed_ok -eq 1 ]]; then
    skip "stack already installed."
else
    command -v yay >/dev/null 2>&1 || die "yay (AUR helper) not found. Install it first: https://github.com/Jguer/yay"
    log "Running: yay --noconfirm --needed ${YAY_SUDO_ARG} -S python-validity"
    yay --noconfirm --needed "$YAY_SUDO_ARG" -S python-validity
    pacman -Q python-validity >/dev/null 2>&1 && pacman -Q open-fprintd >/dev/null 2>&1 \
        || die "python-validity/open-fprintd did not end up installed - see the yay output above."
fi

# ---------------------------------------------------------------------------
# Step 3: udev autosuspend rule
# ---------------------------------------------------------------------------
log "Step 3/5: installing USB autosuspend guard for 06cb:${SENSOR_ID}..."

if [[ -f $UDEV_RULE_PATH ]]; then
    skip "udev rule already present."
else
    tmp=$(mktemp)
    printf '%s\n' \
        "ACTION==\"add\", SUBSYSTEM==\"usb\", ATTR{idVendor}==\"${SENSOR_VENDOR}\", ATTR{idProduct}==\"${SENSOR_ID}\", ATTR{power/control}=\"on\"" > "$tmp"
    priv install -o root -g root -m 0644 "$tmp" "$UDEV_RULE_PATH"
    rm -f "$tmp"
    log "Reloading udev rules..."
    priv udevadm control --reload-rules >/dev/null
    priv udevadm trigger --subsystem-match=usb >/dev/null
fi

# Make sure the CURRENT instance is not autosuspended either.
for d in /sys/bus/usb/devices/*/; do
    [[ -r "$d/idVendor" ]] || continue
    if [[ "$(cat "$d/idVendor" 2>/dev/null)" == "$SENSOR_VENDOR" ]]; then
        dev="${d%/}"
        cur=$(cat "$dev/power/control" 2>/dev/null || echo unknown)
        if [[ $cur != "on" ]]; then
            log "Setting power/control=on for $dev"
            priv sh -c "echo on > '$dev/power/control'"
        else
            skip "power/control already 'on' for $dev"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Step 4: services
# ---------------------------------------------------------------------------
log "Step 4/5: enabling python-validity + suspend/resume units..."

priv systemctl enable --now python3-validity.service
priv systemctl enable python3-validity-suspend-hotfix.service \
    open-fprintd-suspend.service open-fprintd-resume.service
# Clear any stuck suspended state (python-validity can be left "In Suspend"
# if its suspend unit kicked in during the install).
priv systemctl restart python3-validity.service open-fprintd.service

# ---------------------------------------------------------------------------
# Step 5: PAM configuration (with backups)
# ---------------------------------------------------------------------------
log "Step 5/5: wiring PAM for sudo, polkit, lock screen and SDDM login..."

STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$BACKUP_BASE/$STAMP"
priv mkdir -p "$BACKUP_DIR/orig" "$BACKUP_DIR/created"

add_pam_lines() { # add_pam_lines <file>
    local f=$1 tmp gate fp
    gate='auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
    fp='auth      sufficient pam_fprintd.so'
    if grep -q 'pam_fprintd.so' "$f"; then
        skip "PAM $f already has pam_fprintd."
        return 0
    fi
    tmp=$(mktemp)
    if head -1 "$f" | grep -q '^#%PAM-1\.0'; then
        { printf '%s\n' "$(head -1 "$f")"
          if [[ -x /usr/bin/omarchy-hw-laptop-closed ]]; then printf '%s\n' "$gate"; fi
          printf '%s\n' "$fp"
          tail -n +2 "$f" ; } > "$tmp"
    else
        { if [[ -x /usr/bin/omarchy-hw-laptop-closed ]]; then printf '%s\n' "$gate"; fi
          printf '%s\n' "$fp"
          cat "$f" ; } > "$tmp"
    fi
    priv install -o root -g root -m 0644 "$tmp" "$f"
    rm -f "$tmp"
    log "Configured PAM $f."
}

backup_or_record() { # backup_or_record <name> <path>  (path may not exist yet)
    local name=$1 path=$2
    if [[ -e $path ]]; then
        priv install -o root -g root -m 0644 "$path" "$BACKUP_DIR/orig/$name"
    else
        priv touch "$BACKUP_DIR/created/$name"
    fi
}

# sudo
if [[ -f /etc/pam.d/sudo ]]; then
    backup_or_record sudo /etc/pam.d/sudo
    add_pam_lines /etc/pam.d/sudo
else
    skip "no /etc/pam.d/sudo - nothing to do."
fi

# polkit-1 (create only if missing, otherwise prepend)
if [[ -f /etc/pam.d/polkit-1 ]]; then
    backup_or_record polkit-1 /etc/pam.d/polkit-1
    add_pam_lines /etc/pam.d/polkit-1
else
    # Wizard-equivalent minimal file (verified working on Omarchy).
    backup_or_record polkit-1 /etc/pam.d/polkit-1
    tmp=$(mktemp)
    {
        if [[ -x /usr/bin/omarchy-hw-laptop-closed ]]; then
            printf '%s\n' 'auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed'
        fi
        printf '%s\n' \
            'auth      sufficient pam_fprintd.so' \
            'auth      required pam_unix.so' \
            '' \
            'account   required pam_unix.so' \
            'password  required pam_unix.so' \
            'session   required pam_unix.so'
    } > "$tmp"
    priv install -o root -g root -m 0644 "$tmp" /etc/pam.d/polkit-1
    rm -f "$tmp"
    log "Created /etc/pam.d/polkit-1."
fi

# sddm (only if present)
if [[ -f /etc/pam.d/sddm ]]; then
    backup_or_record sddm /etc/pam.d/sddm
    add_pam_lines /etc/pam.d/sddm
else
    skip "no /etc/pam.d/sddm (no SDDM) - skip."
fi

# omarchy lock-screen stack (Omarchy-specific)
if [[ -d /usr/share/omarchy ]]; then
    if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]]; then
        backup_or_record omarchy-lock-fingerprint /etc/pam.d/omarchy-lock-fingerprint
        skip "omarchy-lock-fingerprint already exists."
    else
        backup_or_record omarchy-lock-fingerprint /etc/pam.d/omarchy-lock-fingerprint
        tmp=$(mktemp)
        printf '%s\n' \
            '#%PAM-1.0' \
            'auth       required                    pam_fprintd.so' \
            'account    include                     system-local-login' > "$tmp"
        priv install -o root -g root -m 0644 "$tmp" /etc/pam.d/omarchy-lock-fingerprint
        rm -f "$tmp"
        log "Created /etc/pam.d/omarchy-lock-fingerprint."
    fi
else
    skip "not an Omarchy system - lock-screen stack (omarchy-lock-fingerprint) skipped."
fi

# ---------------------------------------------------------------------------
# Verify + hand off enrollment
# ---------------------------------------------------------------------------
log "Verifying the daemon can see the device..."
sleep 1
out=$(timeout 20 fprintd-list "$USER" 2>&1 && printf 'rc=%s' 0 || printf 'rc=%s' "$?")
say "  $(sed 's/$/ /' <<< "${out//$'\n'/ /}")"
if grep -q 'found 1 devices' <<< "$out" || grep -q '/net/reactivated/Fprint/Device' <<< "$out"; then
    log "Sensor visible to fprintd. "
else
    say "  (If fprintd-list fails, run:  systemctl restart python3-validity.service open-fprintd.service)"
    say "  then retry. This happens when python-validity gets stuck in its suspend path."
fi

if pacman -Q fprintd >/dev/null 2>&1; then
    die "Stock fprintd is installed again after the swap - remove it, then re-run this script."
fi

log "Done. Backups of everything touched are in $BACKUP_DIR."

if [[ $MODE_ENROLL -eq 1 ]]; then
    say ""
    say "Starting enrollment. KEEP MOVING YOUR FINGER around the sensor until it completes."
    if command -v fprintd-enroll >/dev/null 2>&1; then
        fprintd-enroll "$USER" || say "Enrollment did not complete - run 'fprintd-enroll $USER' to retry."
        say "Enrollment step finished."
    else
        die "fprintd-enroll not found."
    fi
else
    say ""
    say "NEXT: enroll your first finger (right index recommended):"
    say "      fprintd-enroll $USER"
    say "      (keep moving your finger around the sensor until it completes)"
    say ""
    say "Then verify:  sudo -v   (touch the sensor at the prompt)"
    say "              lock the screen and unlock by touching (Omarchy: Super+Ctrl+L)"
fi

if [[ -d /usr/share/omarchy ]]; then
    say ""
    say "IMPORTANT (Omarchy): do NOT re-run 'omarchy setup security fingerprint'."
    say "It reinstalls the stock fprintd stack and fights open-fprintd for the"
    say "net.reactivated.Fprint D-Bus name. The lock screen auto-uses fingerprints"
    say "once /etc/pam.d/omarchy-lock-fingerprint exists and prints are enrolled."
fi

exit 0