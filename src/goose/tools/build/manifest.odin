package main

import goose "../.."
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

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

manifest_stage_paths :: proc(
	manifest: Manifest,
	shader: Manifest_Shader,
	stage: string,
	platform: goose.Platform,
) -> (
	artifact: string,
	reflection: string,
) {
	stage_suffix := stage
	if stage == "vertex" do stage_suffix = "vert"
	if stage == "fragment" do stage_suffix = "frag"
	extension := "msl" if platform == .Metal else "spv"
	base :=
		filepath.join(
			{manifest.output_dir, fmt.tprintf("%s.%s", shader.name, stage_suffix)},
			context.temp_allocator,
		) or_else ""
	return fmt.tprintf("%s.%s", base, extension), fmt.tprintf("%s.refl.json", base)
}

compile_manifest_stage :: proc(
	manifest: Manifest,
	shader: Manifest_Shader,
	stage, entrypoint: string,
	platform: goose.Platform,
	slang_path: string,
) -> string {
	target := "metal" if platform == .Metal else "spirv"
	output, reflection := manifest_stage_paths(manifest, shader, stage, platform)
	run_slang(slang_path, shader.source, entrypoint, target, output, reflection)
	manifest_normalize_mtime(output, reflection)
	return reflection
}

// slangc skips writing the artifact when the generated code is byte-identical,
// but always rewrites the reflection JSON. Freshness is mtime-based, so an
// artifact older than its reflection would look stale forever; rewrite it
// with its own bytes to bring its mtime up to the compile it belongs to.
manifest_normalize_mtime :: proc(artifact, reflection: string) {
	artifact_time, artifact_error := os.last_write_time_by_name(artifact)
	reflection_time, reflection_error := os.last_write_time_by_name(reflection)
	if artifact_error != nil || reflection_error != nil do return
	if time.diff(artifact_time, reflection_time) <= 0 do return
	data, read_error := os.read_entire_file(artifact, context.temp_allocator)
	if read_error != nil do return
	_ = os.write_entire_file(artifact, data)
}

// A shader is fresh when its .slang source and the manifest itself are older
// than every generated output, and the generated parameter file targets the
// requested platform. The platform marker matters because the parameter file
// bakes `platform = .X` and #loads the platform-specific artifact, so
// switching --platform must regenerate even when nothing else changed.
manifest_shader_fresh :: proc(
	manifest_path: string,
	manifest: Manifest,
	shader: Manifest_Shader,
	parameter_output: string,
	platform: goose.Platform,
) -> bool {
	parameter_data, read_error := os.read_entire_file(
		parameter_output,
		context.temp_allocator,
	)
	if read_error != nil do return false
	platform_marker := "platform = .Metal" if platform == .Metal else "platform = .Vulkan"
	if !strings.contains(string(parameter_data), platform_marker) do return false

	latest_input, manifest_error := os.last_write_time_by_name(manifest_path)
	if manifest_error != nil do return false
	source_time, source_error := os.last_write_time_by_name(shader.source)
	if source_error != nil do return false
	if time.diff(latest_input, source_time) > 0 do latest_input = source_time

	outputs: [dynamic]string
	defer delete(outputs)
	append(&outputs, parameter_output)
	stages := [?][2]string {
		{"vertex", shader.vertex},
		{"fragment", shader.fragment},
		{"compute", shader.compute},
	}
	for entry in stages {
		if entry[1] == "" do continue
		artifact, reflection := manifest_stage_paths(manifest, shader, entry[0], platform)
		append(&outputs, artifact, reflection)
	}
	for output in outputs {
		output_time, output_error := os.last_write_time_by_name(output)
		if output_error != nil do return false
		if time.diff(output_time, latest_input) > 0 do return false
	}
	return true
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
		parameter_output :=
			filepath.join(
				{
					manifest.parameter_output_dir,
					fmt.tprintf("%s_shader_parameters.odin", shader.name),
				},
				context.temp_allocator,
			) or_else ""
		if manifest_shader_fresh(
			options.path,
			manifest,
			shader,
			parameter_output,
			options.platform,
		) {
			fmt.printfln("goose: %s up to date", shader.name)
			continue
		}
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
