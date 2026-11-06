package gbbfx
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
	}
}

camera_rotate :: proc(camera: ^Camera, yaw_delta, pitch_delta: f32) {
	camera.yaw += yaw_delta
	pitch_limit := linalg.to_radians(f32(89))
	camera.pitch = math.clamp(camera.pitch + pitch_delta, -pitch_limit, pitch_limit)

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

CAMERA_FOV_Y :: 70 * math.RAD_PER_DEG
CAMERA_NEAR :: 0.1

// Reverse-Z, infinite-far perspective for the right-handed view from
// camera_view and NDC depth in [0, 1] (Metal/Vulkan/D3D): depth is 1 at the
// near plane and tends to 0 at infinity. Float depth keeps most of its
// precision far from the camera, where a standard 0..1 mapping (or Odin's
// OpenGL-style linalg.matrix4_perspective, which Metal half-clips) loses it.
// The renderer clears depth to 0 and pipelines compare GREATER to match.
camera_perspective :: proc(
	aspect: f32,
	fov_y: f32 = CAMERA_FOV_Y,
	near: f32 = CAMERA_NEAR,
) -> (
	m: matrix[4, 4]f32,
) {
	focal := 1 / math.tan(0.5 * fov_y)
	m[0, 0] = focal / aspect
	m[1, 1] = focal
	m[3, 2] = -1
	m[2, 3] = near
	return
}

// Rebuilds the projection with a different aspect ratio (viewport resize).
camera_set_aspect :: proc(camera: ^Camera, aspect: f32) {
	camera.projection = camera_perspective(aspect)
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
