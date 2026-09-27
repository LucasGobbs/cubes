package main

import goose "../.."
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

Manifest_Shader :: struct {
	name:     string,
	source:   string,
	vertex:   string,
	fragment: string,
	compute:  string,
}

Manifest :: struct {
	output_dir:           string `json:"outputDir"`,
	parameter_output_dir: string `json:"parameterOutputDir"`,
	package_name:         string `json:"package"`,
	goose_import:         string `json:"gooseImport"`,
	shaders:              []Manifest_Shader,
}

Manifest_Options :: struct {
	path:         string,
	slang:        string,
	platform:     goose.Platform,
	platform_set: bool,
}

parse_manifest_options :: proc() -> (Manifest_Options, bool) {
	options: Manifest_Options
	args := os.args[1:]
	has_manifest := false
	for index := 0; index < len(args); index += 1 {
		argument := args[index]
		if argument != "--manifest" && argument != "--slang" && argument != "--platform" do continue
		if index + 1 >= len(args) do fatal("missing value for %s", argument)
		index += 1
		value := args[index]
		switch argument {
		case "--manifest":
			options.path = value
			has_manifest = true
		case "--slang":
			options.slang = value
		case "--platform":
			switch value {
			case "metal":
				options.platform = .Metal
			case "vulkan":
				options.platform = .Vulkan
			case:
				fatal("unsupported Goose platform: %s", value)
			}
			options.platform_set = true
		}
	}
	if !has_manifest do return {}, false
	if options.slang == "" do fatal("--slang is required with --manifest")
	if !options.platform_set do fatal("--platform is required with --manifest")
	return options, true
}

run_slang :: proc(slang_path, source, entrypoint, target, output, reflection: string) {
	command := []string {
		slang_path,
		source,
		"-entry",
		entrypoint,
		"-target",
		target,
		"-reflection-json",
		reflection,
		"-o",
		output,
	}
	fmt.printfln("goose: %s %s -> %s", source, entrypoint, output)
	state, stdout, stderr, process_error := os.process_exec(
		{command = command},
		context.temp_allocator,
	)
	if len(stdout) > 0 do fmt.print(string(stdout))
	if len(stderr) > 0 do fmt.eprint(string(stderr))
	if process_error != nil do fatal("failed to execute Slang: %v", process_error)
	if !state.success do fatal("Slang failed for %s:%s", source, entrypoint)
}

compile_manifest_stage :: proc(
	manifest: Manifest,
	shader: Manifest_Shader,
	stage, entrypoint: string,
	platform: goose.Platform,
	slang_path: string,
) -> string {
	stage_suffix := stage
	if stage == "vertex" do stage_suffix = "vert"
	if stage == "fragment" do stage_suffix = "frag"
	target := "metal" if platform == .Metal else "spirv"
	extension := "msl" if platform == .Metal else "spv"
	base :=
		filepath.join(
			{manifest.output_dir, fmt.tprintf("%s.%s", shader.name, stage_suffix)},
			context.temp_allocator,
		) or_else ""
	output := fmt.tprintf("%s.%s", base, extension)
	reflection := fmt.tprintf("%s.refl.json", base)
	run_slang(slang_path, shader.source, entrypoint, target, output, reflection)
	return reflection
}

build_manifest :: proc(options: Manifest_Options) {
	data, read_error := os.read_entire_file(options.path, context.temp_allocator)
	if read_error != nil do fatal("failed to read Goose manifest %s: %v", options.path, read_error)
	manifest: Manifest
	unmarshal_error := json.unmarshal(data, &manifest, allocator = context.temp_allocator)
	if unmarshal_error != nil do fatal("failed to parse Goose manifest %s: %v", options.path, unmarshal_error)
	if manifest.output_dir == "" || manifest.parameter_output_dir == "" do fatal("Goose manifest output paths are required")
	if manifest.package_name == "" || manifest.goose_import == "" do fatal("Goose manifest package settings are required")
	if len(manifest.shaders) == 0 do fatal("Goose manifest has no shaders")
	_ = os.mkdir_all(manifest.output_dir)
	_ = os.mkdir_all(manifest.parameter_output_dir)

	for shader in manifest.shaders {
		if shader.name == "" || shader.source == "" do fatal("Goose shader name and source are required")
		reflections: [dynamic]string
		if shader.vertex != "" {
			append_elem(
				&reflections,
				compile_manifest_stage(
					manifest,
					shader,
					"vertex",
					shader.vertex,
					options.platform,
					options.slang,
				),
			)
		}
		if shader.fragment != "" {
			append_elem(
				&reflections,
				compile_manifest_stage(
					manifest,
					shader,
					"fragment",
					shader.fragment,
					options.platform,
					options.slang,
				),
			)
		}
		if shader.compute != "" {
			append_elem(
				&reflections,
				compile_manifest_stage(
					manifest,
					shader,
					"compute",
					shader.compute,
					options.platform,
					options.slang,
				),
			)
		}
		if len(reflections) == 0 do fatal("Goose shader %s has no entry points", shader.name)

		parameter_output :=
			filepath.join(
				{
					manifest.parameter_output_dir,
					fmt.tprintf("%s_shader_parameters.odin", shader.name),
				},
				context.temp_allocator,
			) or_else ""
		generation_options := Options {
			name         = shader.name,
			package_name = manifest.package_name,
			goose_import = manifest.goose_import,
			output       = parameter_output,
			reflections  = reflections,
			platform     = options.platform,
			platform_set = true,
		}
		content := generate(generation_options)
		write_error := os.write_entire_file(parameter_output, content)
		if write_error != nil do fatal("failed to write %s: %v", parameter_output, write_error)
		delete(content)
		delete(reflections)
	}
}

try_build_manifest :: proc() -> bool {
	options, ok := parse_manifest_options()
	if !ok do return false
	build_manifest(options)
	return true
}
