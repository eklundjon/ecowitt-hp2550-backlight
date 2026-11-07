# How the backlight patch works

The design of the HP2550 backlight patch: the hook, the mailbox, the payload,
and how it survives a firmware update. Useful for anyone porting it to another
firmware version, auditing it before flashing, or just wondering how you bolt a
feature onto a console with no source.

The stock firmware already has backlight on/off and brightness internally -
there are routines for it, driven by the on-screen menus - but nothing exposes
them to the network. The WiFi module (an ESP talking to the console MCU over
serial) serves a TCP API on port 45000, but the console answers only a fixed set
of commands and none of them touch the backlight. So the capability exists; it
just has no path from the network to those routines. That path is all the patch
is.

## The mailbox

Rather than add new network code - new serial commands, new TCP handlers on the
ESP, both of which we'd have to reverse and patch - the patch borrows two text
fields the custom-server upload feature already carries end to end: the Station
ID and the second upload path. A client writes a command into the Station ID
over the existing port-45000 API; the console writes a status report into the
second path, which the client reads back. Neither field means anything to the
backlight normally, and the upload itself can be parked (point its host at
`127.0.0.1`), so repurposing them costs nothing as long as you're not actually
uploading.

The wire format is deliberately tiny:

- Command (client → Station ID): `BL <v> #<seq>`, where `v` is `0` (off), `1`
  (on at the saved level), or `2`-`100` (on at that level).
- Status (console → second path): `BL <on> <level> #<seq>`, echoing the sequence
  number it last acted on.

The sequence number is the whole concurrency story. The console acts on a command
only when its `seq` differs from the one already in the status field, so a client
bumps `seq` for each new command and the console runs each exactly once. It's
8-bit (`seq` wraps 1..255), which is plenty when commands are seconds apart.

## The hook

The payload has to run periodically, but there's no spare timer to hijack and no
RTOS hook to register from a patch. So instead of adding a caller, the patch
steals one that already runs constantly: the display task (`TaskDisplaySever`)
redraws the screen in a tight loop, and once per iteration it calls the routine
that nudges the backlight PWM toward its target. That per-frame call is the hook
site.

The patch overwrites that one call - 4 bytes, a single Thumb `BL` - so it points
at the appended payload instead. The payload's entry makes the original call
first, then runs the poll routine, then returns, so the display loop is none the
wiser and the backlight fade it expected still happens. A trampoline: original
behavior, then ours, then back.

Why this site:

- It's on a non-boot task that only runs once the UI is up, so nothing early in
  boot can reach it.
- The loop is self-pacing (gated on the LCD redraw over SPI), so the hook can't
  spin arbitrarily fast.
- The call is AAPCS-clean there: the registers the loop needs afterward are set
  before the call and preserved across it, so a trampoline that saves and
  restores what it touches is transparent.

Don't hook the early boot path, and don't hook anything the SD-update path needs
- a patch that faults before the update task runs can't be recovered from the SD
card (see Recovery).

## The poll routine

The poll runs every display frame, far too often to be hitting the WiFi chip, so
the first thing it does is throttle: decrement a one-byte countdown and bail
unless it reached zero, then reload it. Net effect is a real poll every few
seconds. The countdown lives in an unused byte of the custom-server record - the
payload keeps no private mutable RAM of its own, on the theory that any byte it
picks for scratch is one less thing that can go wrong on a firmware it only half
understands.

When the throttle fires, the routine:

1. Bails if the current screen is the Customized-setup screen, so it doesn't
   fight someone editing those fields on the console by hand.
2. Asks the WiFi chip to refresh the custom-server record - the same serial
   request the factory screens issue when you open them. This is asynchronous:
   the value read this cycle is from last cycle's reply, a one-cycle latency that
   doesn't matter at seconds-apart commands.
3. Reads the Station ID, requires the `BL ` prefix, and parses the value and
   sequence number.
4. Reads the sequence number back out of the status field - not a private
   variable - and compares. Equal means already done; bail.
5. Acts: `v == 0` → off; `v == 1` → on at the saved level; `v` in `2..100` → on,
   then set that level (clamped).
6. Writes `BL <on> <level> #<seq>` into the status field and asks the WiFi chip
   to push the paths back, so a client reading the second path sees the result.

Recovering the last-acted sequence from the status field, instead of a variable,
is what lets the payload carry zero private state - a handy property when you
can't be sure which RAM is safe to scribble on.

## The payload

The payload is hand-written Thumb-2 (see [`backlight.s`](../backlight.s)),
assembled with LLVM and appended after the image's existing code and data. It's
position-independent in the way that matters here: every call into stock firmware
and every data reference goes through an absolute address loaded from a literal
pool, so the blob assumes nothing about where it lands and needs no relocation.
It reuses the stock on/off, set-level, apply, and queue-serial-command routines
rather than reimplementing any of them, and it never writes to its own code
region at runtime - which is both correct (the image is effectively read-only
once running) and the reason the no-private-RAM design exists.

## Image integrity and the build

The image ends in a 32-bit little-endian additive checksum: the sum of every
byte except the last four, stored in the last four. Change any byte and it breaks
- and the SD updater checks it before flashing (below), so the build has to fix
it up.

`patch.py` is the whole build. It refuses any input whose SHA-256 isn't the known
stock V2.0.4 image, applies two edits (the 4-byte hook and the appended payload),
recomputes the checksum, and verifies the result against the known patched hash.
The edits come from `backlight_edits.json`; `backlight.s` is the source they're
built from. Nothing here ships or needs the firmware itself - you supply your
own, and the hashes are the only firmware-derived constants in the repo.

## Flashing, update and recovery

The console updates from an SD card. On boot the running firmware - not a
separate bootloader, this is in the application image - looks for `user.bin` on
the card, checksum-verifies it the same way `patch.py` computes it, and on a
match flashes it and reboots via watchdog. On a bad checksum it rejects the
update and leaves the old firmware intact, so a corrupt or mis-sized image fails
safe rather than bricking.

Two behaviors worth knowing:

- After a successful flash the console **deletes** `user.bin` from the card, so
  it won't re-flash every boot. An update card is single-use; re-stage it to
  flash again.
- The firmware uses a dual-tag scheme (two "GPTG" descriptors) to locate the code
  image, and the updater tolerates one bad tag, failing only if both are bad. A
  known-good image on the SD card is the recovery path: re-stage stock `user.bin`,
  insert, power-cycle.

The one unguarded window is pulling the card mid-write. Don't.

Note that the update check runs in its own task (`sdUpgradeTask`), separate from
the display task the patch hooks, and it polls for the card continuously. So
recovery survives any failure where the scheduler keeps running - a wrong level,
a logic bug, even a hung display task. The only thing that defeats it is a hard
fault that takes the whole MCU down before the update task polls, which is why
the payload is written to never fault: bounds-checked parsing, no writes to its
own region, and validated in emulation before it was ever flashed.

## Side effects

- **It breaks a concurrent custom-server data upload** (confirmed on hardware,
  2026-11). The fields don't actually overlap - the Ecowitt-protocol upload rides
  the *first* upload path, while the mailbox uses the Station ID and the *second*
  path - so this isn't a shared-field clash. It's the push: every time the poll
  writes a status it re-sends the whole paths record to the WiFi chip (`0xD2`)
  from console RAM, and the console's RAM copy of the first path is empty unless
  it was just refreshed, so the push wipes whatever upload path the chip was
  using. The chip keeps uploading, now to an empty path, which a real receiver
  (the HA `ecowitt` integration, ecowitt2mqtt) rejects. The mailbox itself keeps
  working. Net: the patch is incompatible with pushing the console's own weather
  data to Home Assistant through its custom server. It's fine when that data
  reaches HA another way - a separate GW-series gateway, say - or not at all.
  - Fix (not yet done): have the poll refresh the paths (`0xD1`) before it writes
    the status and pushes (`0xD2`), the way the screen-open handler does, so the
    push preserves the upload path. That one change should let the two coexist.
- The image grows by the appended payload plus the checksum change; the updater
  records the new size and bumps the stored version.
- A throttled check runs every display frame, plus periodic serial traffic to the
  WiFi chip (the record refresh and the path push) - the same commands the
  factory screens already issue, just more often.
- The console's auto-brightness and backlight schedule still override remote
  values when enabled.

What it deliberately leaves alone: the factory recovery image and its tag, the
data-initializer section, the early boot path, and its own code region at
runtime.

## Addresses

All offsets are into `user.bin`, which runs at base 0, so a file offset equals
its runtime address. These are specific to V2.0.4; a different build moves them,
which is why the patch is pinned to one firmware.

| What | Address |
|---|---|
| Hook site (per-frame apply call in the display loop) | `0x1CA0E` |
| Appended payload entry | `0x2F06A4` |
| backlight on/off | `0x43100` |
| set level | `0x430B0` |
| apply (PWM fade) | `0x43054` |
| queue serial command to the WiFi task | `0x4B138` |
| command slot (Station ID string) | `0x1F120CF` |
| status slot (second upload path string) | `0x1F12162` |
| poll throttle byte (free byte in the record) | `0x1F12089` |
| current screen id | `0x1F1145C` |
| display task (`TaskDisplaySever`) | `0x1C984` |
| SD-update task (`sdUpgradeTask`) | `0x4C7F0` |
| SD updater (`Interface_UpdateFirmware`) | `0x475D4` |
| image checksum routine | `0x12E1C` |
