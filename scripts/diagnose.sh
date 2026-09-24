#!/usr/bin/env bash
#
# diagnose.sh - read-only fingerprint health check (no root, no changes)
#
# Usage:  bash scripts/diagnose.sh [--user NAME] [--no-daemon]
#   --user NAME    user to query prints for (default: $USER)
#   --no-daemon    skip the fprintd-list daemon round-trip (can be slow
#                  or hang for ~seconds on a suspended python-validity)
#
# Exit code: 0 = everything this project cares about looks healthy
#            1 = at least one problem detected
#
# Intended for the Synaptics/Validity "Metallica MIS" (06cb:009a) reader and
# the python-validity + open-fprintd stack. Output is JSON-free plain text
# so it is easy to paste into issues.
set -uo pipefail

SENSOR_VENDOR="06cb"
SENSOR_ID="009a"
TARGET_USER="${1:-$USER}"
QUERY_LOGIN_USER="$USER"
DO_DAEMON=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) QUERY_LOGIN_USER="$2"; shift 2 ;;
        --no-daemon) DO_DAEMON=0; shift ;;
        *) echo "warning: ignoring unknown argument '$1'" >&2; shift ;;
    esac
done

fail=0

say()   { printf '%s\n' "$*"; }
ok()    { printf '  [ ok ] %s\n' "$*"; }
bad()   { printf '  [FAIL] %s\n' "$*"; fail=1; }
warn()  { printf '  [warn] %s\n' "$*"; }

section() { printf '\n== %s ==\n' "$*"; }

section "Fingerprint sensor (lsusb)"
if command -v lsusb >/dev/null 2>&1; then
    matched=$(lsusb 2>/dev/null | grep -iE '06cb:|synaptics|validity|fingerprint' || true)
    if [[ -z "$matched" ]]; then
        bad "No Synaptics/Validity/fingerprint device found via lsusb."
    else
        while IFS= read -r line; do say "  $line"; done <<< "$matched"
        if ! grep -q "^Bus .* ID ${SENSOR_VENDOR}:${SENSOR_ID} " <<< "$matched"; then
            warn "Expected ${SENSOR_VENDOR}:${SENSOR_ID} but did not see it exactly;"
            warn "continue reading - the udev rule below targets ${SENSOR_VENDOR}:${SENSOR_ID} only."
        fi
    fi
else
    warn "lsusb not installed - cannot check the sensor. Install usbutils."
fi

section "Packages (python-validity stack)"
for p in python-validity open-fprintd fprintd-clients-git; do
    if pacman -Q "$p" >/dev/null 2>&1; then
        ok "$p $(pacman -Q "$p" | awk '{print $2}')"
    else
        bad "$p is NOT installed."
    fi
done
if pacman -Q fprintd >/dev/null 2>&1; then
    bad "Stock 'fprintd' package is installed - it will fight open-fprintd for the"
    bad "net.reactivated.Fprint D-Bus name. Remove it (see README, step 1)."
else
    ok "Stock 'fprintd' package is absent (good - open-fprintd provides the daemon)."
fi

section "Services"
for s in python3-validity.service python3-validity-suspend-hotfix.service \
         open-fprintd.service open-fprintd-suspend.service open-fprintd-resume.service; do
    active=$(systemctl is-active "$s" 2>/dev/null || true); active=${active:-unknown}
    enabled=$(systemctl is-enabled "$s" 2>/dev/null || true); enabled=${enabled:-unknown}
    want_enabled="no"
    case "$s" in
        python3-validity.service|python3-validity-suspend-hotfix.service|open-fprintd-suspend.service|open-fprintd-resume.service) want_enabled="yes" ;;
    esac
    state="active=$active enabled=$enabled"
    if [[ "$want_enabled" == "yes" && "$enabled" != "enabled" ]]; then
        bad "$s  ($state)  - expected enabled."
    elif [[ "$s" == "open-fprintd.service" && "$enabled" != "static" ]]; then
        bad "$s  ($state)  - open-fprintd is D-Bus activated; do NOT enable it."
    elif [[ "$s" == "open-fprintd.service" && "$active" != "active" ]]; then
        # static service, normally pulled up by D-Bus on first use
        warn "$s is not currently active ($state) - it will start on demand via D-Bus."
    else
        ok "$s  ($state)"
    fi
done

if [[ -e /usr/lib/systemd/system/fprintd.service ]]; then
    warn "A 'fprintd.service' unit exists; on this stack it is a leftover shipped by"
    warn "fprintd-clients-git pointing at /usr/lib/fprintd which does not exist."
    warn "Ignore it - do NOT start it. Stock fprintd being installed is the real risk."
fi

section "D-Bus activation (net.reactivated.Fprint)"
dbus_file=/usr/share/dbus-1/system-services/net.reactivated.Fprint.service
if [[ -f $dbus_file ]]; then
    owner_pkg=$(pacman -Qo "$dbus_file" 2>/dev/null | sed -n 's/.*owned by \([^ ]*\).*/\1/p')
    exec=$(awk -F= '/^Exec=/{print $2}' "$dbus_file")
    if [[ $owner_pkg == open-fprintd ]]; then
        ok "Activation file owned by: $owner_pkg  (Exec=${exec})"
    else
        bad "Activation file has unexpected owner: ${owner_pkg:-unknown}"
    fi
else
    bad "D-Bus activation file $dbus_file is missing."
fi

section "udev autosuspend rule"
if [[ -f /etc/udev/rules.d/90-fingerprint-autosuspend.rules ]]; then
    ok "90-fingerprint-autosuspend.rules present:"
    sed 's/^/    /' /etc/udev/rules.d/90-fingerprint-autosuspend.rules
else
    warn "90-fingerprint-autosuspend.rules is missing - add it to prevent USB autosuspend hangs."
fi

section "Sensor power control"
shopt -s nullglob
found_sys=0
for d in /sys/bus/usb/devices/*/; do
    v=$(cat "$d/idVendor" 2>/dev/null || true)
    [[ $v != "$SENSOR_VENDOR" ]] && continue
    found_sys=1
    ctrl=$(cat "$d/power/control" 2>/dev/null || echo "unreadable")
    say "  ${d%/} idVendor=$v power/control=$ctrl"
    if [[ $ctrl != "on" ]]; then
        warn "power/control is '$ctrl'. The udev rule sets 'on' on USB add; re-plug or"
        warn "run 'udevadm trigger' to refresh. The reader often still works as-is."
    fi
done
shopt -u nullglob
[[ $found_sys -eq 1 ]] || warn "Could not locate the 06cb device under /sys/bus/usb/devices."

section "PAM configuration"
pam_targets=(sudo polkit-1 omarchy-lock-fingerprint sddm)
for t in "${pam_targets[@]}"; do
    f="/etc/pam.d/$t"
    if [[ ! -f $f ]]; then
        warn "$t: file does not exist (ok if you don't use $t)."
        continue
    fi
    if grep -q 'pam_fprintd.so' "$f"; then
        ok "$t: pam_fprintd present"
    else
        warn "$t: pam_fprintd NOT configured"
    fi
done

section "Enrolled fingerprints (fprintd-list)"
if [[ $DO_DAEMON -eq 1 ]] && command -v fprintd-list >/dev/null 2>&1; then
    out=$(fprintd-list "$QUERY_LOGIN_USER" 2>&1) && rc=0 || rc=$?
    if [[ $rc -ne 0 ]]; then
        warn "fprintd-list for '$QUERY_LOGIN_USER' failed (rc=$rc)."
        say "$out" | while IFS= read -r l; do say "    $l"; done
        warn "If this says 'Did not receive a reply', restart python3-validity + open-fprintd:"
        say "    systemctl restart python3-validity.service open-fprintd.service"
    elif grep -qE 'fingerprint|[0-9]' <<< "$out" && grep -qi 'found [1-9]' <<< "$out"; then
        ok "Device(s) found; prints for '$QUERY_LOGIN_USER':"
        say "$out" | while IFS= read -r l; do say "    $l"; done
    else
        warn "fprintd-list ran but no prints shown for '$QUERY_LOGIN_USER'. Enroll with:"
        say "    fprintd-enroll $QUERY_LOGIN_USER"
    fi
else
    say "  (skipped fprintd-list - $([ $DO_DAEMON -eq 0 ] && echo '--no-daemon given' || echo 'fprintd-list not found'))"
fi

printf '\n'
if [[ $fail -eq 0 ]]; then
    say "Verdict: OK - fingerprints should work for sudo/polkit/lock screen${TARGET_USER:+ for '$TARGET_USER'}."
else
    say "Verdict: PROBLEMS FOUND (see [FAIL] above)."
    exit 1
fi