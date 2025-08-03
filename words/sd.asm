
;----------------------------------------------------------------------
; SD card words
;----------------------------------------------------------------------

.if TALI_ARCH != "c65"

#nt_header block_sd_init, "block-sd-init"
xt_block_sd_init:       ; ( -- true | false )
w_block_sd_init:
        ; low level SD card init
        phx
        jsr sd_detect
        bne +
        jsr sd_enocard
        bra _fail
+
        jsr sd_init             ; try to init SD card
        beq +                   ; returns A=0 on success, with Z flag
_fail:
        lda #$ff
+
        plx

        dex                     ; return status
        dex
        eor #$ff                ; invert so we have true on success, false on failure
        sta 0,x
        sta 1,x
        beq z_block_sd_init     ; don't set vectors if we failed

        ; direct write to the block vectors
        ldy #blockread_offset+3
-
        lda sd_vectors-blockread_offset,y
        sta (up),y
        dey
        cpy #blockread_offset
        bcs -

z_block_sd_init:
        rts

.cwarn blockwrite_offset != blockread_offset + 2
sd_vectors:     .word sd_blk_read, sd_blk_write

; SD implementations of the block-read|write hooks
; note that forth block is 1kb, which is two raw SD blocks
; so we double the 16 bit block index and read a pair of SD blocks
; This only addresses a fraction of the full addressable SD space.

sd_blk_write:    ; ( addr u -- )
        sec
        bra sd_blk_rw

sd_blk_read:    ; ( addr u -- )
        clc

sd_blk_rw:
        stz blk_rw
        rol blk_rw

        lda 2,x
        sta sd_bufp
        lda 3,x
        sta sd_bufp+1

        stz sd_blk+2            ; hi bytes are usually zero
        stz sd_blk+3

        lda 0,x                 ; double the index
        asl
        sta sd_blk
        lda 1,x
        rol
        sta sd_blk+1
        rol sd_blk+2

        inx                     ; 2drop leaving ( )
        inx
        inx
        inx

        jsr sd_detect
        bne +
        jmp sd_enocard          ; exit with error
+
        phx                     ; save forth data stack pointer
        lda blk_rw
        beq _read

        jsr sd_writeblock
        bne _done
        jsr sd_writeblock
        bra _done

_read:
        jsr sd_readblock        ; increments sd_blk and sd_bufp
        bne _done
        jsr sd_readblock

_done:
        plx
        rts


; low level words to read and write n 512 byte SD blocks using a 32 bit index
; note these routines return 0 on success or a non-zero error status

#nt_header sd_raw_write, "sd-raw-write"
xt_sd_raw_write:   ; ( addr ud n -- 0|err )
        jsr underflow_4
w_sd_raw_write:
        sec
        bra sd_raw_rw

#nt_header sd_raw_read, "sd-raw-read"
xt_sd_raw_read:    ; ( addr ud n -- 0|err )
        jsr underflow_4
w_sd_raw_read:
        clc

sd_raw_rw:
        stz blk_rw
        rol blk_rw              ; remember read or write

        lda 6,x
        sta sd_bufp
        lda 7,x
        sta sd_bufp+1

        lda 2,x                 ; convert forth NUXI double to XINU order
        sta sd_blk+2
        lda 3,x
        sta sd_blk+3
        lda 4,x
        sta sd_blk+0
        lda 5,x
        sta sd_blk+1

        lda 0,x                 ; grab number of blocks to read/write
        sta blk_n               ; ignore MSB since 128 blocks is already 64Kb

        inx                     ; leave ( addr ) where we'll store status
        inx
        inx
        inx
        inx
        inx

        phx                     ; save Forth stack pointer
-
        lda blk_rw
        beq _read
        jsr sd_writeblock       ; low level routines inc bufp and block index
        bra +
_read:
        jsr sd_readblock
+
        bne _done
        dec blk_n
        bne -

_done:
        cmp #0                  ; success?
        bne +
        tax                     ; set X=A=0 on success
+
        phx
        ply                     ; txy
        plx                     ; restore forth data stack pointer

        sty 0,x
        sta 1,x

z_sd_raw_read:
z_sd_raw_write:
        rts

.endif

;----------------------------------------------------------------------
; EOF
;----------------------------------------------------------------------
