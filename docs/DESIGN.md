# How the backlight patch works

The design of the v2 HP2550 backlight patch: the hook, the mailbox, the payload, and
how it behaves around the stock firmware. Useful for anyone porting it to another
firmware version, auditing it before flashing, or wondering how you bolt a feature
onto a console with no source. The wire protocol is in [PROTOCOL.md](PROTOCOL.md);
this page is the implementation.

The stock firmware already has backlight power and brightness internally - routines
for them, driven by the on-screen menus and the keypad - but nothing exposes them to
the network. The WiFi module (an ESP talking to the console MCU over serial) serves a
TCP API on port 45000, but the console answers only a fixed set of commands and none
of them touch the backlight. The capability exists; it just has no path from the
network. That path is all the patch is.

## Evidence basis

Two kinds of claim here, and they're not equally solid.

- **Hardware-tested:** the build in this repo was flashed to an Ambient WS-5000
  (HP2550, V2.0.4) and driven through every command, the reject cases, a reboot with
  a pending command, and a visit to the Customized server screen. It also ran against
  a live Ecowitt upload to a local receiver. Each stock-firmware behaviour listed
  below as observed was seen on that console.
- **Static analysis:** addresses, routine behaviour and the "nothing else writes
  this byte" claims come from reading the disassembly, plus emulating the payload
  against the real patched bytes with firmware calls stubbed. The emulator is a
  sanity check, not a predictor. An earlier model of the chip missed a failure that
  hardware then showed, so a pass there doesn't clear a build for flashing.

Where a section depends on static analysis alone, it says so.

## The mailbox

Rather than add new network code (new serial commands, new TCP handlers on the ESP,
all of which we'd have to reverse and patch), the patch borrows two text fields the
custom-server feature already carries end to end: the Station ID and the password.
A client writes a command into the Station ID with the existing `0x2B` record write.
The console writes a status report into the password, which the client reads back with
`0x2A`. Neither field means anything to the backlight normally.

The wire format is in [PROTOCOL.md](PROTOCOL.md). The part that matters here is the
sequence number: the console acts on a command only when its `<seq>` differs from the
one in the current status, so a client bumps `seq` for each command and the console
runs each exactly once.

## The hook

The payload has to run periodically, but there's no spare timer to hijack and no RTOS
hook to register from a patch. So instead of adding a caller, the patch steals one
that already runs constantly. The display task (`TaskDisplaySever`) loops: a 30-tick
`vTaskDelay`, then a call to the routine that nudges the backlight PWM toward its
target, then the current screen's draw routine. That apply call is the hook site.

The patch overwrites that one call, a 4-byte Thumb `BL`, so it points at the appended
payload. The payload's entry makes the original call first, then runs the poll, then
returns. The display loop is none the wiser, and the fade it expected still happens.

Why this site:

- It's on a non-boot task that only runs once the UI is up, so nothing early in boot
  can reach it.
- The call is AAPCS-clean there: the registers the loop needs afterward are set before
  the call and preserved across it, so a trampoline that saves and restores what it
  touches is transparent.
- A write made here is drawn in the same loop iteration, which matters for `DM`
  (below).

Don't hook the early boot path, and don't hook anything the SD-update path needs - a
patch that faults before the update task runs can't be recovered from the SD card (see
Recovery).

## The poll

The poll runs every display frame, far too often to hit the WiFi chip, so it throttles
first: a one-byte countdown (an unused byte in the custom-server record, reloaded to
100) that fires a real poll every few seconds. The payload keeps no private mutable
RAM of its own, on the theory that any byte it picks for scratch is one less thing
that can go wrong on a firmware it only half understands.

When the throttle fires, in order:

1. **Stand down** if the current screen is the Customized server screen, or the shared
   text editor opened from it (below).
2. **Boot guard:** if no `0xAA` reply has landed yet, queue a refresh and return.
3. **Last-handled seq:** parse the `#<seq>` or `!<seq>` from the status string in RAM
   (the dedup, below).
4. **Parse the command** in the Station ID. No valid `#<seq>` means it isn't a command
   at all: nothing acts, nothing is acknowledged.
5. **Act** if the command's seq differs from the last-handled one, or reject it with
   `!<seq>` if the verb or value is bad.
6. **Build the status** from live state and the seq. If it differs from the RAM
   password, copy it in and queue `0xAB` (push the record) - the change gate.
7. **Queue `0xAA`** (request the record), which refreshes RAM from the chip. This is
   the last step, always.

### Push before refresh

Step 6 coming before step 7 is the most important ordering in the payload, and it
was not the first thing we tried. The serial queue is FIFO with one consumer, so `0xAB` is
serialized from RAM before `0xAA` is even sent. The status is already in RAM at that
point, and the `0xAA` reply that follows returns the record the chip just received.
It's ordering by construction rather than a timing race.

The reverse order (refresh, wait for the reply, then push) never worked. The `0xAA`
reply overwrites the RAM password before the push is serialized, so the push sent the
old status back to the chip and the new one never landed. With no TCP traffic from
anywhere, the status didn't trail the command; it simply never arrived.

The `0xAB` push carries the whole record from RAM: Station ID, password, host, port,
interval, type and active. It doesn't carry the upload paths (those go with `0xD2`,
which the payload never sends). That is what lets the mailbox coexist with a live
upload, below.

### Boot guard

At boot, RAM isn't the chip's record. BSS is zeroed and the load-time sanity check
sets only the interval and port, so the host is empty and type/active are 0. With
push-before-refresh, the first push would send that blank record and wipe the chip's
upload configuration. The payload therefore does nothing but request a refresh until
a `0xAA` reply has landed, which the RX handler records by setting a flag byte (zero
at boot). A push can only follow a reply, so RAM holds the chip's record by then.

The same check covers the Customized screen's draw, which clears the flag: after a
visit, an act with the push blocked would record the seq nowhere and re-act every
cycle until a reply landed. The flag semantics are from static analysis, supported by
the hardware boot and screen-visit tests.

### Dedup from the status

The last-acted seq is the `#<seq>` at the end of the status the payload already keeps
in the password field. The command (Station ID) and status (password) are two fields
of one record. Every `0xAA` reply brings both back from the chip together, every
`0xAB` push sends both, and the stock Customized screen's entry load and exit push move
the same pair. So the pair in RAM is always a pair the chip held, and "command seq ==
status seq" means "this command was acted on," however the pair got there: boot, a
screen visit, a refresh.

This replaced a private dedup byte (kept in RAM at the start of the second upload
path) that failed two ways. Entering the Customized screen requests the paths from the
chip, which overwrote that byte with whatever the chip held there, so a later command
whose seq equalled it was silently ignored. And exiting the screen pushed the byte to
the chip. A byte that starts at 0 also meant the last command replayed after every
reboot. Deriving the dedup from the status removed all three. The payload now never
reads or writes the paths at all.

Edge cases, all emulated and the first two seen on hardware:

- Power cycle with `BP 0 #n` pending and the chip's status at `#n`: no replay. The
  panel stays on and the status is republished with the live power state.
- A valid command with an unparseable status (first contact, or someone typed a
  password on the screen): the command acts once, the status is rebuilt with its seq,
  and from then on it parses. Idempotent set-state commands make that cheap.
- A push that fails to land: the next reply returns the old status with the new command
  still in the slot, so the command acts once more and the push retries. It costs one
  extra act of a set-state command per dropped push. A dead ESP returns no replies, so
  nothing repeats.

### Stand-down screens

The payload skips the poll while someone is editing the record by hand. The screen id
byte indexes the display task's draw table, and four things agree that the Customized
server screen is **24**: the draw table entry for 24 is the routine whose literal pool
holds the field names (Station ID, Station Key, IP/Hostname, Port, Interval, State,
and so on); the key table has its matching handler; the screen dispatcher routes
`0x18` to that routine; and its exit path stores 5 into the screen byte, making 5 the
parent (Setup: Wunderground).

Screen 24 has a sub-screen: the shared text editor, **15**, which edits the RAM record
fields in place. Seven sites enter screen 15 with different return-to ids, so the id
alone isn't enough. The payload skips when `screen == 24`, or `screen == 15` and the
return-to byte is 24. Text entry from other screens is left alone. This holds on
hardware: State toggled to Enabled stays, text typed in the Station ID editor stays.

The static read says the return-to byte holds 24 for the whole edit; I found no writer
in the editor code, but that's analysis, not a trace.

### Reporting the saved level, or `A`

The status reports the *saved* level (CParam+0x16), or the single character `A` while
auto-brightness is on. It does not report the runtime level.

The runtime level is what the PWM fade chases, and the level evaluator rewrites it
every frame: from the solar reading when auto is on, from the saved level when it's
off. Reporting it makes the status string change nearly every cycle under auto and
after every command (the fade), and a changing string means a push every cycle. Each
push carries the Station ID from the previous refresh and overwrites a newer client
write, (on hardware only 1 of 6 commands under auto landed first try), and each push restarted the ESP's
upload timer. The saved level is stable, follows keypad changes (hardware-checked: a
keypad press to 3 reads `BL 30`), and is what `BL n` writes. With auto on, `A` ends
the drift entirely.

Cost: while the backlight is off, the level field shows the saved level, not 0.
`BP` carries power, so clients read the pair.

Auto-brightness follows the outdoor solar reading the weather station reports, not a
sensor in the console.

### BL and BP are orthogonal

Level and power are independent commands. This is deliberate: an earlier set made
`BL 0`/`BL 1` mean off/on, which collided with 0 being a valid lit level (UI 0 is
visibly lit) and made it impossible to set levels 0 and 1.

- `BL n`: sets the saved level, clears auto. If the panel is lit it calls
  `brightness_set(n)`; if dark, it only stores the value, and `BP 1` later lights at
  it. Only `brightness_set` is called. An earlier `backlight_set(1)` first re-applied
  the *old* saved level and dipped.
- `BL A`: auto on, nothing else.
- `BP 0`/`BP 1`: `backlight_set(0)`/`backlight_set(1)`, the same calls the keypad
  power key makes. A no-op when the on flag already matches. The no-op matters: a
  `BP 1` on a lit panel under auto used to jump the panel to the saved level and let
  the evaluator pull it back, a visible dip per command.

The on flag is written only by `backlight_set`, so it's a reliable lit indicator. One
residual risk (not seen): if the flag disagrees with the real panel, `BP 1` can't wake
it until a `BP 0` has been sent.

### DM and its repaint

Dark/light mode is one settings byte, CParam+0x6D, **inverted**: 0 is dark (the
factory default), 1 is light. It's flipped by the fourth home-screen key. `DM v`
writes `v ^ 1` and reports `byte == 0 ? 1 : 0`.

The home draw is incremental: it repaints the whole background only when the
full-redraw flag (`0x40038A`) is set, and a bare byte write would give a mixed look,
new glyph tables over the old background. So `DM` also sets that flag, **only when the
screen id is 0 (home)**. Every screen uses that flag as its init flag, so setting it
on a menu would restart the menu's draw. On other screens the byte is written alone and the home screen
re-initialises on return. The write sits immediately before the draw call, the same
store the keypad makes.

Hardware-tested on the home screen in both directions (clean switch, same brightness).
The behaviour on other screens, and a repaint while a transient overlay is showing,
are from code reading only.

Nothing in the backlight code reads this byte, so dark mode doesn't change brightness
(a white background is physically brighter at the same PWM value). The backlight menu
never touches it either, so a `DM` sent while the menu is open survives, unlike
`BL`/`BP`/`BS`.

### Validation

A command is rejected, not guessed at. The strictness is there because the Station ID is
a free-text field anyone with the record write can use, and the console shouldn't turn
junk into an action.

- A valid seq is `#` directly followed by decimal digits only, value 1-255, ending at
  the NUL. Anything else (`#0`, `#256`, `#12x`, `#5 junk`) isn't a command: no action
  and no acknowledgement. Digit parsing saturates, so a long digit string can't wrap
  32 bits into a valid number.
- Valid seq with an unknown verb, a bad value, or trailing junk: no action, and the
  status ends in `!<seq>`. Out-of-range values are rejected, never clamped.
- The status is built from hardware state, the validated seq, and the `#`/`!` marker.
  Nothing from the command text is copied into it.

Hardware-tested: `BL 150`, `XY 1`, `BL 40x` all returned `!`; `BL 40 #0` and
`BL 40 #256` were silently ignored.

### Change-gated push

The status is pushed only when the built string differs from the RAM password. That
makes pushes events, not a cadence: one per command, one at boot after the first
reply, and one on a real state change (a keypad power press, a schedule edge, a menu
change). With auto on and nothing happening, there are none.

This is also the flash-wear and upload-timer reasoning. See Flash wear below.

## The payload

The payload is hand-written Thumb-2 ([`backlight.s`](../backlight.s)), assembled with
LLVM and appended after the image's existing code and data. It's position-independent
in the way that matters: every call into stock firmware and every data reference goes
through an absolute address loaded from a literal pool, so the blob assumes nothing
about where it lands and needs no relocation. It reuses the stock set-power, set-level,
apply and queue-serial-command routines rather than reimplementing any, and it never
writes to its own code region at runtime. It's about 820 bytes.

## Image integrity and the build

The image ends in a 32-bit little-endian additive checksum: the sum of every byte
except the last four, stored in the last four. Change any byte and it breaks, and the
SD updater checks it before flashing, so the build fixes it up.

`patch.py` is the whole build. It refuses any input whose SHA-256 isn't the stock V2.0.4
image, applies two edits (the 4-byte hook and the appended payload), recomputes the
checksum, and verifies the result against the known SHA-256 for the build. The edits
come from `backlight_edits.json`; `backlight.s` is the source they're built from. The
hashes are the only firmware-derived constants in the repo.

## Flashing, update and recovery

The console updates from an SD card. On boot the running firmware (not a separate
bootloader; this is in the application image) looks for `user.bin` on the card,
checksum-verifies it the same way `patch.py` does, and on a match flashes it and
reboots via watchdog. A bad checksum is rejected and the old firmware left intact.

- After a successful flash the console **deletes** `user.bin` from the card, so it
  won't re-flash every boot. An update card is single-use.
- The firmware uses a dual-tag scheme (two "GPTG" descriptors) to locate the code image,
  and the updater tolerates one bad tag, failing only if both are bad. A known-good
  image on the SD card is the recovery path: re-stage stock `user.bin`, insert,
  power-cycle. The stock round-trip was exercised on hardware.

The one unguarded window is pulling the card mid-write. Don't.

The update check runs in its own task (`sdUpgradeTask`), separate from the display task
the patch hooks, and polls for the card continuously. So recovery survives any failure
where the scheduler keeps running: a wrong level, a logic bug, even a hung display task.
Only a hard fault that takes the whole MCU down before that task polls defeats it,
which is why the payload is written never to fault (bounds-checked parsing, no writes
to its own region) and was emulated before it was ever flashed.

## Stock-firmware behaviours worth knowing

These are the console's, not the patch's. Each was seen on hardware unless noted. The
client-facing consequences are in [PROTOCOL.md](PROTOCOL.md).

- **Leaving the Customized server screen pushes the record as loaded on entry.** A
  command written during the visit is lost. The screen times out on its own after
  roughly 1-1.5 minutes and takes the same exit.
- **The backlight menu writes its entry copy back on exit**, including on timeout. It
  doesn't refresh live, so a toggle sent while it's open is undone.
- **The keypad brightness control** shows saved level / 10 (truncated) and steps the raw
  level by 10 from wherever it is. Starting from a multiple of 10, UI *n* is level 10*n*.
  UI 0 / level 0 is a lit state.
- **The keypad starts the settings save** (a countdown, then a flash write of the whole
  settings block). IP commands don't, deliberately.
- **Sub-step levels are real.** The backlight drive resolves finer than the keypad's
  steps of 10, at least at the dim end: levels 0, 5 and 10 are visibly distinct.
- **An open observation:** during testing, auto-brightness was once unexpectedly on (and
  stayed on across a reboot) with no IP command that would have set it. We didn't
  investigate further.

## The WiFi module's TCP server

Port 45000 is served by the WiFi module, not the console, and the patch doesn't touch
it. Its TCP server has a few habits that a client has to work around. We went looking
after a client lost a command to a single unanswered exchange. Everything below was
measured on hardware (module firmware AMBWeatherV4.3.5, console on this patch) with a
black-box probe and no other client connected.

- **Replies go to the newest connection.** The module serves one client at a time: the
  connection it accepted most recently, as of when the request arrives. Requests that
  arrive on older connections are still read and acted on, but their replies go down the
  newest connection, or are dropped if that one has already closed. Closing the newest
  connection doesn't hand service back to an older one; the next new connection takes
  over.
  - For example, with four connections open, a record read on each of the first three
    timed out, and the fourth immediately received 162 bytes: three 54-byte replies,
    none of them its own. With the newest of two (or four) closed, reads on the rest all
    timed out.
  - The destination is fixed when the request arrives, not when the reply goes out. A
    second connection opened about 5 ms after a `0x2B` went out, with the reply due at
    about 110 ms, didn't take it (6 of 6). Neither did 488 connect-and-close cycles, one
    every 50 ms, during a command.
  - This means a client that connects, sends at once and closes after the reply is only
    exposed for the moment between its connect and its send. A client that holds a
    connection open and sends on it later loses every reply once anyone else connects,
    and neither client gets an error that says so.
  - Note that the request behind a lost reply is still carried out. A timeout on a
    `0x2B` doesn't tell you whether the record changed, so read it back.
- **It may not accept while writing.** In 2 of those 6 runs, the second connect wasn't
  accepted until the write had been answered (113 and 121 ms). Too few runs to call it a
  rule, but it fits a module that handles one thing at a time.
- **At most five connections.** With five open, the next connect got no answer at all (a
  connect timeout, not a refusal). Four held plus one exchange worked. Closing them
  restored service within a few seconds, with no reboot needed.
- **It doesn't close after replying.** The module leaves the connection open, so a client
  that waits for EOF to delimit a reply waits for its own timeout instead; the frame
  carries its length, so read to that. It does close an idle connection eventually: one
  left untouched got a FIN after 1219 s (one observation, so roughly a 20 minute idle
  timeout).
  - This implies that a client that disappears without closing (a dropped link, a crash
    mid-exchange) holds one of the five slots for up to about 20 minutes. Five of those
    at once would lock out new clients for that long.
- **Latency.** A record read (`0x2A`) was answered in about 20 ms (p95 34 ms, worst
  217 ms, over 131 reads) and a record write (`0x2B`) in about 120 ms (worst 197 ms,
  over 100 writes). Connecting took 10-50 ms.
  - Put another way, a healthy exchange is two orders of magnitude inside a 5 s
    timeout, so a timeout means a reply that went somewhere else (or nowhere), or a
    module that stopped answering for a while, not merely a slow reply.
- **No failures with one client.** Those 131 reads and 100 writes, 10 s apart, were all
  answered. That's about 17 minutes of traffic, though, so it can't rule out a rare stall.

The cause of the incident that prompted this is still open. A stolen reply needs another
client to connect inside a window of a millisecond or so, which seems unlikely, and we
haven't found another client anyway. A stall in the module itself (e.g. while it runs its
own uploads) is the obvious alternative and hasn't been tested. The client-facing rules
are in [PROTOCOL.md](PROTOCOL.md).

## Flash wear

- **Console:** the only code that writes SPI flash is the SD updater; the page-write
  primitive is called nowhere else. Settings are read from flash at boot and held in
  RAM, and a change persists only through the event-triggered save. So the patch writes
  no console flash. `BL`, `BS` and `DM` write the settings in RAM without starting the
  save, so they don't survive a reboot (hardware: auto turned on by `BL A` read off again
  after a reflash and reboot), unless a keypad or menu change saves them first.
- **WiFi module:** the push lands on the ESP, whose firmware we can't see, so whether it
  writes the record through to its own flash is unconfirmed. A `0x2B` write over TCP
  takes about 100 ms longer to answer than a read, which I suspect is a flash write,
  but that's circumstantial. The change gate keeps the
  push rate to the command rate plus real state changes. That's low, but if you're
  automating at a high rate it's worth knowing the module's side is unmeasured.

## Side effects

- **Coexists with a live Ecowitt upload** (hardware, 2026-11). The record push restarts
  the ESP's upload timer, so each command delays the next upload by up to one interval
  (observed: 32-48 seconds against a 24-second cadence, then straight back). No upload
  was lost, and the path, host, port, interval and field set never changed. This needs
  the upload's protocol set to Ecowitt ("Same as AmbWeather"); in Wunderground mode the
  Station ID and Station Key go upstream as credentials. With the upload disabled the
  protocol setting doesn't matter (all of the other testing ran that way, in Wunderground
  mode).
- The image grows by the appended payload plus the checksum change; the updater records
  the new size and bumps the stored version.
- A throttled check runs every display frame, plus the record refresh and the occasional
  push to the WiFi chip: the same commands the factory screens already issue.
- Auto-brightness and the schedule still run when enabled.

What it deliberately leaves alone: the factory recovery image and its tag, the
data-initializer section, the early boot path, the upload paths, and its own code region
at runtime.

## History

Short, because the lessons are the useful part.

- **v1** (proof of concept): command in the Station ID, status in the second upload
  path. It worked, and it proved the mailbox idea. It also set brightness by writing
  the runtime target (which the evaluator overwrites within a frame), stood down on
  screen 5 instead of 24, and pushed the paths record (`0xD2`) from RAM, wiping the
  upload path. See [`v1/README.md`](../v1/README.md).
- **The 0xD1 attempt** (flashed and reverted the same day). The theory was to request
  the paths (`0xD1`) before pushing, the way the screen-open handler does, so path 1
  survived. It made the backlight breathe: the chip's async reply overwrote RAM path 2,
  which held the dedup state, so the console re-ran the leftover `BL 1` every cycle and
  fought the auto-brightness evaluator. Lesson: don't point a state variable at a field
  an async reply can overwrite.
- **Status moves to the password** (first working v2). Pushing the record instead of the
  paths never touches path 1, which fixed the coexistence problem outright and the
  breathing with it. But the status never reached the chip, because the reply overwrote
  RAM before the push was serialized.
- **Push before refresh, boot guard.** Reordering the queue fixed the status. The reorder
  made a blank-record push possible at boot, hence the guard. Lesson: ordering by
  construction beats timing.
- **Stand-down on 24 and 15.** Hardware showed the payload acting on the Customized
  screen; the id was wrong in every earlier build.
- **Saved level, `A` under auto.** Level drift under auto-brightness caused a push per
  cycle and lost commands.
- **Dedup from the status; no private byte.** Removed the screen-visit and reboot-replay
  failures.
- **`BL 1` no-op when lit,** then the **protocol rework** (`BL`/`BP`/`BS`/`DM`, orthogonal
  level and power), then **strict validation and the reject ack**. Each was tested on the
  console before the next.

## Addresses

All offsets are into `user.bin`, which runs at base 0, so a file offset equals its
runtime address. They are specific to V2.0.4; a different build moves them, which is why
the patch is pinned to one firmware. The settings block (CParam) starts at `0x1F19090`.

| What | Address |
|---|---|
| Hook site (per-frame apply call in the display loop) | `0x1CA0E` |
| Appended payload entry | `0x2F06A4` |
| backlight apply (PWM fade) | `0x43054` |
| `backlight_set` (power 0/1) | `0x43100` |
| `brightness_set` (level) | `0x430B0` |
| queue serial command to the WiFi task | `0x4B138` |
| command slot (Station ID string, record +0x4B) | `0x1F120CF` |
| status slot (password string, record +0x74) | `0x1F120F8` |
| poll throttle byte (free byte in the record) | `0x1F12089` |
| record-valid flag (set by every `0xAA` reply) | `0x1F1D34C` |
| current screen id | `0x1F1145C` |
| return-to screen id (text editor) | `0x1F11EB4` |
| Customized server screen draw / key handler | `0x25EAC` / `0x25C14` |
| backlight on flag (written only by `backlight_set`) | `0x1F23057` |
| runtime target level / applied level | `0x1F23056` / `0x1F23058` |
| saved level (CParam+0x16) | `0x1F190A6` |
| schedule enable (CParam+0x5B) | `0x1F190EB` |
| auto-brightness enable (CParam+0x5C) | `0x1F190EC` |
| auto-brightness max / min level (CParam+0x6B, +0x6C) | `0x1F190FB` / `0x1F190FC` |
| dark mode byte (CParam+0x6D, 0 = dark) | `0x1F190FD` |
| settings-save countdown (keypad sets 0x1E) | `0x1F19025` |
| home full-redraw flag | `0x40038A` |
| solar lux (full scale 120000) | `0x1F11DA0` |
| level evaluator | `0x3A224` |
| display task (`TaskDisplaySever`) | `0x1C984` |
| SD-update task (`sdUpgradeTask`) | `0x4C7F0` |
| SD updater (`Interface_UpdateFirmware`) | `0x475D4` |
| image checksum routine | `0x12E1C` |

The schedule time bytes are the ones the schedule-enforcement code reads; I haven't
pinned down which of the four is the on-hour, on-minute and so on, and the payload
doesn't touch them. Everything else in the table is confirmed from the routines that read
or write it.
