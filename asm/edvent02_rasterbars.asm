; edvent02_rasterbars.asm — WSYNC raster-color-bars demo.
;
; Demonstrates ROADMAP.md Phase 3's WSYNC support: STA WSYNC stalls the
; CPU to the end of the current scanline, so writing a new COLBK
; (background color) value right after each WSYNC release paints one
; distinct color per scanline — the classic "raster bars" effect.
;
; The bar loop repeats every frame (it re-syncs to the top of the
; display via VCOUNT each time round), so any captured frame shows the
; bars, not just the first one after boot.
;
; Build: scripts/mads-build.sh asm/edvent02_rasterbars.asm
; Run:   scripts/atari-run.sh asm/build/edvent02_rasterbars.xex -frame 30 -o rasterbars.png

        opt h+                  ; emit Atari DOS executable header
        org $2000

WSYNC  = $d40a
COLBK  = $d01a
VCOUNT = $d40b

start
        sei                     ; no OS/DLI interrupts stepping on our raster timing

frame
        ; Wait for the vertical blank (VCOUNT >= 124, i.e. scanline >=
        ; 248), then for the new frame to begin (VCOUNT < 124 again), so
        ; the color-bar loop below starts near the top of the display.
waithi
        lda VCOUNT
        cmp #124
        bcc waithi
waitlo
        lda VCOUNT
        cmp #124
        bcs waitlo

        ldx #64                 ; paint 64 scanlines
        lda #0                  ; starting COLBK value

bars
        sta WSYNC               ; stall to the end of THIS scanline
        sta COLBK               ; ... then color the scanline we just entered
        clc
        adc #16                 ; advance hue (COLBK bits 7-4); wraps mod 256
        dex
        bne bars

        jmp frame

        run start
