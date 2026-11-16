"""Backlight-over-IP client for the HP2550 mailbox (port 45000).

Drives the custom-server fields the console patch uses as a command/status
mailbox:
  command slot = custom-server Station ID  (TCP write 0x2B / read 0x2A)
  status slot  = custom-server password     (v2 coexistence, TCP read 0x2A)
                 or the second upload path   (v1, TCP read 0x51)

v2 reports status in the password field, so the record push (0xAB) never touches
the upload path and the mailbox coexists with the custom-server data upload; v1
reported it in the second path and pushed paths. `status` reads whichever slot
carries a report, so it works on either firmware.

IMPORTANT: the backlight only changes once the console patch is installed. On
stock firmware these writes are a loopback -- you can set the command and read
it back (here, or on the Customized -> Setup screen), but nothing acts on it and
the status slot is never updated by the console. That loopback is still a valid
test of the mailbox plumbing.

The command carries a sequence number so the console acts on each new command
once. By default the next number is one past whatever is already in the slot;
override with --seq.

Command verbs (protocol v2, see docs/PROTOCOL.md; all share "<VERB> <VALUE> #<seq>"):
  BL n  - saved backlight level 0..100, turns auto off; no power change
          (0 is the dimmest lit level, not off)
  BL A  - auto-brightness on; no power change
  BP 0/1 - backlight power off / on at the current level
  BS 0/1 - backlight schedule enable
  DM 0/1 - dark mode off / on (1 = dark)
BA and the v2c-v2f meaning of BL 0 / BL 1 (off / on) are gone.

A v2 console reports state in the status slot as verb/value pairs:
  BP <0|1> BL <0-100|A> BS <0|1> DM <0|1> <#|!><seq>
(pairs in any order, unknown verbs ignored; DM is optional). A v2 console ends with
!<seq> when it rejected command <seq> (unknown verb or value out of range; nothing
changed) and #<seq> when it applied it; status reports rejected=1 for '!'. A command with
no valid seq (1..255) gets no ack at all. The v2c-v2f format
"BL <on> <level> <auto> <sched> #<seq>" and the v1 format "BL <on> <level> #<seq>"
are still parsed, so status works against older consoles too.

Usage:
  ewbacklight.py HOST level N        # N 0..100: BL N (level only, power unchanged)
  ewbacklight.py HOST level auto     # BL A: auto-brightness on (alias: ewbacklight.py HOST auto)
  ewbacklight.py HOST power on|off   # BP 1 / BP 0 (aliases: HOST on, HOST off)
  ewbacklight.py HOST sched on|off   # BS 1 / BS 0
  ewbacklight.py HOST dark on|off    # DM 1 / DM 0 (on = dark background)
  ewbacklight.py HOST status         # read the status slot the console writes
  ewbacklight.py HOST get            # show the raw command and status slots
  ewbacklight.py --dry-run ...       # print frames instead of sending
  ewbacklight.py --seq N ...         # force the command sequence number
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ewcustom import (  # noqa: E402  (sibling tool; verified frame builder)
    frame, transact, parse_custom, build_custom, parse_paths, payload,
    CMD_READ_CUSTOMIZED, CMD_WRITE_CUSTOMIZED, CMD_READ_USR_PATH,
)

# v1 consoles report status in the second upload path (index 1); v2 uses the password.
STATUS_PATH_INDEX = 1

SEQ_RE = re.compile(r'#(\d+)')
# v2 pair format: BP <0|1> BL <0-100|A> BS <0|1> [DM <0|1>] <#|!><seq>
PAIR_VERBS = ('BP', 'BL', 'BS', 'DM')
# v2c-v2f: BL <on> <level> <auto> <sched> #<seq>   v1: BL <on> <level> #<seq>
# (v2d+: the level field may be the single character A, auto-brightness on)
STATUS_V2_RE = re.compile(r'BL\s+(\d+)\s+(\d+|A)\s+(\d+)\s+(\d+)\s+#(\d+)')
STATUS_V1_RE = re.compile(r'BL\s+(\d+)\s+(\d+)\s+#(\d+)')


def next_seq(current_id):
    """Next command sequence number: 1-255, 8-bit, never 0 (matches the HA client)."""
    m = SEQ_RE.search(current_id or '')
    cur = int(m.group(1)) if m else 0
    return (cur % 255) + 1


def parse_pairs(raw):
    """Parse the v2 pair status. Returns a dict, or None if it is not that format.

    Pairs may come in any order and unknown verbs are ignored. BP and the trailing
    #<seq> / !<seq> are required. level is None while the console reports BL A (auto on)."""
    toks = (raw or '').split()
    if not toks or toks[0] not in PAIR_VERBS or not re.fullmatch(r'[#!]\d+', toks[-1]):
        return None
    pairs = {}
    body = toks[:-1]
    if len(body) % 2:
        return None
    for verb, val in zip(body[0::2], body[1::2]):
        pairs.setdefault(verb, val)
    if 'BP' not in pairs or not pairs['BP'].isdigit():
        return None
    lvl = pairs.get('BL')
    if lvl is not None and lvl != 'A' and not lvl.isdigit():
        return None
    def num(v):
        return int(v) if v is not None and v.isdigit() else None
    return dict(on=int(pairs['BP']),
                level=None if lvl in (None, 'A') else int(lvl),
                auto=None if lvl is None else int(lvl == 'A'),
                sched=num(pairs.get('BS')), dark=num(pairs.get('DM')),
                seq=int(toks[-1][1:]), rejected=int(toks[-1][0] == '!'), fmt='pair')


def parse_status(raw):
    """Return a dict for a v2, v2c-v2f or v1 status string, or None if it matches none.

    Keys: on, level (None under auto), auto, sched, dark (None if not reported), seq,
    rejected (1 if the last token was !<seq>), fmt ('pair', 'v2' or 'v1'). v1 has auto and sched None."""
    d = parse_pairs(raw)
    if d:
        return d
    m = STATUS_V2_RE.search(raw or '')
    if m:
        lvl = m.group(2)
        return dict(on=int(m.group(1)), level=None if lvl == 'A' else int(lvl),
                    auto=int(m.group(3)), sched=int(m.group(4)), dark=None,
                    seq=int(m.group(5)), rejected=0, fmt='v2')
    m = STATUS_V1_RE.search(raw or '')
    if m:
        return dict(on=int(m.group(1)), level=int(m.group(2)), auto=None, sched=None,
                    dark=None, seq=int(m.group(3)), rejected=0, fmt='v1')
    return None


def format_status(s, where='', raw=''):
    """One-line human text for a parse_status() dict."""
    lvl = 'A' if s['level'] is None and s['auto'] != 0 else s['level']
    if s['fmt'] == 'v1':
        return ('status: on=%d level=%d seq=%d  (v1 console, %s; raw %r)'
                % (s['on'], s['level'], s['seq'], where, raw))
    extra = '' if s['dark'] is None else ' dark=%d' % s['dark']
    ack = 'REJECTED seq=%d (nothing changed)' % s['seq'] if s.get('rejected') else 'seq=%d' % s['seq']
    return ('status: power=%d level=%s sched=%s%s %s  (%s format, %s; raw %r)'
            % (s['on'], lvl, s['sched'] if s['sched'] is not None else '?', extra,
               ack, s['fmt'], where, raw))


def onoff(word):
    w = word.lower()
    if w in ('on', '1', 'true', 'yes'):
        return 1
    if w in ('off', '0', 'false', 'no'):
        return 0
    sys.exit('expected on/off, got %r' % word)


def main(argv):
    dry = '--dry-run' in argv
    argv = [a for a in argv if a != '--dry-run']

    forced_seq = None
    if '--seq' in argv:
        i = argv.index('--seq')
        forced_seq = int(argv[i + 1])
        del argv[i:i + 2]

    if len(argv) < 2:
        sys.exit(__doc__)
    host, op = argv[0], argv[1]

    def send(pkt):
        print('->', pkt.hex(' '))
        if dry:
            return b''
        r = transact(host, pkt)
        print('<-', r.hex(' '))
        return r

    def read_custom():
        if dry:
            return dict(id='', key='', host='', port=0, interval=60, type=1, active=0)
        return parse_custom(payload(send(frame(CMD_READ_CUSTOMIZED))))

    def read_status():
        if dry:
            return '', ''
        return parse_paths(payload(send(frame(CMD_READ_USR_PATH))))

    def write_command(verb, value):
        c = read_custom()
        seq = forced_seq if forced_seq is not None else next_seq(c['id'])
        c['id'] = '%s %s #%d' % (verb, value, seq)
        print('command slot <- %r' % c['id'])
        send(frame(CMD_WRITE_CUSTOMIZED, build_custom(c)))
        if not dry:
            print('(stock firmware: this is a loopback until the console patch is installed)')

    if op in ('level', 'auto'):
        if op == 'auto' and len(argv) < 3:
            v = 'A'
        else:
            if len(argv) < 3:
                sys.exit('level needs a value 0..100 or auto')
            if argv[2].lower() in ('auto', 'a'):
                v = 'A'
            elif op == 'auto':
                sys.exit('"auto" takes no on/off any more; use "level N" to turn auto off (BA is gone)')
            else:
                v = int(argv[2])
                if not 0 <= v <= 100:
                    sys.exit('level out of range (0..100)')
        write_command('BL', v)

    elif op in ('on', 'off', 'power'):
        if op == 'power':
            if len(argv) < 3:
                sys.exit('power needs on/off')
            v = onoff(argv[2])
        else:
            v = 1 if op == 'on' else 0
        write_command('BP', v)

    elif op in ('sched', 'dark'):
        if len(argv) < 3:
            sys.exit('%s needs on/off' % op)
        write_command('BS' if op == 'sched' else 'DM', onoff(argv[2]))

    elif op == 'status':
        if dry:
            print('(dry-run: would read the status slot)')
            return
        # v2 reports in the password field; v1 in the second path. Try both.
        pw = read_custom()['key']
        raw, where = (pw, 'password') if parse_status(pw) else \
                     (read_status()[STATUS_PATH_INDEX], 'path2')
        s = parse_status(raw)
        if not s:
            print('status: no BP/BL report in either slot  (password %r)' % pw)
            print('(empty/garbage is expected on stock firmware -- the console never writes it)')
        else:
            print(format_status(s, where, raw))

    elif op == 'get':
        c = read_custom()
        p1, p2 = read_status()
        if not dry:
            print('command slot (Station ID): %r' % c['id'])
            print('status  slot (password):   %r   <- v2' % c['key'])
            print('path1 (Ecowitt upload):    %r' % p1)
            print('path2 (v1 status slot):    %r' % p2)

    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
