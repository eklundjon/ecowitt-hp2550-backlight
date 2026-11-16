# Backlight mailbox protocol, v2

The command and status language the patched console speaks, and what a client has
to allow for. This is the spec for the v2 patch; [DESIGN.md](DESIGN.md) covers how
the payload implements it. The reference client is
[`client/ewbacklight.py`](../client/ewbacklight.py).

There's no new network code on the console. Everything rides the port-45000 API
the WiFi module already serves, in two fields of the custom-server record.

## Transport

Frames are the stock port-45000 format. Read the custom-server record with `0x2A`,
write it with `0x2B`. The record is, in order: Station ID, password, host (each a
length-prefixed string), then port, interval (big-endian 16-bit), type, active.

- **Command slot:** the Station ID.
- **Status slot:** the password.

If the custom-server upload is enabled, its protocol **shall** be Ecowitt (type 0,
shown as "Same as AmbWeather" on Ambient-branded consoles).
note: in Wunderground mode (type 1) the console sends the Station ID and the
password (Station Key) upstream as credentials, i.e. the mailbox's command and
status. With the upload disabled, either protocol works.

note: the console doesn't need the custom server enabled for the mailbox to work.
With it enabled and pointed at a real receiver, the mailbox coexists with the
Ecowitt upload (see Behaviour clients must allow for).

## Commands

One command per write: `<VERB> <VALUE> #<seq>`, ASCII, single spaces.

`<seq>` is 1-255. Clients increment it and wrap 255 to 1. The console acts on a
command once, when its `<seq>` differs from the `#<seq>` or `!<seq>` in the current
status. Every command sets state; there are no toggles, so a command acted on twice
leaves the same state as once.

| Verb | Value | Effect |
|---|---|---|
| `BL` | `0`-`100` | Backlight level. Sets the saved level and turns auto-brightness off. Does not change power: if the backlight is off it stays off, and the level applies when it next comes on. 0 is the dimmest lit level, not off. |
| `BL` | `A` | Auto-brightness on (level follows the outdoor solar reading). Does not change power. |
| `BP` | `0` / `1` | Backlight power: off, or on at the current level (the auto level if auto is on). `BP 1` on a lit panel and `BP 0` on a dark one are no-ops. |
| `BS` | `0` / `1` | Backlight schedule enable. |
| `DM` | `0` / `1` | Dark mode: 0 = light background, 1 = dark (the console default). |

### Validation and acknowledgement

| Command received | Acted on | Acknowledged in the status as |
|---|---|---|
| No `#<seq>`, or `<seq>` outside 1-255 | no | nothing (status unchanged) |
| Valid `<seq>`, unknown verb or a value outside the verb's domain (`BL 101`, `BS 9`, `BP 2`) | no | `!<seq>` (rejected) |
| Valid `<seq>`, valid verb and value | yes (a no-op if already in that state) | `#<seq>` (applied) |

Syntax is strict:

- Exactly one space between verb and value and before `#`, no other whitespace.
- Numbers are plain decimal. Leading zeros are accepted (`BL 040` = 40, `#007` echoes as `#7`).
- The first `#` starts the seq, which runs to the end of the field.
- Out-of-range values are rejected, never clamped or coerced.
- The status is built only from the console's state. Nothing from a command
  appears in it except the validated `<seq>`.

## Status

The console writes the status into the password field and pushes it to the WiFi
module whenever the string changes:

```
BP <0|1> BL <0-100|A> BS <0|1> [DM <0|1>] <#|!><seq>
```

Each pair is the command that would reproduce that piece of state.

| Pair | Meaning |
|---|---|
| `BP 0/1` | Backlight power. The only on/off indicator. |
| `BL n` / `BL A` | Saved level (stable; follows keypad changes), or `A` while auto-brightness is on. Reported while the backlight is off, too. |
| `BS 0/1` | Schedule enable. |
| `DM 0/1` | Dark mode (1 = dark). Optional for clients: absent on builds without it. |
| `#<seq>` / `!<seq>` | Last command with a valid seq: `#` applied, `!` rejected (nothing changed). `#0` means none since the status was last empty. |

Client parsing rules:

- Split on spaces into verb/value pairs, then the trailing `#<seq>` or `!<seq>`.
- Accept pairs in any order and ignore unknown verbs, so pairs can be added later
  without breaking clients.
- A status that doesn't start with a known verb means the console hasn't published
  one yet.

Example: `BP 1 BL A BS 0 #7` is on, auto-brightness, schedule off, last command 7.

Length is at most 26 characters (`DM` present, 3-digit level and seq). The console
accepts a password of up to 39 characters; a longer one is dropped, not truncated.

## Timing

The console polls about every 3-6 seconds (a throttled check in the display loop),
and an applied command is typically echoed 6-12 seconds after the write. Clients
should wait up to roughly twice the poll period plus a couple of seconds before
treating a missing echo as lost.

note: the poll period is estimated, not measured precisely. The 6-12 second echo
range is what we saw on hardware.

## Behaviour clients must allow for

These come from the stock firmware, not the patch. The patch can't change them.

- **Confirm, then send.** Wait for `#<seq>` (applied) or `!<seq>` (rejected: don't
  resend) before the next command. A second command written within one poll cycle
  of the first can be overwritten by the push that reports the first.
- **Customized server screen.** While someone is on it, or in its text editor, the
  patch stands down. Leaving it (by key, or by its roughly 1-1.5 minute timeout)
  pushes the record as loaded on entry, so a command written during the visit is
  lost. Resend if the echo doesn't arrive.
- **Backlight menu.** It shows settings as of entry and writes them back on exit
  (including timeout), which undoes `BL`/`BP`/`BS` sent while it was open. `DM`
  survives, since the menu never touches that byte.
- **Settings are RAM-only.** `BL`, `BS` and `DM` over IP write the console's RAM
  settings, not flash, so they don't survive a reboot unless a console menu or
  keypad change saves them first. The console comes up on its saved settings and
  publishes them; clients that care re-assert desired state after a reboot.
  - Caveat: a keypad change starts the console's own settings save, which writes
    all of the settings block, so IP-set values present at that moment get saved
    too. Deliberate: IP commands don't start the save themselves, to avoid a flash
    write per command from an automation.
- **Uploads.** Each command delays the next custom-server upload by up to one
  interval, since pushing the record restarts the module's upload timer.
- **Brightness scale.** The keypad's 0-10 is level / 10, truncated, and its steps
  are 10 wide from wherever the level is (75 goes to 85, shown as 8). Levels
  between steps are real and visibly distinct, so use the full 0-100 range;
  multiples of 10 keep the console and a client displaying the same number.
- **Auto-brightness and the schedule** still run when enabled. `BL n` turns auto
  off; the schedule keeps its own on/off times and flips power at them, so disable
  it (`BS 0`) for power commands that stick.
- **Power key.** The console's power key changes `BP`; clients should treat the
  status as authoritative and follow it.
