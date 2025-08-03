TXT_WIDTH       = LCD_COLS      ; screen width, < 256
TXT_HEIGHT      = LCD_ROWS

.cwarn TXT_BUF % 1024, "Expected 1K boundary for TXT_BUF"

.section zp

txt_x       .byte ?
txt_y       .byte ?
txt_offset  .word ?
txt_tmp     .byte ?
txt_pager   .byte ?             ; counts number of scroll events between key press

txt_strz    .word ?             ; input zero-terminated string
txt_outz    .word ?             ; output buffer for zero-terminated string
txt_digrams .word ?             ; digram lookup table (128 2-byte pairs)

; unwrap temps
wrp_len     .byte ?             ; number of cols buffered this line
wrp_col     .byte ?             ; best current break column
wrp_flg     .byte ?

; woozy temps
wzy_rpt     .byte ?
wzy_shft    .byte ?
wzy_chr     .byte ?

; dizzy temp
dzy_stk   .byte ?

cb_head     .word ?, ?
cb_tail     .word ?, ?

.endsection


; hardcoded vectors are OK for now

; buffer 0 is a push buffer to output
; buffer 1 is a pull buffer for intermediate dizzy decompression

cb_src: .word txt_noop
        .word txt_undizzy       ; undizzy fills buffer 1

cb_snk: .word wrp_putc          ; buffer 0 feeds to output
        .word txt_noop


txt_init:
        ; initialize screen buffer and blit
        jsr txt_cls

        ; set up two circular one page buffers
        ; both buffers start with head=tail,
        ; with buffer 0 at $600, buffer 1 at $700
        ; these overlap the top half of the block-buffer
        stz cb_head
        stz cb_tail
        stz cb_head+2
        stz cb_tail+2

        lda #6
        sta cb_head+1
        sta cb_tail+1
        ina
        sta cb_head+3
        sta cb_tail+3
        rts


txt_putc:   ; (A) -> nil const X,Y
        phy
        jsr _txt_putc
        ply
        rts

_txt_putc:
    ; put printable chr A (stomped) at the current position, handle bksp, tab, CR, LF
.if TALI_ARCH != "c65"
        cmp #AscBS
        beq _bksp
.endif
        ldy txt_y               ; do we need to scroll before new character?
        cpy #TXT_HEIGHT
        bmi +
        pha
        jsr txt_scrollup
        pla
+
        cmp #AscLF
        beq _nl
        cmp #AscCR
        beq _nl
        cmp #AscTab
        beq _tab
_putc:
    ; else write character and advance position with wrapping
        sta (txt_offset)        ; buffer the character
        jsr lcd_putc            ; and display it
        inc txt_offset
        bne +
        inc txt_offset+1
+
        inc txt_x               ; update position for next write
        lda txt_x
        cmp #TXT_WIDTH          ; end of line?
        bmi +
        stz txt_x               ; wrap to start of next line
        inc txt_y               ; NB don't check for scroll yet
        inc txt_pager           ; count rows between keypresses
.if TALI_ARCH == "c65"
        lda #'|'
        sta io_putc
        lda #AscLF
        sta io_putc
.endif
+
        rts

        ; go back, write a space, go back again
_bksp:  pha                     ; save nozero chr as flag
_back:  dec txt_x
        bpl _erase
        lda #TXT_WIDTH-1
        sta txt_x
        dec txt_y
        bpl _erase
        lda #TXT_HEIGHT-1
        sta txt_y
_erase: jsr txt_setxy
        pla
        beq _done               ; first pass?
        lda #0
        pha
        lda #AscSP
        jsr _putc
        bra _back

_nl:
        lda #$ff                ; advance until txt_x is zero (all bits clear to wrap)
        bra +
_tab:   lda #$03                ; advance until lower two bits in txt_x are clear
+
        sta txt_tmp
_fill:  lda #' '                ; fill until txt_x zeros all bits in mask
        jsr _putc
        lda txt_x
        and txt_tmp
        bne _fill               ; done fill?

        bit txt_tmp             ; was it NL (all bits set?)
        bpl _done

        lda txt_y               ; if NL and scroll due, force it now
        cmp #TXT_HEIGHT
        bpl txt_scrollup

_done:  rts


txt_scrollup:
        ; not safe to use Forth words that change tmps since this might be called any time
        lda txt_pager
        cmp #TXT_HEIGHT
        bne +
        jsr kernel_getc         ; wait for a key press
+

;TODO is the 5*128 scheme better?

        lda #>TXT_BUF           ; starting address
        sta txt_offset+1
        stz txt_offset

        ldy #TXT_WIDTH

        lda #TXT_HEIGHT         ; repeat # rows
        sta lcd_args

_row:
        sty txt_tmp
-
        lda (txt_offset),y
        sta (txt_offset)
        inc txt_offset
        bne +
        inc txt_offset+1
+
        dec txt_tmp             ; count down cols
        bne -
        dec lcd_args            ; count down rows
        bne _row

        ; if y>0 move position back one row
        lda txt_y
        beq txt_blit
        dec txt_y
        bra txt_blit


xt_page:
w_page:
txt_cls:
        lda #>(TXT_BUF + TXT_WIDTH*(TXT_HEIGHT+1))
        sta txt_offset+1
        stz txt_offset
        ldy #<(TXT_BUF + TXT_WIDTH*(TXT_HEIGHT+1))
_page:
        lda #AscSP
-
        dey
        sta (txt_offset),y
        bne -
        dec txt_offset+1
        lda txt_offset+1
        cmp #>TXT_BUF
        bpl _page

        stz txt_x
        stz txt_y

txt_blit:
        lda #<TXT_BUF
        ldy #>TXT_BUF
        jsr lcd_blit

        ; fall through and update current offset
txt_setxy:
        ; update offset from X and Y
        ; calculate offset: x + y*40 = x + y*(32 + 8) = x + (y*8) + (y*8)*4
        .cwarn TXT_WIDTH != 40, "txt_setxy hard-coded for 40 cols"

        ldy #0
        lda txt_y
        asl
        asl
        asl
        sta txt_offset
        asl
        asl
        bcc +
        iny
        clc
+
        adc txt_offset
        bcc +
        iny
        clc
+
        adc txt_x
        sta txt_offset          ; same low byte for LCD and buffer
        sta lcd_args

        tya
        adc #0
        sta lcd_args+1
        ora #(>TXT_BUF) & %1111_1100
        sta txt_offset+1        ; set high bits for txt_offset

        jmp lcd_setadp
z_page:


txt_show_cursor:
        lda txt_y
        cmp #TXT_HEIGHT         ; if we're about to scroll, show cursor at bottom right
        bmi +
        lda #TXT_HEIGHT-1
        sta lcd_args+1
        lda #TXT_WIDTH-1
        sta lcd_args
        jmp lcd_show_cursor
+
        sta lcd_args+1
        lda txt_x
        sta lcd_args
        jmp lcd_show_cursor

txt_hide_cursor:
        jmp lcd_hide_cursor


; Simple circular buffer implementation, with optional src/snk handlers

; puts a character into a circular buffer, updating head
cb1_put:    ; (A) -> circular buffer and notify sink
        ldx #2
        bra +
cb0_put:
        ldx #0
+       sta (cb_head,x)
        inc cb_head,x           ; wrap is OK in circular buffer
        jmp (cb_snk,x)          ; notify sink and return from there


; returns the next character and advances tail of a circular buffer,
; first refilling if needed to advance head past tail
cb1_get:    ; (circular buffer) -> A
        ldx #2
        bra +
cb0_get:
        ldx #0
+       lda cb_tail,x
        cmp cb_head,x
        bne _fetch              ; if tail is at head we need to refill
        phx
        jsr _refill
        plx
_fetch: lda (cb_tail,x)
        inc cb_tail,x
        rts
_refill:
        jmp (cb_src,x)


wrp_init:
        ; wrp_len tracks number of buffered chars, aka current col position 0,1,2...
        stz wrp_len
wrp_new_line:
        lda #$ff
        sta wrp_col         ; col index of latest break
        sta wrp_flg         ; set flg to -1 (skip leading ws)
        rts

wrp_putc:   ; buffer output via cb0 to txt_putc
        ; enter with latest character in A which is also buffered
        ; so will eventually be retrieved via cb0_get
        ; the goal here is to track potential line and page breaks
        ; and decide when to flush the buffer
        ; currently always adds a newline following the string
        ; (could be configurable but no current need)
        cmp #0
        beq _force              ; force break after each string

        cmp #AscLF              ; explicit LF?
        bne _chkws

_force: lda wrp_len             ; wrap at this col
        sta wrp_col
        bra _putln

_chkws: sec
        sbc #' '+1
        eor wrp_flg             ; flg 0 is no-op, -1 flips sign of comparison
        bpl _cont               ; mode 0 skips non-ws looking for break, flg -1 skips ws

        lda wrp_flg             ; hit; either way switch mode
        eor #$ff
        sta wrp_flg
        beq _cont               ; if flg is 0 (was -1) we were just skipping ws

        lda wrp_len             ; else we found ws, update break point
        sta wrp_col

_cont:  lda wrp_len
        cmp #TXT_WIDTH          ; end of line?
        beq _flush

        inc wrp_len             ; otherwise just advance col and wait for next chr
        rts

_flush:
        lda wrp_col             ; did we find a break?
        cmp #$ff
        bne _putln
        lda #TXT_WIDTH-1        ; else force one at col w-1

        ; A contains the column index to wrap at.  We'll consume A+1
        ; characters, with the last one getting special treatment

_putln: tay                     ; save number of characters for loop
        eor #$ff
        sec                     ; new column will be wrp_len - A = ~A + 1 + col
        adc wrp_len
        sta wrp_len

_out:   jsr cb0_get             ; consume wrp_col+1 chars
        dey
        bmi _last               ; last char gets special treatment
        jsr emit_a
        bra _out

_last:
        cmp #' '+1              ; for hard break at end of line, we don't need NL
        bpl +
        lda wrp_col
        cmp #TXT_WIDTH
        beq wrp_new_line        ; eat soft break at TXT_WIDTH

        lda #AscLF              ; otherwise add NL
+
        jsr emit_a             ; non-ws character is at EOL so no NL needed
        bra wrp_new_line        ; set state for new line and return



txt_typez:   ;  (txt_strz, txt_digrams via buf1) -> buf0
    ; print a dizzy+woozy encoded string in (txt_strz) using streaming decode
    ; outputs via wrp_putc which always adds a trailing newline
    ; undo woozy prep for dizzy, pulls from buf1 (dizzy), pushes to buf0 (output)
        stz wzy_shft            ; shift state, 0 = none, 1 = capitalize, 2 = all caps
        stz wzy_rpt             ; repeat count for output (0 means once)

        jsr wrp_init

_loop:  jsr cb1_get
        cmp #0
        beq _rput               ; return after writing terminator
        cmp #$0d                ; $b,c: set shift status
        bpl _out
        cmp #$0b
        bmi _nobc
        sbc #$0a
        sta wzy_shft            ; save shift state
        bra _loop

_nobc:  cmp #$09                ; $3-8: rle next char
        bpl _out
        cmp #$03
        bmi _out
        dea
        sta wzy_rpt
        bra _loop

_out:   cmp #'A'
        bmi _notuc
        cmp #'Z'+1
        bpl _notuc
        ora #%0010_0000         ; lowercase
        pha
        lda #' '                ; add a space
        jsr _rput
        pla

_notuc: ldx wzy_shft
        beq _next
        cmp #'a'
        bmi _noshf
        cmp #'z'+1
        bpl _noshf
        and #%0101_1111         ; capitalize
        cpx #2                  ; all caps?
        beq _next
_noshf: stz wzy_shft            ; else end shift
_next:  jsr _rput
        bra _loop

_rput:  sta wzy_chr
_r:     jsr cb0_put
        lda wzy_rpt
        beq _done
        dec wzy_rpt
        lda wzy_chr
        bra _r
_done:
txt_noop:
        rts


txt_undizzy:                    ; (txt_strz, txt_digrams) -> buf1
    ; uncompress a zero-terminated dizzy string at txt_strz using txt_digrams lookup
    ; writes next character(s) from input stream to circular buf0

        stz dzy_stk             ; track stack depth
        lda (txt_strz)          ; get encoded char

_chk7:  bpl _asc7               ; 7-bit char or digram (bit 7 set)?
        sec
        rol                     ; index*2+1 for second char in digram
        tay
        lda (txt_digrams),y
        inc dzy_stk             ; track stack depth
        pha                     ; stack the second char
        dey
        lda (txt_digrams),y     ; fetch the first char of the digram
        bra _chk7               ; keep going

_asc7:  jsr cb1_put
_stk:   lda dzy_stk             ; any stacked items?
        beq _done
        dec dzy_stk
        pla                     ; pop latest
        bra _chk7

_done:  inc txt_strz            ; inc pointer
        bne _rts
        inc txt_strz+1

_rts:   rts



.if TESTS

test_start:
        lda #<test_digrams
        sta txt_digrams
        lda #>test_digrams
        sta txt_digrams+1

        ; undizzy: dzy -> buf
        lda #<test_dzy
        sta txt_strz
        lda #>test_dzy
        sta txt_strz+1

        jsr txt_wrapz

_done:  brk


test_digrams:
        .byte $68, $65, $72, $65, $6f, $75, $54, $80, $69, $6e, $73, $74, $84, $67, $6e, $64
        .byte $69, $74, $6c, $6c, $49, $6e, $65, $72, $61, $72, $2e, $0b, $4f, $66, $0b, $79
        .byte $8f, $82, $65, $73, $6f, $72, $49, $73, $59, $82, $6f, $6e, $6f, $6d, $54, $6f
        .byte $61, $6e, $6f, $77, $6c, $65, $61, $73, $76, $65, $61, $74, $74, $80, $41, $81
        .byte $0b, $9e, $65, $6e, $42, $65, $67, $65, $61, $89, $65, $64, $41, $87, $54, $68
        .byte $90, $9f, $69, $64, $74, $68, $65, $81, $73, $61, $61, $64, $52, $6f, $69, $63
        .byte $9b, $ac, $6c, $79, $63, $6b, $27, $81, $41, $4c, $65, $74, $50, $b0, $6c, $6f
        .byte $69, $73, $67, $68, $4f, $6e, $43, $98, $90, $b3, $41, $74, $49, $74, $65, $ad
        .byte $88, $74, $88, $68, $75, $74, $61, $6d, $6f, $74, $a8, $8a, $8d, $83, $57, $c1
        .byte $69, $85, $4d, $61, $53, $74, $41, $6e, $72, $6f, $81, $93, $57, $68, $45, $87
        .byte $8e, $83, $69, $72, $76, $8b, $48, $ab, $63, $74, $ae, $96, $65, $85, $61, $9c
        .byte $61, $79, $53, $65, $20, $22, $61, $6c, $61, $85, $69, $95, $6b, $65, $72, $61
        .byte $8a, $83, $46, $72, $45, $78, $b6, $a3, $27, $74, $72, $82, $c0, $9a, $55, $70
        .byte $2c, $41, $52, $65, $a0, $cd, $72, $79, $97, $83, $41, $53, $6c, $64, $e1, $96
        .byte $75, $81, $a9, $65, $63, $65, $57, $d6, $b9, $74, $69, $f4, $bc, $8a, $0b, $64
        .byte $43, $68, $6e, $74, $50, $88, $96, $65, $98, $74, $4f, $c2, $44, $69, $9d, $65
test_dzy:
        .byte $0b, $73, $fb, $77, $80, $81, $4e, $65, $8c, $62, $79, $93, $0b, $43, $6f, $b7
        .byte $73, $ac, $6c, $0b, $43, $d7, $2c, $57, $80, $81, $4f, $9e, $72, $73, $48, $d7
        .byte $46, $82, $87, $46, $92, $74, $75, $6e, $91, $8a, $54, $81, $9b, $f0, $a6, $47
        .byte $6f, $ee, $2c, $a7, $82, $b9, $be, $93, $52, $75, $6d, $6f, $81, $64, $a7, $9d
        .byte $53, $fb, $ce, $6f, $45, $f9, $8b, $9f, $4e, $65, $d2, $d9, $a1, $41, $67, $61
        .byte $84, $8d, $c9, $67, $af, $93, $53, $61, $a9, $97, $57, $92, $6b, $e0, $43, $d7
        .byte $8d, $49, $57, $69, $89, $a2, $94, $72, $45, $79, $91, $a6, $48, $61, $87, $73
        .byte $8d, $fe, $81, $d4, $4d, $65, $c7, $43, $96, $6d, $61, $87, $73, $8e, $20, $31
        .byte $4f, $72, $20, $32, $57, $92, $64, $73, $8d, $49, $53, $68, $82, $ee, $57, $8c
        .byte $6e, $94, $a7, $9d, $0b, $49, $4c, $6f, $6f, $6b, $bd, $ba, $b1, $83, $46, $d1
        .byte $85, $46, $69, $9c, $4c, $b5, $74, $8b, $73, $8e, $45, $61, $63, $68, $57, $92
        .byte $64, $2c, $53, $6f, $94, $27, $89, $48, $d7, $97, $45, $f9, $8b, $da, $0b, $6e
        .byte $92, $9e, $dc, $22, $41, $73, $da, $6e, $65, $22, $97, $44, $c8, $86, $75, $b8
        .byte $68, $be, $ef, $da, $0b, $6e, $92, $aa, $22, $2e, $20, $28, $0b, $73, $68, $82
        .byte $ee, $94, $47, $b5, $ca, $75, $b2, $2c, $54, $79, $70, $65, $da, $80, $6c, $70
        .byte $22, $46, $92, $53, $fb, $47, $a1, $8b, $db, $48, $84, $74, $73, $29, $2e, $00

.endif
