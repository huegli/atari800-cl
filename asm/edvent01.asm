; EdVenture - An Adventure in Atari 8-Bit Assembly
; Video 1: Initial Setup

	org $2000
SAVMSC = $0058	; Screen Memory address

	ldy #0
loop
	lda hello,y
	sta (SAVMSC),y
	iny
	cpy #12
	bne loop
	
	jmp *
	
; Data
hello
	.byte "HELLO ATARI!"
	