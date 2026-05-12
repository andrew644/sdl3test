package main

import "base:runtime"
import "core:c"
import "core:math/linalg"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

device: ^sdl.GPUDevice
window: ^sdl.Window
pipeline: ^sdl.GPUGraphicsPipeline

proj: matrix[4, 4]f32

UBO :: struct {
	mvp: matrix[4, 4]f32,
}

rotation: f32 = 0.0

delta_time: f32 = 0.001

frag_shader_code := #load("shader.spv.frag")
vert_shader_code := #load("shader.spv.vert")

main :: proc() {
	c_args := make([]cstring, len(os.args))
	defer delete(c_args)

	for arg, i in os.args {
		cstr, _ := strings.clone_to_cstring(arg)
		c_args[i] = cstr
	}
	defer for arg in c_args {
		delete(arg)
	}

	sdl.EnterAppMainCallbacks(
		cast(c.int)len(os.args),
		raw_data(c_args),
		SDL_AppInit,
		SDL_AppIterate,
		SDL_AppEvent,
		SDL_AppQuit,
	)
}

@(export)
SDL_AppInit :: proc "c" (appstate: ^rawptr, argc: c.int, cargv: [^]cstring) -> sdl.AppResult {
	context = runtime.default_context()
	meta_ok := sdl.SetAppMetadata("Snake", "0.1", "snake in odin")
	sdl_ok := sdl.Init({.VIDEO, .EVENTS})
	if !meta_ok || !sdl_ok {
		sdl.Log("Failed to initialize: %s", sdl.GetError())
		return .FAILURE
	}

	window = sdl.CreateWindow("SDL3 Window", 640, 480, {.HIGH_PIXEL_DENSITY})
	if window == nil {
		sdl.Log("SDL_CreateWindow failed: %s", sdl.GetError())
		return .FAILURE
	}

	device = sdl.CreateGPUDevice({.SPIRV}, false, nil)
	if device == nil {
		return .FAILURE
	}
	sdl.Log("GPU device: %s", sdl.GetGPUDeviceDriver(device))

	if sdl.ClaimWindowForGPUDevice(device, window) == false {
		sdl.Log("Failed to bind GPU to window: %s", sdl.GetError())
		return .FAILURE
	}

	vert_shader := load_shader(vert_shader_code, .VERTEX, 1)
	frag_shader := load_shader(frag_shader_code, .FRAGMENT, 0)

	pipeline = sdl.CreateGPUGraphicsPipeline(
		device,
		{
			vertex_shader = vert_shader,
			fragment_shader = frag_shader,
			primitive_type = .TRIANGLELIST,
			target_info = {
				num_color_targets = 1,
				color_target_descriptions = &(sdl.GPUColorTargetDescription {
						format = sdl.GetGPUSwapchainTextureFormat(device, window),
					}),
			},
		},
	)

	sdl.ReleaseGPUShader(device, vert_shader)
	sdl.ReleaseGPUShader(device, frag_shader)

	win_size: [2]i32
	sdl.GetWindowSize(window, &win_size.x, &win_size.y)

	proj = linalg.matrix4_perspective_f32(70, f32(win_size.x) / f32(win_size.y), 0.0001, 1000)

	return .CONTINUE
}

@(export)
SDL_AppEvent :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	if event.type == .QUIT {
		return .SUCCESS
	}

	if event.type == .KEY_DOWN {
		switch event.key.key {
		case sdl.K_ESCAPE:
			return .SUCCESS
		case sdl.K_Q:
			return .SUCCESS
		}
	}

	return .CONTINUE
}

@(export)
SDL_AppIterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	frame_start := sdl.GetTicksNS()
	cmdBuf := sdl.AcquireGPUCommandBuffer(device)
	if cmdBuf == nil {
		sdl.Log("Failed to get command buffer: %s", sdl.GetError())
		return .FAILURE
	}

	swapchain_texure: ^sdl.GPUTexture
	if sdl.WaitAndAcquireGPUSwapchainTexture(cmdBuf, window, &swapchain_texure, nil, nil) ==
	   false {
		sdl.Log("Wait for swapchainTexture: %s", sdl.GetError())
		return .FAILURE
	}

	if swapchain_texure != nil {
		targetInfo := sdl.GPUColorTargetInfo {
			texture     = swapchain_texure,
			cycle       = true,
			load_op     = .CLEAR,
			store_op    = .STORE,
			clear_color = {.2, .2, .4, 1},
		}

		rotation += delta_time * linalg.to_radians(f32(90))
		model_mat :=
			linalg.matrix4_translate_f32({0, 0, -5}) *
			linalg.matrix4_rotate_f32(rotation, {0, 1, 0})

		ubo := UBO {
			mvp = proj * model_mat,
		}

		render_pass := sdl.BeginGPURenderPass(cmdBuf, &targetInfo, 1, nil)
		sdl.BindGPUGraphicsPipeline(render_pass, pipeline)
		sdl.PushGPUVertexUniformData(cmdBuf, 0, &ubo, size_of(ubo))
		sdl.DrawGPUPrimitives(render_pass, 3, 1, 0, 0)
		sdl.EndGPURenderPass(render_pass)
	}

	if sdl.SubmitGPUCommandBuffer(cmdBuf) == false {
		sdl.Log("Submit command buffer: %s", sdl.GetError())
		return .FAILURE
	}

	frame_end := sdl.GetTicksNS()

	npf_target := u64(1_000_000_000 / 60) // nanoseconds per frame target
	if (frame_end - frame_start) < npf_target {
		sleep_time := npf_target - (frame_end - frame_start)
		sdl.DelayPrecise(sleep_time)
		frame_end = sdl.GetTicksNS() // Update frame_end counter to include sleep_time for fps calculation
	}

	delta_time = f32(frame_end - frame_start) / 1_000_000_000

	return .CONTINUE
}

@(export)
SDL_AppQuit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	sdl.Log("quitting")
	if device != nil {
		if window != nil {
			sdl.ReleaseWindowFromGPUDevice(device, window)
			sdl.DestroyWindow(window)
		}

		sdl.DestroyGPUDevice(device)
	}

	sdl.Quit()
}

load_shader :: proc(code: []u8, stage: sdl.GPUShaderStage, num_buffers: u32) -> ^sdl.GPUShader {
	return sdl.CreateGPUShader(
		device,
		{
			code_size = len(code),
			code = raw_data(code),
			entrypoint = "main",
			format = {.SPIRV},
			stage = stage,
			num_uniform_buffers = num_buffers,
		},
	)
}
