# Adjust the run address to match the .org in the source code
all: basic.hex

basic.hex: basic.bin
	bin2hex.py --offset 0xC000 basic.bin basic.hex

basic.bin: min_mon.asm
	acme -f plain -o basic.bin min_mon.asm

clean:
	$(RM) *.bin *.hex

distclean: clean
