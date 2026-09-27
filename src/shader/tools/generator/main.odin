package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Resource_Counts :: struct {
	samplers:                   int,
	readonly_storage_textures:  int,
	readonly_storage_buffers:   int,
	readwrite_storage_textures: int,
	readwrite_storage_buffers:  int,
	uniform_buffers:            int,
}

Reflection_Parameter :: struct {
	name:    string,
	type_:   json.Value `json:"type"`,
	binding: Reflection_Binding_Info,
}

Reflection_Binding_Info :: struct {
	kind:           string,
	index:          int,
	used:           int,
	offset:         int,
	size:           int,
	element_stride: int `json:"elementStride"`,
}

Reflection_Binding :: struct {
	name:    string,
	binding: Reflection_Binding_Info,
}

Reflection_Entry_Point :: struct {
	name:              string,
	stage:             string,
	thread_group_size: [3]int `json:"threadGroupSize"`,
	parameters:        []Reflection_Parameter,
	bindings:          []Reflection_Binding,
}

Reflection_Document :: struct {
	version:      string,
	parameters:   []Reflection_Parameter,
	entry_points: []Reflection_Entry_Point `json:"entryPoints"`,
}

Vertex_Attribute :: struct {
	name:     string,
	format:   string,
	location: int,
}

Uniform_Block :: struct {
	name:  string,
	slot:  int,
	type_: json.Value,
}

Uniform_Field :: struct {
	name:         string,
	type_value:   json.Value,
	offset, size: int,
}

Uniform_Emitter :: struct {
	builder: strings.Builder,
	emitted: map[string]bool,
	prefix:  string,
	path:    string,
}

Stage_Reflection :: struct {
	stage:             string,
	entrypoint:        string,
	counts:            Resource_Counts,
	thread_count:      [3]int,
	vertex_attributes: []Vertex_Attribute,
	uniform_blocks:    []Uniform_Block,
}

Options :: struct {
	name:          string,
	package_name:  string,
	shader_import: string,
	output:        string,
	reflections:   [dynamic]string,
	check:         bool,
}

fatal :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

parse_options :: proc() -> Options {
	options: Options
	args := os.args[1:]
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		switch argument {
		case "--check":
			options.check = true
		case "--name", "--package", "--shader-import", "--output", "--reflection":
			if index + 1 >= len(args) do fatal("missing value for %s", argument)
			index += 1
			value := args[index]
			switch argument {
			case "--name":
				options.name = value
			case "--package":
				options.package_name = value
			case "--shader-import":
				options.shader_import = value
			case "--output":
				options.output = value
			case "--reflection":
				append_elem(&options.reflections, value)
			}
		case:
			fatal("unknown argument: %s", argument)
		}
	}
	if options.name == "" do fatal("--name is required")
	if options.package_name == "" do fatal("--package is required")
	if options.shader_import == "" do fatal("--shader-import is required")
	if options.output == "" do fatal("--output is required")
	if len(options.reflections) == 0 do fatal("at least one --reflection is required")
	return options
}

find_parameter :: proc(
	parameters: []Reflection_Parameter,
	name: string,
) -> (
	^Reflection_Parameter,
	bool,
) {
	for &parameter in parameters {
		if parameter.name == name do return &parameter, true
	}
	return nil, false
}

json_object :: proc(value: json.Value, description: string) -> json.Object {
	object, ok := value.(json.Object)
	if !ok do fatal("expected JSON object for %s", description)
	return object
}

json_array :: proc(value: json.Value, description: string) -> json.Array {
	array, ok := value.(json.Array)
	if !ok do fatal("expected JSON array for %s", description)
	return array
}

json_value :: proc(object: json.Object, key, description: string) -> json.Value {
	value, ok := object[key]
	if !ok do fatal("missing %s.%s", description, key)
	return value
}

json_string :: proc(object: json.Object, key, description: string, default := "") -> string {
	value, ok := object[key]
	if !ok do return default
	string_value, string_ok := value.(json.String)
	if !string_ok do fatal("expected string for %s.%s", description, key)
	return string(string_value)
}

json_int :: proc(object: json.Object, key, description: string, default := 0) -> int {
	value, ok := object[key]
	if !ok do return default
	integer, integer_ok := value.(json.Integer)
	if !integer_ok do fatal("expected integer for %s.%s", description, key)
	return int(integer)
}

vertex_format :: proc(path, field_name: string, type_value: json.Value) -> string {
	type_ := json_object(type_value, field_name)
	kind := json_string(type_, "kind", field_name)
	component_count := 1
	scalar_type := json_string(type_, "scalarType", field_name)
	if kind == "vector" {
		component_count = json_int(type_, "elementCount", field_name)
		element_type := json_object(json_value(type_, "elementType", field_name), field_name)
		scalar_type = json_string(element_type, "scalarType", field_name)
	} else if kind != "scalar" {
		fatal("%s: unsupported vertex type %s for %s", path, kind, field_name)
	}

	prefix := ""
	switch scalar_type {
	case "float32":
		prefix = "FLOAT"
	case "int32":
		prefix = "INT"
	case "uint32":
		prefix = "UINT"
	case:
		fatal("%s: unsupported vertex scalar type %s for %s", path, scalar_type, field_name)
	}
	if component_count < 1 || component_count > 4 {
		fatal(
			"%s: unsupported vertex component count %d for %s",
			path,
			component_count,
			field_name,
		)
	}
	if component_count == 1 do return fmt.tprintf(".%s", prefix)
	return fmt.tprintf(".%s%d", prefix, component_count)
}

load_stage :: proc(path: string) -> Stage_Reflection {
	context.allocator = context.temp_allocator
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil do fatal("failed to read reflection %s: %v", path, read_error)
	document: Reflection_Document
	unmarshal_error := json.unmarshal(data, &document, allocator = context.temp_allocator)
	if unmarshal_error != nil do fatal("failed to parse reflection %s: %v", path, unmarshal_error)
	if document.version != "1.1" do fatal("%s: unsupported reflection version %s", path, document.version)
	if len(document.entry_points) != 1 {
		fatal("%s: expected one entry point, found %d", path, len(document.entry_points))
	}
	entry := &document.entry_points[0]
	if entry.stage != "vertex" && entry.stage != "fragment" && entry.stage != "compute" {
		fatal("%s: unsupported stage %s", path, entry.stage)
	}
	uniform_blocks: [dynamic]Uniform_Block
	counts: Resource_Counts
	for reflected_binding in entry.bindings {
		if reflected_binding.binding.used == 0 do continue
		parameter, found := find_parameter(document.parameters, reflected_binding.name)
		if !found do fatal("%s: unknown parameter %s", path, reflected_binding.name)
		type_ := json_object(parameter.type_, reflected_binding.name)
		kind := json_string(type_, "kind", reflected_binding.name)
		switch kind {
		case "constantBuffer", "uniform":
			counts.uniform_buffers += 1
			append_elem(
				&uniform_blocks,
				Uniform_Block {
					name = reflected_binding.name,
					slot = parameter.binding.index,
					type_ = json_value(type_, "elementType", reflected_binding.name),
				},
			)
		case "samplerState":
		case "resource":
			access := json_string(type_, "access", reflected_binding.name, "read")
			base_shape := json_string(type_, "baseShape", reflected_binding.name)
			writable := access == "readWrite"
			if strings.starts_with(base_shape, "texture") {
				if writable {
					counts.readwrite_storage_textures += 1
				} else {
					counts.samplers += 1
				}
			} else if strings.contains(
				strings.to_lower(base_shape, context.temp_allocator),
				"buffer",
			) {
				if writable {
					counts.readwrite_storage_buffers += 1
				} else {
					counts.readonly_storage_buffers += 1
				}
			} else {
				fatal("%s: unsupported resource shape %s", path, base_shape)
			}
		case:
			fatal("%s: unsupported parameter kind %s", path, kind)
		}
	}

	vertex_attributes: [dynamic]Vertex_Attribute
	if entry.stage == "vertex" {
		for parameter in entry.parameters {
			if parameter.binding.kind != "varyingInput" do continue
			parameter_type := json_object(parameter.type_, parameter.name)
			if json_string(parameter_type, "kind", parameter.name) != "struct" do continue
			fields := json_array(
				json_value(parameter_type, "fields", parameter.name),
				parameter.name,
			)
			for field_value in fields {
				field := json_object(field_value, parameter.name)
				field_name := json_string(field, "name", parameter.name)
				binding := json_object(json_value(field, "binding", field_name), field_name)
				if json_string(binding, "kind", field_name) != "varyingInput" {
					fatal("%s: vertex field %s has no varyingInput binding", path, field_name)
				}
				append_elem(
					&vertex_attributes,
					Vertex_Attribute {
						name = field_name,
						format = vertex_format(
							path,
							field_name,
							json_value(field, "type", field_name),
						),
						location = json_int(binding, "index", field_name),
					},
				)
			}
		}
		if len(vertex_attributes) == 0 do fatal("%s: vertex entry point has no attributes", path)
		for index in 1 ..< len(vertex_attributes) {
			for cursor := index;
			    cursor > 0 &&
			    vertex_attributes[cursor].location < vertex_attributes[cursor - 1].location;
			    cursor -= 1 {
				temporary := vertex_attributes[cursor]
				vertex_attributes[cursor] = vertex_attributes[cursor - 1]
				vertex_attributes[cursor - 1] = temporary
			}
		}
	}
	if entry.name == "" do fatal("%s: entry point has no name", path)
	if entry.stage == "compute" {
		for value in entry.thread_group_size {
			if value <= 0 do fatal("%s: invalid compute thread group size", path)
		}
	}
	return {
		stage = entry.stage,
		entrypoint = entry.name,
		counts = counts,
		thread_count = entry.thread_group_size,
		vertex_attributes = vertex_attributes[:],
		uniform_blocks = uniform_blocks[:],
	}
}

identifier :: proc(name: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for byte, index in transmute([]byte)name {
		value := byte
		is_letter := value >= 'a' && value <= 'z' || value >= 'A' && value <= 'Z'
		is_digit := value >= '0' && value <= '9'
		if is_letter {
			if value >= 'A' && value <= 'Z' do value += 'a' - 'A'
			strings.write_byte(&builder, value)
		} else if is_digit && index > 0 {
			strings.write_byte(&builder, value)
		} else {
			strings.write_byte(&builder, '_')
		}
	}
	return strings.to_string(builder)
}

uniform_size :: proc(type_value: json.Value, description: string) -> int {
	type_ := json_object(type_value, description)
	sizes := json_array(json_value(type_, "sizes", description), description)
	for size_value in sizes {
		size := json_object(size_value, description)
		if json_string(size, "kind", description) == "uniform" {
			return json_int(size, "value", description)
		}
	}
	fatal("no uniform size reflected for %s", description)
}

uniform_scalar_type :: proc(scalar_type, description: string) -> string {
	switch scalar_type {
	case "float32":
		return "f32"
	case "int32":
		return "i32"
	case "uint32":
		return "u32"
	case:
		fatal("unsupported uniform scalar type %s for %s", scalar_type, description)
	}
}

uniform_type_symbol :: proc(prefix: string, type_value: json.Value, fallback: string) -> string {
	type_ := json_object(type_value, fallback)
	reflected_name := json_string(type_, "name", fallback, fallback)
	type_name := strings.to_ada_case(reflected_name, context.temp_allocator) or_else ""
	return fmt.tprintf("%s_%s", prefix, type_name)
}

uniform_odin_type :: proc(prefix: string, type_value: json.Value, fallback: string) -> string {
	type_ := json_object(type_value, fallback)
	kind := json_string(type_, "kind", fallback)
	switch kind {
	case "scalar":
		return uniform_scalar_type(json_string(type_, "scalarType", fallback), fallback)
	case "vector":
		element := json_object(json_value(type_, "elementType", fallback), fallback)
		scalar := uniform_scalar_type(json_string(element, "scalarType", fallback), fallback)
		return fmt.tprintf("[%d]%s", json_int(type_, "elementCount", fallback), scalar)
	case "matrix":
		element := json_object(json_value(type_, "elementType", fallback), fallback)
		scalar := uniform_scalar_type(json_string(element, "scalarType", fallback), fallback)
		return fmt.tprintf(
			"matrix[%d, %d]%s",
			json_int(type_, "columnCount", fallback),
			json_int(type_, "rowCount", fallback),
			scalar,
		)
	case "struct":
		return uniform_type_symbol(prefix, type_value, fallback)
	case:
		fatal("unsupported uniform type %s for %s", kind, fallback)
	}
}

uniform_native_size :: proc(type_value: json.Value, description: string) -> int {
	type_ := json_object(type_value, description)
	kind := json_string(type_, "kind", description)
	switch kind {
	case "scalar":
		return 4
	case "vector":
		return json_int(type_, "elementCount", description) * 4
	case "matrix":
		return(
			json_int(type_, "rowCount", description) *
			json_int(type_, "columnCount", description) *
			4 \
		)
	case "struct":
		return uniform_size(type_value, description)
	case:
		fatal("unsupported uniform type %s for %s", kind, description)
	}
}

uniform_fields :: proc(type_value: json.Value, description: string) -> []Uniform_Field {
	type_ := json_object(type_value, description)
	fields := json_array(json_value(type_, "fields", description), description)
	result := make([dynamic]Uniform_Field, context.temp_allocator)
	for field_value in fields {
		field := json_object(field_value, description)
		name := json_string(field, "name", description)
		binding := json_object(json_value(field, "binding", name), name)
		append_elem(
			&result,
			Uniform_Field {
				name = name,
				type_value = json_value(field, "type", name),
				offset = json_int(binding, "offset", name),
				size = json_int(binding, "size", name),
			},
		)
	}
	for index in 1 ..< len(result) {
		for cursor := index;
		    cursor > 0 && result[cursor].offset < result[cursor - 1].offset;
		    cursor -= 1 {
			temporary := result[cursor]
			result[cursor] = result[cursor - 1]
			result[cursor - 1] = temporary
		}
	}
	return result[:]
}

emit_uniform_struct :: proc(
	emitter: ^Uniform_Emitter,
	type_value: json.Value,
	symbol, description: string,
) {
	if emitter.emitted[symbol] do return
	type_ := json_object(type_value, description)
	if json_string(type_, "kind", description) != "struct" {
		fatal("uniform block %s is not a struct", description)
	}
	fields := uniform_fields(type_value, description)
	for field in fields {
		field_type := json_object(field.type_value, field.name)
		if json_string(field_type, "kind", field.name) == "struct" {
			nested_symbol := uniform_type_symbol(emitter.prefix, field.type_value, field.name)
			emit_uniform_struct(emitter, field.type_value, nested_symbol, field.name)
		}
	}

	emitter.emitted[symbol] = true
	fmt.sbprintf(&emitter.builder, `%s :: struct #max_field_align(16) {{
`, symbol)
	cursor := 0
	padding_index := 0
	for field in fields {
		if field.offset < cursor do fatal("overlapping uniform field %s", field.name)
		if field.offset > cursor {
			fmt.sbprintf(
				&emitter.builder,
				`	_padding_%d: [%d]u8,
`,
				padding_index,
				field.offset - cursor,
			)
			padding_index += 1
		}
		field_type := uniform_odin_type(emitter.prefix, field.type_value, field.name)
		fmt.sbprintf(&emitter.builder, `	%s: %s,
`, field.name, field_type)
		native_size := uniform_native_size(field.type_value, field.name)
		if native_size > field.size do fatal("native uniform field %s exceeds reflected size", field.name)
		if native_size < field.size {
			fmt.sbprintf(
				&emitter.builder,
				`	_padding_%d: [%d]u8,
`,
				padding_index,
				field.size - native_size,
			)
			padding_index += 1
		}
		cursor = field.offset + field.size
	}
	struct_size := uniform_size(type_value, description)
	if cursor < struct_size {
		fmt.sbprintf(
			&emitter.builder,
			`	_padding_%d: [%d]u8,
`,
			padding_index,
			struct_size - cursor,
		)
	}
	fmt.sbprintf(&emitter.builder, `}}

`)
	for field in fields {
		fmt.sbprintf(
			&emitter.builder,
			`#assert(offset_of(%s, %s) == %d)
`,
			symbol,
			field.name,
			field.offset,
		)
	}
	fmt.sbprintf(&emitter.builder, `#assert(size_of(%s) == %d)

`, symbol, struct_size)
}

emit_uniform_blocks :: proc(name, stage_name: string, blocks: []Uniform_Block) -> string {
	if len(blocks) == 0 do return ""
	prefix := fmt.tprintf(
		"%s_%s",
		strings.to_ada_case(name, context.temp_allocator) or_else "",
		strings.to_ada_case(stage_name, context.temp_allocator) or_else "",
	)
	emitter := Uniform_Emitter {
		builder = strings.builder_make(context.temp_allocator),
		emitted = make(map[string]bool, context.temp_allocator),
		prefix  = prefix,
	}
	for block in blocks {
		block_name := strings.to_ada_case(block.name, context.temp_allocator) or_else ""
		block_symbol := fmt.tprintf("%s_%s", prefix, block_name)
		emit_uniform_struct(&emitter, block.type_, block_symbol, block.name)
		constant :=
			strings.to_upper_snake_case(
				fmt.tprintf(
					"%s_%s_%s",
					strings.to_snake_case(name, context.temp_allocator) or_else "",
					stage_name,
					block.name,
				),
				context.temp_allocator,
			) or_else ""
		helper := fmt.tprintf(
			"%s_%s_push_%s",
			identifier(name),
			stage_name,
			strings.to_snake_case(block.name, context.temp_allocator) or_else "",
		)
		block_size := uniform_size(block.type_, block.name)
		fmt.sbprintf(
			&emitter.builder,
			`%s_SLOT :: %d
%s_SIZE :: %d

%s :: proc(command_buffer: ^shader.Command_Buffer, data: ^%s) {{
`,
			constant,
			block.slot,
			constant,
			block_size,
			helper,
			block_symbol,
		)
		if stage_name == "compute" {
			fmt.sbprintf(
				&emitter.builder,
				`	shader.push_compute_uniform(command_buffer, %s_SLOT, data)
`,
				constant,
			)
		} else {
			stage := "Vertex" if stage_name == "vertex" else "Fragment"
			fmt.sbprintf(
				&emitter.builder,
				`	shader.push_graphics_uniform(command_buffer, .%s, %s_SLOT, data)
`,
				stage,
				constant,
			)
		}
		fmt.sbprintf(&emitter.builder, `}}

`)
	}
	return strings.to_string(emitter.builder)
}

artifact_load_path :: proc(output, reflection, extension: string) -> string {
	base := strings.trim_suffix(reflection, ".refl.json")
	artifact := fmt.tprintf("%s.%s", base, extension)
	relative, relative_error := filepath.rel(
		filepath.dir(output),
		artifact,
		context.temp_allocator,
	)
	if relative_error != .None do fatal("cannot make %s relative to %s", artifact, output)
	normalized, _ := filepath.replace_separators(relative, '/', context.temp_allocator)
	return normalized
}

emit_vertex_attributes :: proc(prefix: string, attributes: []Vertex_Attribute) -> string {
	if len(attributes) == 0 do return ""
	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&builder,
		`%s_attributes :: proc($Vertex: typeid) -> [%d]shader.Vertex_Attribute {{
	return {{
`,
		prefix,
		len(attributes),
	)
	for attribute in attributes {
		fmt.sbprintf(
			&builder,
			`		{{location = %d, format = %s, offset = u32(offset_of(Vertex, %s))}},
`,
			attribute.location,
			attribute.format,
			attribute.name,
		)
	}
	fmt.sbprintf(&builder, `	}}
}}

`)
	return strings.to_string(builder)
}

emit_graphics :: proc(
	name: string,
	stage: Stage_Reflection,
	reflection, output: string,
) -> string {
	prefix := fmt.tprintf("%s_%s", identifier(name), stage.stage)
	constant := strings.to_upper(prefix, context.temp_allocator)
	metal := artifact_load_path(output, reflection, "msl")
	spirv := artifact_load_path(output, reflection, "spv")
	counts := stage.counts
	storage_textures := counts.readonly_storage_textures + counts.readwrite_storage_textures
	storage_buffers := counts.readonly_storage_buffers + counts.readwrite_storage_buffers
	stage_name := "Vertex" if stage.stage == "vertex" else "Fragment"
	vertex_attributes := emit_vertex_attributes(prefix, stage.vertex_attributes)
	uniform_blocks := emit_uniform_blocks(name, stage.stage, stage.uniform_blocks)

	return fmt.aprintf(
		`%s_METAL_CODE :: #load("%s")
%s_SPIRV_CODE :: #load("%s")

%s_SAMPLERS :: %d
%s_STORAGE_TEXTURES :: %d
%s_STORAGE_BUFFERS :: %d
%s_UNIFORM_BUFFERS :: %d

%s%s%s :: proc() -> shader.Graphics_Parameters {{
	return {{
		code = {{
			name = "%s.%s",
			entrypoint = "%s",
			metal = {{data = raw_data(%s_METAL_CODE), size = len(%s_METAL_CODE)}},
			spirv = {{data = raw_data(%s_SPIRV_CODE), size = len(%s_SPIRV_CODE)}},
		}},
		stage = .%s,
		resources = {{
			samplers = %s_SAMPLERS,
			storage_textures = %s_STORAGE_TEXTURES,
			storage_buffers = %s_STORAGE_BUFFERS,
			uniform_buffers = %s_UNIFORM_BUFFERS,
		}},
	}}
}}

`,
		constant,
		metal,
		constant,
		spirv,
		constant,
		counts.samplers,
		constant,
		storage_textures,
		constant,
		storage_buffers,
		constant,
		counts.uniform_buffers,
		uniform_blocks,
		vertex_attributes,
		prefix,
		name,
		stage.stage,
		stage.entrypoint,
		constant,
		constant,
		constant,
		constant,
		stage_name,
		constant,
		constant,
		constant,
		constant,
		allocator = context.temp_allocator,
	)
}

emit_compute :: proc(name: string, stage: Stage_Reflection, reflection, output: string) -> string {
	base := identifier(name)
	prefix := base if base == "compute" else fmt.tprintf("%s_compute", base)
	constant := strings.to_upper(prefix, context.temp_allocator)
	metal := artifact_load_path(output, reflection, "msl")
	spirv := artifact_load_path(output, reflection, "spv")
	counts := stage.counts
	uniform_blocks := emit_uniform_blocks(name, stage.stage, stage.uniform_blocks)

	return fmt.aprintf(
		`%s_METAL_CODE :: #load("%s")
%s_SPIRV_CODE :: #load("%s")

%s_SAMPLERS :: %d
%s_READONLY_STORAGE_TEXTURES :: %d
%s_READONLY_STORAGE_BUFFERS :: %d
%s_READWRITE_STORAGE_TEXTURES :: %d
%s_READWRITE_STORAGE_BUFFERS :: %d
%s_UNIFORM_BUFFERS :: %d
%s_THREAD_COUNT :: [3]u32{{%d, %d, %d}}

%s%s :: proc() -> shader.Compute_Parameters {{
	return {{
		code = {{
			name = "%s.%s",
			entrypoint = "%s",
			metal = {{data = raw_data(%s_METAL_CODE), size = len(%s_METAL_CODE)}},
			spirv = {{data = raw_data(%s_SPIRV_CODE), size = len(%s_SPIRV_CODE)}},
		}},
		resources = {{
			samplers = %s_SAMPLERS,
			readonly_storage_textures = %s_READONLY_STORAGE_TEXTURES,
			readonly_storage_buffers = %s_READONLY_STORAGE_BUFFERS,
			readwrite_storage_textures = %s_READWRITE_STORAGE_TEXTURES,
			readwrite_storage_buffers = %s_READWRITE_STORAGE_BUFFERS,
			uniform_buffers = %s_UNIFORM_BUFFERS,
		}},
		thread_count = %s_THREAD_COUNT,
	}}
}}

`,
		constant,
		metal,
		constant,
		spirv,
		constant,
		counts.samplers,
		constant,
		counts.readonly_storage_textures,
		constant,
		counts.readonly_storage_buffers,
		constant,
		counts.readwrite_storage_textures,
		constant,
		counts.readwrite_storage_buffers,
		constant,
		counts.uniform_buffers,
		constant,
		stage.thread_count[0],
		stage.thread_count[1],
		stage.thread_count[2],
		uniform_blocks,
		prefix,
		name,
		stage.stage,
		stage.entrypoint,
		constant,
		constant,
		constant,
		constant,
		constant,
		constant,
		constant,
		constant,
		constant,
		constant,
		constant,
		allocator = context.temp_allocator,
	)
}

generate :: proc(options: Options) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	fmt.sbprintf(
		&builder,
		`// Generated by shader/tools/generator. Do not edit.
package %s

import shader "%s"

`,
		options.package_name,
		options.shader_import,
	)
	for reflection in options.reflections {
		stage := load_stage(reflection)
		if stage.stage == "compute" {
			strings.write_string(
				&builder,
				emit_compute(options.name, stage, reflection, options.output),
			)
		} else {
			strings.write_string(
				&builder,
				emit_graphics(options.name, stage, reflection, options.output),
			)
		}
	}
	return strings.clone(strings.to_string(builder)) or_else ""
}

main :: proc() {
	options := parse_options()
	defer delete(options.reflections)
	content := generate(options)
	defer delete(content)
	if options.check {
		current, read_error := os.read_entire_file(options.output, context.allocator)
		if read_error != nil do fatal("generated shader parameters missing: %v", read_error)
		defer delete(current)
		if string(current) != content do fatal("generated shader parameters are stale: %s", options.output)
		return
	}
	mkdir_error := os.mkdir_all(filepath.dir(options.output))
	if mkdir_error != nil && mkdir_error != .Exist do fatal("failed to create output directory: %v", mkdir_error)
	write_error := os.write_entire_file(options.output, content)
	if write_error != nil do fatal("failed to write %s: %v", options.output, write_error)
}
