package gbbfx

import "core:math"
import "core:math/linalg"
import loader "loader"

// Per-entity skinning result: one palette matrix per skin joint, already
// multiplied by the inverse bind matrix, ready for the GPU.
Pose :: struct {
	palette: [loader.MAX_JOINTS]matrix[4, 4]f32,
	count:   int,
}

// Writes the palette of `skin` at `time` (seconds) for `clip_index`. Time wraps
// modulo the clip duration. A negative clip index (or a skin without clips)
// samples the rest pose.
clip_sample :: proc(skin: ^loader.Skin, clip_index: int, time: f32, out: ^Pose) {
	joint_count := len(skin.joints)
	assert(joint_count <= loader.MAX_JOINTS)
	out.count = joint_count

	translation: [loader.MAX_JOINTS]Vec3
	rotation: [loader.MAX_JOINTS]quaternion128
	scale: [loader.MAX_JOINTS]Vec3
	for joint, j in skin.joints {
		translation[j] = joint.local_translation
		rotation[j] = joint.local_rotation
		scale[j] = joint.local_scale
	}

	if clip_index >= 0 && clip_index < len(skin.clips) {
		clip := skin.clips[clip_index]
		t: f32 = 0
		if clip.duration > 0 {
			t = math.mod(time, clip.duration)
			if t < 0 do t += clip.duration
		}
		for channel in clip.channels {
			j := int(channel.joint)
			switch channel.path {
			case .Translation:
				translation[j] = sample_vec3(channel, t)
			case .Scale:
				scale[j] = sample_vec3(channel, t)
			case .Rotation:
				rotation[j] = sample_quat(channel, t)
			}
		}
	}

	global: [loader.MAX_JOINTS]matrix[4, 4]f32
	for joint, j in skin.joints {
		local :=
			linalg.matrix4_translate_f32(translation[j]) *
			linalg.matrix4_from_quaternion(rotation[j]) *
			linalg.matrix4_scale_f32(scale[j])
		global[j] = joint.pre * local if joint.parent < 0 else global[joint.parent] * joint.pre * local
		out.palette[j] = global[j] * skin.inverse_bind[j]
	}
}

// Index of the clip named `name`, or (-1, false) when the skin has none.
clip_find :: proc(skin: ^loader.Skin, name: string) -> (int, bool) {
	for clip, i in skin.clips {
		if clip.name == name do return i, true
	}
	return -1, false
}

// Finds the key interval for `t`: returns (i, alpha) with i the lower key and
// alpha in [0, 1) for linear blends. Clamps to the first and last key.
@(private = "file")
key_interval :: proc(times: []f32, t: f32) -> (i: int, alpha: f32) {
	n := len(times)
	if t <= times[0] do return 0, 0
	if t >= times[n - 1] do return n - 1, 0
	for k in 0 ..< n - 1 {
		if t < times[k + 1] {
			dt := times[k + 1] - times[k]
			alpha = dt > 0 ? (t - times[k]) / dt : 0
			return k, alpha
		}
	}
	return n - 1, 0
}

@(private = "file")
sample_vec3 :: proc(channel: loader.Channel, t: f32) -> Vec3 {
	i, alpha := key_interval(channel.times, t)
	a := Vec3{channel.values[i * 3], channel.values[i * 3 + 1], channel.values[i * 3 + 2]}
	if channel.interpolation == .Step || alpha == 0 || i + 1 >= len(channel.times) do return a
	b := Vec3 {
		channel.values[(i + 1) * 3],
		channel.values[(i + 1) * 3 + 1],
		channel.values[(i + 1) * 3 + 2],
	}
	return linalg.lerp(a, b, alpha)
}

@(private = "file")
sample_quat :: proc(channel: loader.Channel, t: f32) -> quaternion128 {
	i, alpha := key_interval(channel.times, t)
	v := channel.values
	a := quaternion(x = v[i * 4], y = v[i * 4 + 1], z = v[i * 4 + 2], w = v[i * 4 + 3])
	if channel.interpolation == .Step || alpha == 0 || i + 1 >= len(channel.times) do return a
	b := quaternion(
		x = v[(i + 1) * 4],
		y = v[(i + 1) * 4 + 1],
		z = v[(i + 1) * 4 + 2],
		w = v[(i + 1) * 4 + 3],
	)
	return linalg.quaternion_slerp(a, b, alpha)
}
