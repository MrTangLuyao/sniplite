"""Check a GIF encoder against the reference in this folder.

The reference (refgif.c) and the encoder under test must produce the same
bytes for the same picture, and the picture must come back out of the file
unchanged.

    python3 tools/gifref/check.py            # the reference against itself
    python3 tools/gifref/check.py <encoder>  # the encoder against the reference

The encoder under test is a program that takes the same arguments as
refgif.c and writes a GIF:

    <encoder> <out.gif> <width> <height> <pattern>
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gifread import parse  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
REF = os.path.join(HERE, 'refgif')
ENC = os.path.join(HERE, 'gifenc')

# The pictures the encoders are given. The first four are the ones refgif.c
# knows; the rest are the awkward ones: all one colour, two colours, a
# gradient with noise, and a picture with long runs.
PATTERNS = [0, 1, 2, 3]
SIZES = [(1, 1), (17, 9), (64, 48), (200, 150), (400, 300)]

# What a file of the reference has to be: the delay of its one frame, and the
# disposal method, are fixed by the reference.
DELAY = 7
DISPOSAL = 1


def build_ref():
    subprocess.run(['cc', '-O2', '-o', REF, os.path.join(HERE, 'refgif.c')], check=True)


def build_enc():
    """The encoder of src/gif.c, driven by the harness in this folder.

    The stub of the Windows header is what lets common.h be compiled here.
    """
    subprocess.run(['cc', '-O2',
                    '-I', os.path.join(HERE, 'win'), '-I', os.path.join(ROOT, 'src'),
                    '-o', ENC, os.path.join(HERE, 'gifenc.c'), os.path.join(ROOT, 'src', 'gif.c')],
                   check=True)


def run(prog, out, w, h, pattern, px=None):
    """Runs the encoder. The pixels go out beside the file when they are wanted."""
    args = [prog, out, str(w), str(h), str(pattern)]
    if px:
        args.append(px)
    subprocess.run(args, check=True)
    return open(out, 'rb').read()


def problems(path, w, h):
    """What is wrong with the file, if anything."""
    g = parse(path)
    bad = []
    if g['size'] != (w, h):
        bad.append('the picture is %r, not %r' % (g['size'], (w, h)))
    if g['palette'] is None or len(g['palette']) != 256:
        bad.append('the colour table has %s entries, not 256' % (len(g['palette'] or []),))
    if g['loop'] != 0:
        bad.append('the animation loops %r times, not forever' % (g['loop'],))
    if len(g['frames']) != 1:
        bad.append('there are %d frames, not one' % len(g['frames']))
    else:
        f = g['frames'][0]
        if (f['x'], f['y'], f['w'], f['h']) != (0, 0, w, h):
            bad.append('the frame is at %r, not over the whole picture' % ((f['x'], f['y'], f['w'], f['h']),))
        if f['gce']['delay'] != DELAY:
            bad.append('the delay is %d, not %d' % (f['gce']['delay'], DELAY))
        if f['gce']['disposal'] != DISPOSAL:
            bad.append('the disposal method is %d, not %d' % (f['gce']['disposal'], DISPOSAL))
        if f['gce']['trans'] is not None:
            bad.append('there is a transparent index, and there should not be one')
    return bad


def main():
    build_ref()
    if len(sys.argv) > 1:
        under_test = sys.argv[1]
    else:
        build_enc()
        under_test = ENC
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
            # the file has to be the file it is supposed to be
            for what in problems(b, w, h):
                print('MISMATCH  %dx%d pattern %d: %s' % (w, h, pattern, what))
                fails += 1
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
