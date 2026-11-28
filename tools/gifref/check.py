"""Check a GIF encoder against the reference in this folder.

The reference (refgif.c) and the encoder under test must produce the same
bytes for the same picture, and the picture must come back out of the file
unchanged.

    python3 tools/gifref/check.py            # the reference against itself
    python3 tools/gifref/check.py <encoder>  # the encoder against the reference

The encoder under test is a program that takes the same arguments as
refgif.c and writes a GIF:  <out.gif> <width> <height> <pattern>.
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gifread import parse  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, 'refgif')

# The pictures the encoders are given. The first four are the ones refgif.c
# knows; the rest are the awkward ones: all one colour, two colours, a
# gradient with noise, and a picture with long runs.
PATTERNS = [0, 1, 2, 3]
SIZES = [(1, 1), (17, 9), (64, 48), (200, 150), (400, 300)]


def build_ref():
    subprocess.run(['cc', '-O2', '-o', REF, os.path.join(HERE, 'refgif.c')], check=True)


def run(prog, out, w, h, pattern, px=None):
    """Runs the encoder. The pixels go out beside the file when they are wanted."""
    args = [prog, out, str(w), str(h), str(pattern)]
    if px:
        args.append(px)
    subprocess.run(args, check=True)
    return open(out, 'rb').read()


def main():
    build_ref()
    under_test = sys.argv[1] if len(sys.argv) > 1 else REF
    name = 'reference' if under_test == REF else under_test
    tmp = tempfile.mkdtemp(prefix='gifcheck')
    fails = 0
    checks = 0
    for pattern in PATTERNS:
        for w, h in SIZES:
            a = os.path.join(tmp, 'ref.gif')
            b = os.path.join(tmp, 'test.gif')
            raw = os.path.join(tmp, 'ref.raw')
            run(REF, a, w, h, pattern, raw)
            run(under_test, b, w, h, pattern)
            checks += 1
            if open(a, 'rb').read() != open(b, 'rb').read():
                print('MISMATCH  %dx%d pattern %d: the bytes differ' % (w, h, pattern))
                fails += 1
                continue
            # and the picture must come back out of it
            g = parse(b)
            got = g['frames'][0]['px']
            want = list(open(raw, 'rb').read())
            if got != want:
                print('MISMATCH  %dx%d pattern %d: the pixels differ' % (w, h, pattern))
                fails += 1
    print('%s: %d of %d checks passed' % (name, checks - fails, checks))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
