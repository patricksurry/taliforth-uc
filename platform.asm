; debug with simulator:    tools/c65/c65 -r taliforth-uc.bin -m 0xffe0 -l platform/uc/uc-labelmap.txt -m 0xffe0 -gg

        .cpu "65c02"
        .enc "none"

.weak
TESTS           = 0             ; enable tests?
DEBUG           = 0
.endweak

; For our minimal build, we'll drop all the optional words

TALI_ARCH       :?= "c65"
; TALI_ARCH       :?= "bb2"

TALI_OPTIONAL_WORDS := [ "block" ]
TALI_OPTION_CR_EOL := [ "lf" ]
TALI_OPTION_MAX_COLS := 40              ; use narrow DUMP
TALI_OPTION_HISTORY := 0
TALI_OPTION_TERSE := 1

AscFF       = $0f               ; form feed
AscTab      = $09               ; tab

ram_end = $bbff                 ; end of RAM for Tali (saving 1K screen buffer)
TXT_BUF = address(ram_end+1)    ; 1K screen buffer (40*16 + 40*16/2 = 960 bytes)

IOBASE  = address($c000)

; IO address decoding uses low 8 bits of address $c0xx
;
;   a7   a6   a5   a4   a3   a2   a1   a0
; +----+----+----+----+----+----+----+----+
; | V/L| xx | D1 | D0 | R3 | R2 | R1 | R0 |
; +----+----+----+----+----+----+----+----+
;
; The top bit selects VIA (H) or LCD (L)
; Bits D0-1 select VIA device 0 (none), KBD = 2, LCD = 3
; Bits R0-3 select VIA register or LCD C/D (R0)

; =====================================================================

        * = zpage_end + 1       ; leave the bottom of zp for Tali
.dsection zp

; =====================================================================

        * = $8000

.byte 0                         ; force 32kb image for EEPROM

; ---------------------------------------------------------------------
; Start of code

        * = $c100

.include "hardware/via.asm"
.include "hardware/spi.asm"

.include "hardware/speaker.asm"
.include "hardware/lcd6963.asm"
.include "hardware/kbspi.asm"
.include "hardware/joypad.asm"
.include "hardware/sd.asm"
.include "hardware/tty.asm"

.include "kernel/util.asm"
.include "kernel/morse.asm"
.include "kernel/txt.asm"
.if TESTS
.include "kernel/memtest.asm"
.endif

; =====================================================================
; kernel I/O routines

kernel_init:
    ; Hardware initialization called as turnkey during forth startup
        sei                     ; no interrupts until we've set up I/O hardware

        jsr util_init
        jsr via_init
        jsr spi_init

.if TALI_ARCH != "c65"
        lda #<spk_morse
        sta morse_emit
        lda #>spk_morse
        sta morse_emit+1

        lda #('A' | $80)        ; prosign "wait" elides A^S  ._...
        jsr morse_send
        lda #'S'
        jsr morse_send
.endif

        jsr lcd_init
        jsr txt_init

        jsr tty_init

        cli

        ; if high byte of turnkey vector is in RAM, we're in a simulator and want warm start
        lda #$c0
        cmp $fff9               ; C=1 if turnkey is in RAM, C=0 normally

        jmp forth               ; Setup complete, show kernel string and return to forth



kernel_bye:
        brk


kernel_putc = txt_putc

kernel_getc:
        phy
        jsr txt_show_cursor
;TODO in a non-blocking version we should inc rand16 l/h (skip 0)
.if TALI_ARCH != "c65"
        jsr kbspi_getc             ; preserves X and Y
.else
-
        lda io_getc
        beq -           ; c65 is blocking but py65mon isn't
.endif
        pha
        jsr txt_hide_cursor
        pla
        ply
        stz txt_pager           ; reset pager count
        rts

.if TALI_ARCH != "c65"          ; c65 implements this already
kernel_kbhit = kbspi_kbhit
.endif

s_kernel_id:
        .byte n_kernel_id
        .text 9, " _   _  ____", AscLF
        .text 9, "| | | |/ ___)", 9, "Micro Colossus", AscLF
        .text 9, "| |_| | (___",  9, " Tali Forth 2", AscLF
        .text 9, "| ._,_|\____)", 9, "  ", TODAY, AscLF
        .text 9, "| |   `", AscLF
        .text 9, "|_|  ", GIT_IDENT, AscLF, AscLF
n_kernel_id = * - s_kernel_id

; =====================================================================
; Finally include Taliforth itself, along with the extra words we need

prev_nt := 0
.include "../../examples/words/bind.asm"
.include "../../examples/words/block-ext.asm"
.include "../../examples/words/byte.asm"
.include "../../examples/words/core-ext.asm"
.include "../../examples/words/dasm.asm"
.include "../../examples/words/rand.asm"
.include "../../examples/words/srecord.asm"

.include "words/adventure.asm"
.include "words/sd.asm"
.include "words/tty.asm"
.include "words/facility.asm"

; Make sure TALI_xxx options are set BEFORE this include.
.include "../../taliforth.asm"

user_words_start:
.binary "platform_forth.asc"
user_words_end:

; =====================================================================
; Simulator IO definitions

.if TALI_ARCH == "c65"

.cwarn *-1 >= $ffe0, "Magic IO conflict"

        * = $ffe0               ; use top memory to avoid stomping IO page

; Define the c65 / py65mon magic IO addresses relative to $ffe0
                .byte ?
io_putc:        .byte ?         ; +1     write byte to stdout
                .byte ?
io_kbhit:       .byte ?         ; +3     read non-zero on key ready (c65 only)
io_getc:        .byte ?         ; +4     non-blocking read input character (0 if no key)
                .byte ?
io_clk_start:   .byte ?         ; +6     *read* to start cycle counter
io_clk_stop:    .byte ?         ; +7     *read* to stop the cycle counter
io_clk_cycles:  .word ?,?       ; +8-b   32-bit cycle count in NUXI order
                .word ?,?

; These magic block IO addresses are only implemented by c65 (not py65mon)
; see c65/README.md for more detail

io_blk_action:  .byte ?         ; +$10     Write to act (status=0 read=1 write=2)
io_blk_status:  .byte ?         ; +$11     Read action result (OK=0)
io_blk_number:  .word ?         ; +$12     Little endian block number 0-ffff
io_blk_buffer:  .word ?         ; +$14     Little endian memory address

.endif

; =====================================================================
; System vectors

        * = $fff6
        .word s_kernel_id       ; $fff6 counted ID string
        .word w_block_boot      ; $fff8 turnkey (startup) word
        .word kernel_init       ; $fffa nmi
        .word kernel_init       ; $fffc reset
.if TALI_ARCH != "c65"          ; $fffe irq/brk
        ; TTY device is the only source of interrupts
        .word tty_isr
.else
        .word kernel_init
.endif

; =====================================================================
