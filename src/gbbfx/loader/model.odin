package loader

import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import gltf "vendor:cgltf"

Vec2 :: [2]f32
Vec3 :: [3]f32

VertexData :: struct {
	position: Vec3,
	color:    [4]f32,
	uv:       Vec2,
	normal:   [3]f32,
}

VertexLayout :: enum {
	POS_COLOR_UV,
}

ImageFormat :: enum {
	RGBA8_UNORM,
}

ImportedMesh :: struct {
	// Owned CPU memory. Never allocate with context.temp_allocator.
	vertices: []VertexData,
	indices:  []u32,
	layout:   VertexLayout,
}

ImageData :: struct {
	// Owned CPU memory. Copy stb_image output into this slice.
	pixels: []byte,
	width:  u32,
	height: u32,
	format: ImageFormat,
}

ImportedModel :: struct {
	mesh:  ImportedMesh,
	image: ImageData,
}

// Imports a .glb/.gltf into one merged mesh: every triangle primitive of
// every mesh node, baked with its node's world transform. The base color
// factor of each primitive's material becomes the vertex color; the first
// base color texture found becomes the model's image (a 1x1 white image when
// there is none).
//
// shortcut: one texture per model; primitives that reference a different
// base color image are drawn with the first one. Split into one Model per
// material when an asset needs more.
model_import_from_gltf :: proc(path: string) -> (model: ImportedModel, ok: bool) {
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

	vertices: [dynamic]VertexData
	indices: [dynamic]u32
	defer if !ok {
		delete(vertices)
		delete(indices)
	}
	image_source: ^gltf.image

	for &node in data.nodes {
		if node.mesh == nil do continue
		world: matrix[4, 4]f32 // cgltf writes column-major, same as Odin matrices
		gltf.node_transform_world(&node, ([^]f32)(&world))
		mirrored := linalg.determinant(world) < 0
		// Normals are perpendicular directions: they need the inverse transpose
		// of the 3x3 part (translation is irrelevant), not the model matrix.
		normal_matrix := linalg.matrix3_inverse_transpose(linalg.matrix3_from_matrix4(world))

		for &primitive in node.mesh.primitives {
			if primitive.type != .triangles do continue
			position_accessor, uv_accessor, normal_accessor: ^gltf.accessor
			for attribute in primitive.attributes {
				#partial switch attribute.type {
				case .position:
					position_accessor = attribute.data
				case .texcoord:
					if attribute.index == 0 do uv_accessor = attribute.data
				case .normal:
					normal_accessor = attribute.data
				}
			}
			if position_accessor == nil do continue

			tint := [4]f32{1, 1, 1, 1}
			if material := primitive.material;
			   material != nil && material.has_pbr_metallic_roughness {
				pbr := material.pbr_metallic_roughness
				tint = pbr.base_color_factor
				if texture := pbr.base_color_texture.texture;
				   texture != nil && texture.image_ != nil {
					if image_source == nil do image_source = texture.image_
				}
			}

			count := int(position_accessor.count)
			positions := make([]f32, count * 3, context.temp_allocator)
			_ = gltf.accessor_unpack_floats(
				position_accessor,
				raw_data(positions),
				uint(count * 3),
			)
			uvs: []f32
			if uv_accessor != nil {
				uvs = make([]f32, count * 2, context.temp_allocator)
				_ = gltf.accessor_unpack_floats(uv_accessor, raw_data(uvs), uint(count * 2))
			}

			normals: []f32
			if normal_accessor != nil {
				normals = make([]f32, count * 3, context.temp_allocator)
				_ = gltf.accessor_unpack_floats(
					normal_accessor,
					raw_data(normals),
					uint(count * 3),
				)
			}

			base := u32(len(vertices))
			for i in 0 ..< count {
				point :=
					world * [4]f32{positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2], 1}
				vertex := VertexData {
					position = point.xyz,
					color    = tint,
				}
				// glTF UVs are top-left origin, same as stb_image/SDL: no flip.
				if uvs != nil do vertex.uv = {uvs[i * 2], uvs[i * 2 + 1]}
				if normals != nil {
					vertex.normal = linalg.normalize(
						normal_matrix *
						Vec3{normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]},
					)
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
			if mirrored { 	// a mirroring transform flips triangle winding
				for i := first_index; i + 2 < len(indices); i += 3 {
					indices[i + 1], indices[i + 2] = indices[i + 2], indices[i + 1]
				}
			}
		}
	}
	if len(indices) == 0 {
		log.errorf("gltf: %s has no triangles", path)
		return {}, false
	}

	model.image = gltf_load_image(path, image_source)
	model.mesh = {
		vertices = vertices[:],
		indices  = indices[:],
		layout   = .POS_COLOR_UV,
	}
	return model, true
}

// Embedded images (.glb bufferView) decode from memory; external ones load
// relative to the model file. Falls back to white when absent or unreadable.

gltf_load_image :: proc(model_path: string, source: ^gltf.image) -> ImageData {
	if source == nil do return image_white()

	if view := source.buffer_view; view != nil {
		bytes := gltf.buffer_view_data(view)[:view.size]
		if image, ok := image_load_from_memory(bytes); ok do return image
		log.errorf("gltf: cannot decode embedded image of %s", model_path)
		return image_white()
	}

	if source.uri == nil do return image_white()
	uri := strings.clone(string(source.uri), context.temp_allocator)
	if strings.has_prefix(uri, "data:") {
		log.warnf("gltf: data-URI images are not supported (%s)", model_path)
		return image_white()
	}
	decoded := transmute([]byte)uri
	decoded = decoded[:gltf.decode_uri(raw_data(decoded))]
	directory := filepath.dir(model_path)
	full_path, _ := filepath.join({directory, string(decoded)}, context.temp_allocator)
	return image_load(full_path)
}

model_import_destroy :: proc(model: ^ImportedModel) {
	delete(model.mesh.vertices)
	delete(model.mesh.indices)
	image_destroy(&model.image)
	model^ = {}
}
