# Proposal: match-on-chip fingerprint support in `omarchy-setup-security-fingerprint`

> **Status: proposal, not submitted upstream.** This is a design sketch with the
> real upstream source (branch `quattro`, fetched 2026-09) as the baseline. It
> exists so the maintainers (and you) can evaluate the change. Nothing here has
> been sent as a PR. See `omarchy-suggestion.md` for the Discussion post.

## The gap

`omarchy-setup-security-fingerprint` does the right things for libfprint-backed
readers:

1. `omarchy-hw-fingerprint` (sysfs) detects a reader — and it *does* match our
   `06cb:009a`, since `06cb` is in its `fingerprint_vendors` list and the reader
   has no kernel driver bound.
2. It installs `libfprint-git fprintd usbutils`.
3. It runs `fprintd-enroll`.

Step 3 fails on Synaptics/Validity **match-on-chip** readers with
`No devices available`, because upstream libfprint does not drive them. The
wizard then prints "Enrollment failed. Please try again." and exits — with the
stock stack installed and no way forward.

The same class includes other `06cb:xxxx` Prometheus sensors. They work with the
AUR **python-validity + open-fprintd + fprintd-clients-git** stack, which speaks
the sensor firmware's protocol directly. (Verified end-to-end on a ThinkPad
T480s: sudo, polkit, lock screen, SDDM.)

## Why this can't be "just another libfprint driver"

Match-on-chip sensors do enrollment *and* matching inside the sensor firmware.
There is no libusb-side image to hand to libfprint's matching pipeline, so the
Goodix/Elan "add a driver to libfprint" route does not apply. The host side is a
different daemon (`open-fprintd`) that python-validity feeds. That means Omarchy
would be swapping daemons, not adding a driver.

## Proposed change (sketch)

Add a fallback after the libfprint install, before enrollment:

```bash
# Returns 0 when a Synaptics/Validity reader (06cb) is present.
omarchy-hw-validity() {
  local usb_devices_path="${OMARCHY_USB_DEVICES_PATH:-/sys/bus/usb/devices}" dev
  for dev in "$usb_devices_path"/*; do
    [[ -r $dev/idVendor ]] || continue
    [[ $(<"$dev/idVendor") == "06cb" ]] && return 0
  done
  return 1
}

if omarchy-pkg-missing libfprint-git fprintd usbutils; then
  sudo pacman -S --needed --noconfirm --ask 4 -- libfprint-git fprintd usbutils
fi

# libfprint cannot drive match-on-chip 06cb readers. When one is present but
# fprintd sees no device, use the python-validity stack instead.
if omarchy-hw-validity && ! fprintd-list "$USER" 2>/dev/null | grep -q '/net/reactivated/Fprint/Device'; then
  echo "Detected a match-on-chip fingerprint reader unsupported by libfprint."
  echo "Switching to the python-validity stack..."
  sudo pacman -R --noconfirm fprintd
  # NOTE: the AUR step cannot run as root (see open question 1).
  yay --sudo=pkexec --noconfirm --needed -S python-validity
  sudo systemctl enable --now python3-validity.service
  sudo systemctl enable python3-validity-suspend-hotfix.service \
      open-fprintd-suspend.service open-fprintd-resume.service
  # then continue to the existing enroll/verify/PAM path unchanged
fi
```

`setup_pam_config` / `setup_lock_fingerprint_pam` need no changes — they only
touch `pam_fprintd.so` and the PAM files, which the new stack also provides.

## Open questions for maintainers

1. **AUR in a `requires-sudo` script.** `omarchy-setup-security-fingerprint`
   runs with `requires-sudo=true`; `yay` refuses to build AUR packages as root.
   Options: (a) package python-validity/open-fprintd in `omarchy-pkgs` and use
   `omarchy-pkg-add`; (b) `runuser -u "$SUDO_USER" -- yay ...`; (c) leave the
   stack to the community recipe and have the wizard *point* to it. This is the
   main decision; everything else is mechanical.
2. **Detection breadth.** `06cb` covers both libfprint-supported Synaptics
   readers and match-on-chip ones. The `fprintd-list` probe above only falls
   back when libfprint genuinely sees nothing, which keeps working readers on
   the stock path.
3. **Removal symmetry.** `omarchy-remove-security-fingerprint` currently drops
   `fprintd libfprint libfprint-git`. It would also need to drop
   `python-validity open-fprintd fprintd-clients-git` and disable the four
   units, or a removal leaves the AUR stack behind.

## If the full change is too much

The smallest useful upstream step is documentation: a note in the manual that
match-on-chip `06cb:xxxx` readers need the python-validity stack, with a link to
the community recipe (`upstream/manual-37-note.md`). That unblocks affected
users without touching installer policy.
