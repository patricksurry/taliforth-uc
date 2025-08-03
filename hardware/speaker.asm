
.section zp

spk_duty:       .word ?
spk_notes:      .word ?
spk_delay16:    .word ?         ; the two byte delay() constant for one sixteenth of a beat

.endsection



spk_tone:   ; (A) -> nil
    ; start playing midi note number in A (A=69 for A4 @ 440Hz; A=0 for C(-2))
        ldy #0                  ; rewrite A as Y * 12 + (A % 12)
;TODO for 4x clock, start y at -2  (should later chk if <0)
        ldy #$fe
_noct:  cmp #12                 ; Y = A // 12 (octave shifts)
        bmi _found
        sec
        sbc #12
        iny
        bra _noct
_found: tax                     ; A is the remainder used to index the low octave
        lda spk_octave, x       ; get hi/lo from octave lookup
        sta spk_duty
        lda spk_octave+12, x
        sta spk_duty+1
_halve: dey                     ; halve the note value Y times to get the duty cycle
        bmi _done
        lsr spk_duty+1
        ror spk_duty
        bra _halve
_done:  lda VIA_ACR
        and #(255-VIA_T1_MASK)
        ora #VIA_T1_PB7_CTS     ; enable PB7 square wave
        sta VIA_ACR

        lda spk_duty
        sta VIA_T1C
        lda spk_duty+1
        sta VIA_T1C+1
        rts

spk_morse:  ; (Y, C) -> nil
    ; emit morse signal C=on/off for Y units (1,2,3,4)
        bcc _wait               ; signal is normally off
        tya                     ; vary tone for dit and dah
        asl                     ; y = 1/3 => a = 2/6
        eor #$ff                ; -2/-6
        adc #68                 ; carry is set, so A => 67 for dit, 63 for dah
        phy
        jsr spk_tone
        ply
_wait:  jsr morse_delay
        ; fall through to spk_off

spk_off:    ; () -> nil const X, Y
    ; turn off the speaker
        lda VIA_ACR
        and #(255-VIA_T1_MASK)
        ora #VIA_T1_ONCE        ; disable PB7 square wave
        sta VIA_ACR
        rts

;TODO only hi byte for delay, other byte for vol(say),
; notes <128 so could use hi bit as flag
spk_play:
        lda (spk_notes)         ; read the two byte timing header for delay value
        sta spk_delay16
        ldy #1
        lda (spk_notes),y
        sta spk_delay16+1
_loop:  clc
        lda #2
        adc spk_notes
        sta spk_notes
        bcc _note
        inc spk_notes+1
_note:  lda (spk_notes)         ; get next note
        beq _rest               ; 0 means rest
        jsr spk_tone
_rest:  ldy #1
        lda (spk_notes),y       ; get delay count
        beq _done               ; 0 means end
        tax
_more:  ldy spk_delay16
        lda spk_delay16+1
        jsr sleep
        dex
        bne _more
        jsr spk_off
        bra _loop
_done:  rts

.comment
Simplifed ABC notation, see https://abcnotation.com/wiki/abc:standard:v2.1

https://en.wikipedia.org/wiki/Key_signature
https://en.wikipedia.org/wiki/Circle_of_fifths

Notes
        A  A# B  C  C# D  D# E  F  F# G  G#
           Bb       Db    Eb       Gb    Ab
index:  0  1  2  3  4  5  6  7  8  9  a  b
fifth: +3 -2 +5  0 -5 +2 -3 +4 -1 +6 +1 -4      ; inc by 7 mod 12

Circle of fifths:

        Cb Gb Db Ab Eb Bb F  C  G  D  A  E  B  F# C#
        2  9  4  b  6  1  8  3  a  5  0  7  2  9  4
        7b 6b 5b 4b 3b 2b 1b 0  1# 2# 3# 4# 5# 6# 7#

Order of sharps/flats on natural notes:

        F  C  G  D  A  E  B
        1# 2# 3# 4# 5# 6# 7#
        7b 6b 5b 4b 3b 2b 1b
fifth:  -1  0 +1 +2 +3 +4 +5

Given a key signature, look up fifth and write as key = sgn * |key|.
sgn = +1 means sharps, -1 means flats.  |key| gives number.
For sgn = +1, natural notes with fifth + 1 < |key| are sharp.
For sgn = -1, natural notes with fifth + 1 > 6 - |key| are flat.

We'll measure tempo using the delay constant for one sixteenth of a beata:

120 bmp = 0.5 sec/beat = 1/32 sec per 16th; 31250us => 3472 delay const
60 bpm = 1 sec/beat = 1/16 sec per 16th => 6944 delay const
30 bpm = 2 sec/beat = 1/8 sec per 16th => 13889 delay const

And we'll write note duration d in 16ths of a beat.  So we just call delay() d times
with the appropriate constant
.endcomment


twinkle:
    .word $1000
    .byte 72,16, 72,16, 79,16, 79,16, 81,16, 81,16, 79,32, 77,16, 77,16, 76,16, 76,16, 74,16, 74,16, 72,32
    .byte 0,0

; Beethoven's fifth GGGEb|FFFD played |-1114|-1114

.comment
The frequency of the i-th key on a 88 key piano, with i=69 corresponding to A4 @ 440Hz,
is equal to 440 * pow(2, (i-69)/12).  At a clock frequency F=1MHz we have
N = F/freq = 1e6/(440 * pow(2, i-69/12)) cycles per period.
The VIA timer needs to invert twice, so the duty cycle is half of that.
Here's some python code to calculate the frequencies for the lowest octave (with the longest duty cycle)
since we can calculate other octaves by repeatedly halving:

from math import pow

clock = 1e6
notes = "C C# D D# E F F# G G# A A# B".split()
for i in range(0, 12):
    freq = 440 * pow(2, (i-69)/12.)
    duty = round(clock/freq/2)
    octave = (i-21)//12
    note = notes[i%12]
    print(f".byte ${duty & 0xff:02x}, ${duty >> 8:02x}   ; {note:3s}{octave} {freq:.1f}Hz  N={duty}")
.endcomment

; 1MHz
spk_octave:                     ; note octave freq duty
        .byte $e4               ; C     -2  8.2Hz  N=61156     midi note 0 is C(-2) @ 8.1758 Hz
        .byte $7c               ; C# Db -2  8.7Hz  N=57724
        .byte $d4               ; D     -2  9.2Hz  N=54484
        .byte $e2               ; D# Eb -2  9.7Hz  N=51426
        .byte $9c               ; E     -2 10.3Hz  N=48540
        .byte $f7               ; F     -2 10.9Hz  N=45815
        .byte $ec               ; F# Gb -2 11.6Hz  N=43244
        .byte $71               ; G     -2 12.2Hz  N=40817
        .byte $7e               ; G# Ab -2 13.0Hz  N=38526
        .byte $0c               ; A     -1 13.8Hz  N=36364
        .byte $13               ; A# Bb -1 14.6Hz  N=34323
        .byte $8c               ; B     -1 15.4Hz  N=32396
    ; hi bytes
        .byte $ee
        .byte $e1
        .byte $d4
        .byte $c8
        .byte $bd
        .byte $b2
        .byte $a8
        .byte $9f
        .byte $96
        .byte $8e
        .byte $86
        .byte $7e
