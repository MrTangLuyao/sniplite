"""An independent GIF reader.

It parses the file and decodes the LZW itself, rather than leaning on a
library, so that it is a second opinion about the format and not a copy of
the encoder's idea of it. It is used by check.py.
"""
import struct


def parse(path):
    """Returns {'size': (w, h), 'frames': [...]} for a GIF file."""
    d = open(path, 'rb').read()
    if d[:6] not in (b'GIF87a', b'GIF89a'):
        raise ValueError('not a GIF: %r' % d[:6])
    p = 6
    w, h, packed, bg, aspect = struct.unpack_from('<HHBBB', d, p)
    p += 7
    gct = None
    if packed & 0x80:
        n = 2 << (packed & 7)
        gct = [tuple(d[p + 3 * i:p + 3 * i + 3]) for i in range(n)]
        p += 3 * n
    frames = []
    gce = None
    loop = None
    while p < len(d):
        b = d[p]
        if b == 0x3B:  # the trailer
            break
        if b == 0x21:  # an extension
            label = d[p + 1]
            p += 2
            blocks = b''
            while d[p] != 0:
                ln = d[p]
                blocks += d[p + 1:p + 1 + ln]
                p += 1 + ln
            p += 1
            if label == 0xF9:  # the graphic control extension
                flags = blocks[0]
                gce = {
                    'delay': struct.unpack_from('<H', blocks, 1)[0],
                    'trans': blocks[3] if flags & 1 else None,
                    'disposal': (flags >> 2) & 7,
                }
            elif label == 0xFF and blocks[:11] == b'NETSCAPE2.0':  # the loop count
                loop = struct.unpack_from('<H', blocks, 12)[0]
            continue
        if b == 0x2C:  # the image descriptor
            ix, iy, iw, ih, ipacked = struct.unpack_from('<HHHHB', d, p + 1)
            p += 10
            lct = None
            if ipacked & 0x80:
                n = 2 << (ipacked & 7)
                lct = [tuple(d[p + 3 * i:p + 3 * i + 3]) for i in range(n)]
                p += 3 * n
            mincode = d[p]
            p += 1
            data = b''
            while d[p] != 0:
                ln = d[p]
                data += d[p + 1:p + 1 + ln]
                p += 1 + ln
            p += 1
            px = lzw_decode(data, mincode, iw * ih)
            frames.append({
                'x': ix, 'y': iy, 'w': iw, 'h': ih, 'px': px,
                'pal': lct or gct, 'gce': gce,
                'interlaced': bool(ipacked & 0x40),
            })
            gce = None
            continue
        raise ValueError('unknown block %#x at %d' % (b, p))
    return {'size': (w, h), 'frames': frames, 'palette': gct, 'loop': loop}


def compose(g):
    """The picture of every frame, as a viewer shows it: the transparent index
    means the pixel of the frame before stays. The colours, not the indices."""
    w, h = g['size']
    canvas = [None] * (w * h)
    out = []
    for f in g['frames']:
        pal = f['pal']
        trans = f['gce']['trans'] if f['gce'] else None
        for i, v in enumerate(f['px']):
            if trans is not None and v == trans:
                continue
            canvas[(f['y'] + i // f['w']) * w + f['x'] + i % f['w']] = pal[v]
        out.append(list(canvas))
    return out


def lzw_decode(data, mincode, npix):
    """The GIF flavour of LZW, decoded from the bytes of one frame."""
    clear = 1 << mincode
    end = clear + 1
    dic = {i: [i] for i in range(clear)}
    nxt = end + 1
    size = mincode + 1
    out = []
    acc = 0
    bits = 0
    prev = None
    for byte in data:
        acc |= byte << bits
        bits += 8
        while bits >= size:
            code = acc & ((1 << size) - 1)
            acc >>= size
            bits -= size
            if code == clear:
                dic = {i: [i] for i in range(clear)}
                nxt = end + 1
                size = mincode + 1
                prev = None
                continue
            if code == end:
                return out
            if code in dic:
                entry = dic[code]
            elif prev is not None:
                entry = dic[prev] + [dic[prev][0]]
            else:
                raise ValueError('bad code %d' % code)
            out.extend(entry)
            if prev is not None:
                dic[nxt] = dic[prev] + [entry[0]]
                nxt += 1
                if nxt == (1 << size) and size < 12:
                    size += 1
            prev = code
            if len(out) >= npix:
                return out[:npix]
    return out[:npix]
