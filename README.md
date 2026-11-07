# Ecowitt HP2550 backlight patch

A small firmware patch for the Ambient Weather WS-5000 / Ecowitt HP2550 weather
console that adds **network control of the LCD backlight**, which the stock
firmware has no way to expose. It turns two unused custom-server fields into a
command/status mailbox on the console's existing port-45000 API, so a client on
the LAN can turn the backlight on and off and set its level. The Home Assistant
end is a separate integration,
[ha-ecowitt-hp2550](https://github.com/eklundjon/ha-ecowitt-hp2550).

This modifies the console's firmware. **You can brick the console.** Flash at
your own risk, on hardware you own, and keep a known-good image on an SD card for
recovery (see below). Not affiliated with or endorsed by Ambient Weather or
Ecowitt.

## No firmware here - you supply your own

A patched image is a derivative of the vendor's copyrighted firmware, so this
repo ships **source and hashes, never firmware**. What's here is the payload
source, the build tool, and a reference client - all original work. You bring
your own `user.bin` (dumped from your console, or the vendor's official firmware
download), and the build runs entirely on your machine:

- `patch.py` refuses to touch anything whose SHA-256 isn't the exact stock image
  it targets (Ambient / Ecowitt HP2550 **V2.0.4**). So you can't accidentally
  patch the wrong build and flash something broken.
- It applies the patch and prints the expected output hash, so you can confirm a
  correct build before it goes near the console.

## What it does

The patch hooks the console's display refresh loop and, a few times a second,
reads a command out of one custom-server text field and writes a status report
into another. It reuses the console's own backlight and WiFi-serial routines -
there's no new network code. The command language is small: on, off, or a level
0-100, each carrying a sequence number so the console acts on each new command
once.

See [docs/DESIGN.md](docs/DESIGN.md) for how the hook, the mailbox and the
payload actually work.

## Side effects

- It repurposes two custom-server fields (the Station ID and the second upload
  path) as the mailbox. If you also use the console's real custom-server upload,
  that collides - pick one. Park the upload host somewhere harmless (e.g.
  `127.0.0.1`) if you're not using it.
- The image grows by a few hundred bytes and its checksum changes. The SD updater
  records the new size and bumps the stored version on flash.
- The patched code runs a throttled check every display frame, and drives the
  WiFi chip with the same serial commands the factory screens already use.
- The console's **auto-brightness** and **backlight schedule** still override
  remote values when enabled - auto-brightness owns the level, the schedule owns
  on/off. For control that sticks, disable both on the console.

It doesn't touch the factory recovery image, the data-init section, or anything
on the early boot path, and it treats the code region as read-only at runtime.

## Apply it

You need Python 3 and an SD card. Rebuilding the payload from source (rather than
using the committed build) also needs the LLVM toolchain (`clang`,
`llvm-objcopy`); most people won't.

1. Get your console's `user.bin` (V2.0.4) onto your machine.
2. `python3 patch.py verify user.bin` - confirms it's the exact stock image.
3. `python3 patch.py build user.bin --out user_patched.bin` - applies the patch,
   fixes the checksum, and verifies the output against the known-good hash.
4. Format the SD card **FAT16 or FAT32, MBR scheme**, and copy
   `user_patched.bin` onto it as `user.bin`.
5. Insert it and power-cycle the console. It finds the file, checksum-verifies it,
   flashes, and reboots on its own. The console deletes the update file after a
   successful flash, so an update card is single-use.

Keep a card with the **stock** `user.bin` for recovery: re-stage it, insert,
power-cycle. The updater rejects a bad checksum and leaves the old firmware
intact, so the only real danger is pulling the card mid-write.

## Supported firmware

The patch is pinned to one firmware build - fixed code offsets and a checksum -
so it applies to that build regardless of brand, and needs re-porting for any
other version even on identical hardware. That, not the brand, is the real
constraint.

| Console | Firmware | Status |
|---|---|---|
| HP2550 (Ambient WS-5000) | V2.0.4 | Verified, 2026-11 |
| HP2550 (Ecowitt) | V2.0.4 | Inferred - same brand-selected image |
| HP2560 | V2.0.4 line | Inferred - the firmware declares both HP2550 and HP2560 |

`patch.py` carries the full SHA-256 of both the stock V2.0.4 image
(`4ef66b3…1cae9f`) and the patched output, and gates on them.

## Related

- [ha-ecowitt-hp2550](https://github.com/eklundjon/ha-ecowitt-hp2550) - the Home
  Assistant integration that speaks this mailbox.
