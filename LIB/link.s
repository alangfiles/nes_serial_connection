; Port-2 serial routines, included by crt0.s and declared in link.h.
;
; HOW THE LINK WORKS (overview)
;   * Transmit: $4016 bit 0 ("OUT0", normally the controller strobe) is used
;     as a plain output pin. Writing 1 or 0 there drives the wire high or low.
;   * Receive: $4017 is read. Bits 0, 1 and 4 (D0, D1, D4 = mask $13) are the
;     controller-port-2 data pins; any of them may carry the incoming wire.
;     The hardware INVERTS them: wire driven high by the sender reads as 0,
;     wire driven low reads as non-zero.
;   * Format is 8-N-1 at ~19200 baud (93 CPU cycles per bit on NTSC): one
;     start bit (line low), 8 data bits sent least-significant-bit first, no
;     parity, one stop bit (line high). The line idles high.
;   * Timing is done with busy-wait loops, so NMI must be off while bytes are
;     moving. These routines do NOT touch PPU_CTRL except that link_receive
;     turns NMI off once a start bit is seen; the caller turns it back on with
;     link_nmi_on() when the whole transaction is finished. Keeping one
;     NMI-off section for the whole packet exchange (< ~2.5 ms, about the
;     length of vblank) means a vblank that happens during it is still pending
;     when NMI is re-enabled, so the NMI handler can upload sprites right away.

.export _link_send, _link_receive, _link_idle, _link_nmi_on, _link_nmi_off

SERIAL_MASK = $13       ; %00010011 = D4, D1, D0 of $4017

.segment "ZEROPAGE"
link_value: .res 1      ; shift register used while sending/receiving a byte

.segment "CODE"

; TIMING. One bit at 19200 baud on an NTSC NES is 1789773/19200 = ~93 cycles.
; A delay routine "ldx #n / loop dex,bne / rts" called with JSR costs exactly
; 5n+13 cycles (ldx 2 + loop 5n-1 + rts 6 + jsr 6). Every delay below is
; chosen so the instructions AROUND the delay add up to a whole 93-cycle bit
; (a write to $4016 or a read of $4017 is the reference point, since each is
; one 4-cycle instruction). All paths through the bit loops are cycle-equal;
; the receive loop is branch-free for that reason.

; One whole bit time (n=16 -> 93 cycles). Used for the stop bit and guard time.
; Clobbers X.
delay_bit:
	ldx #16
@loop:
	dex
	bne @loop
	rts

; 73 cycles (n=12). Filler for the data-bit loops: with the surrounding
; instructions it makes exactly 93 cycles between consecutive bit edges
; (send) or consecutive samples (receive). Clobbers X.
delay_data:
	ldx #12
@loop:
	dex
	bne @loop
	rts

; 78 cycles (n=13). Start bit: the 15 cycles of setup before the first data
; edge plus this make exactly 93. Clobbers X.
delay_start:
	ldx #13
@loop:
	dex
	bne @loop
	rts

; 28 cycles (n=3). Moves the receiver's first look at the line to about 43
; cycles after the start edge was seen, inside the start bit (which lasts 93
; cycles after an edge seen up to 13 cycles late), to reject glitches.
; Clobbers X.
delay_check:
	ldx #3
@loop:
	dex
	bne @loop
	rts

; void link_send(unsigned char value)
; A = byte to send (cc65 __fastcall__ passes the last argument in A).
; Output is active high: a 1 bit drives the wire high, 0 drives it low.
_link_send:
	sta link_value          ; keep the byte; we shift bits out of it

	; Guard time: two bit times of idle (line already high from the previous
	; stop bit). The peer's link_receive returns in the middle of our stop bit
	; and its C code needs a little time to call link_receive again, so this
	; makes sure the next start bit never arrives before it is listening.
	jsr delay_bit
	jsr delay_bit

	; START BIT: pull the line low. Edge-to-edge until the first data bit:
	; sta 4 + delay_start 78 + ldy 2 + (lsr 5 + lda 2 + rol 2) = 93.
	lda #0
	sta CTRL_PORT1
	jsr delay_start

	ldy #8                  ; 8 data bits
@send_bit:
	lsr link_value          ; shift lowest bit into carry (LSB first)
	lda #0
	rol a                   ; A = carry = 0 or 1
	sta CTRL_PORT1          ; drive the wire with that bit
	; Bit-to-bit: sta 4 + delay 73 + nop 2 + dey 2 + bne 3 + lsr 5 + lda 2
	; + rol 2 = 93.
	jsr delay_data
	nop
	dey
	bne @send_bit

	; STOP BIT: the last bit's loop exit is 8 cycles short of a full bit
	; (bne not taken saves 1, and no lsr/lda/rol follow), so pad with 4 NOPs:
	; sta 4 + delay 73 + nop 2 + dey 2 + bne 2 + 4 nop 8 + lda 2 = 93.
	nop
	nop
	nop
	nop
	lda #1
	sta CTRL_PORT1          ; line high = stop bit / idle
	jsr delay_bit           ; hold the stop bit for a full bit time
	rts

; unsigned int link_receive(unsigned char timeout)
; Wait up to about timeout * 1.9 ms for a start bit, then receive one 8-N-1
; byte. The result is 16 bits: A = byte, X = 0 on success, X = 1 (and A = $FF)
; on timeout or framing error, so every byte value is a valid payload.
; The port input is inverted: sender-high reads 0, sender-low reads non-zero.
_link_receive:
	tax                     ; X = outer loop count (timeout)
	lda #1
	sta CTRL_PORT1          ; keep our own output idle (high) while listening

	; Wait for the START BIT (sender pulls the line low = reads non-zero).
	; NMI may still be on here, so a vblank NMI can run while we wait.
@wait_outer:
	ldy #0                  ; inner loop count (256 iterations, ~1.9 ms total)
@wait_inner:
	lda CTRL_PORT2
	and #SERIAL_MASK        ; look only at the serial input pins
	bne @start_found        ; non-zero = line went low = start bit began
	dey
	bne @wait_inner
	dex
	bne @wait_outer
	jmp @receive_error      ; nothing arrived: timeout

@start_found:
	lda #0
	sta PPU_CTRL            ; a packet is coming: NMI off until link_nmi_on()

	; Time zero = the read that saw the start bit. The edge itself happened
	; 0-13 cycles earlier (the polling loop is 13 cycles long), so on average
	; bit centres are at about 40 + 93*k cycles after time zero.
	;
	; Look again about 43 cycles after time zero (inside the start bit). If
	; the line is already high again it was a glitch, not a start bit.
	jsr delay_check
	lda CTRL_PORT2
	and #SERIAL_MASK
	beq @receive_error      ; line already high again: not a real start bit

	; The first data read lands at 43 + (and 2, beq 2, lda 2, sta 3, ldy 2)
	; + delay_data 73 + lda 4 = 131 cycles, i.e. mid-bit-0 for any start-edge
	; latency from 0 to 13 cycles (centre range 126-140).
	lda #0
	sta link_value
	ldy #8                  ; 8 data bits
@read_bit:
	jsr delay_data
	lda CTRL_PORT2
	and #SERIAL_MASK
	; The line reads inverted: non-zero (line low) is a 0 bit, zero (line
	; high) is a 1 bit. cmp #1 sets carry when the value is non-zero, so no
	; branch is needed and every iteration takes exactly the same time. The
	; collected bits are therefore inverted; they are flipped back at the end.
	cmp #1
	nop                     ; pad: and 2 + cmp 2 + ror 5 + nop 2 + dey 2 +
	ror link_value          ; bne 3 + delay 73 + lda 4 = 93 cycles per sample
	dey
	bne @read_bit

	; STOP BIT: the last data read is followed by 15 cycles + delay_data 73
	; + lda 4, so the stop bit is read about 92 cycles later (near its
	; middle). It must be high (reads as zero); otherwise the byte is
	; misaligned or corrupt, so report an error.
	jsr delay_data
	lda CTRL_PORT2
	and #SERIAL_MASK
	bne @receive_error
	ldx #0                  ; X = 0 means success (high byte of the result)
	lda link_value
	eor #$ff                ; undo the inversion from the cmp trick above
	rts

@receive_error:
	lda #1
	sta CTRL_PORT1          ; make sure our output is idle again
	ldx #1                  ; X = 1 tells the caller this was an error
	lda #$ff
	rts

; void link_idle(void)
; Drive the line high (idle). pad_poll() leaves $4016 at 0, which the other
; console would see as a permanent start bit, so call this after every pad_poll.
_link_idle:
	lda #1
	sta CTRL_PORT1
	rts

; void link_nmi_off(void) / void link_nmi_on(void)
; Disable NMI, or restore it to the value the library keeps in PPU_CTRL_VAR.
; The master calls link_nmi_off() before a transaction; both sides call
; link_nmi_on() after it.
_link_nmi_off:
	lda #0
	sta PPU_CTRL
	rts

_link_nmi_on:
	lda <PPU_CTRL_VAR
	sta PPU_CTRL
	rts
