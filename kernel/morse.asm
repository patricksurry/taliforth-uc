.section zp
morse_emit:  .word ?    ; pointer to routine that outputs one morse 'bit'
.endsection


.comment
We can emit morse code on any desired output device (speaker, LED, text, ...)
by providing a morse_emit routine.  This routine simply sends on/off signals
for a specified duration.  The on symbols are the normal dit/dah (dot/dash)
and the off symbols represent spaces between symbols, characters and words.

The routine receives C=on/off in the carry bit with Y=1,2,3,4 as the duration units.
It can use morse_delay(Y) to wait for the appropriate duration.
It needn't preserve any registers.  For an LED or speaker pin it can be very simple (below).
See also morse_puts as an example of emitting a text representation like "... --- ..."

simple_emitter: ; (C, Y) -> nil
        bcc wait                ; signal is normally off
        signal(on)
wait:   jsr morse_delay
        signal(off)
        rts
.endcomment


morse_delay:    ; (Y) -> nil const X
    ; delay for about Y * 100ms where 0 < Y <= 6
    ; 10*39*256 ~ 100K cycles is about 100ms at 1MHz
        lda #0
        clc
-
        adc #39                 ; A = 39 * Y
        dey
        bne -
_done:  jmp sleep               ; sleep for 39*Y*256*10*grain cycles


morse_send: ; (A) -> nil
    ; Output chr A in morse code.  The ascii characters [0-9A-Za-z] and [space] are recognized.
    ; All other characters are sent as the error prosign (........) aka H^H.
    ; Normally each character is followed by an intra letter space (silent dah)
    ; but setting A's msb shortens that to an intra symbol space (silent dit)
    ; so that you can elide multiple characters to form arbitrary patterns.
    ; For example sending 'S'|$80, 'O'|$80, 'S' yields the SOS procedural sign (prosign)

    ; morse_emit should point at a routine which handles output of individual symbols
    ; essentially setting your target output device on or off for N time units as described above

        asl
        php                     ; remember hi bit in the carry
        lsr                     ; clear hi bit
        cmp #' '
        bne _notsp
        plp                     ; discard elide flag
        ldy #4                  ; off(4) to extend prev inter-letter delay from 3 to 7 (silent dah-dit-dah)
        clc                     ; signal off
        bra morse_send_end      ; short circuit to end

_notsp: cmp #$40                ; letters vs numbers
        bmi _notaz
        and #$1f                ; A-Z/a-z is $41-$5A/$61-7A, mask to $01-$1A
        dea
        cmp #26
        bpl _error
        tay                     ; A is index 0-25
        lda morse_az,y
        bra _pfx

_notaz: sec
        sbc #$30                ; 0-9 is $30-39
        bcc _error
        cmp #10
        bpl _error
        tay
        lda morse_09,y

_pfx:   ldy #6                  ; at most 6+1 bits to shift out
_skip:  asl
        bcs morse_send_emit     ; found leading 1 ?
        dey
        bpl _skip

_error: lda #0                  ; error is 8 dits ........
        ldy #7

morse_send_emit:                ; shift out Y+1 msb of A
        asl                     ; top bit => C
        pha
        phy
        ldy #3
        bcs _on
        ldy #1
        sec                     ; signal on
_on:    jsr _end                ; output on(1 or 3)
        ldy #1
        clc                     ; signal off
        jsr _end                ; output off(1) for inter-symbol delay (silent dit)
        ply
        pla
        dey
        bpl morse_send_emit
        plp                     ; original high bit set means elide
        bcc _nrml               ; no elide, add inter-character delay.  note C=0 already for off
        rts                     ; if eliding just inter-symbol off(1) after chr (silent dit)
_nrml:  ldy #2                  ; usually extend +off(2) (silent dah) ...
_end:
morse_send_end:                 ; ... then ' ' adds off(4) to give off(1)+off(2)+off(4) = off(7) between words
        jmp (morse_emit)        ; jump to output routine and return from there


morse_byte: ; (A) -> nil
    ; send the byte A as a morse sequence (msb first), by eliding the top and bottom nibbles
        pha
        lsr
        lsr
        lsr
        lsr
        ora #%1000_0000         ; high bit to elide
        jsr morse_nibble
        pla
        and #$0f

        ; fall through for lower nibble

morse_nibble: ; (A) -> nil
    ; send the lower four bits of A as morse sequence; hi-bit to elide with next
        ldy #$4
        asl
        php                     ; stash carry (msb)
        asl
        asl
        asl
        ldy #3                  ; send 3+1 bits
        bra morse_send_emit


        ; morse characters stored one per byte, right-justified with a leading 1 prefix
        ; we shift left to find the first 1, and the remaining bits represent dit/dah symbols
        ; all the basic chars are 6 symbols or less, and any other can be formed by
        ; composition (eliding the normal intra-character space)

morse_az:
        .byte %000001_01        ; A .-
        .byte %0001_1000        ; B -...
        .byte %0001_1010        ; C -.-.
        .byte %00001_100        ; D -..
        .byte %0000001_0        ; E .
        .byte %0001_0010        ; F ..-.
        .byte %00001_110        ; G --.
        .byte %0001_0000        ; H ....
        .byte %000001_00        ; I ..
        .byte %0001_0111        ; J .---
        .byte %00001_101        ; K -.-
        .byte %0001_0100        ; L .-..
        .byte %000001_11        ; M --
        .byte %000001_10        ; N -.
        .byte %00001_111        ; O ---
        .byte %0001_0110        ; P .--.
        .byte %0001_1101        ; Q --.-
        .byte %00001_010        ; R .-.
        .byte %00001_000        ; S ...
        .byte %0000001_1        ; T -
        .byte %00001_001        ; U ..-
        .byte %0001_0001        ; V ...-
        .byte %00001_011        ; W .--
        .byte %0001_1001        ; X -..-
        .byte %0001_1011        ; Y -.--
        .byte %0001_1100        ; Z --..
morse_09:
        .byte %001_11111        ; 0 -----
        .byte %001_01111        ; 1 .----
        .byte %001_00111        ; 2 ..---
        .byte %001_00011        ; 3 ...--
        .byte %001_00001        ; 4 ....-
        .byte %001_00000        ; 5 .....
        .byte %001_10000        ; 6 -....
        .byte %001_11000        ; 7 --...
        .byte %001_11100        ; 8 ---..
        .byte %001_11110        ; 9 ----.
