CC65 = cc65
CA65 = ca65
LD65 = ld65
NAME = nes-serial-connection
CFG = nrom_32k_vert.cfg

.PHONY: all clean

all: $(NAME).nes

$(NAME).nes: main.o crt0.o $(CFG) Alpha3.chr
	$(LD65) -C $(CFG) -o $@ crt0.o main.o nes.lib -Ln labels.txt
	@echo "$@ created"

main.s: main.c Sprites.h LIB/neslib.h LIB/nesdoug.h LIB/link.h
	$(CC65) -Oirs $< --add-source

main.o: main.s
	$(CA65) $< -g

crt0.o: crt0.s Alpha3.chr LIB/neslib.s LIB/nesdoug.s LIB/link.s MUSIC/famitone2.s
	$(CA65) crt0.s

clean:
	rm -f $(NAME).nes main.s main.o crt0.o labels.txt
