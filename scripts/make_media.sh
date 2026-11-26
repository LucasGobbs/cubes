#!/bin/sh
# Regenerates media/ (hero video, GIF, stills of the city and the other scenes).
# Needs: make build done (./main), ffmpeg + ffprobe, sips (macOS, for JPEG).
# Idempotent: overwrites the outputs, never touches sea*.png / sea.gif.
# Run from the repo root: sh scripts/make_media.sh
set -eu

MEDIA=media
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Pose = "eye x,y,z target x,y,z" as --record; 4 s render, frame at 3.5 s is the still.
# Env vars are the city demo hooks (src/scenes/city/scene.odin): HOUR, HOURS_PER_SEC, WEATHER.
still() { # still <out> <pose> <hour> <weather>
	CUBES_CITY_HOUR=$3 CUBES_CITY_WEATHER=$4 ./main city \
		--render-video "$TMP/still.mp4" --fps 60 --seconds 4 --video-size 1920x1080 --record "$2"
	ffmpeg -loglevel error -y -ss 3.5 -i "$TMP/still.mp4" -frames:v 1 "$1"
}
OVERVIEW="1536,190,1800,1536,60,1150"
AERIAL="1800,200,2300,1400,30,1000"
AVENUE="1536,14,1880,1536,30,1000"

# Hero: sunset 17.6 h -> ~20 h over 24 s (0.1 h/s), light rain. Path (media/city-hero.path.json):
# 3 s hold at key 0 + last key t=20 + 1 s tail = 24 s at 60 fps.
CUBES_CITY_HOUR=17.6 CUBES_CITY_HOURS_PER_SEC=0.1 CUBES_CITY_WEATHER=0.5 ./main city \
	--render-video "$TMP/hero_raw.mp4" --record "$MEDIA/city-hero.path.json" --fps 60 --video-size 1920x1080
# shortcut: re-encode of the engine's CRF 20 raw file, CRF 28 keeps it under ~25 MB, upgrade by lowering CRF if size allows.
ffmpeg -loglevel error -y -i "$TMP/hero_raw.mp4" -c:v libx264 -preset slow -crf 28 -pix_fmt yuv420p -an \
	-movflags +faststart "$MEDIA/city-hero.mp4"

# GIF: 8 s loop from the hero (12 s to 20 s: dusk to night through the street and the final aerial), 800x450, 12 fps, 32 colours.
# shortcut: 800x450 / 12 fps instead of 960x540 / 15 fps, rain noise makes larger GIFs exceed 10 MB.
ffmpeg -loglevel error -y -ss 12 -t 8 -i "$MEDIA/city-hero.mp4" \
	-vf "fps=12,scale=800:-1:flags=lanczos,palettegen=max_colors=32:stats_mode=full" "$TMP/pal.png"
ffmpeg -loglevel error -y -ss 12 -t 8 -i "$MEDIA/city-hero.mp4" -i "$TMP/pal.png" \
	-lavfi "fps=12,scale=800:-1:flags=lanczos [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5" \
	-loop 0 "$MEDIA/city-hero.gif"

# City stills (1920x1080).
still "$MEDIA/city-day.png" "$OVERVIEW" 12 0
still "$TMP/city-sunset.png" "$OVERVIEW" 18 0
still "$TMP/city-night.png" "$AERIAL" 22 0
still "$TMP/city-rain.png" "$AVENUE" 22 0.5

# Storm: clear night at weather 1, 14 s clip; the still is the brightest frame (lightning) by YAVG.
CUBES_CITY_HOUR=22 CUBES_CITY_WEATHER=1 ./main city --render-video "$TMP/storm.mp4" --fps 60 --seconds 14 \
	--video-size 1920x1080 --record "1536,14,1880,1536,30,1000"
ffmpeg -nostats -loglevel error -i "$TMP/storm.mp4" -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=$TMP/yavg.txt" -f null - 2>/dev/null
FLASH=$(grep -o 'YAVG=[0-9.]*' "$TMP/yavg.txt" | awk -F= '{print NR-1, $2}' | sort -k2 -n -r | head -1 | cut -d' ' -f1)
ffmpeg -loglevel error -y -i "$TMP/storm.mp4" -vf "select=eq(n\,$FLASH)" -fps_mode passthrough -frames:v 1 "$MEDIA/city-storm.png"

# Sunset, night and rain stills to JPEG q88 (sips on macOS).
for n in sunset night rain; do
	sips -s format jpeg -s formatOptions 88 "$TMP/city-$n.png" --out "$MEDIA/city-$n.jpg" >/dev/null
done

# Other scenes, default/initial camera, frame at 3.5 s.
for s in boat forest_instanced skinned physics benchmark; do
	./main "$s" --render-video "$TMP/$s.mp4" --fps 60 --seconds 4 --video-size 1920x1080
	name=$s
	[ "$s" = forest_instanced ] && name=forest
	ffmpeg -loglevel error -y -ss 3.5 -i "$TMP/$s.mp4" -frames:v 1 "$MEDIA/scene-$name.png"
done

ls -la "$MEDIA"
