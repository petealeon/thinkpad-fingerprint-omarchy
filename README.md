# ThinkPad fingerprint reader (Synaptics/Validity `06cb:009a`) for Omarchy / Arch Linux

Fixes the fingerprint reader on the **Lenovo ThinkPad T480s** (and similar
Synaptics "Metallica MIS"-class readers) by swapping the stock fprintd stack
for the **python-validity + open-fprintd** stack.

> **DISCLAIMER — NO WARRANTY, USE AT YOUR OWN RISK.**
>
> This project is provided "as is", **without warranty of any kind**, express
> or implied, including but not limited to the warranties of merchantability,
> fitness for a particular purpose and noninfringement. In no event shall the
> authors or copyright holders be liable for any claim, damages or other
> liability arising from, out of or in connection with the software or the use
> or other dealings in the software.
>
> In plain terms: **back up /etc/pam.d and your packages before you start.**
> You are modifying PAM, which is how your system authenticates. A mistake can
> lock you out of `sudo`. Practically every step below is reversible (the
> scripts back everything up), and there is a `revert.sh`, but nothing here is
> guaranteed. Test on a machine you can afford to break.
>
> This repository is **not** affiliated with or endorsed by Synaptics, Lenovo,
> Omarchy, or the python-validity/open-fprintd projects. The real work is done
> by those projects — this is just a tested, opinionated recipe.

---

## Why this exists

The T480s ships a **Synaptics, Inc. Metallica MIS Touch Fingerprint Reader**
(`lsusb`: `06cb:009a`). It is a *match-on-chip* sensor: it builds and matches
templates in its own firmware, and it is **not supported by upstream libfprint**.
That's why stock setups (Omarchy's `Setup > Security > Fingerprint`, plain Arch,
GNOME, etc.) report:

```
Impossible to enroll: GDBus.Error:...: No devices available
```

The working approach is to use a different daemon:

| Component | Role | Upstream |
|---|---|---|
| `python-validity` | Talks to the sensor firmware directly | https://github.com/uunicorn/python-validity |
| `open-fprintd` | fprintd-compatible daemon that python-validity feeds | https://github.com/uunicorn/open-fprintd |
| `fprintd-clients-git` | `fprintd-*` client tools, PAM module, D-Bus files | fork of freedesktop `libfprint`'s fprintd |

For Zen: the sensor keeps your fingerprint template **on its chip**, quality-
and match decisions happen in the firmware. This recipe just wires a working
host daemon to it.

## What you get

- `sudo` with a finger touch (`auth sufficient pam_fprintd.so`)
- polkit/authorization prompts with a finger touch
- Lock screen unlock by touch (**Omarchy**: `Super + Ctrl + L`)
- SDDM / login screen: fingerprint first, password as fallback
- Omarchy's "Set up fingerprint reader" notification stops nagging

## Does it apply to you?

- Run it if `lsusb` shows `ID 06cb:009a` (or another `06cb:` Validity device).
- If `fprintd-list` already shows a device **and** prints can be enrolled, you
  don't need this (your reader is supported by normal libfprint).
- Non-Arch distros / other sensors: only the general ideas transfer. Pull
  requests welcome for other distros.

---

## Option A — one-shot scripts (recommended)

```bash
git clone https://github.com/petealeon/thinkpad-fingerprint-omarchy.git
cd thinkpad-fingerprint-omarchy

bash scripts/install.sh          # does everything except enrollment
fprintd-enroll "$USER"           # interactive: keep moving your finger
sudo -v                          # test: touch the sensor at the prompt
```

`install.sh` is idempotent and backs up everything it touches to
`/var/lib/fingerprint-omarchy-backup/`. Useful flags:

```bash
bash scripts/install.sh --check     # status only, changes nothing
bash scripts/install.sh --enroll    # run enrollment at the end
bash scripts/install.sh --priv=sudo # use sudo instead of pkexec/polkit
```

Need stock back? `bash scripts/revert.sh` (config) or
`bash scripts/revert.sh --full --yes` (also uninstall the AUR stack and
reinstall stock fprintd).

Diagnose later: `bash scripts/diagnose.sh`.

## Option B — manual, step by step

Verified on ThinkPad T480s + Omarchy (Arch-based, `yay` AUR helper, `pkexec`
available). Run every privileged step via the polkit prompt. Adapt the OPS below.

### 1. Remove the stock fprintd stack

```bash
# Only if present:
pkexec pacman -R --noconfirm fprintd
pkexec pacman -Q libfprint-git && pkexec pacman -Rdd --noconfirm libfprint-git
```

Stock `fprintd` and `open-fprintd` would fight over the `net.reactivated.Fprint`
D-Bus name, so it must go.

### 2. Install the python-validity stack (as your normal user)

```bash
yay --sudo=pkexec --noconfirm --needed -S python-validity
```

This brings in `open-fprintd`, `fprintd-clients-git` (and its dependency,
the `libfprint` library — that's fine, it's just the client library; the
daemon that owns the reader is now open-fprintd).

### 3. Keep the reader out of USB autosuspend

The T480s reader hangs if the USB port autosuspends. Write
`/etc/udev/rules.d/90-fingerprint-autosuspend.rules` (see
`config/udev/`):

```
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="06cb", ATTR{idProduct}=="009a", ATTR{power/control}="on"
```

then:

```bash
pkexec udevadm control --reload-rules
pkexec udevadm trigger --subsystem-match=usb
```

Verify the live value for your device: `cat /sys/bus/usb/devices/*/power/control` → `on`.

### 4. Enable the services

```bash
pkexec systemctl enable --now python3-validity.service
pkexec systemctl enable python3-validity-suspend-hotfix.service open-fprintd-suspend.service open-fprintd-resume.service
pkexec systemctl restart python3-validity.service open-fprintd.service
```

Notes:

- `open-fprintd.service` is **static** (D-Bus activated) — do **not** enable it.
- Don't start `fprintd.service`: on this stack it's a leftover compat unit
  shipped by `fprintd-clients-git` pointing at `/usr/lib/fprintd`, which does
  not exist.

### 5. Wire PAM

The Omarchy wizard normally does this, but its install path would reinstall the
stock stack — so do it by hand. Sample files in `config/pam/`.

`/etc/pam.d/sudo` — prepend these two lines at the very top:

```
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
```

`/etc/pam.d/sddm` — same two lines, right after the `#%PAM-1.0` line
(fingerprint-first login, password fallback).

`/etc/pam.d/polkit-1` — create it (it doesn't exist on Omarchy) with:

```
auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth      sufficient pam_fprintd.so
auth      required pam_unix.so

account   required pam_unix.so
password  required pam_unix.so
session   required pam_unix.so
```

`/etc/pam.d/omarchy-lock-fingerprint` — create it (this is the Omarchy lock
screen's PAM stack):

```
#%PAM-1.0
auth       required                    pam_fprintd.so
account    include                     system-local-login
```

> On non-Omarchy Linux, the `omarchy-hw-laptop-closed` gate line is unnecessary;
> that binary only exists on Omarchy. Just prepend `auth sufficient pam_fprintd.so`
> on its own. The install script does this automatically.

### 6. Enroll + verify

```bash
fprintd-enroll "$USER"     # keep moving your finger; releases after enough data
fprintd-list "$USER"       # should show your prints
sudo -v                    # touch the sensor
```

Lock the screen (`Super + Ctrl + L` on Omarchy) and unlock by touch. On reboot,
the login screen accepts fingerprint then falls back to password.

**Enrollment speed concern:** this sensor is match-on-chip and large; it can
finish enrollment after a single clean press. That is normal and safe — the
sensor firmware rejects a capture if it doesn't contain enough distinctive
detail, and only reports success once its own algorithm has enough.

---

## Omarchy-specific notes

- The lock screen auto-enables fingerprint unlock once **both** of these are
  true: `/etc/pam.d/omarchy-lock-fingerprint` exists **and**
  `fprintd-list "$USER"` shows an enrolled print. No shell/plugin changes needed.
- The "Set up fingerprint reader" invitation hook also checks for that PAM file,
  so it goes quiet automatically.
- **Do not re-run `omarchy setup security fingerprint`.** Its `setup_pam_config`
  and package steps assume the stock stack and can reinstall `fprintd`, which
  then races `open-fprintd` for the D-Bus name. Everything it would do is what
  this guide does manually.
- If you ever want Omarchy to handle this natively, there is an upstream
  feature request (see `upstream/omarchy-suggestion.md`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| `fprintd-list`: `Did not receive a reply...` | python-validity got stuck in its suspend path: `systemctl restart python3-validity.service open-fprintd.service` |
| Reader dead after laptop woke from suspend | The suspend/resume units handle this; make sure all four units from step 4 are enabled |
| First touch after resume does nothing | Known quirk — retry once; python-validity re-initializes the sensor |
| `sudo` still asks for password only | Check `/etc/pam.d/sudo` has the two lines at the very top; check `fprintd-list "$USER"` shows your print |
| Nothing happens at the lock screen | Omarchy needs prints enrolled **and** `/etc/pam.d/omarchy-lock-fingerprint` present |
| Reader shows as `auto` in `power/control` | Re-plug/unplug or `udevadm trigger` — the rule sets `on` on USB add |

## Reverting

```bash
bash scripts/revert.sh              # undo all config changes (from backups)
bash scripts/revert.sh --full --yes # + remove AUR stack, reinstall stock fprintd
```

## Security notes

- Match-on-chip: your fingerprint template stays on the sensor; Linux does not
  get a copy to steal. This is a real advantage over match-on-host readers.
- Fingerprint auth lowers the barrier for physical access. Same as Windows
  Hello on this machine; fine for a laptop threat model, not a bank vault.
- This project does **not** weaken `/etc/pam.d/system-auth` or `system-login`;
  LUKS, tty logins and your default PAM policy are untouched.

## License / credits

MIT — see `LICENSE`. Built on the shoulders of:
[uunicorn/python-validity](https://github.com/uunicorn/python-validity),
[uunicorn/open-fprintd](https://github.com/uunicorn/open-fprintd),
[fprintd / libfprint](https://fprint.freedesktop.org/), and Omarchy.