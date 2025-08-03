#nt_header tty
xt_tty:
w_tty:
        ldy #io_tty - io_vectors + 5
        bra io_common

#nt_header con
xt_con:
w_con:
        ldy #io_con - io_vectors + 5
io_common:
        phx
        ldx #5
-
        lda io_vectors,y
        sta output,x
        dex
        dey
        bpl -
        plx
z_tty:
z_con:
        rts

.cerror input != output + 2 || havekey != input + 2, "Expected consecutive output / input / havekey"

io_vectors:
io_con:
    .word kernel_putc
    .word kernel_getc
    .word kernel_kbhit
io_tty:
    .word tty_putc
    .word tty_getc
    .word tty_buflen