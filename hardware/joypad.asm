jpad_buttons:
        ; read button channel X=0 or 1, returning button flags in Y's four LSB (0000 = none pressed)
        ; channel 0 order is (msb) 0000_BAYX (lsb)
        ; channel 1 order is (msb) 0000_21<select><start> (lsb)
        ; measured values range from 16 (all)..251 (none)
        ; best cutoff for no buttons is about 237 with steps of 15
        jsr jpad_read
        tya
        ldy #0
        clc
        adc #255-237        ; add initial step to test no buttons
        bcs +
-
        iny
        adc #15             ; count how many 15s we can add before carry
        bcc -
+
        rts

jpad_stick:
        ; read joystick axis X=0/1 for horiz/vert => Y
        inx              ; add two for stick axes
        inx
        ; fall through

jpad_read:
        ; X = channel; 0/1 for main/meta buttons; 2/3 for stick X/Y axes
        ; value returned in Y
        lda # JPAD_CS           ; select jpad
        trb DVC_CTRL

        txa
        asl
        asl
        ora # %0110_0000        ; %01sx_cc00: start bit 1, single=1, don't care=x, channel = cc

        jsr spi_exchbyte        ; grab appropriate channel
        jsr spi_exchbyte
        tay                     ; save result in Y

        lda # JPAD_CS           ; deselect jpad
        tsb DVC_CTRL

        rts
