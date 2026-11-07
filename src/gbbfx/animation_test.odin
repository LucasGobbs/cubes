package gbbfx

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import loader "loader"

// Two joints: root at origin, child at (0,1,0). Child rotates 0 -> 90° about Z
// over 1 s. A point 1 unit above the child's joint is (0,2,0) in model space.
make_two_joint_skin :: proc(step: bool) -> loader.Skin {
	skin := loader.Skin {
		joints = make([]loader.Joint, 2),
		inverse_bind = make([]matrix[4, 4]f32, 2),
		clips = make([]loader.Clip, 1),
	}
	skin.joints[0] = {parent = -1, pre = linalg.MATRIX4F32_IDENTITY, local_rotation = quaternion(x = 0, y = 0, z = 0, w = 1), local_scale = {1, 1, 1}}
	skin.joints[1] = {parent = 0, pre = linalg.MATRIX4F32_IDENTITY, local_translation = {0, 1, 0}, local_rotation = quaternion(x = 0, y = 0, z = 0, w = 1), local_scale = {1, 1, 1}}
	skin.inverse_bind[0] = linalg.MATRIX4F32_IDENTITY
	skin.inverse_bind[1] = linalg.matrix4_translate_f32({0, -1, 0})

	q := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1})
	channel := loader.Channel {
		joint = 1,
		path = .Rotation,
		interpolation = step ? .Step : .Linear,
		times = make([]f32, 2),
		values = make([]f32, 8),
	}
	channel.times[0], channel.times[1] = 0, 1
	copy(channel.values, []f32{0, 0, 0, 1, q.x, q.y, q.z, q.w})
	skin.clips[0] = loader.Clip {
		name     = "spin",
		duration = 1,
		channels = make([]loader.Channel, 1),
	}
	skin.clips[0].channels[0] = channel
	return skin
}

destroy_test_skin :: proc(skin: ^loader.Skin) {
	for clip in skin.clips {
		for channel in clip.channels {
			delete(channel.times)
			delete(channel.values)
		}
		delete(clip.channels)
	}
	delete(skin.clips)
	delete(skin.joints)
	delete(skin.inverse_bind)
}

// Palette of joint 1 applied to the point above it, in model space.
top_of_child :: proc(pose: ^Pose) -> Vec3 {
	return (pose.palette[1] * [4]f32{0, 2, 0, 1}).xyz
}

@(test)
clip_sample_rotates_child_linearly_and_wraps :: proc(t: ^testing.T) {
	skin := make_two_joint_skin(false)
	defer destroy_test_skin(&skin)
	pose: Pose

	clip_sample(&skin, 0, 0, &pose)
	testing.expect(t, linalg.length(top_of_child(&pose) - Vec3{0, 2, 0}) < 1e-4)

	s: f32 = math.SQRT_TWO / 2
	clip_sample(&skin, 0, 0.5, &pose)
	testing.expect(t, linalg.length(top_of_child(&pose) - Vec3{-s, 1 + s, 0}) < 1e-4)

	clip_sample(&skin, 0, 1.0, &pose)
	// Exactly one duration wraps to 0 (looping), so this is the rest pose again.
	testing.expect(t, linalg.length(top_of_child(&pose) - Vec3{0, 2, 0}) < 1e-4)

	// 1.5 s wraps to 0.5 s.
	clip_sample(&skin, 0, 1.5, &pose)
	testing.expect(t, linalg.length(top_of_child(&pose) - Vec3{-s, 1 + s, 0}) < 1e-4)
}

@(test)
clip_sample_step_holds_previous_key :: proc(t: ^testing.T) {
	skin := make_two_joint_skin(true)
	defer destroy_test_skin(&skin)
	pose: Pose

	clip_sample(&skin, 0, 0.4, &pose)
	testing.expect(t, linalg.length(top_of_child(&pose) - Vec3{0, 2, 0}) < 1e-4)

	clip_sample(&skin, 0, 0.99, &pose)
	testing.expect(t, linalg.length(top_of_child(&pose) - Vec3{0, 2, 0}) < 1e-4)
}

@(test)
clip_find_returns_index_or_false :: proc(t: ^testing.T) {
	skin := make_two_joint_skin(false)
	defer destroy_test_skin(&skin)
	index, found := clip_find(&skin, "spin")
	testing.expect(t, found && index == 0)
	_, missing := clip_find(&skin, "nope")
	testing.expect(t, !missing)
}

// Joint 1 has translation and scale channels on different key timelines, and the
// clip loops over a duration longer than the last key of either channel.
@(test)
clip_sample_applies_translation_and_scale_channels_on_same_joint :: proc(t: ^testing.T) {
	skin := make_two_joint_skin(false)
	defer destroy_test_skin(&skin)
	clip := &skin.clips[0]
	clip.duration = 2
	for channel in clip.channels {
		delete(channel.times)
		delete(channel.values)
	}
	delete(clip.channels)
	clip.channels = make([]loader.Channel, 2)
	clip.channels[0] = loader.Channel {
		joint         = 1,
		path          = .Translation,
		interpolation = .Linear,
		times         = slice.clone([]f32{0, 2}),
		values        = slice.clone([]f32{0, 1, 0, 0, 3, 0}),
	}
	clip.channels[1] = loader.Channel {
		joint         = 1,
		path          = .Scale,
		interpolation = .Linear,
		times         = slice.clone([]f32{0, 1, 2}),
		values        = slice.clone([]f32{1, 1, 1, 2, 2, 2, 1, 1, 1}),
	}
	pose: Pose

	// t = 1: translation (0,2,0), scale 2. Rest point (0,2,0) -> joint-local (0,1,0) -> scaled (0,2,0) -> (0,4,0).
	clip_sample(&skin, 0, 1, &pose)
	testing.expect(t, linalg.length((pose.palette[1] * [4]f32{0, 2, 0, 1} - [4]f32{0, 4, 0, 1}).xyz) < 1e-4)

	// t = 2.5 wraps to 0.5: translation (0,1.5,0), scale 1.5 -> (0,1.5,0)+1.5*(0,1,0)=(0,3,0).
	clip_sample(&skin, 0, 2.5, &pose)
	testing.expect(t, linalg.length((pose.palette[1] * [4]f32{0, 2, 0, 1} - [4]f32{0, 3, 0, 1}).xyz) < 1e-4)
}

// Root joint sits under a non-joint transform (glTF Armature/Z_UP style). Its
// inverse bind matches that rest global, so the palette must be identity at rest.
@(test)
clip_sample_applies_root_pre_transform_to_palette :: proc(t: ^testing.T) {
	skin := make_two_joint_skin(false)
	defer destroy_test_skin(&skin)
	base := linalg.matrix4_rotate_f32(math.PI / 2, {0, 0, 1}) * linalg.matrix4_translate_f32({2, 0, 0})
	skin.joints[0].pre = base
	skin.inverse_bind[0] = linalg.inverse(base)
	skin.inverse_bind[1] = linalg.inverse(base * linalg.matrix4_translate_f32({0, 1, 0}))
	pose: Pose

	clip_sample(&skin, 0, 0, &pose)
	p := [4]f32{0.3, 0.7, -0.2, 1}
	for j in 0 ..< 2 {
		testing.expect(t, linalg.length((pose.palette[j] * p - p).xyz) < 1e-4)
	}
}
