# gifref — the reference for the GIF encoder

This folder is how the encoder in `src/gif.c` is checked. It is not part of
the program and is not linked into it.

## What is here

- `refgif.c` — a reference GIF encoder. It is deliberately the plainest
  possible implementation of the format: not small, not fast, only obviously
  correct. It is the yardstick.
- `gifread.py` — an independent GIF reader, with its own LZW decoder. It
  parses the file rather than leaning on a library, so it is a second opinion
  about the format and not a copy of the encoder's idea of it.
- `check.py` — the check itself.

## Running it

    python3 tools/gifref/check.py              # the reference against itself
    python3 tools/gifref/check.py <encoder>    # the encoder against the reference

The encoder under test is a program that takes the same arguments as
`refgif.c` and writes a GIF:

    <encoder> <out.gif> <width> <height> <pattern>

`pattern` is 0 for random, 1 for a gradient, 2 for one colour, 3 for
alternating.

For every picture the check asks two questions: are the bytes the same as the
reference's, and does the picture come back out of the file unchanged?

## Why it is not in src/

The program is about 320 KB and the author watches its size. A test harness
does not belong in it. But the encoder's correctness rests on this, so it is
in the repository, and a reader of the pull request can run it.

It needs a C compiler and Python with PIL. The PIL part is a convenience: the
reader in `gifread.py` does the work on its own.
