.comment

We use the VIA shift-out under PHI2 to host SPI mode 0 devices like the SD card at 18 cycles per byte.
The incoming data is stored in a '595 shift register.  This lets us write a byte to the
VIA to start a data exchange and collect the incoming byte a few cycles later.

The standard VIA shift isn't compatible with SPI mode 0, but we can make it work
by delaying the clock signal slightly.  We trigger an exchange by writing to VIA SR
using shift-out under PHI2.
This uses CB1 as the clock input (@ half the PHI2 rate) and CB2 for data out.
SPI mode 0 wants the clock rising edge after the data is ready.
We use two chained D-flip flops to invert and delay the CB1 clock by a full PHI2 cycle.

We can also masquerade as an SPI peripheral with a slower device driving the CB1 clock.
Since the clock is inverted the device should use SPI mode 2 - the one cycle delay
shouldn't matter baud rates up to 100K or so.
See https://en.wikipedia.org/wiki/Serial_Peripheral_Interface#Clock_polarity_and_phase

Timing diagram (https://wavedrom.com/editor.html):

{
    signal: [
      {name: 'ϕ2',    wave: 'N.....................'},
      {name: 'op',    wave: "=.x..............=...x", data: ['STA SR', 'LDA PA']},
      {name: 'SO',    wave: 'lhl...................'},
      {name: 'RD',    wave: 'l...................hl'},
      {name: 'CB1',   wave: 'h.n.......h', phase: 0.5, period: 2},
      {name: 'CB2',   wave: 'xx========.', phase: 0.15, period: 2, data: [7,6,5,4,3,2,1,0]},
      {name: 'ϕ1',    wave: 'P.....................'},
      {name: "CB1'",  wave: 'h.n.......h', phase: 0, period: 2},
      {name: "CB1''", wave: 'h.n.......h', phase: -0.5, period: 2},
      {name: 'SCK',   wave: 'l.P.......l', phase: -0.5, period: 2},
      {name: '? RCK',   wave: 'l..H.......l.......H..', phase: -0.5},
    ],
    head:{
        text: 'VIA shift out ϕ2 → SPI mode 0 (18 cycles)',
        tock:-2,
    },
    foot: {
        text: 'CB2 data lags CB1 by half a ϕ cycle, so we convert CB1 → SPI-0 SCK by inverting and delaying a full ϕ cycle using two chained D flip-flops'
    }
}
.endcomment


SPI_RECV = DVC_DATA
SPI_SEND = VIA_SR


spi_init:   ; () -> (); X,Y const
spi_host:
    ; set up VIA for shift-out under PHI2 driving CB1 aka SPI_SEND
        lda VIA_ACR
        and #(255 - VIA_SR_MASK)
        ora #VIA_SR_OUT_PHI2
        sta VIA_ACR
        rts


spi_peripheral: ; () -> A; X,Y const
    ; set up VIA as an SPI peripheral for slow external host to drive CB1 clock
        lda VIA_ACR
        and #(255 - VIA_SR_MASK)
        ora #VIA_SR_OUT_CB1
        sta VIA_ACR
        rts


spi_readbyte:   ; () -> A; X,Y const
    ; trigger an SPI byte exchange and return the result
        lda #$ff                ; write a noop byte to exchange SR
spi_exchbyte:   ; A -> A; X,Y const
        sta SPI_SEND            ; A -> VIA SR -> SD triggers SD -> ext SR; then lda SPI_RECV
        jsr delay12             ; 12 cycles
        nop                     ; 2 cycles giving 14 between SR out -> start of receive
        lda SPI_RECV            ; 4 cycles
        rts                     ; 6 cycles
