# Ecowitt HP2550 backlight patch

A small firmware patch for the Ambient Weather WS-5000 / Ecowitt HP2550 weather
console that adds **network control of the LCD backlight**, which the stock firmware
has no way to expose. It turns two custom-server text fields into a command/status
mailbox on the console's existing port-45000 API, so a client on the LAN can set the
backlight power and level, switch auto-brightness and the schedule, and flip dark mode.
It also reports the console's actual state back, including changes made at the keypad.
The Home Assistant end is a separate integration,
[ha-ecowitt-hp2550](https://github.com/eklundjon/ha-ecowitt-hp2550) (0.2.0 and later
support v2).

This modifies the console's firmware. **You can brick the console.** Flash at your own
risk, on hardware you own, and keep a known-good image on an SD card for recovery (see
below). Not affiliated with or endorsed by Ambient Weather or Ecowitt.

**Use v2** (the build at the repo root). v1 was the proof of concept and is superseded;
see [v1/README.md](v1/README.md) for its known bugs.

## No firmware here - you supply your own

A patched image is a derivative of the vendor's copyrighted firmware, so this repo ships
**source and hashes, never firmware**. What's here is the payload source, the build
tool, and a reference client - all original work. You bring your own `user.bin` (dumped
from your console, or the vendor's official firmware download), and the build runs
entirely on your machine:

- `patch.py` refuses to touch anything whose SHA-256 isn't the exact stock image it
  targets (Ambient / Ecowitt HP2550 **V2.0.4**), so you can't accidentally patch the
  wrong build and flash something broken.
- It applies the patch and checks the output against the known SHA-256 for that build,
  so you can confirm a correct build before it goes near the console.

## What it does

The patch hooks the console's display loop and, every few seconds, reads a command out
of the custom-server Station ID and writes a status report into the password field. It
reuses the console's own backlight and WiFi-serial routines; there's no new network
code. See [docs/DESIGN.md](docs/DESIGN.md) for how.

The custom server doesn't need to be enabled. If you do enable its upload, set its
protocol to Ecowitt ("Same as AmbWeather" on an Ambient-branded console), not
Wunderground: in Wunderground mode the console sends the Station ID and Station Key
upstream as credentials, which here would be the mailbox's command and status. With
the upload disabled either protocol works. The mailbox coexists with a live Ecowitt
upload: each command delays one upload by up to one interval, and nothing else changes.

## The protocol in brief

One command per write to the Station ID: `<VERB> <VALUE> #<seq>`, with `seq` 1-255.
The console acts on it once and echoes the seq in the status (`#<seq>` applied,
`!<seq>` rejected).

| Verb | Value | Effect |
|---|---|---|
| `BL` | `0`-`100` / `A` | Saved level (turns auto off) / auto-brightness on. No power change. |
| `BP` | `0` / `1` | Backlight power off / on. |
| `BS` | `0` / `1` | Backlight schedule enable. |
| `DM` | `0` / `1` | Dark mode off / on. |

The status, in the password field, looks like `BP 1 BL A BS 0 DM 1 #7`. The full spec,
including validation and what clients have to allow for, is in
[docs/PROTOCOL.md](docs/PROTOCOL.md).

## Side effects and limits

- Auto-brightness and the backlight schedule still run when enabled. `BL n` turns auto
  off; for power commands that stick, turn the schedule off (`BS 0`).
- Changes made over IP are **RAM-only**. They don't survive a reboot unless a keypad or
  menu change saves the console's settings first, so a client should re-assert what it
  wants after a reboot.
- Anything written while someone is on the Customized server screen is lost when they
  leave it, and the backlight menu undoes `BL`/`BP`/`BS` sent while it's open. Clients
  should wait for the echo and resend. Details in the protocol doc.
- The image grows by a few hundred bytes and its checksum changes. The SD updater
  records the new size and bumps the stored version on flash.
- It doesn't touch the factory recovery image, the data-init section, or anything on
  the early boot path.

## Apply it

You need Python 3 and an SD card. Rebuilding the payload from source (rather than using
the committed build) also needs the LLVM toolchain (`clang`, `llvm-objcopy`); most
people won't.

1. Get your console's `user.bin` (V2.0.4) onto your machine.
2. `python3 patch.py verify user.bin` confirms it's the exact stock image.
3. `python3 patch.py build user.bin --out user_patched.bin` applies the v2 patch, fixes
   the checksum, and verifies the output hash (`f40024ef...bf7af0f`). Add `--v1` for the
   superseded v1 build.
4. Format the SD card **FAT16 or FAT32, MBR scheme**, and copy `user_patched.bin` onto
   it as `user.bin`.
5. Insert it and power-cycle the console. It finds the file, checksum-verifies it,
   flashes, and reboots on its own. The console deletes the update file after a
   successful flash, so an update card is single-use.
6. If the custom server's upload is enabled, make sure its protocol is Ecowitt ("Same as
   AmbWeather"), then try the client below.

Keep a card with the **stock** `user.bin` for recovery: re-stage it, insert, power-cycle.
The updater rejects a bad checksum and leaves the old firmware intact, so the only real
danger is pulling the card mid-write.

Going back to v1 from v2: clear the custom-server password (the Station Key row on the
Customized server screen) before flashing v1. The WiFi module keeps the field across
reflashes and v1 never writes it, so a stale v2 status would stay there, and a client
that detects the firmware from where the status appears (the HA integration does) would
keep treating the console as v2.

## The client

[`client/ewbacklight.py`](client/ewbacklight.py) is a small reference client (Python 3,
no dependencies) that speaks the mailbox. It increments the seq for you.

```
python3 client/ewbacklight.py HOST level 40      # BL 40
python3 client/ewbacklight.py HOST level auto    # BL A
python3 client/ewbacklight.py HOST power off     # BP 0
python3 client/ewbacklight.py HOST sched off     # BS 0
python3 client/ewbacklight.py HOST dark on       # DM 1
python3 client/ewbacklight.py HOST status
python3 client/ewbacklight.py --dry-run HOST ... # print the frames, send nothing
```

`client/ewcustom.py` reads and writes the custom-server record and paths directly. It
doesn't wait for the echo; if you're scripting commands, wait for the seq to appear in
`status` before sending the next.

## Supported firmware

The patch is pinned to one firmware build - fixed code offsets and a checksum - so it
applies to that build regardless of brand, and needs re-porting for any other version
even on identical hardware. That, not the brand, is the real constraint.

Verified means someone flashed it and drove it. Inferred means it should work, for the
reason given, and nobody has reported it.

| Console | Firmware | Patch | Status |
|---|---|---|---|
| HP2550 (Ambient WS-5000) | V2.0.4 | v2 | Verified, 2026-11 |
| HP2550 (Ecowitt) | V2.0.4 | v2 | Inferred - same brand-selected image |
| HP2560 | V2.0.4 line | v2 | Inferred - the firmware declares both HP2550 and HP2560 |

`patch.py` carries the full SHA-256 of the stock V2.0.4 image (`4ef66b3...1cae9f`) and of
each patched output, and gates on them. If you try another console and it works (or
doesn't), a report is how a row moves from inferred to verified.

## Related

- [ha-ecowitt-hp2550](https://github.com/eklundjon/ha-ecowitt-hp2550) - the Home
  Assistant integration that speaks this mailbox.
