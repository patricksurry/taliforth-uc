.comment
Good SD interface intro http://www.rjhcoding.com/avrc-sd-interface-4.php

See also http://forum.6502.org/viewtopic.php?t=1674

Code adapted from https://github.com/gfoot/sdcard6502/blob/master/src/libsd.s

See https://stackoverflow.com/questions/8080718/sdhc-microsd-card-and-spi-initialization

    TL;DR
    1. CMD0 arg: 0x0, CRC: 0x95 (response: 0x01)
    2. CMD8 arg: 0x000001AA, CRC: 0x87 (response: 0x01)
    3. CMD55 arg: 0x0, CRC: any (CMD55 being the prefix to every ACMD)
    4. ACMD41 arg: 0x40000000, CRC: any
        if response: 0x0, you're OK; if it's 0x1, goto 3.

    N.b. Note that most cards *require* steps 3/4 to be repeated, usually once,
    i.e. the actual sequence is CMD0/CMD8/CMD55/ACMD41/CMD55/ACMD41

Commands are sent like 01cc cccc / 32-bit arg / xxxx xxx1  where c is command, x is crc7
so first byte is cmd + $40

For FAT32 layout see https://www.pjrc.com/tech/8051/ide/fat32.html

.endcomment

.section zp

sd_cmdp:    ; two byte pointer to a command sequence
sd_bufp:    ; or two byte pointer to data buffer
sd_err:     ; or two byte of error info
    .word ?
sd_blk:     ; four byte block index (little endian)
    .dword ?

.endsection

sd_err_wake     = $e0
sd_err_rw       = $e1
sd_err_dstok    = $e2
sd_err_wstat    = $e3


; we write to the SPI_SR with SD_CS low to shift a byte out to the SD
; this triggers an exchange where the SD writes a byte to the external SR
; which we can then read by selecting that device and reading port A

sd_init:    ; () -> A = 0 on success, err on failure, with X=cmd

        ; After power up, the host starts the clock and sends the initializing sequence on the CMD line.
        ; This sequence is a contiguous stream of logical ‘1’s.
        ; The sequence length is the maximum of 1msec, 74 clocks or the supply-ramp-uptime;
        ; the additional 10 clocks (over the 64 clocks after what the card should be ready for communication)
        ; is provided to eliminate power-up synchronization problems.

        ; ACMD41 is a special synchronization command used to negotiate the operation voltage range
        ; and to poll the cards until they are out of their power-up sequence.
        ; Besides the operation voltage profile of the cards, the response to ACMD41 contains a busy flag,
        ; indicating that the card is still working on its power-up procedure and is not ready for identification.
        ;  This bit informs the host that the card is not ready. The host has to wait until this bit is cleared.
        ; The maximum period of power up procedure of single card shall not exceed 1 second.

        ; We need to send 74+ high bits with both CS and MOSI high.
        ; Normally MOSI doesn't matter when CS is high, but the card is
        ; not yet is SPI mode, and in this non-SPI state it does care.

        lda #SD_CS
        tsb DVC_CTRL

        ; clock 10 x 8 high bits out without chip enable (CS hi)
        ldy #10                 ; 80 high bits
-
        jsr spi_readbyte        ; sends $ff, i.e. 8 high bits
        dey                     ; 2 cycles
        bne -                   ; 2(+1) cycles

        tya
        ldy #100
        jsr sleep               ; sleep for 1000xgrain cycles (1ms)

        ; now set CS low and send startup sequence
        lda #SD_CS
        trb DVC_CTRL

        jsr sd_command
        .word sd_cmd0
        cmp #1
        bne _fail

        jsr sd_command
        .word sd_cmd8
        cmp #1
        bne _fail

        ldx #4
-
        jsr spi_readbyte
        sta sd_blk,x            ; store for debug
        dex
        bne -

        ldx #10                 ; try up to 10x with 100ms delay

_cmd55:
        jsr sd_command
        .word sd_cmd55
        cmp #1
        bne _fail

        jsr sd_command
        .word sd_cmd41
        cmp #0
        beq sd_exit             ; 0 = initialized OK
        cmp #1
        bne _fail

        lda #40                 ; sleep about 100 millis (40*256+y)*10*grain and try again
        jsr sleep

        dex
        bne _cmd55

        ldx #sd_err_wake
        txa
        bra sd_exit

_fail:
        cmp #0
        bne +                   ; need to return a non-zero code
        lda #$ee
+
        tay
        lda (sd_cmdp)           ; report the failing command
        tax                     ; X has failing command
        tya                     ; A has error code

        bra sd_exit


sd_detect:
    ; test whether card is present (Z clear) or not (Z set)
        lda #SD_CD
        and DVC_CTRL
        rts


sd_rwcmd:
    ; send a read (17) or write (24) command
    ; arg is block num, CRC not checked
        ora #$40                ; set bit six of command
        tay

        ; select card
        lda #SD_CS
        trb DVC_CTRL

        sty SPI_SEND            ; A -> VIA SR -> SD
        jsr delay12             ; need 18 cycles before next write

        ldx #3                  ;2
-
        lda sd_blk,x            ;4  send little endian block index in big endian order
        sta SPI_SEND            ;4  A -> VIA SR -> SD
        jsr delay12             ;12  a little overkill for 18 total
        dex                     ;2
        bpl -                   ;3/2
-
        inx                     ; sd_blk++
        inc sd_blk,x
        beq -

        ldx #sd_err_rw

        lda #1                  ; send CRC 0 with termination bit
        sta SPI_SEND
        jsr sd_await
        cmp #0                  ; R1 response has leading 0 with 7 potential error bits
        bne sd_exit             ; 0 -> success; else return error

        rts


sd_exit:
        ; disable the card, returning status in A (0 = OK)
        tay
        lda #SD_CS
        tsb DVC_CTRL
        tya
        beq +
        sta sd_err
        stx sd_err+1
+
        rts



sd_readblock:
    ; read the 512-byte with 32-bit index sd_blk to sd_bufp
    ; sd_bufp += $200, sd_blk += 1
    ; sd_blk is stored in little endian (XINU) order
        lda #17
        jsr sd_rwcmd

        ldx #sd_err_dstok

        jsr sd_await            ; wait for data start token #$fe
        ina                     ; A=$fe on success, +2 => 0
        ina
        bne sd_exit

        ; now read 512 bytes of data
        ; unroll first loop step to interpose indexing stuff between write/write

        ldx #$ff
        bit sd_cmd0             ; set overflow as page 0 indicator (all cmd bytes have bit 6 set)
        stx SPI_SEND            ; 4 cycles      trigger first exchange
        jsr delay12             ; 12 cycles
        ldy #0                  ; 2 cycles      byte counter
-
        lda SPI_RECV            ; 4 cycles
        stx SPI_SEND            ; 4 cycles      trigger next exchange (need 18+ cycles loop)
        sta (sd_bufp),y         ; 6 cycles
        cmp 0                   ; delay 3 cycles preserving V flag
        iny                     ; 2 cycles
        bne -                   ; 2(+1) cycles

        inc sd_bufp+1
        bvc _crc                ; second page?
        clv                     ; clear overflow for second page
        bra -

_crc:
        ;TODO check crc-16
        lda SPI_RECV            ; first byte of crc-16, completing final exchange
        jsr spi_readbyte        ; second byte of crc-16

        lda #0                  ; success
        bra sd_exit


sd_writeblock:
    ; write the 512-byte with 32-bit index sd_blk to sd_bufp
        lda #24
        jsr sd_rwcmd

        lda #$fe
        sta SPI_SEND            ;4  write data start token

        ; now write 512 bytes of data

        bit sd_cmd0             ;4  set V=1 for page 0 (all cmd bytes have bit 6 set)
        ldy #0                  ;2
-
        nop                     ;2
        nop                     ;2
        lda (sd_bufp),y         ;5
        sta SPI_SEND            ;4  write byte (need 18+ cycle loop)
        iny                     ;2
        bne -                   ;3/2

        inc sd_bufp+1
        bvc _check              ; second page?
        clv                     ; clear overflow for second page
        bra -

_check:
        ldx #sd_err_wstat

        jsr sd_await            ; data response is xxx0sss1 where x is don't care
        and #$1f                ; and sss is status (010 ok, 101 CRC err, 110 write err)
        cmp #5                  ; so 0sss1 == 00101 means data was accepted
        bne sd_exit

_busy:
        jsr spi_readbyte
        beq _busy               ; wait until not busy ($0)

        lda #0
        bra sd_exit


sd_command:     ; (sd_cmdp) -> A; X const
    ; write six bytes from (sd_cmdp), wait for result with a 0 bit

        ; The command pointer follows the JSR
        ; First we capture the address of the pointer
        ; while incrementing the return address by two
        pla                     ; LSB
        ply                     ; MSB
        ina                     ; increment to point at pointer
        bne +
        iny
+
        sta sd_cmdp             ; stash address of pointer (return + 1)
        sty sd_cmdp+1

        ina                     ; increment again to return past pointer
        bne +
        iny
+
        phy                     ; put back return address + 2
        pha

        ; Now dereference the address to fetch the pointer itself
        ldy #1
        lda (sd_cmdp),y         ; fetch pointer MSB
        tay
        lda (sd_cmdp)           ; fetch LSB
        sta sd_cmdp
        sty sd_cmdp+1

        ldy #0
-
        lda (sd_cmdp),y         ; 5 cycles
        sta SPI_SEND            ; 4 cycles
        cmp #0                  ; delay 2 cycles
        iny                     ; 2 cycles
        cpy #6                  ; 2 cycles
        bne -                   ; 2(+1) cycles

        ; fall through

sd_await:
    ; wait for a response byte which is not all ones
        jsr spi_readbyte
        cmp #$ff
        beq sd_await

        rts


; see command descriptions at https://chlazza.nfshost.com/sdcardinfo.html
            ;    %01...cmd, 32-bit argument,     %crc7...1
sd_cmd0:    .byte $40 |  0,  $00,$00,$00,$00,  $94 | 1    ; GO_IDLE_STATE
sd_cmd8:    .byte $40 |  8,  $00,$00,$01,$AA,  $86 | 1    ; SEND_IF_COND
sd_cmd55:   .byte $40 | 55,  $00,$00,$00,$00,   $0 | 1    ; APP_CMD
sd_cmd41:   .byte $40 | 41,  $40,$00,$00,$00,   $0 | 1    ; SD_SEND_OP_COND


