#!/bin/sh
# Screenshot of a scene's window (macOS): scripts/snap.sh <scene> <out.png> [delay_seconds=6]
# Runs the scene windowed for delay+4 s, captures its window by id, lets it exit.
scene=${1:?scene} out=${2:?out.png} delay=${3:-6}
./main "$scene" --WINDOWED --bench $((delay + 4)) > /tmp/snap.log 2>&1 &
pid=$!
sleep "$delay"
id=$(swift -e '
import CoreGraphics
for w in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]] {
  if (w["kCGWindowName"] as? String ?? "").hasPrefix("Cubes") { print(w["kCGWindowNumber"]!); break }
}')
screencapture -x -l "$id" "$out"
wait $pid
