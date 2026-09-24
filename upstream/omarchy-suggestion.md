# Omarchy: suggestion — support match-on-chip fingerprint readers (e.g. Synaptics `06cb:009a`)

> Paste this as a **Discussion → Suggestion** in the
> [basecamp/omarchy](https://github.com/basecamp/omarchy) repo, or adapt it to
> your own words. This is a feature request, not a bug report (per Omarchy's own
> guidance, feature ideas belong in Discussions under Suggestions).
>
> Suggested title:
> **Support match-on-chip fingerprint readers (Synaptics/Validity `06cb:xxxx`) via the python-validity/open-fprintd stack**

---

## Summary

The fingerprint setup (`Setup > Security > Fingerprint`) and stock `fprintd` /
`libfprint-git` cannot drive **match-on-chip** Synaptics/Validity readers — e.g.
the ThinkPad T480s reader `06cb:009a` "Metallica MIS Touch Fingerprint Reader".
`fprintd-list` finds no devices and enrollment fails with `No devices available`.

These sensors work perfectly with the **python-validity + open-fprintd** stack
(AUR: `python-validity`, `open-fprintd`, `fprintd-clients-git`). I verified a
complete install on a T480s running Omarchy: **sudo, polkit, the Omarchy lock
screen (Super+Ctrl+L), and SDDM login** all accept the fingerprint. Lock-screen
integration requires no shell changes — the lock plugin already auto-enables
fingerprint once `/etc/pam.d/omarchy-lock-fingerprint` exists and
`fprintd-list "$USER"` shows an enrolled print.

A tested recipe, install/revert/diagnose scripts, config samples, and this
report live at: https://github.com/petealeon/thinkpad-fingerprint-omarchy

## Why this matters

Match-on-chip sensors cannot be added to upstream libfprint the way the Goodix
driver was — the enrollment/match is done on the sensor firmware and driven by
a completely different host protocol (python-validity). So this class of
hardware needs Omarchy to either:

1. detect Validity-class devices (`06cb:*`) during `omarchy setup security fingerprint`
   and install the python-validity stack instead of `fprintd`/`libfprint-git`, **and**
2. stop installing/planning around stock `fprintd` when the open-fprintd stack
   is present (so an update or a re-run of the setup doesn't pull stock `fprintd`
   back in — it would fight open-fprintd for the `net.reactivated.Fprint`
   D-Bus name; today `fprintd-clients-git` conflicts with stock `fprintd`, so
   the re-run fails outright rather than silently breaking).

## Concrete asks

- Detect Validity devices and offer the python-validity stack in the fingerprint setup.
- Teach the setup/package checks to treat `open-fprintd` (provides the
  `fprintd` capability) as the fingerprint daemon, and never reinstall stock
  `fprintd` when it's present.
- Consider updating `manual/37-hardware-authentication.md` with a short
  "match-on-chip readers" note pointing at the recipe above.

## System details

- Hardware: Lenovo ThinkPad T480s, reader `06cb:009a` Synaptics "Metallica MIS"
- OS: Omarchy (Arch-based)
- Working stack: python-validity 0.15, open-fprintd 0.7, fprintd-clients-git
  1.90.1.r2, libfprint 1.94.100 (client library only)

---

*Filed by big-pickle via opencode.*