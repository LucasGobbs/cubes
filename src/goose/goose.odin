package goose

Platform :: enum {
	Metal,
	Vulkan,
}

Code_Format :: enum {
	Metal_Source,
	Metal_Library,
	Spirv,
}

Stage :: enum {
	Vertex,
	Fragment,
	Compute,
}

Blob :: struct {
	data: [^]u8,
	size: uint,
}

Code :: struct {
	name:       string,
	entrypoint: cstring,
	platform:   Platform,
	format:     Code_Format,
	blob:       Blob,
}

Binding_Table :: struct {
	data:  [^]Binding,
	count: u32,
}

Graphics_Resource_Counts :: struct {
	samplers:         u32,
	storage_textures: u32,
	storage_buffers:  u32,
	uniform_buffers:  u32,
}

Graphics_Parameters :: struct {
	code:      Code,
	stage:     Stage,
	resources: Graphics_Resource_Counts,
	bindings:  Binding_Table,
}

Compute_Resource_Counts :: struct {
	samplers:                   u32,
	readonly_storage_textures:  u32,
	readonly_storage_buffers:   u32,
	readwrite_storage_textures: u32,
	readwrite_storage_buffers:  u32,
	uniform_buffers:            u32,
}

Compute_Parameters :: struct {
	code:         Code,
	resources:    Compute_Resource_Counts,
	bindings:     Binding_Table,
	thread_count: [3]u32,
}

Vertex_Format :: enum {
	Int,
	Int2,
	Int3,
	Int4,
	Uint,
	Uint2,
	Uint3,
	Uint4,
	Float,
	Float2,
	Float3,
	Float4,
	Sint8,
	Sint8x2,
	Sint8x3,
	Sint8x4,
	Uint8,
	Uint8x2,
	Uint8x3,
	Uint8x4,
	Snorm8,
	Snorm8x2,
	Snorm8x3,
	Snorm8x4,
	Unorm8,
	Unorm8x2,
	Unorm8x3,
	Unorm8x4,
	Sint16,
	Sint16x2,
	Sint16x3,
	Sint16x4,
	Uint16,
	Uint16x2,
	Uint16x3,
	Uint16x4,
	Snorm16,
	Snorm16x2,
	Snorm16x3,
	Snorm16x4,
	Unorm16,
	Unorm16x2,
	Unorm16x3,
	Unorm16x4,
	Float16,
	Float16x2,
	Float16x3,
	Float16x4,
	Snorm10_10_10_2,
	Unorm10_10_10_2,
}

Vertex_Attribute :: struct {
	location:    u32,
	buffer_slot: u32,
	format:      Vertex_Format,
	offset:      u32,
}

Binding_Location :: struct {
	space:   u32,
	binding: u32,
	slot:    u32,
	count:   u32,
}

Uniform_Block :: struct {
	stage:    Stage,
	location: Binding_Location,
	size:     u32,
}

Texture_Binding :: struct {
	stage:    Stage,
	location: Binding_Location,
}

Sampler_Binding :: struct {
	stage:    Stage,
	location: Binding_Location,
}


Resource_Access :: enum {
	Read_Only,
	Read_Write,
}


Binding_Kind :: enum {
	Uniform_Buffer,
	Texture,
	Sampler,
	Storage_Buffer,
	Storage_Texture,
}

Binding :: struct {
	name:     string,
	stage:    Stage,
	kind:     Binding_Kind,
	access:   Resource_Access,
	location: Binding_Location,
	size:     u32,
}
