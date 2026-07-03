; hello.asm — Minimal MADS test program.
;
; Lives at $2000, fills $0600..$0609 with $00, and halts on BRK.  Useful for
; smoke-testing the full edit → assemble → emulate → halt round trip.
;
; Build:  bin/mads-build.sh examples/hello.asm
; Run:    bin/atari-run.sh  examples/build/hello.xex
; Both:   bin/mads-run.sh   examples/hello.asm
;
; Expected:  "BRK reached" at PC=$200A, A=$00, X=$0A.

        opt h+                  ; emit Atari DOS executable header
        org $2000

start
        ldx #$00
loop
        sta $0600,x             ; A is still 0 from cold reset
        inx
        cpx #$0a                ; 10 iterations
        bne loop

        brk                     ; halt — the runner stops here cleanly

        run start               ; populate the $02E0 RUN vector
