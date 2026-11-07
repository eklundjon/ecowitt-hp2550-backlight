"""Read or write the custom-server record and upload paths over the port-45000 API.

Usage:
  ewcustom.py HOST read
  ewcustom.py HOST set-id TEXT [TYPE [ACTIVE]]
                                      # custom-server Station ID (command slot); State Disabled unless ACTIVE=1;
                                      # TYPE 0 = Ecowitt, 1 = Wunderground (Station ID only shows for 1)
  ewcustom.py HOST set-host ADDR      # custom-server upload target; other fields kept
  ewcustom.py HOST set-path TEXT      # first upload path (status slot)
  ewcustom.py --dry-run ...           # print frames instead of sending
"""
import socket
import struct
import sys

PORT = 45000
CMD_READ_CUSTOMIZED, CMD_WRITE_CUSTOMIZED = 0x2A, 0x2B
CMD_READ_USR_PATH, CMD_WRITE_USR_PATH = 0x51, 0x52


def frame(cmd, data=b''):
    body = bytes([cmd, 3 + len(data)]) + data
    if body[1] > 0xFF:
        raise ValueError('payload too long for a 1-byte size field')
    return b'\xff\xff' + body + bytes([sum(body) & 0xFF])


def transact(host, pkt, timeout=4):
    with socket.create_connection((host, PORT), timeout=timeout) as s:
        s.sendall(pkt)
        buf = b''
        try:
            while len(buf) < 4 or len(buf) < buf[3] + 2:
                chunk = s.recv(1024)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            pass
    return buf


def pstr(b, i):
    n = b[i]
    return b[i + 1:i + 1 + n].decode('latin1'), i + 1 + n


def lstr(s):
    b = s.encode('latin1')
    return bytes([len(b)]) + b


def parse_custom(d):
    sid, i = pstr(d, 0)
    key, i = pstr(d, i)
    host, i = pstr(d, i)
    port, interval = struct.unpack_from('>HH', d, i)
    typ, active = d[i + 4], d[i + 5]
    return dict(id=sid, key=key, host=host, port=port, interval=interval, type=typ, active=active)


def build_custom(c):
    return (lstr(c['id']) + lstr(c['key']) + lstr(c['host'])
            + struct.pack('>HHBB', c['port'], c['interval'], c['type'], c['active']))


def parse_paths(d):
    p1, i = pstr(d, 0)
    p2, _ = pstr(d, i)
    return p1, p2


def payload(resp):
    # header FF FF, cmd, size, data..., checksum (the checksum is sometimes missing)
    return resp[4:resp[3] + 1] if len(resp) >= 4 else b''


def main(argv):
    dry = '--dry-run' in argv
    argv = [a for a in argv if a != '--dry-run']
    host, op = argv[0], argv[1]

    def send(pkt):
        print('->', pkt.hex(' '))
        if dry:
            return b''
        r = transact(host, pkt)
        print('<-', r.hex(' '))
        return r

    if op == 'read':
        rc = send(frame(CMD_READ_CUSTOMIZED))
        rp = send(frame(CMD_READ_USR_PATH))
        if not dry:
            print(parse_custom(payload(rc)))
            print(parse_paths(payload(rp)))
    elif op == 'set-id':
        c = dict(id='', key='', host='', port=0, interval=60, type=0, active=0)
        if not dry:
            c = parse_custom(payload(send(frame(CMD_READ_CUSTOMIZED))))
        c.update(id=argv[2], active=0)
        if len(argv) > 3:
            c['type'] = int(argv[3])
        if len(argv) > 4:
            c['active'] = int(argv[4])
        send(frame(CMD_WRITE_CUSTOMIZED, build_custom(c)))
    elif op == 'set-host':
        c = dict(id='', key='', host='', port=0, interval=60, type=0, active=0)
        if not dry:
            c = parse_custom(payload(send(frame(CMD_READ_CUSTOMIZED))))
        c['host'] = argv[2]
        send(frame(CMD_WRITE_CUSTOMIZED, build_custom(c)))
    elif op == 'set-path':
        p1, p2 = '', '/weatherstation/updateweatherstation.php?'
        if not dry:
            p1, p2 = parse_paths(payload(send(frame(CMD_READ_USR_PATH))))
        send(frame(CMD_WRITE_USR_PATH, lstr(argv[2]) + lstr(p2)))
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
