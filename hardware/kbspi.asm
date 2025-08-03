kbspi_kbhit:    ; () -> A; X,Y const
    ; return A non-zero if a key is available
        lda #KBD_RDY
        and DVC_CTRL
        rts


kbspi_getc:     ; () -> A; X,Y const
    ; block until a character is ready, return in A
-
        jsr kbspi_kbhit
        beq -           ; wait for key ready

        sei             ; set interrupt disable
        jsr spi_peripheral      ; act as peripheral with KB as host

        lda #KBD_CS     ; generate falling edge to trigger an exchange
        trb DVC_CTRL
-
        jsr kbspi_kbhit ; wait for falling edge to indicate exchange is complete
        bne -           ; also avoiding the VIA shift-on-external-clock bug

        lda #KBD_CS     ; disable /CS
        tsb DVC_CTRL

        jsr spi_host    ; revert to SPI host role

        lda SPI_RECV    ; fetch the key from the shift register
        cli             ; clear interupt-disable (allow interrupts again)

        rts
