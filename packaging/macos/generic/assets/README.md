# DMG artwork

The installer uses `install.tiff`: a 760×480 point background with 1× and 2×
representations for ordinary and Retina displays. The normal build copies this
committed file; it does not compile an artwork tool or require extra packages.

`install.svg` is the editable source. Its low-opacity watermark references the
unchanged corporate logo in `assets/images/cilex-logo.png` at the repository
root. Icon cards align with the native Finder positions in `dmg_layout.py`:
160 point icons centred at (190, 282) and (570, 282). Finder draws the actual
app icon, Applications shortcut and filenames; they are not painted into the
background.

To regenerate after editing the SVG, run from the repository root on a Mac with
the project's Qt development kit and `pkg-config`. These commands write their
temporary compiler/PNG outputs under `/tmp/cilex-dmg-artwork` and replace only
the committed TIFF. `tiffutil` ships with macOS.

START OF PROMPT
```sh
mkdir -p /tmp/cilex-dmg-artwork
/usr/bin/clang++ -std=c++17 -fPIC packaging/macos/generic/assets/render-background.cpp -o /tmp/cilex-dmg-artwork/render-background $(pkg-config --cflags --libs Qt6Svg Qt6Gui)
QT_QPA_PLATFORM=offscreen /tmp/cilex-dmg-artwork/render-background packaging/macos/generic/assets/install.svg /tmp/cilex-dmg-artwork
/usr/bin/tiffutil -cathidpicheck /tmp/cilex-dmg-artwork/install.png /tmp/cilex-dmg-artwork/install@2x.png -out packaging/macos/generic/assets/install.tiff
```
END OF PROMPT

The renderer's first argument is the SVG input path; the second is the output
directory for both PNG scales. Neither temporary executable nor PNG belongs in
the release or Git history.
