"""Build user_patched.bin from stock user.bin plus an edit set, fixing the checksum.

This is the build harness only. It carries no firmware code of its own: the
backlight payload, the hook-site patch, and the dispatcher-table edit all come
from an external edits file produced by the assembler step (see PATCH_SPEC.md).
With no edits loaded it performs a no-op round-trip, which is a useful self-test
of the checksum arithmetic (output must be byte-identical to the stock image).

Image format: the file is `body || checksum`, where checksum is the low 32 bits
of the sum of every byte in body, stored little-endian in the final 4 bytes.

Usage:
  patch.py verify [STOCK]                 # check SHA-256 and trailing checksum
  patch.py build  [STOCK] [--edits F] [--out F]
  patch.py --help

Edits file (JSON), all byte strings hex, offsets decimal or 0x-hex:
  {
    "overwrites": [{"offset": "0x1c984", "bytes": "01de"}, ...],
    "append": "..hex..",          # new code/data placed after the image body
    "notes": "free text"
  }
Overwrite offsets are absolute offsets into the ORIGINAL image body (before the
trailing checksum). Appended bytes land at offset len(body) in the patched image
(the old 4 checksum bytes are not code and are overwritten by the new trailer).
"""
import hashlib
import json
import os
import struct
import sys

STOCK_SHA = '4ef66b35e756c091e922b47af5ab1f67cfd9f67905a2f14a3fe0915b1b1cae9f'
PATCHED_SHA = '3874906d2361360e8f1bd73753ae390f8f1b9bfc3a3b53090437ec2adac32899'
STOCK_LEN = 3081893
TRAILER = 4  # bytes of trailing little-endian checksum


def load_stock(path):
    with open(path, 'rb') as f:
        data = f.read()
    sha = hashlib.sha256(data).hexdigest()
    if sha != STOCK_SHA:
        sys.exit('refusing: %s is not the known stock image\n  expected SHA-256 %s\n  got      %s'
                 % (path, STOCK_SHA, sha))
    if len(data) != STOCK_LEN:
        sys.exit('refusing: unexpected length %d (want %d)' % (len(data), STOCK_LEN))
    return data


def checksum(body):
    return sum(body) & 0xFFFFFFFF


def verify(path):
    data = load_stock(path)
    body, stored = data[:-TRAILER], struct.unpack('<I', data[-TRAILER:])[0]
    calc = checksum(body)
    print('file         %s' % path)
    print('SHA-256      %s' % hashlib.sha256(data).hexdigest())
    print('             matches known stock image (V2.0.4)')
    print('size         %d bytes (0x%X)' % (len(data), len(data)))
    print('body         %d bytes, checksummed' % len(body))
    print('stored cksum 0x%08X' % stored)
    print('computed     0x%08X' % calc)
    print('match        %s' % ('yes' if calc == stored else 'NO'))
    return calc == stored


def _int(x):
    return int(x, 0) if isinstance(x, str) else int(x)


def load_edits(path):
    if not path or not os.path.exists(path):
        return [], b'', None
    with open(path) as f:
        spec = json.load(f)
    overwrites = [(_int(e['offset']), bytes.fromhex(e['bytes'].replace(' ', '')))
                  for e in spec.get('overwrites', [])]
    append = bytes.fromhex(spec.get('append', '').replace(' ', ''))
    return overwrites, append, spec.get('notes')


def build(path, edits_path, out_path):
    stock = load_stock(path)
    overwrites, append, notes = load_edits(edits_path)

    body = bytearray(stock[:-TRAILER])
    append_base = len(body)

    changed = []
    for off, new in overwrites:
        if off < 0 or off + len(new) > append_base:
            sys.exit('overwrite at 0x%X len %d runs past the image body (0x%X)'
                     % (off, len(new), append_base))
        old = bytes(body[off:off + len(new)])
        body[off:off + len(new)] = new
        changed.append((off, old, bytes(new)))

    body += append
    body += struct.pack('<I', checksum(body))

    with open(out_path, 'wb') as f:
        f.write(body)

    if notes:
        print('notes: %s' % notes)
    if not overwrites and not append:
        print('no edits loaded: no-op round-trip (output should equal the stock image)')
    for off, old, new in changed:
        print('overwrite 0x%06X  %s -> %s' % (off, old.hex(), new.hex()))
    if append:
        print('append    0x%06X  %d bytes' % (append_base, len(append)))
    out_sha = hashlib.sha256(body).hexdigest()
    print('out          %s' % out_path)
    print('size         %d bytes (0x%X)  [stock %d]' % (len(body), len(body), STOCK_LEN))
    print('new cksum    0x%08X' % struct.unpack('<I', body[-TRAILER:])[0])
    print('new SHA-256  %s' % out_sha)
    if out_sha == PATCHED_SHA:
        print('verified     output matches the known-good patched image')
    else:
        print('note         output does NOT match the reference patched SHA')
        print('             reference %s' % PATCHED_SHA)
        print('             (expected only if you changed the payload or edits)')


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        sys.exit(__doc__)
    op = argv[0]
    rest = argv[1:]

    def opt(name, default):
        if name in rest:
            i = rest.index(name)
            val = rest[i + 1]
            del rest[i:i + 2]
            return val
        return default

    edits_path = opt('--edits', None)
    out_path = opt('--out', 'user_patched.bin')
    stock = rest[0] if rest else 'user.bin'

    if op == 'verify':
        sys.exit(0 if verify(stock) else 1)
    elif op == 'build':
        if edits_path is None:
            default = os.path.join(os.path.dirname(os.path.abspath(stock)), 'backlight_edits.json')
            edits_path = default if os.path.exists(default) else None
        build(stock, edits_path, out_path)
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
