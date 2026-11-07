"""Backlight-over-IP client for the HP2550 mailbox (port 45000).

Drives the custom-server fields the phase-2 console patch uses as a
command/status mailbox:
  command slot = custom-server Station ID  (TCP write 0x2B / read 0x2A)
  status slot  = second upload path        (TCP write 0x52 / read 0x51)

IMPORTANT: the backlight only changes once the console patch is installed. On
stock firmware these writes are a loopback -- you can set the command and read
it back (here, or on the Customized -> Setup screen), but nothing acts on it and
the status slot is never updated by the console. That loopback is still a valid
test of the mailbox plumbing.

The command carries a sequence number so the console acts on each new command
once. By default the next number is one past whatever is already in the slot;
override with --seq.

Usage:
  ewbacklight.py HOST on
  ewbacklight.py HOST off
  ewbacklight.py HOST level N        # N 0..100; 0 = off, 1 = on, 2..100 = brightness
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

# The status slot is the second upload path (see PATCH_SPEC.md). Flip to 0 if
# on-device testing shows the console writes status into the first path instead.
STATUS_PATH_INDEX = 1

SEQ_RE = re.compile(r'#(\d+)')
STATUS_RE = re.compile(r'BL\s+(\d+)\s+(\d+)\s+#(\d+)')


def next_seq(current_id):
    m = SEQ_RE.search(current_id or '')
    return int(m.group(1)) + 1 if m else 1


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

    if op in ('on', 'off', 'level'):
        if op == 'on':
            v = 1
        elif op == 'off':
            v = 0
        else:
            if len(argv) < 3:
                sys.exit('level needs a value 0..100')
            v = int(argv[2])
            if not 0 <= v <= 100:
                sys.exit('level out of range (0..100)')

        c = read_custom()
        seq = forced_seq if forced_seq is not None else next_seq(c['id'])
        c['id'] = 'BL %d #%d' % (v, seq)
        print('command slot <- %r' % c['id'])
        send(frame(CMD_WRITE_CUSTOMIZED, build_custom(c)))
        if not dry:
            print('(stock firmware: this is a loopback until the console patch is installed)')

    elif op == 'status':
        paths = read_status()
        if dry:
            print('(dry-run: would read the status slot)')
            return
        raw = paths[STATUS_PATH_INDEX]
        m = STATUS_RE.search(raw or '')
        if m:
            on, level, seq = int(m.group(1)), int(m.group(2)), int(m.group(3))
            print('status: on=%d level=%d seq=%d  (raw %r)' % (on, level, seq, raw))
        else:
            print('status: no BL report in slot  (raw %r)' % raw)
            print('(empty/garbage is expected on stock firmware -- the console never writes it)')

    elif op == 'get':
        c = read_custom()
        p1, p2 = read_status()
        if not dry:
            print('command slot (Station ID): %r' % c['id'])
            print('status  slot (path1):      %r' % p1)
            print('status  slot (path2):      %r' % p2)
            print('(status slot per spec is path%d)' % (STATUS_PATH_INDEX + 1))

    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
