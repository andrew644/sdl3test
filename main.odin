package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

device: ^sdl.GPUDevice
window: ^sdl.Window

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

	device = sdl.CreateGPUDevice({.SPIRV, .DXIL, .MSL}, false, nil)
	if device == nil {
		return .FAILURE
	}
	sdl.Log("GPU device: %s", sdl.GetGPUDeviceDriver(device))

	if sdl.ClaimWindowForGPUDevice(device, window) == false {
		sdl.Log("Failed to bind GPU to window: %s", sdl.GetError())
		return .FAILURE
	}

	return .CONTINUE

	/*
	fps_cap_enabled := true
	fps_target := 60
	fps: f64

	main_loop: for {
		frame_start := sdl.GetTicksNS()

		for event: sdl.Event; sdl.PollEvent(&event); {
			#partial switch event.type {
			case .QUIT:
				break main_loop
			case .WINDOW_CLOSE_REQUESTED:
				break main_loop
			case .KEY_DOWN:
				switch event.key.key {
				case sdl.K_ESCAPE:
					break main_loop
				case sdl.K_Q:
					break main_loop
				}
			}
		}

		sdl.SetRenderDrawColorFloat(renderer, .2, .2, .2, 1)
		sdl.RenderClear(renderer)

		sdl.SetRenderDrawColorFloat(renderer, .8, .3, .8, 1)
		sdl.RenderDebugText(renderer, 10, 10, fmt.ctprintf("%-16s%.2f", "FPS Current:", fps))

		free_all(context.temp_allocator)

		sdl.RenderPresent(renderer)

		frame_end := sdl.GetTicksNS()

		// Cap fps if enabled
		npf_target := u64(1_000_000_000 / fps_target) // nanoseconds per frame target
		if fps_cap_enabled && (frame_end - frame_start) < npf_target {
			sleep_time := npf_target - (frame_end - frame_start)
			sdl.DelayPrecise(sleep_time)
			frame_end = sdl.GetTicksNS() // Update frame_end counter to include sleep_time for fps calculation
		}

		// update fps tracker
		fps = 1_000_000_000.0 / f64(frame_end - frame_start)
	}
	*/
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
	cmdBuf := sdl.AcquireGPUCommandBuffer(device)
	if cmdBuf == nil {
		sdl.Log("Failed to get command buffer: %s", sdl.GetError())
		return .FAILURE
	}

	swapchainTexure: ^sdl.GPUTexture
	if sdl.WaitAndAcquireGPUSwapchainTexture(cmdBuf, window, &swapchainTexure, nil, nil) == false {
		sdl.Log("Wait for swapchainTexture: %s", sdl.GetError())
		return .FAILURE
	}

	if swapchainTexure != nil {
		clearColor: sdl.FColor
		clearColor.r = .2
		clearColor.g = .2
		clearColor.b = .2
		clearColor.a = 1
		targetInfo := sdl.GPUColorTargetInfo {
			texture     = swapchainTexure,
			cycle       = true,
			load_op     = sdl.GPULoadOp.CLEAR,
			store_op    = sdl.GPUStoreOp.STORE,
			clear_color = clearColor,
		}

		renderPass := sdl.BeginGPURenderPass(cmdBuf, &targetInfo, 1, nil)
		sdl.EndGPURenderPass(renderPass)
	}

	if sdl.SubmitGPUCommandBuffer(cmdBuf) == false {
		sdl.Log("Submit command buffer: %s", sdl.GetError())
		return .FAILURE
	}

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
