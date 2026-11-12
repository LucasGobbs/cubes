package gfx
import "core:math"
import "core:math/linalg"

Vec3 :: [3]f32
CameraType :: enum {
	FLY_BY,
}
Camera :: struct {
	type:       CameraType,
	position:   Vec3,
	direction:  Vec3,
	up, right:  Vec3,
	yaw, pitch: f32,
	projection: matrix[4, 4]f32,
	lens:       Projection,
}

// fov_y in radians. far = 0 means infinite (reverse-Z, see camera_perspective).
Perspective :: struct {
	fov_y, near, far: f32,
}

// size = half height of the view in world units. far must be > near.
Orthographic :: struct {
	size, near, far: f32,
}

Projection :: union {
	Perspective,
	Orthographic,
}

camera_create :: proc(
	type: CameraType = .FLY_BY,
	position: Vec3 = Vec3{0, 0, 3.0},
	target: Vec3 = Vec3{},
	projection: matrix[4, 4]f32 = linalg.MATRIX4F32_IDENTITY,
) -> Camera {
	world_up := Vec3{0, 1, 0}
	direction := linalg.normalize(target - position)
	yaw := math.atan2(direction.z, direction.x)
	pitch := math.asin(direction.y)
	right := linalg.normalize(linalg.cross(direction, world_up))
	up := linalg.normalize(linalg.cross(right, direction))
	return Camera {
		type = type,
		position = position,
		up = up,
		right = right,
		direction = direction,
		yaw = yaw,
		pitch = pitch,
		projection = projection,
		lens = Perspective{fov_y = CAMERA_FOV_Y, near = CAMERA_NEAR},
	}
}

camera_pitch_limit :: proc() -> f32 {
	return linalg.to_radians(f32(89))
}

// Sets absolute yaw/pitch (pitch clamped) and rebuilds direction, right and up.
camera_set_angles :: proc(camera: ^Camera, yaw, pitch: f32) {
	camera.yaw = yaw
	pitch_limit := camera_pitch_limit()
	camera.pitch = math.clamp(pitch, -pitch_limit, pitch_limit)

	cos_pitch := math.cos(camera.pitch)
	camera.direction = linalg.normalize(
		Vec3 {
			math.cos(camera.yaw) * cos_pitch,
			math.sin(camera.pitch),
			math.sin(camera.yaw) * cos_pitch,
		},
	)

	world_up := Vec3{0, 1, 0}
	camera.right = linalg.normalize(linalg.cross(camera.direction, world_up))
	camera.up = linalg.normalize(linalg.cross(camera.right, camera.direction))
}

camera_rotate :: proc(camera: ^Camera, yaw_delta, pitch_delta: f32) {
	camera_set_angles(camera, camera.yaw + yaw_delta, camera.pitch + pitch_delta)
}

CAMERA_FOV_Y :: 70 * math.RAD_PER_DEG
CAMERA_NEAR :: 0.1

// Reverse-Z perspective for the right-handed view from camera_view and NDC
// depth in [0, 1] (Metal/Vulkan/D3D): depth is 1 at the near plane and tends to
// 0 at far (or infinity when far = 0). Float depth keeps most of its
// precision far from the camera, where a standard 0..1 mapping (or Odin's
// OpenGL-style linalg.matrix4_perspective, which Metal half-clips) loses it.
// The renderer clears depth to 0 and pipelines compare GREATER to match.
camera_perspective :: proc(
	aspect: f32,
	fov_y: f32 = CAMERA_FOV_Y,
	near: f32 = CAMERA_NEAR,
	far: f32 = 0,
) -> (
	m: matrix[4, 4]f32,
) {
	focal := 1 / math.tan(0.5 * fov_y)
	m[0, 0] = focal / aspect
	m[1, 1] = focal
	m[3, 2] = -1
	if far == 0 {
		m[2, 3] = near
	} else {
		m[2, 2] = near / (far - near)
		m[2, 3] = near * far / (far - near)
	}
	return
}

// Reverse-Z orthographic: depth 1 at near, 0 at far, same convention as camera_perspective.
lens_matrix :: proc(lens: Projection, aspect: f32) -> (m: matrix[4, 4]f32) {
	switch p in lens {
	case Perspective:
		return camera_perspective(aspect, p.fov_y, p.near, p.far)
	case Orthographic:
		m[0, 0] = 1 / (p.size * aspect)
		m[1, 1] = 1 / p.size
		m[2, 2] = 1 / (p.far - p.near)
		m[2, 3] = p.far / (p.far - p.near)
		m[3, 3] = 1
	}
	return
}

camera_set_projection :: proc(camera: ^Camera, lens: Projection, aspect: f32) {
	camera.lens = lens
	camera.projection = lens_matrix(lens, aspect)
}

// Rebuilds the projection with a different aspect ratio (viewport resize), keeping the lens.
camera_set_aspect :: proc(camera: ^Camera, aspect: f32) {
	camera_set_projection(camera, camera.lens, aspect)
}

camera_view :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
	view_matrix := linalg.matrix4_look_at_f32(
		camera.position,
		camera.position + camera.direction,
		camera.up,
	)
	return view_matrix
}

camera_view_projection :: proc(camera: ^Camera) -> matrix[4, 4]f32 {
	view_matrix := camera_view(camera)
	projection_matrix := camera.projection

	return projection_matrix * view_matrix
}
