#ifndef LINK_H
#define LINK_H

/* Transmit one 8-N-1 byte (~19200 baud) through controller-port 2 serial
 * output. Includes two idle bit times before the start bit. NMI is not touched. */
void __fastcall__ link_send(unsigned char value);

/* Wait up to timeout*1.9 ms for a start bit and receive one byte. The byte is
 * in the low 8 bits; the high byte is 0 on success and 1 on timeout/framing
 * error (so test `result > 255`). Turns NMI off once a start bit is seen; call
 * link_nmi_on() when the transaction is over. */
unsigned int __fastcall__ link_receive(unsigned char timeout);

/* Drive the link line high (idle). Call after pad_poll(), which strobes it. */
void __fastcall__ link_idle(void);

/* Disable NMI / restore it. Wrap each packet exchange in these so a vblank
 * NMI can't disturb bit timing. */
void __fastcall__ link_nmi_off(void);
void __fastcall__ link_nmi_on(void);

#endif
