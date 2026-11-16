# v1 payload (superseded)

This is the first backlight payload, the one the repo shipped with: a proof of
concept that showed the mailbox idea works on hardware. It's kept here unchanged
so the history is reproducible. **Use v2** (the build at the repo root) instead.
`patch.py build --v1` still builds it, and checks the output against its known
SHA-256.

Known bugs, none of which will be fixed here:

- It stands down on screen 5 (Setup: Wunderground) when it means the Customized
  server screen, which is 24. So it keeps polling while you're on the Customized
  screen, and its refresh reverts on-screen edits of the custom server (toggling
  State to Enabled flips back within a second or so).
- Its status push (`0xD2`) re-sends the whole paths record from console RAM, which
  wipes the Ecowitt upload path. It's incompatible with a live custom-server
  upload.
- The last command replays after a reboot, because nothing records on the console
  side that it was already acted on.
- It sets brightness by writing the runtime target level, which the console's
  level evaluator rewrites within a frame, so a level doesn't hold.

v1 has a different protocol (`BL 0`/`BL 1` as off/on, status in path2, no `BP`,
`BS` or `DM`). `client/ewbacklight.py` can still read its status. If you're going
back to v1 from v2, clear the custom-server password first (see the README).

Files: `backlight.s` (payload source), `backlight_edits.json` (hook and payload
bytes, as `patch.py` consumes them).
