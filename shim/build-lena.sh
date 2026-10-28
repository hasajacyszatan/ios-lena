#!/bin/bash
# Build the shim and wrap it in a boot.img v2 for Sony Xperia 10 III (pdx213 / SM6350).
# Appends payload directly to Image (after _end at 4K boundary) so ABL loads it into
# RAM alongside the kernel, bypassing any ABL initrd-drop issues.
set -euo pipefail
cd "$(dirname "$0")"
CC=aarch64-linux-gnu-gcc
OBJCOPY=aarch64-linux-gnu-objcopy
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
abs=$(aarch64-linux-gnu-readelf -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
size=$((16#$(aarch64-linux-gnu-nm out/shim.elf | awk '$3=="_end"{print $1}')))
truncate -s "$size" out/Image

RAMDISK=out/ramdisk-lena.bin
if [ -n "${1:-}" ]; then
	# 1. Embed directly after _end at 4K boundary
	align_size=$(( (size + 0xfff) & ~0xfff ))
	truncate -s "$align_size" out/Image
	cat "$1" >> out/Image
	# Update ARM64 Linux header image_size (offset 16, 64-bit LE)
	python3 -c 'import os,struct,sys; f=open(sys.argv[1],"r+b"); f.seek(16); f.write(struct.pack("<Q", os.path.getsize(sys.argv[1])))' out/Image
	echo "payload embedded into out/Image at offset $align_size"

	# 2. Also put into ramdisk cpio just in case
	(cd out && rm -rf rd && mkdir rd && cp "../${1}" rd/payload.bin && \
	 cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk-lena.bin)
else
	(cd out && rm -rf rd && mkdir rd && cd rd && \
	 find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk-lena.bin)
fi

DTB="${DTB:-../xperia-backup/boot_unpacked/dtb}"
[ -f "$DTB" ] || { echo "error: DTB not found at $DTB" >&2; exit 1; }

MKBOOTIMG="${MKBOOTIMG:-mkbootimg}"
$MKBOOTIMG \
	--header_version 2 \
	--kernel out/Image \
	--ramdisk "$RAMDISK" \
	--dtb "$DTB" \
	--base 0 \
	--kernel_offset 0x8000 \
	--ramdisk_offset 0x1000000 \
	--tags_offset 0x100 \
	--dtb_offset 0x1f00000 \
	--pagesize 4096 \
	--os_version 16.0.0 \
	--os_patch_level 2026-10 \
	--cmdline "console=null" \
	-o out/shim-boot-lena.img

ls -lh out/Image out/shim-boot-lena.img
