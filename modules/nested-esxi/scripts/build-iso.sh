#!/usr/bin/env bash
# build-iso.sh — build a customized ESXi ISO with an embedded kickstart.
#
# The installer (weasel) reads /KS.CFG from the boot CD when boot.cfg
# kernelopt includes `ks=cdrom:/KS.CFG`. We patch both the BIOS-boot
# boot.cfg and the UEFI-boot efi/boot/boot.cfg so the ISO works
# regardless of how the VM is configured to boot.
#
# Usage:
#   ./build-iso.sh  <input.iso>  <ks.cfg>  <output.iso>
#
# Requires:  xorriso (brew install xorriso ; apt-get install xorriso)

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <input.iso> <ks.cfg> <output.iso>" >&2
  exit 1
fi

INPUT_ISO="$1"
KS_CFG="$2"
OUTPUT_ISO="$3"

command -v xorriso >/dev/null || { echo "xorriso missing — brew install xorriso" >&2; exit 1; }
[ -f "$INPUT_ISO" ] || { echo "Input ISO not found: $INPUT_ISO" >&2; exit 1; }
[ -f "$KS_CFG" ]    || { echo "Kickstart file not found: $KS_CFG" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "[build-iso] extracting $INPUT_ISO ..."
xorriso -osirrox on -indev "$INPUT_ISO" -extract / "$WORK/iso" >/dev/null 2>&1

# Copy the kickstart in. ESXi's boot loader case-folds; use uppercase
# to be safe with old ISO9660 paths.
cp "$KS_CFG" "$WORK/iso/KS.CFG"

# Patch boot.cfg (BIOS) and efi/boot/boot.cfg (UEFI) to auto-load ks.cfg.
# - kernelopt= line: tack on `ks=cdrom:/KS.CFG`
# - The `runweasel` flag tells the installer to run the unattended path.
for cfg in "$WORK/iso/boot.cfg" "$WORK/iso/efi/boot/boot.cfg"; do
  if [ -f "$cfg" ]; then
    echo "[build-iso] patching $cfg"
    # If kernelopt= already has runweasel, append ks=…; otherwise replace.
    if grep -q '^kernelopt=' "$cfg"; then
      sed -i.bak \
        -e 's|^kernelopt=.*|kernelopt=runweasel ks=cdrom:/KS.CFG|' \
        "$cfg"
    else
      echo "kernelopt=runweasel ks=cdrom:/KS.CFG" >> "$cfg"
    fi
    rm -f "$cfg.bak"
  fi
done

echo "[build-iso] rebuilding ISO → $OUTPUT_ISO"
# El-torito boot args replicate the stock ESXi ISO layout.
xorriso -as mkisofs \
  -relaxed-filenames -J -R \
  -b isolinux.bin -c boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e efiboot.img -no-emul-boot \
  -o "$OUTPUT_ISO" \
  "$WORK/iso" \
  2>&1 | grep -vE 'note|GNU' || true

echo "[build-iso] done — $(stat -f '%z' "$OUTPUT_ISO" 2>/dev/null || stat -c '%s' "$OUTPUT_ISO") bytes"
