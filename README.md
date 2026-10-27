# NES Serial Connection

A proof-of-concept for connecting two NES consoles through controller port 2.
Each console keeps a controller in port 1, shows both players' dots, and
exchanges controller input over the serial cable.

## Demo operation

The ROM now exchanges each console's controller state over the port-2 serial link.
Connect a controller to port 1 on each NES and power both on. Both consoles
start identical and listening ("PRESS START ON ONE NES"). Press **Start on
exactly one console**: it becomes the master and starts sending; the other
becomes the slave as soon as it receives the master's first valid packet. The
master controls the yellow dot and the slave controls the blue dot. Each screen shows both dots.

Build with cc65, ca65, ld65, and make installed:

```sh
make
```

Load `nes-serial-connection.nes` on both consoles, connect the crossed serial
cable between their port-2 connectors, and use each controller's D-pad to move
its local dot. Each frame is one master-paced transaction at approximately 19200 baud:

- master to slave: pad byte, one sync byte, and a tag byte (sync index plus a
  6-bit check);
- slave to master: pad byte.

Both consoles run the same movement for both dots from the two pads. The sync
byte is one of the four dot coordinates, rotating each frame, and the slave
overwrites its copy, so any drift caused by a lost packet is corrected within
four frames. Master packets are accepted only if their check matches, so no pad
value (including `$FF`) is reserved as an error code. `link_receive` reports
success in the high byte of its 16-bit result. The master holds still until the
slave has answered once; after that, a lost reply makes it reuse the slave's
last known pad.

Starting both consoles as master at once would make both transmit; press Start on only one.

## Port-2 serial approach

The link uses the controller-port signals as TTL-level serial I/O:

- The port-2 data inputs D0, D1, and D4 can be used to read the incoming serial
  signal. The combined, inverted value is read through `$4017`.
- OUT0 (controller strobe) is the console's serial output and is controlled
  through `$4016` D0. For a two-way link, connect each console's OUT0 to the
  other console's chosen port-2 data input.
- The serial signals are TTL-level, not RS-232-level. Do not connect an
  RS-232 interface directly to an NES.

## Building the cable

You need two NES controller extension cables (or two controller-port plugs
wired to a cable), and three wires between the consoles. Only **port 2** is
used for the link. Connect the NES controller port pins as follows
(pin numbers as in the diagram below, viewed from the front of the socket):

```
      _
 GND |1\
     |.5| +5V
OUT0 |3.|
  D0 |47| D4
     '--'
```

| Console A port-2 pin | Console B port-2 pin | Purpose                        |
|----------------------|----------------------|--------------------------------|
| 1 GND                | 1 GND                | common ground                  |
| 3 OUT0 (strobe)      | 4 D0                 | A transmits, B receives        |
| 4 D0                 | 3 OUT0 (strobe)      | B transmits, A receives        |
| 5 +5V                | not connected        | **never connect the +5V pins** |

So: join the two grounds straight through, and **cross** the two signal
wires, so each console's OUT0 (pin 3) goes to the other console's D0 (pin 4).
Leave +5V, and all other pins, unconnected. D4 (pin 7) would also work as the
receive pin, but the ROM reads D0, D1, and D4 together, so use only one of
them.

Construction tips:

- Cut a controller extension cable in half and use one half per console, or
  use a female controller-port plug on each end. Identify wires by
  continuity-testing from the plug pins; wire colors vary between cables.
- Wire as three-conductor: GND, A.OUT0 to B.D0, and B.OUT0 to A.D0. Keep it
  short (a metre or two) since the signals are unbuffered 5 V TTL.
- Check the wiring with a multimeter (no short between any signal and +5V or
  GND, and no short between the two signals) **before** powering either
  console.
- Do not connect this to an RS-232 port; the levels are 0 V / 5 V, not
  +/-12 V.
- Controllers stay in port 1 on each console and are unaffected.
- Port 2 pin 3 (OUT0) is the same signal as the port 1 latch, which is why
  the code polls the pad only when the other console isn't listening.

The code uses `$4016` D0 for transmit and reads the combined, inverted
`$4017` D0/D1/D4 inputs. It bit-bangs 8-N-1 and temporarily disables PPU NMI
during each byte to avoid frame interrupts disturbing bit timing. The master
paces the link: it waits for its own vblank, then sends. Each packet exchange
runs with NMI off (about 2.5 ms, roughly the length of vblank) and NMI is
turned back on afterwards, so a vblank that occurred during the exchange still
fires and uploads sprites. The slave listens with NMI on, so its own vblank
runs normally between packets. Residual limitation: if a console's vblank
falls in the small part of the exchange longer than vblank, that frame's
sprite upload waits for the next vblank. `link_send` idles two bit times before
each byte so the peer is ready for the start bit. `pad_poll` also strobes the
serial output pin, so each side polls only when the other is not listening and
then calls `link_idle` to put the line back high. There is no flow control or
retransmission, so it is intended as a proof of concept rather than a robust
long-distance link.


## Next steps

1. Verify the cable pinout and signal levels before connecting powered consoles.
2. Test the ROM on both consoles and confirm both directions of communication.
3. If needed, add packet checksums, link-status feedback, and retransmission.
