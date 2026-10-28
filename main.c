#include "LIB/neslib.h"
#include "LIB/nesdoug.h"
#include "LIB/link.h"
#include "Sprites.h"

#pragma bss-name(push, "BSS")
unsigned char local_x = 64;
unsigned char local_y = 112;
unsigned char remote_x = 176;
unsigned char remote_y = 112;
unsigned char is_master;
unsigned char decided;
unsigned char linked;
unsigned char have_packet;
unsigned char drawn_role;
unsigned char pad;
unsigned char received_pad;
unsigned char remote_pad;
unsigned char next_pad;
unsigned char frame;
unsigned char sync_idx;
unsigned char sync_val;
unsigned char sync_tag;
unsigned int rx0;
unsigned int rx1;
unsigned int rx2;

const unsigned char title[] = "PORT 1: MOVE YOUR DOT";
const unsigned char wait_text[] = "PRESS START ON ONE NES";
const unsigned char master_text[] = "ROLE: MASTER          ";
const unsigned char slave_text[] = "ROLE: SLAVE           ";
const unsigned char palette_bg[] = {
	0x0f, 0x00, 0x10, 0x30,
	0, 0, 0, 0,
	0, 0, 0, 0,
	0, 0, 0, 0
};
const unsigned char palette_sp[] = {
	0x0f, 0x0f, 0x0f, 0x28,
	0x0f, 0x0f, 0x0f, 0x12,
	0, 0, 0, 0,
	0, 0, 0, 0
};

static void move_dot(unsigned char *x, unsigned char *y, unsigned char pad)
{
	if ((pad & PAD_LEFT) && *x > 8)
		--*x;
	if ((pad & PAD_RIGHT) && *x < 224)
		++*x;
	if ((pad & PAD_UP) && *y > 24)
		--*y;
	if ((pad & PAD_DOWN) && *y < 208)
		++*y;
}

/* 6-bit check over the pad and sync bytes (the byte values are all valid). */
static unsigned char check6(unsigned char a, unsigned char b)
{
	unsigned char t = a ^ b ^ 0x5A;
	return (t ^ (t >> 6)) & 0x3F;
}

static unsigned char sync_get(unsigned char idx)
{
	switch (idx) {
	case 0: return local_x;
	case 1: return local_y;
	case 2: return remote_x;
	default: return remote_y;
	}
}

/* Master's local is the slave's remote, so the slave maps indexes 0..3 to
 * remote_x, remote_y, local_x, local_y. */
static void sync_set_slave(unsigned char idx, unsigned char v)
{
	switch (idx) {
	case 0: remote_x = v; break;
	case 1: remote_y = v; break;
	case 2: local_x = v; break;
	default: local_y = v; break;
	}
}

/* Receive and validate one master packet; returns 1 if rx0 (pad), rx1 (sync
 * value) and rx2 (tag) are good. NMI is off if it returns 1, on if it returns 0. */
static unsigned char slave_receive(unsigned char timeout)
{
	rx0 = link_receive(timeout);
	if (rx0 <= 255) {
		rx1 = link_receive(1);
		rx2 = link_receive(1);
		if (rx1 <= 255 && rx2 <= 255 &&
		    (rx2 & 0x3F) == check6((unsigned char)rx0, (unsigned char)rx1))
			return 1;
	}
	link_nmi_on();
	return 0;
}

/* Debug line at the top of the screen, rewritten by the NMI every frame:
 * "P1:xx P2:xx" = the two controller bytes in hex (P1 = master, P2 = slave). */
unsigned char dbg_buf[] = {
	NT_UPD_HORZ | 0x23, 0x6A, 11, /* row 27, column 10: bottom, centered */
	'P', '1', ':', '0', '0', ' ', 'P', '2', ':', '0', '0',
	NT_UPD_EOF
};

static unsigned char hex_digit(unsigned char v)
{
	v &= 0x0F;
	return v < 10 ? '0' + v : 'A' - 10 + v;
}

static void show_pads(unsigned char p1, unsigned char p2)
{
	dbg_buf[6] = hex_digit(p1 >> 4);
	dbg_buf[7] = hex_digit(p1);
	dbg_buf[12] = hex_digit(p2 >> 4);
	dbg_buf[13] = hex_digit(p2);
}

static void draw_role(void)
{
	ppu_off();
	vram_adr(NTADR_A(6, 4));
	if (is_master)
		vram_write(master_text, sizeof(master_text) - 1);
	else
		vram_write(slave_text, sizeof(slave_text) - 1);
	ppu_on_all();
}

void main(void)
{
	ppu_off();
	pal_bg(palette_bg);
	pal_spr(palette_sp);
	bank_spr(1);

	vram_adr(NTADR_A(6, 2));
	vram_write(title, sizeof(title) - 1);
	vram_adr(NTADR_A(6, 4));
	vram_write(wait_text, sizeof(wait_text) - 1);
	ppu_on_all();
	set_vram_update(dbg_buf);

	/*
	 * Startup handshake (like the Game Boy link tutorial): both consoles are
	 * identical and begin undecided, listening. Pressing START on one console
	 * makes it the master; the other becomes the slave when it receives the
	 * master's first valid packet, so no button needs to be held at boot.
	 *
	 * Protocol (one transaction per frame, master paced), ~19200 baud:
	 *   master -> slave: pad, sync value, tag = (sync index << 6) | check6
	 *   slave -> master: pad
	 * The sync value is one of the four dot coordinates, rotating by frame,
	 * taken from the master BEFORE this frame's movement. The slave overwrites
	 * its copy, so any drift from a lost packet heals within four frames.
	 * Packets are checked, so no byte value (not even $FF) is an error code.
	 *
	 * NMI is off for the whole transaction (about 2.5 ms, roughly the length
	 * of vblank) and turned back on afterwards, so a vblank that happened
	 * during it still triggers the sprite upload. The master waits for its own
	 * vblank before each transaction. The slave never waits for vblank: it
	 * listens with NMI on, so its own vblank can run normally in the idle gap.
	 *
	 * pad_poll() strobes OUT0, the serial output line, and leaves it low, so
	 * link_idle() restores the high idle level. Each console polls only while
	 * the other is not listening.
	 */
	while (1) {
		if (!decided) {
			pad = pad_poll(0);
			link_idle();
			if (pad & PAD_START) {
				is_master = 1;
				decided = 1;
				draw_role();
			} else if (slave_receive(8)) {
				is_master = 0;
				decided = 1;
				have_packet = 1;
			} else {
				continue;
			}
		}

		if (is_master) {
			ppu_wait_nmi();
			link_nmi_off();
			sync_idx = frame & 3;
			sync_val = sync_get(sync_idx);
			sync_tag = (sync_idx << 6) | check6(pad, sync_val);
			link_send(pad);
			link_send(sync_val);
			link_send(sync_tag);
			rx0 = link_receive(2);
			link_nmi_on();
			if (rx0 <= 255) {
				remote_pad = (unsigned char)rx0;
				linked = 1;
			}
			++frame;
			received_pad = remote_pad;
			next_pad = pad_poll(0);
			link_idle();
		} else {
			if (!have_packet && !slave_receive(8))
				continue; /* nothing from master yet; keep listening */
			have_packet = 0;
			received_pad = (unsigned char)rx0;
			sync_set_slave((unsigned char)rx2 >> 6, (unsigned char)rx1);
			link_send(pad);
			linked = 1;
		}

		/* Both consoles run the same simulation from the two controllers;
		 * the master holds still until the slave has answered once. */
		if (linked) {
			move_dot(&local_x, &local_y, pad);
			move_dot(&remote_x, &remote_y, received_pad);
		}

		if (is_master)
			show_pads(pad, received_pad);
		else
			show_pads(received_pad, pad);

		oam_clear();
		if (is_master) {
			oam_meta_spr(local_x, local_y, YellowSpr);
			oam_meta_spr(remote_x, remote_y, BlueSpr);
			pad = next_pad;
		} else {
			oam_meta_spr(remote_x, remote_y, YellowSpr);
			oam_meta_spr(local_x, local_y, BlueSpr);
			/* NMI is still off from the transaction, so the buffer can't be
			 * uploaded half-built; the pending vblank (if any) fires on enable. */
			ppu_request_update();
			link_nmi_on();
			pad = pad_poll(0);
			link_idle();
			if (!drawn_role) {
				drawn_role = 1;
				draw_role();
			}
		}
	}
}
