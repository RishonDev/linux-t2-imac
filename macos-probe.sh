#!/bin/bash
# Run from macOS terminal. Saves output to ~/Desktop/imac20-probe/
# Usage: bash macos-probe.sh [output-dir]

OUT="${1:-$HOME/Desktop/imac20-probe}"
mkdir -p "$OUT"

echo "Output directory: $OUT"

BOOT_EFI="/System/Library/CoreServices/boot.efi"
AMD_FB="/System/Library/Extensions/AMDRadeonX6000FB.kext/Contents/MacOS/AMDRadeonX6000FB"
AMD_X6="/System/Library/Extensions/AMDRadeonX6000.kext/Contents/MacOS/AMDRadeonX6000"

for bin in "$BOOT_EFI" "$AMD_FB" "$AMD_X6"; do
	name=$(basename "$bin")
	if [[ ! -f "$bin" ]]; then
		echo "SKIP (not found): $bin"
		continue
	fi
	echo "Scanning: $bin"
	strings "$bin" | grep -i "APPAE\|5120\|2880\|tile\|panel\|bridgeOS\|display.mode\|handoff" \
		> "$OUT/${name}.strings.txt"
	otool -tv "$bin" > "$OUT/${name}.disasm.txt" 2>&1 &
done

# ioreg dumps
echo "Dumping ioreg..."
ioreg -l -w 0 -c IOFramebuffer   > "$OUT/ioreg-framebuffer.txt"
ioreg -l -w 0 -c IODisplay       > "$OUT/ioreg-display.txt"
ioreg -l -w 0 -c IOPCIDevice     > "$OUT/ioreg-pci.txt"
ioreg -l -w 0 | grep -i "APPAE\|DisplayMode\|5120\|2880\|tiled\|tile" \
	> "$OUT/ioreg-5k-grep.txt"

# System log - AMD + bridgeOS entries from last boot
echo "Capturing logs..."
log show --predicate 'sender == "AMDRadeonX6000" OR sender CONTAINS "bridge" OR sender CONTAINS "display"' \
	--last boot --info > "$OUT/system-log-amd-bridge.txt" 2>&1

wait
echo "Done. Files saved to $OUT"
ls -lh "$OUT"
