#!/bin/bash
# Records docs/demo.gif from a Debug build of FalcoFold that is already running.
#
# A synthetic desktop (FakeDesktop.swift) covers the built-in display just below the overlay
# while the script sweeps the manual angle and asks the app for debug snapshots, so the GIF
# never shows your real windows. Your settings are exported first and restored at the end.
# Needs ffmpeg (brew install ffmpeg), an unlocked screen and about 30 seconds.
set -u
cd "$(dirname "$0")/../.."
D=io.github.pietrouk.FalcoFold
W=$(mktemp -d); F=$W/frames; mkdir -p "$F"
swiftc -O -o "$W/FakeDesktop" scripts/demo/FakeDesktop.swift || exit 1
defaults export $D "$W/settings.plist"
restore() { defaults import $D "$W/settings.plist"; kill "$FD" 2>/dev/null; }

"$W/FakeDesktop" 60 & FD=$!
sleep 1.5
defaults write $D preset -string silk; defaults write $D perspective -float 1.0
defaults write $D blur -float 0.1; defaults write $D shadow -float 0.3
defaults write $D manualAngle -float 130; defaults write $D manualMode -bool true
sleep 0.6

i=0
snap() {
    f=$(printf "$F/f%03d.png" $i); defaults write $D debugSnapshotPath "$f"
    for t in $(seq 1 60); do [ -s "$f" ] && break; sleep 0.05; done
    if [ ! -s "$f" ]; then echo "Snapshot $i never appeared. Is a Debug build running and the screen unlocked?"; restore; exit 1; fi
    sleep 0.08; i=$((i+1))
}
snap                                                        # f000: open desktop
for a in $(seq 98 -2 24); do defaults write $D manualAngle -float $a; sleep 0.35; snap; done   # f001-f038
sleep 0.3; snap                                             # f039: settled at 24°
defaults write $D manualAngle -float 130
snap; snap; snap                                            # f040-f042: snapping back
sleep 0.6; snap                                             # f043: open again
restore

# Assemble at 12 fps: hold open, sweep down, hold closed, snap back, hold open.
L=$W/list.txt; : > "$L"
add() { for k in $(seq 1 "$2"); do printf "file '%s'\nduration 0.0833\n" "$1" >> "$L"; done; }
add "$F/f000.png" 10
for k in $(seq 1 38); do add "$(printf "$F/f%03d.png" $k)" 1; done
add "$F/f039.png" 8
for k in 40 41 42; do add "$(printf "$F/f%03d.png" $k)" 1; done
add "$F/f043.png" 12
printf "file '%s'\n" "$F/f043.png" >> "$L"
ffmpeg -y -loglevel error -f concat -safe 0 -i "$L" \
    -vf "scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" \
    -loop 0 docs/demo.gif || { rm -rf "$W"; exit 1; }
rm -rf "$W"
ls -la docs/demo.gif
