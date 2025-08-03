mem_test:

.comment

Perform several memory integrity tests based on Michael Barr's
"Software-based memory testing" article.
See https://www.esacademy.com/en/library/technical-articles-and-documents/miscellaneous/software-based-memory-testing.html

These help detect wiring issues in the data bus and address
bus, as well as address decoding problems or missing / damaged ICs.
If you suspect a problem it can be helpful to burn this code
and observe it with an external monitor like https://github.com/Nectivio/65C02-Tool

By default test results are written to $d0-$ff, and the stack ($100-1ff)
is filled with all possible byte values: 0, $80, 1, $81, 2, $82, ..., $7f, $ff.

With RAM at $0000-bfff, IO at $c000-c0ff and ROM at $c100-ffff
we'd expect results like this:

00d0  ff ff ff ff ff ff ff ff  ff ff ff ff ff ff ff ff
00e0  ff ff ff ff ff ff ff ff  0? 00 00 00 00 00 00 00
00f0  01 02 04 08 10 20 40 80  c0 ff ff ff ff ff ff ff
0100  00 80 01 81 02 82 03 83  04 84 05 85 06 86 07 87
...

The range $d0-$ef is a memory map showing one bit per page (256/8 = 32 bytes)
indicating if a byte within page is writable (RAM) or not (ROM).
The ? is 0 or 1 depending on whether the tested I/O byte acts like RAM or not.
(Nb. a simulator without ROM write protection will likely show all $ff values.)

The test results $fb-ff should be $ff, with $fa counting the number of pages
which supported read/write.

.endcomment

rw_map = $d0        ; 32 byte memory bitmap
dbus_tgt = $f0      ; 8 byte output range

test_out = $f8      ; we loop reading these 8 bytes at end of test

rw_cnt = $f8        ; count of r/w RAM pages (usually, e.g $c0, or $0 for all RAM)
rw_out = $f9        ; tested pages-1 (should be $ff)
dbus_out = $fa      ; single byte test result (should be $ff)
abus_out = $fb      ; single byte test result (should be $ff)
stk_out = $fc       ; two byte stack test result (should be $ffff)
test_ptr = $fe      ; temporary two byte pointer
jsr_out = $fe       ; overwrites test_ptr in last test (should be $ffff)

; If your highest RAM address is smaller than $8000, choose the highest
; max_ram_bit where 1 << max_ram_bit is still RAM.  For example if your
; address decoding has RAM from $0..3fff then choose max_ram_bit=13 since
; $2000 (binary %0010_0000_0000_0000) is in RAM but $4000 is not.

max_ram_bit = 15     ; In my system, $8000 is in RAM

dbus_test:
    ; Test that the databus lines are wired correctly by checking that
    ; they can each be set independently.  We write a "walking one"
    ; to a fixed address and test that we can read back. It's OK
    ; to read immediately after write since we'll check persistence later.
    ; If the test fails dbus_val will contain the failing pattern,
    ; otherwise it will contain $0.
        lda #$80
        ldx #7
-
        sta dbus_tgt,x
        cmp dbus_tgt,x
        bne _fail
        lsr
        dex
        bpl -
_fail:
        stx dbus_out

abus_test:
    ; Now test that the address bus lines can be set independently
    ; to both one and zero.  We'll write the values 1,2,3, ... to
    ; RAM addresses %0, %1, %10, %100, %1000 and so forth.
    ; If any bit is stuck high or low, or two bits are coupled, then
    ; writing to one of these addresses will change one or more of the others.
    ; We do a slightly less strict test than described in the article
    ; by simply reading back and summing the values after we've written
    ; them all.  A successful test sums 1+2+3+..+(max_bit+2)
    ; which equals (max_bit+2)*(max_bit+3)/2.

        ; Set up first test address
        stz test_ptr
        stz test_ptr+1

        lda #max_ram_bit+2
        sec
-
        sta (test_ptr)          ; Store test value
        rol test_ptr
        rol test_ptr+1          ; Walk the address bit upward
        dea                     ; Decrement test value
        bne -

        ; Repeat the process to validate the sum, starting
        ; from an offset that should make us finish at $ff

        stz test_ptr
        stz test_ptr+1

        lda #255 - (max_ram_bit+2) * (max_ram_bit+3) / 2
        clc
        adc (test_ptr)          ; initial value

        ldx #max_ram_bit+1
        sec
-
        rol test_ptr
        rol test_ptr+1
        adc (test_ptr)          ; C=0 before and after
        dex
        bne -
        sta abus_out

rw_test:
    ; form a bitmap indicating whether we can write to a byte in each page
    ; we use addresses like $0080, $0181, $0282, $0383, ..., $1090, ...
    ; We test reading and writing complementary bit patterns $aa and $55
    ; but restore the original value to avoid stomping simulator "ROM".
        lda #$80
        sta test_ptr
        stz test_ptr+1
        stz rw_cnt
        stz rw_out

        ldx #0
_loop:
        lda #$80                ; sentinel bit sets C=1 after 8 shifts
        sta rw_map,x
-
        clc                     ; assume we can't r/w (c=0)
        lda (test_ptr)
        tay                     ; save original value
        lda #$55
        sta (test_ptr)
        cmp (test_ptr)
        bne +
        lda #$aa
        sta (test_ptr)
        eor (test_ptr)
        bne +
        tya
        sec                     ; r/w succeeded, c=1
        inc rw_cnt              ; count r/w pages
+
        inc rw_out              ; count pages
        sta (test_ptr)          ; restore original value

        ror rw_map,x            ; roll in the result for this page
        inc test_ptr            ; move to next target address
        inc test_ptr+1
        beq _done               ; wrapped?
        bcc -                   ; finished 8 pages?

        inx
        bra _loop
_done:
        dec rw_out              ; # pages - 1 should be $ff

stk_test:
    ; Test the stack by writing the values $ff, 0, ... $fe
    ; to memory locations $100..1ff and then popping them all
    ; in turn to sum them.  We expect 255*256/2 = $7f80
    ; and add the constant $807f to get a result of $ffff.

        ldx #0
-
        txa                     ; fill stack with ff, 0, ..., fe
        inx
        sta $100,x
        bne -

        lda #$7f                ; initial value $807f
        sta stk_out
        ina
        sta stk_out+1

        dex                     ; X is 0 => $ff
        txs                     ; SP = $ff
        inx                     ; back to X=0
-
        pla                     ; pop 256 items off the stack and sum
        clc
        adc stk_out
        sta stk_out
        lda #0
        adc stk_out+1
        sta stk_out+1
        inx
        bne -

jsr_test:
    ; test filling the stack with 128 recursive calls and unwinding
    ; we'll sum up the stack pointer values we see within each call,
    ; which look like $fd, then $fb, $f9, ... $1 and finally $ff on
    ; the final iteration.   The sum of odd values 1+3+...+255
    ; ending in 2*128-1 is 128^2 = $4000.
    ; We'll leave the stack itself filled with all unique bytes like
    ; $0

    ; SP starts as $ff (empty stack),

        lda #$ff                ; Start sum from $bfff so we end at $ffff
        sta jsr_out
        lda #$bf
        sta jsr_out+1

        ldy #$80

recurse_test:
        dey                     ; count down recursion depth
        bmi +

        tsx
        txa                     ; grab stack pointer
        clc
        adc jsr_out             ; add to running sum
        sta jsr_out
        lda #0
        adc jsr_out+1           ; handle carry
        sta jsr_out+1
        jsr recurse_test
        tya                     ; leave breadcrumbs as we empty stack
        ora #$80                ; -Y-1
        pha
        phy                     ; original
        pla
        pla
+
        iny
        bmi _done
        rts
_done:

; --- tests end ---

forever:
    ; after the tests we'll just loop reading the output so that
    ; we can easily observe the values in a monitor tool
        ldx #test_out
-
        lda 0,x
        inx
        bne -                   ; cycle thru values until we wrap past $ff

        bra forever             ; or jump to your kernel etc
