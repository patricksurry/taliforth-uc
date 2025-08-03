;----------------------------------------------------------------------
; adventure-specific words
;----------------------------------------------------------------------

; ## typez ( strz digrams -- ) "emit a wrapped dizzy+woozy encoded string"
; ## "typez"  tested ad hoc
#nt_header typez
xt_typez:
        jsr underflow_2
w_typez:
        lda (2,x)
        beq _empty              ; skip empty string to avoid a newline

        lda 0,x
        sta txt_digrams
        lda 1,x
        sta txt_digrams+1

        lda 2,x
        sta txt_strz
        lda 3,x
        sta txt_strz+1

        phx
        jsr txt_typez           ; print encoded string plus trailing newline
        plx

_empty:
        inx
        inx
        inx
        inx

z_typez:
        rts


; linkz decode 4 byte packed representation into 3 words
;
;           addr+3          addr+2             addr+1           addr+0
;    +-----------------+-----------------+-----------------+-----------------+
;    | 7 6 5 4 3 2 1 0 | 7 6 5 4 3 2 1 0 | 7 6 5 4 3 2 1 0 | 7 6 5 4 3 2 1 0 |
;    +------+-----+----+-----------------+--------------+--+-----------------+
;    | . . .|  cf | dt |     dest        |     cobj     |          verb      |
;    +------+-----+----+-----------------+--------------+--+-----------------+
;             1,x   5,x      4,x               0,x       3,x       2,x

#nt_header decode_link, "decode-link"
xt_decode_link:     ; ( link-addr -- dest' verb cond' )
        jsr underflow_1
w_decode_link:
        lda 0,x         ; copy addr to tmp1
        sta tmp1
        lda 1,x
        sta tmp1+1

        dex             ; make space for cond' @ 0-1, verb @ 2-3, dest at 4-5
        dex
        dex
        dex

        ldy #0
        lda (tmp1),y
        sta 2,x         ; verb lo
        iny
        lda (tmp1),y
        lsr
        sta 0,x         ; cond lo
        lda #0
        rol
        sta 3,x         ; verb hi
        iny
        lda (tmp1),y
        sta 4,x         ; dest lo
        iny
        lda (tmp1),y
        tay
        and #3
        sta 5,x         ; dest hi
        tya
        lsr
        lsr
        sta 1,x         ; cond hi
z_decode_link:
        rts

