# fixtures/

Small binary assets this project's own code depends on at runtime and
therefore commits directly -- unlike `roms/`, which is gitignored because
it holds copyrighted Atari OS/BASIC ROM dumps the user must supply
themselves.  Nothing here is copyrighted third-party material.

## xexboot.bin

The assembled boot-sector loader `src/xex.lisp` (ROADMAP.md Phase 16,
stage 16d) prepends to a raw XEX/OBX file to build an in-memory bootable
ATR image (`make-xex-atr`).

- Source: `minimal-xl/tools/xexboot.asm`, part of this project's own
  `minimal-xl` submodule (an OS this project controls, not a copyrighted
  ROM dump).
- Built with: `make -C minimal-xl xexboot.bin` (invokes `mads
  tools/xexboot.asm -o:xexboot.bin`; see `minimal-xl/Makefile`).
- Submodule commit it was built from: `446eb6a1aafaba711cb94df50ae41d6e66c66d82`.
- Verified byte-identical to `minimal-xl/xexboot.bin` at that commit
  before being committed here.

If `minimal-xl/tools/xexboot.asm` ever changes, rebuild and re-copy:

```sh
make -C minimal-xl xexboot.bin
cp minimal-xl/xexboot.bin fixtures/xexboot.bin
```

and update the submodule commit noted above.
