#!/bin/sh
# Clip of a scene (macOS): scripts/record.sh <scene> <ex,ey,ez,tx,ty,tz | path.json> <out.mp4>
# Runs ./main <scene> --WINDOWED --record <pose or path>, screen-records the window content rectangle (screencapture -v -R),
# trims to the motion using the RECORD_START/RECORD_END timestamps the game prints and encodes 1280x720 H.264. A pose
# gives a 10 s clip; a path.json gives its length (keys' last t). Needs ffmpeg and screen-recording permission for the terminal.
scene=${1:?scene} pose=${2:?ex,ey,ez,tx,ty,tz or path.json} out=${3:?out.mp4}
# capture length in s: settle (3) + motion + tail (1) + margin (3)
case $pose in
  *.json) cap_len=$(python3 -c "import json,sys; print(int(json.load(open(sys.argv[1]))['keys'][-1]['t']) + 7)" "$pose") ;;
  *) cap_len=17 ;;
esac
log=$(mktemp) raw=$(mktemp).mov
./main "$scene" --WINDOWED --record "$pose" > "$log" 2>&1 &
game=$!
rect=
for _ in $(seq 1 100); do
  # x,y,w,h of the window content (below the 28 pt title bar), in points
  rect=$(swift -e '
import CoreGraphics
for w in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]] {
  if (w["kCGWindowName"] as? String ?? "").hasPrefix("Cubes") {
    let b = w["kCGWindowBounds"] as! [String: Double]
    print("\(Int(b["X"]!)),\(Int(b["Y"]!) + 28),\(Int(b["Width"]!)),\(Int(b["Height"]!) - 28)"); break
  }
}')
  [ -n "$rect" ] && break
  sleep 0.2
done
[ -n "$rect" ] || { echo "no game window"; kill $game; exit 1; }
cap_start=$(python3 -c 'import time; print(time.time())')
screencapture -x -v -V "$cap_len" -R "$rect" "$raw" &
cap=$!
wait $game; wait $cap
s=$(sed -n 's/^RECORD_START //p' "$log"); e=$(sed -n 's/^RECORD_END //p' "$log")
[ -n "$s" ] && [ -n "$e" ] || { echo "no markers"; cat "$log"; exit 1; }
ss=$(python3 -c "print(max(0, $s - $cap_start - 0.4))")   # 0.4 s lead-in; capture start latency is included in cap_start
dur=$(python3 -c "print($e - $s + 0.8)")
ffmpeg -y -loglevel error -ss "$ss" -t "$dur" -i "$raw" \
  -vf "scale=1280:720:flags=lanczos" -an -c:v libx264 -crf 24 -preset slow -pix_fmt yuv420p -movflags +faststart "$out"
rm -f "$raw" "$log"
