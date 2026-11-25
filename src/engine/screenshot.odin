// F12 screenshot: the frame just rendered without overlays, written as PNG into shots/.
package engine

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import stbi "vendor:stb/image"

SCREENSHOT_DIR :: "shots"

// Pure: shots/<scene>-<YYYYMMDD-HHMMSS>.png. Scene characters outside [A-Za-z0-9_-] become '_'.
screenshot_file_name :: proc(scene: string, year, month, day, hour, minute, second: int, allocator := context.temp_allocator) -> string {
	safe := transmute([]u8)strings.clone(scene, allocator)
	for c, i in safe {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			safe[i] = '_'
		}
	}
	return fmt.aprintf("%s/%s-%04d%02d%02d-%02d%02d%02d.png", SCREENSHOT_DIR, string(safe), year, month, day, hour, minute, second, allocator = allocator)
}

// Writes RGBA8 pixels (top row first, as gfx.readback_frame returns them) to a new file named for the scene and the local time.
screenshot_save :: proc(pixels: []u8, w, h: u32, scene: string) {
	if !os.exists(SCREENSHOT_DIR) {
		if err := os.make_directory(SCREENSHOT_DIR); err != nil {
			log.errorf("screenshot: cannot create %s/: %v", SCREENSHOT_DIR, err)
			return
		}
	}
	secs := posix.time_t(time.time_to_unix(time.now()))
	tm: posix.tm
	posix.localtime_r(&secs, &tm)
	path := screenshot_file_name(
		scene,
		int(tm.tm_year) + 1900,
		int(tm.tm_mon) + 1,
		int(tm.tm_mday),
		int(tm.tm_hour),
		int(tm.tm_min),
		int(tm.tm_sec),
	)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	// The frame's alpha is 0 (no compositing alpha); without this viewers show the PNG as blank white.
	for i := 3; i < len(pixels); i += 4 do pixels[i] = 255
	if stbi.write_png(cpath, i32(w), i32(h), 4, raw_data(pixels), i32(w * 4)) == 0 {
		log.errorf("screenshot: cannot write %s", path)
		return
	}
	log.infof("screenshot saved: %s", path)
}
