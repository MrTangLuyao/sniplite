"""Check the GIF encoder against the reference in this folder, and the picture
the recorder scales down.

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
from gifread import parse, compose  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
REF = os.path.join(HERE, 'refgif')
ENC = os.path.join(HERE, 'gifenc')
PIX = os.path.join(HERE, 'gifpix')

# The frame rate the pictures are made at, and so the delay of every frame.
FPS = 15

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


def build_pix():
    """The encoder of src/gif.c, driven with pixels by the harness in this folder."""
    subprocess.run(['cc', '-O2',
                    '-I', os.path.join(HERE, 'win'), '-I', os.path.join(ROOT, 'src'),
                    '-o', PIX, os.path.join(HERE, 'gifpix.c'), os.path.join(ROOT, 'src', 'gif.c')],
                   check=True)


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


# The four colours of the checkerboard, and the picture of a frame: the
# checkerboard with the block of the mode on top of it.
COLOURS = [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 0, 255)]


def picture(w, h, n, mode):
    """The picture of frame n, in colours. The grey block of mode 2 comes back
    as white: it is the nearest of the four colours, and that is what the
    quantiser promises."""
    px = []
    for y in range(h):
        for x in range(w):
            px.append(COLOURS[((x // 8) + (y // 8)) % 4])
    if mode == 0:
        x0, y0 = n * 4, h // 4
        for y in range(y0, min(h, y0 + 16)):
            for x in range(x0, min(w, x0 + 16)):
                px[y * w + x] = (255, 0, 0)
    elif mode == 2 and n >= 1:
        x0, y0 = w // 2, h // 4
        for y in range(y0, min(h, y0 + 16)):
            for x in range(x0, min(w, x0 + 16)):
                px[y * w + x] = (255, 255, 255)
    elif mode == 3:
        # a gradient: every pixel is a colour of its own, so the palette has to
        # be cut out of the colour cube
        for y in range(h):
            for x in range(w):
                px[y * w + x] = (x * 255 // (w - 1), y * 255 // (h - 1), 0x40)
    return px


def error(got, want):
    """The worst a channel is off by, over the whole picture."""
    worst = 0
    for a, b in zip(got, want):
        if a is None or b is None:
            return 255
        for i in range(3):
            worst = max(worst, abs(a[i] - b[i]))
    return worst


def delay_of(n):
    """The delay of frame n: from its number, so that the total comes out right."""
    return round((n + 1) * 100.0 / FPS) - round(n * 100.0 / FPS)


def check_pixels(tmp):
    """The encoder, driven with pixels: the frames have to come back out of the
    file as they went in."""
    build_pix()
    fails = 0
    checks = 0

    def bad(what):
        """One check that did not pass."""
        nonlocal fails
        fails += 1
        print('MISMATCH  ' + what)

    for mode in (0, 1, 2, 3):
        for w, h, nframes in ((64, 48, 4), (37, 23, 3)):
            out = os.path.join(tmp, 'pix.gif')
            subprocess.run([PIX, out, str(w), str(h), str(nframes), str(mode)], check=True)
            g = parse(out)
            checks += 1
            if g['size'] != (w, h):
                bad('pixels %dx%d mode %d: the picture is %r' % (w, h, mode, g['size']))
            if g['loop'] != 0:
                bad('pixels %dx%d mode %d: the animation does not loop' % (w, h, mode))
            if len(g['frames']) != nframes:
                bad('pixels %dx%d mode %d: %d frames, not %d' % (w, h, mode, len(g['frames']), nframes))
                continue
            for n, f in enumerate(g['frames']):
                checks += 1
                if f['gce']['delay'] != delay_of(n):
                    bad('pixels %dx%d mode %d: the delay of frame %d is %d, not %d'
                        % (w, h, mode, n, f['gce']['delay'], delay_of(n)))
                checks += 1
                if f['gce']['disposal'] != DISPOSAL:
                    bad('pixels %dx%d mode %d: the disposal method of frame %d is %d'
                        % (w, h, mode, n, f['gce']['disposal']))
            # the first frame is the whole picture, the later ones only what changed
            first = g['frames'][0]
            checks += 1
            if (first['x'], first['y'], first['w'], first['h']) != (0, 0, w, h):
                bad('pixels %dx%d mode %d: the first frame is not the whole picture' % (w, h, mode))
            checks += 1
            if first['gce']['trans'] is not None:
                bad('pixels %dx%d mode %d: the first frame has a transparent index' % (w, h, mode))
            # a frame in which nothing changed is one transparent pixel
            for n, f in enumerate(g['frames'][1:], start=1):
                if mode == 1 or (mode == 2 and n >= 2) or mode == 3:
                    checks += 1
                    if (f['w'], f['h']) != (1, 1):
                        bad('pixels %dx%d mode %d: frame %d is %dx%d, not one pixel'
                            % (w, h, mode, n, f['w'], f['h']))
            # and the picture of every frame has to come back out of the file
            for n, got in enumerate(compose(g)):
                checks += 1
                want = picture(w, h, n, mode)
                if mode == 3:
                    # the palette cannot hold every colour of a gradient: the
                    # picture comes back close to it, not exactly
                    if error(got, want) > 24:
                        bad('pixels %dx%d mode %d: the picture of frame %d is %d off'
                            % (w, h, mode, n, error(got, want)))
                        break
                elif got != want:
                    bad('pixels %dx%d mode %d: the picture of frame %d is not the one that went in'
                        % (w, h, mode, n))
                    break
            # the file has to be a valid GIF after every frame, too
            for n in range(1, nframes + 1):
                checks += 1
                part = parse('%s.%d' % (out, n))
                if len(part['frames']) != n:
                    bad('pixels %dx%d mode %d: the file after frame %d has %d frames'
                        % (w, h, mode, n, len(part['frames'])))
    return checks, fails


def check_scale(tmp):
    """The recorder scales a region down to the picture: the code is taken from
    src/rec.c, so that what is checked is what runs."""
    rec = open(os.path.join(ROOT, 'src', 'rec.c')).read()
    start = rec.find('static void scale_pixels')
    if start < 0:
        print('MISMATCH  the scaling: src/rec.c has no scale_pixels')
        return 0, 1
    end = rec.index('\n}\n', start) + 3
    code = rec[start:end]
    program = """#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
%s
int main(int argc, char **argv) {
    int w = atoi(argv[2]), h = atoi(argv[3]), sw = atoi(argv[4]), sh = atoi(argv[5]);
    uint32_t *src = malloc((size_t)w * h * 4), *dst = malloc((size_t)sw * sh * 4);
    for (int i = 0; i < w * h; i++) src[i] = (uint32_t)atoi(argv[6 + i]);
    scale_pixels(src, w, h, dst, sw, sh);
    for (int i = 0; i < sw * sh; i++) printf("%%u ", dst[i]);
    return 0;
}
""" % code
    src_file = os.path.join(tmp, 'scale.c')
    open(src_file, 'w').write(program)
    exe = os.path.join(tmp, 'scale')
    subprocess.run(['cc', '-O2', '-o', exe, src_file], check=True)
    fails = 0
    checks = 0
    for w, h, sw, sh in ((4, 4, 2, 2), (3, 3, 2, 2), (5, 3, 2, 1), (8, 8, 8, 8)):
        # the picture: every pixel is a number of its own
        picture = [(i * 37 + 11) & 0xFFFFFF for i in range(w * h)]
        got = subprocess.run([exe, 'x', str(w), str(h), str(sw), str(sh)] +
                             [str(c) for c in picture], check=True, capture_output=True, text=True)
        values = [int(v) for v in got.stdout.split()]
        # what it has to be: the average of the pixels of the block
        want = []
        for y in range(sh):
            for x in range(sw):
                y0, y1 = y * h // sh, (y + 1) * h // sh
                x0, x1 = x * w // sw, (x + 1) * w // sw
                r = g = b = n = 0
                for yy in range(y0, y1):
                    for xx in range(x0, x1):
                        v = picture[yy * w + xx]
                        r += v >> 16 & 255
                        g += v >> 8 & 255
                        b += v & 255
                        n += 1
                want.append((r // n << 16) | (g // n << 8) | b // n)
        checks += 1
        if values != want:
            print('MISMATCH  the scaling: %dx%d to %dx%d is %r, not %r' % (w, h, sw, sw, values, want))
            fails += 1
    return checks, fails


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
    pchecks, pfails = check_pixels(tmp)
    print('the pixels: %d of %d checks passed' % (pchecks - pfails, pchecks))
    schecks, sfails = check_scale(tmp)
    print('the scaling: %d of %d checks passed' % (schecks - sfails, schecks))
    return 1 if (fails or pfails or sfails) else 0


if __name__ == '__main__':
    sys.exit(main())
