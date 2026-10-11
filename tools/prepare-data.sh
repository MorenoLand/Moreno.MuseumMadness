#!/bin/sh
# Copies your original game files into assets/game/ as <NAME>.dat so Godot exports include them.
# (assets/original/ is ignored by the editor because Godot would read MUSEUM.RES as its own .res.)
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/assets/game"
n=0
for f in "$root"/assets/original/*; do
	[ -f "$f" ] || continue
	name="$(basename "$f" | tr '[:lower:]' '[:upper:]')"
	cp "$f" "$root/assets/game/$name.dat"
	n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "No game files in assets/original/" >&2; exit 1; }
echo "Copied $n files to assets/game/"
