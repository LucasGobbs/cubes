package loader

import "core:c"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:strings"
import gltf "vendor:cgltf"

MAX_JOINTS :: 128

SkinnedVertexData :: struct {
	position: Vec3,
	normal:   Vec3,
	uv:       Vec2,
	joints:   [4]u16,
	weights:  [4]f32,
}

Joint :: struct {
	parent:            i32, // index into Skin.joints, always < own index; -1 for roots
	pre:               matrix[4, 4]f32, // non-joint ancestors between this joint and its parent joint (or scene root); identity when none
	local_translation: Vec3,
	local_rotation:    quaternion128, // stored as xyzw via quaternion(x, y, z, w)
	local_scale:       Vec3,
}

Channel_Path :: enum {
	Translation,
	Rotation,
	Scale,
}

Channel_Interpolation :: enum {
	Linear,
	Step,
}

Channel :: struct {
	joint:         i32,
	path:          Channel_Path,
	interpolation: Channel_Interpolation,
	times:         []f32,
	values:        []f32, // 3 floats per key (T/S) or 4 (R, xyzw)
}

Clip :: struct {
	name:     string,
	duration: f32,
	channels: []Channel,
}

Skin :: struct {
	joints:       []Joint,
	inverse_bind: []matrix[4, 4]f32,
	clips:        []Clip,
}

ImportedSkinnedModel :: struct {
	vertices: []SkinnedVertexData,
	indices:  []u32,
	image:    ImageData,
	tint:     [4]f32,
	skin:     Skin,
}

// Product of the non-joint ancestor nodes between `node` and its nearest joint
// ancestor (or the scene root), outermost first. Joint TRS is relative to this.
@(private = "file")
joint_pre_transform :: proc(node: ^gltf.node, node_to_skin: map[^gltf.node]int) -> matrix[4, 4]f32 {
	pre := linalg.MATRIX4F32_IDENTITY
	for p := node.parent; p != nil; p = p.parent {
		if _, is_joint := node_to_skin[p]; is_joint do break
		local: matrix[4, 4]f32
		gltf.node_transform_local(p, ([^]f32)(&local))
		pre = local * pre
	}
	return pre
}

skin_destroy :: proc(skin: ^Skin) {
	delete(skin.joints)
	delete(skin.inverse_bind)
	for clip in skin.clips {
		delete(clip.name)
		for channel in clip.channels {
			delete(channel.times)
			delete(channel.values)
		}
		delete(clip.channels)
	}
	delete(skin.clips)
	skin^ = {}
}

skinned_model_destroy :: proc(model: ^ImportedSkinnedModel) {
	delete(model.vertices)
	delete(model.indices)
	delete(model.image.pixels)
	skin_destroy(&model.skin)
	model^ = {}
}

// Imports the first skin of a .glb/.gltf: mesh-local vertices of every
// triangle primitive on nodes using that skin, the joint hierarchy (sorted so
// parents precede children), inverse bind matrices, and all animation clips.
//
// shortcut: cubic-spline channels are skipped; only the first skin is read.
// Extend when an asset needs them.
model_import_skinned_from_gltf :: proc(path: string) -> (model: ImportedSkinnedModel, ok: bool) {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	options: gltf.options
	data, parse_result := gltf.parse_file(options, path_c)
	if parse_result != .success || data == nil {
		log.errorf("gltf: failed to parse %s (%v)", path, parse_result)
		return {}, false
	}
	defer gltf.free(data)
	if load_result := gltf.load_buffers(options, data, path_c); load_result != .success {
		log.errorf("gltf: failed to load buffers of %s (%v)", path, load_result)
		return {}, false
	}
	if len(data.skins) == 0 {
		log.errorf("gltf: %s has no skin", path)
		return {}, false
	}
	skin := &data.skins[0]
	joint_total := len(skin.joints)
	if joint_total > MAX_JOINTS {
		log.errorf("gltf: skin has %d joints, max is %d", joint_total, MAX_JOINTS)
		return {}, false
	}

	vertices: [dynamic]SkinnedVertexData
	indices: [dynamic]u32
	defer if !ok {
		delete(vertices)
		delete(indices)
		skinned_model_destroy(&model)
	}

	// Parent of each skin joint, as a skin index (-1 for roots).
	node_to_skin := make(map[^gltf.node]int, joint_total, context.temp_allocator)
	for joint, i in skin.joints do node_to_skin[joint] = i
	skin_parent := make([]int, joint_total, context.temp_allocator)
	for joint, i in skin.joints {
		skin_parent[i] = -1
		for p := joint.parent; p != nil; p = p.parent {
			if index, found := node_to_skin[p]; found {
				skin_parent[i] = index
				break
			}
		}
	}

	// Topological order: parents first. remap[skin index] = sorted index.
	remap := make([]int, joint_total, context.temp_allocator)
	for &r in remap do r = -1
	order := make([dynamic]int, 0, joint_total, context.temp_allocator)
	for len(order) < joint_total {
		before := len(order)
		for i in 0 ..< joint_total {
			if remap[i] == -1 && (skin_parent[i] == -1 || remap[skin_parent[i]] != -1) {
				remap[i] = len(order)
				append(&order, i)
			}
		}
		if len(order) == before {
			log.errorf("gltf: cyclic joint hierarchy in %s", path)
			return {}, false
		}
	}

	model.skin.joints = make([]Joint, joint_total)
	model.skin.inverse_bind = make([]matrix[4, 4]f32, joint_total)
	for src, dst in order {
		node := skin.joints[src]
		joint := Joint {
			parent            = -1,
			pre               = joint_pre_transform(node, node_to_skin),
			local_rotation    = quaternion(x = 0, y = 0, z = 0, w = 1),
			local_scale       = {1, 1, 1},
		}
		if skin_parent[src] != -1 do joint.parent = i32(remap[skin_parent[src]])
		if node.has_matrix {
			m := (^matrix[4, 4]f32)(&node.matrix_)^
			t := m[3].xyz
			s := Vec3{linalg.length(m[0].xyz), linalg.length(m[1].xyz), linalg.length(m[2].xyz)}
			rot3 := linalg.matrix3_from_matrix4(m)
			for c in 0 ..< 3 do rot3[c] /= s[c]
			joint.local_translation = t
			joint.local_rotation = linalg.quaternion_from_matrix3(rot3)
			joint.local_scale = s
		} else {
			if node.has_translation do joint.local_translation = node.translation
			if node.has_rotation do joint.local_rotation = quaternion(x = node.rotation.x, y = node.rotation.y, z = node.rotation.z, w = node.rotation.w)
			if node.has_scale do joint.local_scale = node.scale
		}
		model.skin.joints[dst] = joint

		ibm := linalg.MATRIX4F32_IDENTITY
		if skin.inverse_bind_matrices != nil {
			buf: [16]f32
			if gltf.accessor_read_float(skin.inverse_bind_matrices, uint(src), raw_data(buf[:]), 16) {
				ibm = (^matrix[4, 4]f32)(&buf)^
			}
		}
		model.skin.inverse_bind[dst] = ibm
	}

	model.tint = {1, 1, 1, 1}
	image_source: ^gltf.image
	first_primitive := true
	for &node in data.nodes {
		if node.mesh == nil do continue
		if node.skin != skin {
			log.warnf("gltf: skipped non-skinned primitive in %s", path)
			continue
		}
		for &primitive in node.mesh.primitives {
			if primitive.type != .triangles do continue
			position_accessor, uv_accessor, normal_accessor, joints_accessor, weights_accessor: ^gltf.accessor
			for attribute in primitive.attributes {
				#partial switch attribute.type {
				case .position:
					position_accessor = attribute.data
				case .texcoord:
					if attribute.index == 0 do uv_accessor = attribute.data
				case .normal:
					normal_accessor = attribute.data
				case .joints:
					if attribute.index == 0 do joints_accessor = attribute.data
				case .weights:
					if attribute.index == 0 do weights_accessor = attribute.data
				}
			}
			if position_accessor == nil do continue
			if joints_accessor == nil || weights_accessor == nil {
				log.errorf("gltf: skinned primitive without JOINTS_0/WEIGHTS_0 in %s", path)
				return {}, false
			}
			if material := primitive.material;
			   material != nil && material.has_pbr_metallic_roughness {
				pbr := material.pbr_metallic_roughness
				if first_primitive do model.tint = pbr.base_color_factor
				if texture := pbr.base_color_texture.texture;
				   texture != nil && texture.image_ != nil && image_source == nil {
					image_source = texture.image_
				}
			}
			first_primitive = false

			count := int(position_accessor.count)
			positions := make([]f32, count * 3, context.temp_allocator)
			_ = gltf.accessor_unpack_floats(position_accessor, raw_data(positions), uint(count * 3))
			uvs: []f32
			if uv_accessor != nil {
				uvs = make([]f32, count * 2, context.temp_allocator)
				_ = gltf.accessor_unpack_floats(uv_accessor, raw_data(uvs), uint(count * 2))
			}
			normals: []f32
			if normal_accessor != nil {
				normals = make([]f32, count * 3, context.temp_allocator)
				_ = gltf.accessor_unpack_floats(normal_accessor, raw_data(normals), uint(count * 3))
			}
			weights := make([]f32, count * 4, context.temp_allocator)
			_ = gltf.accessor_unpack_floats(weights_accessor, raw_data(weights), uint(count * 4))

			base := u32(len(vertices))
			for i in 0 ..< count {
				vertex := SkinnedVertexData {
					position = {positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]},
				}
				if uvs != nil do vertex.uv = {uvs[i * 2], uvs[i * 2 + 1]}
				if normals != nil do vertex.normal = {normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]}
				raw: [4]c.uint
				_ = gltf.accessor_read_uint(joints_accessor, uint(i), raw_data(raw[:]), 4)
				w := [4]f32{weights[i * 4], weights[i * 4 + 1], weights[i * 4 + 2], weights[i * 4 + 3]}
				sum := w.x + w.y + w.z + w.w
				if sum > 0 {
					vertex.weights = w / sum
					for k in 0 ..< 4 {
						vertex.joints[k] = u16(remap[min(int(raw[k]), joint_total - 1)])
					}
				} else {
					vertex.weights = {1, 0, 0, 0}
				}
				append(&vertices, vertex)
			}

			first_index := len(indices)
			if primitive.indices != nil {
				index_count := int(primitive.indices.count)
				resize(&indices, first_index + index_count)
				_ = gltf.accessor_unpack_indices(
					primitive.indices,
					&indices[first_index],
					size_of(u32),
					uint(index_count),
				)
				for &index in indices[first_index:] do index += base
			} else {
				for i in 0 ..< count do append(&indices, base + u32(i))
			}
		}
	}
	if len(indices) == 0 {
		log.errorf("gltf: %s has no skinned triangles", path)
		return {}, false
	}

	clips := make([dynamic]Clip)
	defer if !ok {
		for clip in clips {
			delete(clip.name)
			for channel in clip.channels {
				delete(channel.times)
				delete(channel.values)
			}
			delete(clip.channels)
		}
		delete(clips)
	}
	for &animation, ai in data.animations {
		clip := Clip {
			name = animation.name != nil ? strings.clone_from_cstring(animation.name) : fmt.aprintf("clip_%d", ai),
		}
		channels := make([dynamic]Channel)
		for &channel in animation.channels {
			joint_src, is_joint := node_to_skin[channel.target_node]
			if !is_joint || channel.sampler == nil do continue
			sampler := channel.sampler
			if sampler.interpolation == .cubic_spline {
				log.warnf("gltf: skipped cubic-spline channel in %s", path)
				continue
			}
			out: Channel
			#partial switch channel.target_path {
			case .translation:
				out.path = .Translation
			case .rotation:
				out.path = .Rotation
			case .scale:
				out.path = .Scale
			case:
				continue
			}
			components := out.path == .Rotation ? 4 : 3
			key_count := int(sampler.input.count)
			out.joint = i32(remap[joint_src])
			out.interpolation = sampler.interpolation == .step ? .Step : .Linear
			out.times = make([]f32, key_count)
			out.values = make([]f32, key_count * components)
			_ = gltf.accessor_unpack_floats(sampler.input, raw_data(out.times), uint(key_count))
			_ = gltf.accessor_unpack_floats(sampler.output, raw_data(out.values), uint(key_count * components))
			if key_count > 0 do clip.duration = max(clip.duration, out.times[key_count - 1])
			append(&channels, out)
		}
		clip.channels = channels[:]
		append(&clips, clip)
		log.infof("clip: %s", clip.name)
	}
	model.skin.clips = clips[:]

	model.vertices = vertices[:]
	model.indices = indices[:]
	model.image = gltf_load_image(path, image_source)
	return model, true
}

// True when the .glb/.gltf at `path` has at least one skin. Parses only the JSON,
// so it is cheap enough to call before choosing the static or skinned import path.
gltf_has_skin :: proc(path: string) -> bool {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	options: gltf.options
	data, parse_result := gltf.parse_file(options, path_c)
	if parse_result != .success || data == nil {
		log.errorf("gltf: failed to parse %s (%v)", path, parse_result)
		return false
	}
	defer gltf.free(data)
	return len(data.skins) > 0
}
