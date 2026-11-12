#!/bin/bash
# Regenerate the checked-in icon; never called by build-app.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/app-icon/AppIcon.iconset Resources

python3 - <<'PY'
import xml.etree.ElementTree as ET
from copy import deepcopy

ET.register_namespace('', 'http://www.w3.org/2000/svg')
icon = ET.parse('docs/logo/tokotoko-icon.svg').getroot()
mascot = ET.parse('docs/logo/tokotoko-mascot.svg').getroot()
small = ET.Element(icon.tag, icon.attrib)
plate = deepcopy(icon[0])
plate.set('fill', '#F4B63F')  # Amber, so the egg's ink outline and feet stay visible when small.
small.append(plate)
art = ET.SubElement(small, '{http://www.w3.org/2000/svg}g',
                    {'transform': 'translate(0 -64) scale(6.4)'})
art.extend(mascot)  # Align the mascot's 10-unit pixels to the 16 px grid.
ET.ElementTree(small).write('.build/app-icon/mascot-icon.svg', encoding='unicode')
PY

for size in 16 32 128 256 512; do
  source=docs/logo/tokotoko-icon.svg
  if [ "$size" -le 32 ]; then source=.build/app-icon/mascot-icon.svg; fi
  for scale in 1 2; do
    suffix=""
    if [ "$scale" -eq 2 ]; then suffix="@2x"; fi
    pixels=$((size * scale))
    rsvg-convert --width "$pixels" --height "$pixels" "$source" \
      --output ".build/app-icon/AppIcon.iconset/icon_${size}x${size}${suffix}.png"
  done
done

# Use the native ImageIO encoder, including DPI to distinguish 1x and 2x slots.
cat > .build/app-icon/encode.swift <<'SWIFT'
import Foundation
import ImageIO

let sizes = [16, 32, 128, 256, 512]
let output = URL(fileURLWithPath: "Resources/AppIcon.icns")
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.apple.icns" as CFString, sizes.count * 2, nil) else {
    fatalError("Cannot create AppIcon.icns")
}
for size in sizes {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let url = URL(fileURLWithPath: ".build/app-icon/AppIcon.iconset/icon_\(size)x\(size)\(suffix).png")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fatalError("Cannot decode \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: 72 * scale,
            kCGImagePropertyDPIHeight: 72 * scale,
        ] as CFDictionary)
    }
}
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot encode AppIcon.icns") }
SWIFT
swift -module-cache-path .build/app-icon/ModuleCache .build/app-icon/encode.swift
echo "Generated Resources/AppIcon.icns"
