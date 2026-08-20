; EdVenture - An Adventure in Atari 8-Bit Assembly
; Video 4: Colors

	org $2000

SDLSTL  = $0230 	; Display list starting address
CHBAS   = $02f4     ; Character Base Register
COLOR0  = $02c4     ; Color for %01
COLOR1  = $02c5     ; Color for %10
COLOR2  = $02c6     ; Color for %11 (normal)
COLOR3  = $02c7     ; Color for %11 (inverse)
COLOR4  = $02c8     ; Color for %00 (background)

charset = $3c00     ; Character Set
screen  = $4000 	; Screen buffer
blank8  = $70   	; 8 blank lines
lms     = $40	; Load Memory Scan
jvb     = $41	; Jump while vertical blank

antic2 = 2   ; Antic mode 2
antic5 = 5	; Antic mode 5

med_gray = $06
lt_gray = $0a
green = $c2
brown = $22
black = $00

; Load display list
	mwa #dlist SDLSTL
	
; Set up character set
	mva #>charset CHBAS

	ldx #0
loop
	mva chars,x charset+8,x
	inx
	cpx #16
	bne loop

; change colors
    mva #med_gray COLOR0
    mva #lt_gray COLOR1
    mva #green COLOR2
    mva #brown COLOR3
    mva #black COLOR4
        
	ldy #0
loop2
	mva scene,y screen,y
	iny
	cpy #12
	bne loop2
	
	jmp *

; Display List
dlist
	.byte blank8, blank8, blank8
	.byte antic5 + lms, <screen, >screen
	.byte antic5, antic5, antic5, antic5, antic5, antic5
	.byte antic5, antic5, antic5, antic5, antic5
	.byte jvb, <dlist, >dlist

; %00 = 0
; %01 = 1
; %10 = 2
; %11 = 3

scene
	.byte 1,2,129,130,1,2,129,130,1,2,129,130

chars
	.byte %00000000
	.byte %00000001
	.byte %00000110
	.byte %00011011
	.byte %00011011
	.byte %00000110
	.byte %00000001
	.byte %00000000

	.byte %00000000
	.byte %01000000
	.byte %10010000
	.byte %11100100
	.byte %11100100
	.byte %10010000
	.byte %01000000
	.byte %00000000

	
