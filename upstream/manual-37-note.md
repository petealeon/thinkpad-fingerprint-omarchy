# Suggested manual note — `manual/37-hardware-authentication.md`

> **Status: proposal, not submitted.** Suggested wording for the Fingerprint
> authentication section of the Omarchy manual. The current page (branch
> `quattro`) assumes every reader works once `Setup > Security > Fingerprint`
> installs `libfprint-git`. That is not true for match-on-chip sensors.

## Where it would go

After the paragraph ending "...enter sudo mode, and authorize system prompts."
(around line 7 of the current page), add something like:

---

Some laptops ship a **match-on-chip** fingerprint reader — for example the
Synaptics/Validity `06cb:009a` in the ThinkPad T480s. These sensors do
enrollment and matching in their own firmware and are **not supported by
libfprint**, so the normal setup reaches the enrollment step and fails with
"No devices available".

For those readers, the community **python-validity + open-fprintd** stack works
instead (it also covers `sudo`, polkit, the lock screen and the login screen).
A tested, reversible recipe is at
<https://github.com/petealeon/thinkpad-fingerprint-omarchy>.

---

## Why document rather than only patch the wizard

Even without changing installer policy, a short note:

- stops affected users from concluding their reader is broken or unsupported;
- gives a supported-looking pointer to a tested recipe;
- documents the known limitation honestly.

If/when the wizard learns to detect these sensors, this paragraph can be
shortened to "Omarchy handles this automatically for `06cb:xxxx` readers."
