.comment

LCD T6963C commands:

check status (C/D = 1, /RD = 0, /WR = 1, /CE = 0)  - required before data r/w or command with msb=0
  wait for data & 0x11 == 3  (bit 1 = ready data r/w, bit 1 = ready cmd)

write happens on rising edge of /WR (or /CE)

To send command, wait status OK, then send 0-2 data bytes, wait status after each, then send command byte.

write (C/D = 1, /RD = 1, /WR = 0, /CE = 0)

data          command
00100xxx  DD  set register: D1, D2;  xxx: 1=cursor (X, Y), 2=offset (cols, 0), 4=addr
010000xx  DD  set control word: D1, D2; xx: 0=txt home, 1=txt area, 2=gfx home, 3=gfx area
1000yxxx      mode set: y: 0=internal CG ROM, 1=external CG RAM; xxx: 000=OR, 001=XOR, 011=AND, 100=TEXT (attr)
1001wxyz      display mode: w: graphic on/off, x: text on/off, y: cursor on/off, z: cursor blink on/off
10100xxx      set cursor: xxx: n+1 line cursor
101100xy      data auto r/w: x: 0=set data auto, 1=auto reset; y: 0=write, 1=read
11000xxy  D   data r/w: xx: 00=inc adp, 01: dec adp, 10: fixed adp; y: 0=write + D1, 1=read
11100000      screen peek
11101000      screen copy
1111xyyy      bit set/reset

Status bits via CMD+RD:

0 - command execution ok
1 - data xfer ok (must check 0 and 1 together)
2 - auto mode data read ok
3 - auto mode data write ok
4 - nc
5 - controller ok
6 - error flag for screen peek/copy
7 - check blink condition 1=normal display, 0=display off

References:

https://www.sparkfun.com/datasheets/LCD/Monochrome/Datasheet-T6963C.pdf
https://www.lcd-module.de/eng/pdf/zubehoer/t6963.pdf

Hardware setup:

/WR = /IOW
/RD = /IOR
/CE = a7                        ; address LCD as $c000
C/D = a0                        ; high for cmd/status, low for data

.endcomment

LCD_DATA   = IOBASE
LCD_CMD    = IOBASE + 1

LCD_ST_RDY = %0011              ; status masks for normal command
LCD_ST_ARD = %0100              ; and auto read/write specials
LCD_ST_AWR = %1000

LCD_COLS = 40
LCD_ROWS = 16

LCD_ATTR = $400

.section zp

lcd_args    .word ?
lcd_tmp     .byte ?

.endsection


lcd_init:   ; () -> nil const X
        ; NB. assumes all DVC_CDR pins are already set as output

        stz lcd_args
        stz lcd_args+1
        ldy #%0100_0000         ; text base $0000
        jsr lcd_cmd2

        lda #>LCD_ATTR
        sta lcd_args+1
        ldy #%0100_0010         ; gfx base $0400
        jsr lcd_cmd2

        lda #LCD_COLS           ; match text area to cols (no row padding)
        sta lcd_args
        stz lcd_args+1          ; 0 high
        ldy #%0100_0001         ; text area (row offset)
        jsr lcd_cmd2

        ldy #%0100_0011         ; ditto for gfx area (row offset)
        jsr lcd_cmd2

        ldy #%1010_0000         ; underline cursor
        jsr lcd_cmd0

        jsr lcd_hide_cursor

        ldy #%1000_0100         ; mode: internal CG, text attr mode
        jsr lcd_cmd0

        ; fall through to set offset
        stz lcd_args

lcd_setadp:     ; () -> nil const X
        ldy #%0010_0100         ; set ADP as (lcd_args, lcd_args+1)
        ; fall through

lcd_cmd2:   ; (Y) -> nil const X
    ; Y = cmd; data in lcd_args+0,1
        sec
        bra lcd_cmdn


lcd_hide_cursor:
        ldy #%1001_1100         ; display:  gfx (text attr) on, text on, cursor off
        bra lcd_cmd0

lcd_show_cursor:
    ; show cursor at (X, Y) = (lcd_args, lcd_args+1)
        ldy #%0010_0001         ; set cursor pointer
        jsr lcd_cmd2

        ldy #%1001_1111         ; display: gfx (text attr) on, text on, cursor blink
        bra lcd_cmd0

lcd_putc:   ; (A) -> nil const X
    ; write A to ADP++
.if TALI_ARCH == "c65"
        sta io_putc
.endif
        sec
        sbc #$20                ; character table is offset from ascii

lcd_putb:
        sta lcd_args
        ldy #%1100_0000

        ; fall through to emit the character

lcd_cmd1:   ; (Y) -> nil const X
    ; Y = cmd; data in lcd_args+0
        clc
lcd_cmdn:

        phx
        ldx #0
-
        jsr lcd_wait            ; leaves C_D set
        lda lcd_args,x
        sta LCD_DATA            ; write data byte to LCD
        bcc +

        clc
        inx
        bra -
+
        plx
        ; fall through

lcd_cmd0:   ; (Y) -> nil const X
    ; Y = cmd
        jsr lcd_wait
        sty LCD_CMD            ; write command byte to LCD
        rts


lcd_blit:
    ; write 640 chars of character data from <Y,A> to the LCD
        pha
        phy
        stz lcd_args
        stz lcd_args+1
        jsr lcd_setadp

        lda #%10101             ; 5 iterations, page++ every other loop
        sta lcd_tmp

        ldy #%1011_0000         ; start auto-write
        jsr lcd_cmd0

        ply
        sty lcd_args+1
        pla
        sta lcd_args
_txt:
        ldy #0
-
        lda LCD_CMD             ; read status
        and #LCD_ST_AWR         ; wait for auto write status bit
.if TALI_ARCH != "c65"
        beq -
.endif
        lda (lcd_args),y
        sec
        sbc #$20
        sta LCD_DATA            ; write byte and inc ADP

        iny
        bpl -

        lda lcd_args
        eor #$80                ; next half page
        sta lcd_args
        lsr lcd_tmp
        bcs _txt                ; inc page after even steps

        beq +
        inc lcd_args+1
        bra _txt
+
        ; seems to work either with wait-auto or regular wait (lcd_cmd0)
        ldy #%1011_0010         ; end auto-write
        jsr lcd_cmd0

        ; TODO copy 320 nibbles of attr to 640 bytes
        ; for now just write 640 bytes of zero
        stz lcd_args
        lda #>LCD_ATTR
        sta lcd_args+1
        jsr lcd_setadp

        lda #%10101             ; 5 iterations, page++ every other loop
        sta lcd_tmp

        ldy #%1011_0000         ; start auto-write
        jsr lcd_cmd0

_attr:
        ldy #0
-
        lda LCD_CMD             ; read status
        and #LCD_ST_AWR         ; wait for auto write status bit
.if TALI_ARCH != "c65"
        beq -
.endif
        stz LCD_DATA            ; write byte and inc ADP
        iny
        bpl -

        lda lcd_args
        eor #$80                ; next half page
        lsr lcd_tmp
        bcs _attr               ; inc page after even steps

        beq +
        inc lcd_args+1
        bra _attr
+
        ldy #%1011_0010         ; end auto-write
        bra lcd_cmd0


lcd_wait:   ; () -> nil const X, Y
    ; Read LCD control status until ready for command
-
        lda LCD_CMD             ; read status
        and #LCD_ST_RDY         ; check both bits are set
        eor #LCD_ST_RDY         ; mask and then eor so 0 if set
.if TALI_ARCH != "c65"
        bne -
.endif
        rts

