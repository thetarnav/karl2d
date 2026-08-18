#+build linux
package karl2d

@(private="package")
LINUX_WINDOW_WAYLAND :: Linux_Window_Interface {
	state_size = wl_state_size,
	init = wl_init,
	shutdown = wl_shutdown,
	get_window_render_glue = wl_get_window_render_glue,
	get_events = wl_get_events,
	set_title = wl_set_title,
	get_screen_width = wl_get_screen_width,
	get_screen_height = wl_get_screen_height,
	set_position = wl_set_position,
	get_position = wl_get_position,
	set_screen_size = wl_set_screen_size,
	get_window_scale = wl_get_window_scale,
	set_window_mode = wl_set_window_mode,
	set_cursor_hidden = wl_set_cursor_hidden,
	is_cursor_hidden = wl_is_cursor_hidden,
	set_mouse_locked = wl_set_mouse_locked,
	is_mouse_locked = wl_is_mouse_locked,
	create_custom_cursor = wl_create_custom_cursor,
	set_cursor = wl_set_cursor,
	destroy_custom_cursor = wl_destroy_custom_cursor,
	set_internal_state = wl_set_internal_state,
	get_clipboard_text = wl_get_clipboard_text,
	set_clipboard_text = wl_set_clipboard_text,
}

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:c"
import "core:math"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"
import hm "core:container/handle_map"

import "log"
import wl "platform_bindings/linux/wayland"
import xkb "platform_bindings/linux/xkbcommon"

_ :: log
_ :: fmt

// What size the theme cursor ends up on screen, in logical pixels. The theme is loaded at
// THEME_CURSOR_SIZE*scale physical pixels and a viewport scales it back down to this.
THEME_CURSOR_SIZE :: 24

@(private="package")

wl_state_size :: proc() -> int {
	return size_of(WL_State)
}

wl_init :: proc(
	window_state: rawptr,
	screen_width: int,
	screen_height: int,
	window_title: string,
	options: Init_Options,
	allocator: runtime.Allocator,
) {
	s = (^WL_State)(window_state)
	s.allocator = allocator
	s.scale = 1
	s.odin_ctx = context
	hm.dynamic_init(&s.custom_cursors, allocator)
	s.clipboard_mimes = make([dynamic]string, allocator = allocator)

	s.xkb_context = xkb.context_new(.No_Flags)

	s.display = wl.display_connect(nil)

	display_registry := wl.display_get_registry(s.display)
	wl.add_listener(display_registry, &registry_listener, nil)

	// Collects all the globals.
	wl.display_roundtrip(s.display)

	wl.add_listener(s.seat, &seat_listener, nil)

	// Initializes pointer and keyboard based on seat capabilities.
	wl.display_roundtrip(s.display)

	if s.data_device_manager != nil && s.seat != nil {
		s.data_device = wl.data_device_manager_get_data_device(s.data_device_manager, s.seat)
		wl.add_listener(s.data_device, &data_device_listener, nil)
		wl.display_roundtrip(s.display)
	}

	// Sets default size that gets used if the compositor doesn't suggest a size.
	s.last_configure_width = screen_width
	s.last_configure_height = screen_height
	s.last_configure_windowed_width = screen_width
	s.last_configure_windowed_height = screen_height

	s.surface = wl.compositor_create_surface(s.compositor)
	log.ensure(s.surface != nil, "Error creating Wayland surface")
	
	// Makes sure the window does "pings" that keeps it alive.
	wl.add_listener(s.xdg_base, &wm_base_listener, nil)
	xdg_surface := wl.xdg_wm_base_get_xdg_surface(s.xdg_base, s.surface)

	// Top-level means an application at the top of the window hierarchy. The callback in the
	// toplevel listener effecively creates a window handle.
	s.toplevel = wl.xdg_surface_get_toplevel(xdg_surface)
	wl.add_listener(s.toplevel, &toplevel_listener, nil)
	wl.add_listener(xdg_surface, &window_listener, nil)
	wl.xdg_toplevel_set_title(s.toplevel, strings.clone_to_cstring(window_title, frame_allocator))

	wl_set_window_mode(options.window_mode)

	if s.decoration_manager != nil {
		decoration := wl.zxdg_decoration_manager_v1_get_toplevel_decoration(s.decoration_manager, s.toplevel)

		// This adds titlebar and buttons to the window.
		wl.zxdg_toplevel_decoration_v1_set_mode(decoration, wl.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE)
	}

	if s.fractional_scale_manager != nil {
		fractional_scale := wl.wp_fractional_scale_manager_get_fractional_scale(
			s.fractional_scale_manager,
			s.surface,
		)

		wl.add_listener(fractional_scale, &fractional_scale_listener, nil)
	}

	if s.relative_pointer_manager != nil && s.pointer != nil {
		s.relative_pointer = wl.zwp_relative_pointer_manager_v1_get_relative_pointer(
			s.relative_pointer_manager,
			s.pointer,
		)

		wl.add_listener(s.relative_pointer, &relative_pointer_listener, nil)
	} else {
		log.warn("Relative pointer not available: mouse locking will not work")
	}

	s.cursor_surface = wl.compositor_create_surface(s.compositor)
	s.cursor_viewport = wl.wp_viewporter_get_viewport(s.viewporter, s.cursor_surface)
	wl.wp_viewport_set_destination(s.cursor_viewport, THEME_CURSOR_SIZE, THEME_CURSOR_SIZE)

	// The cursor shape protocol lets the compositor render its own default cursor at the correct
	// size and DPI, so the theme is only needed as a fallback for compositors without it.
	if s.cursor_shape_device == nil {
		wl_load_cursor_theme()
	}

	s.viewport = wl.wp_viewporter_get_viewport(s.viewporter, s.surface)

	wl.surface_commit(s.surface)

	// Wait for the first configure: it's what creates the EGL window.
	for !s.configured {
		if wl.display_dispatch(s.display) < 0 {
			break
		}
	}

	log.ensure(s.window != nil, "Wayland compositor never sent an initial configure")

	when RENDER_BACKEND_NAME == "gl" {
		s.window_render_glue = make_linux_gl_wayland_glue(s.display, s.window, s.allocator)
	} else when RENDER_BACKEND_NAME == "nil" {
		s.window_render_glue = {}
	} else {
		#panic("Unsupported combo of Linux + X11 and render backend '" + RENDER_BACKEND_NAME + "'")
	}

	if options.disable_auto_scale_hint {
		log.warn("disable_auto_scale_hint not supported on linux/wayland")
	}
}

registry_listener := wl.Registry_Listener {
	global = proc "c" (
		data: rawptr,
		registry: ^wl.Registry,
		name: u32,
		interface: cstring,
		version: u32,
	) {
		context = s.odin_ctx
		switch interface {
		case wl.compositor_interface.name:
			s.compositor = wl.registry_bind(
				wl.Compositor,
				registry,
				name,
				&wl.compositor_interface,
				version,
			)

		case wl.xdg_wm_base_interface.name:
			s.xdg_base = wl.registry_bind(
				wl.XDG_WM_Base,
				registry,
				name,
				&wl.xdg_wm_base_interface,
				version,
			)

		case wl.seat_interface.name:
			s.seat = wl.registry_bind(
				wl.Seat,
				registry,
				name,
				&wl.seat_interface,
				version,
			)

		case wl.zxdg_decoration_manager_v1_interface.name:
			s.decoration_manager = wl.registry_bind(
				wl.ZXDG_Decoration_Manager_V1,
				registry,
				name,
				&wl.zxdg_decoration_manager_v1_interface,
				version,
			)

		case wl.wp_fractional_scale_manager_v1_interface.name:
			s.fractional_scale_manager = wl.registry_bind(
				wl.WP_Fractional_Scale_Manager_V1,
				registry,
				name,
				&wl.wp_fractional_scale_manager_v1_interface,
				version,
			)

		case wl.wp_viewporter_interface.name:
			s.viewporter = wl.registry_bind(
				wl.WP_Viewporter,
				registry,
				name,
				&wl.wp_viewporter_interface,
				version,
			)

		case wl.zwp_relative_pointer_manager_v1_interface.name:
			s.relative_pointer_manager = wl.registry_bind(
				wl.ZWP_Relative_Pointer_Manager_V1,
				registry,
				name,
				&wl.zwp_relative_pointer_manager_v1_interface,
				version,
			)

		case wl.zwp_pointer_constraints_v1_interface.name:
			s.pointer_constraints = wl.registry_bind(
				wl.ZWP_Pointer_Constraints_V1,
				registry,
				name,
				&wl.zwp_pointer_constraints_v1_interface,
				version,
			)

		case wl.shm_interface.name:
			s.shm = wl.registry_bind(
				wl.SHM,
				registry,
				name,
				&wl.shm_interface,
				version,
			)

		case wl.wp_cursor_shape_manager_v1_interface.name:
			s.cursor_shape_manager = wl.registry_bind(
				wl.WP_Cursor_Shape_Manager_V1,
				registry,
				name,
				&wl.wp_cursor_shape_manager_v1_interface,
				version,
			)

		case wl.data_device_manager_interface.name:
			s.data_device_manager = wl.registry_bind(
				wl.Data_Device_Manager,
				registry,
				name,
				&wl.data_device_manager_interface,
				version,
			)
		}
	},
	global_remove = proc "c" (data: rawptr, registry: ^wl.Registry, name: u32) {},
}

seat_listener := wl.Seat_Listener {
	capabilities = proc "c" (data: rawptr, seat: ^wl.Seat, capabilities: wl.Seat_Capabilities) {
		context = s.odin_ctx

		if .Pointer in capabilities {
			if s.pointer != nil {
				if s.cursor_shape_device != nil {
					wl.cursor_shape_device_destroy(s.cursor_shape_device)
					s.cursor_shape_device = nil
				}
				wl.pointer_release(s.pointer)
			}

			s.pointer = wl.seat_get_pointer(seat)
			wl.add_listener(s.pointer, &pointer_listener, nil)
			if s.cursor_shape_manager != nil {
				s.cursor_shape_device = wl.cursor_shape_manager_get_pointer(
					s.cursor_shape_manager,
					s.pointer,
				)
			}
		} else if s.pointer != nil {
			if s.cursor_shape_device != nil {
				wl.cursor_shape_device_destroy(s.cursor_shape_device)
				s.cursor_shape_device = nil
			}
			wl.pointer_release(s.pointer)
			s.pointer = nil
		}

		if .Keyboard in capabilities {
			if s.keyboard != nil {
				wl.keyboard_release(s.keyboard)
			}

			s.keyboard = wl.seat_get_keyboard(seat)
			wl.add_listener(s.keyboard, &keyboard_listener, nil)
		} else if s.keyboard != nil {
			wl.keyboard_release(s.keyboard)
			s.keyboard = nil
		}
	},
	name = proc "c" (data: rawptr, seat: ^wl.Seat, name: cstring) {},
}

toplevel_listener := wl.XDG_Toplevel_Listener {
	configure = proc "c" (
		data: rawptr,
		xdg_toplevel: ^wl.XDG_Toplevel,
		width: c.int32_t,
		height: c.int32_t,
		states: ^wl.Array,
	) {
		w := int(width)
		h := int(height)

		context = s.odin_ctx

		new_width: int
		new_height: int

		if s.window_mode == .Windowed {
			// Fixed-size window: we dictate the size, the compositor doesn't.
			new_width = s.last_configure_windowed_width
			new_height = s.last_configure_windowed_height
		} else {
			// A zero axis means the compositor lets us pick that dimension.
			new_width = w != 0 ? w : s.last_configure_windowed_width
			new_height = h != 0 ? h : s.last_configure_windowed_height
		}

		window_resized := new_width != s.last_configure_width || new_height != s.last_configure_height

		if window_resized || !s.configured {
			s.screen_width = int(f32(new_width) * s.scale)
			s.screen_height = int(f32(new_height) * s.scale)

			if !s.configured {
				s.window = wl.egl_window_create(s.surface, i32(s.screen_width), i32(s.screen_height))
			} else {
				wl.egl_window_resize(s.window, i32(s.screen_width), i32(s.screen_height), 0, 0)
			}
			wl.wp_viewport_set_destination(s.viewport, i32(new_width), i32(new_height))

			s.last_configure_width = new_width
			s.last_configure_height = new_height
			if s.window_mode == .Windowed || s.window_mode == .Windowed_Resizable {
				s.last_configure_windowed_width = new_width
				s.last_configure_windowed_height = new_height
			}

			append(&s.events, Event_Screen_Resize {
				width = s.screen_width,
				height = s.screen_height,
			})
		}
		s.configured = true
	},
	close = proc "c" (data: rawptr, xdg_toplevel: ^wl.XDG_Toplevel) {
		context = s.odin_ctx
		append(&s.events, Event_Close_Window_Requested{})
	},
	configure_bounds = proc "c" (data: rawptr, xdg_toplevel: ^wl.XDG_Toplevel, width: c.int32_t, height: c.int32_t,) {},
	wm_capabilities = proc "c" (data: rawptr, xdg_toplevel: ^wl.XDG_Toplevel, capabilities: ^wl.Array,) {},
}


window_listener := wl.XDG_Surface_Listener {
	configure = proc "c" (data: rawptr, surface: ^wl.XDG_Surface, serial: c.uint32_t) {
		wl.xdg_surface_ack_configure(surface, serial)
	},
}

wm_base_listener := wl.XDG_WM_Base_Listener {
	ping = proc "c" (data: rawptr, xdg_wm_base: ^wl.XDG_WM_Base, serial: c.uint32_t) {
		wl.xdg_wm_base_pong(xdg_wm_base, serial)
	},
}

keyboard_listener := wl.Keyboard_Listener {
	keymap = proc "c" (
		data: rawptr,
		keyboard: ^wl.Keyboard,
		format: u32,
		fd: c.int32_t,
		size: u32,
	) {
		context = s.odin_ctx
		defer linux.close(linux.Fd(fd))

		if format != wl.KEYBOARD_KEYMAP_FORMAT_XKB_V1 {
			log.error("Unsupported Wayland keymap format, typed text input won't work")
			return
		}

		mapped, mmap_err := linux.mmap(0, uint(size), {.READ}, {.PRIVATE}, linux.Fd(fd))

		if mmap_err != .NONE {
			log.error("Failed mapping Wayland keymap into memory, typed text input won't work")
			return
		}

		defer linux.munmap(mapped, uint(size))

		// The mapped memory holds a NUL-terminated string, so it's safe to treat as a cstring.
		keymap := xkb.keymap_new_from_string(s.xkb_context, cstring(mapped), .Text_V1, .No_Flags)

		if keymap == nil {
			log.error("Failed parsing Wayland keymap, typed text input won't work")
			return
		}

		if s.xkb_state != nil {
			xkb.state_unref(s.xkb_state)
		}

		if s.xkb_keymap != nil {
			xkb.keymap_unref(s.xkb_keymap)
		}

		s.xkb_keymap = keymap
		s.xkb_state = xkb.state_new(keymap)
	},
	enter = proc "c" (data: rawptr, keyboard: ^wl.Keyboard, serial: c.uint32_t, surface: ^wl.Surface, keys: ^wl.Array) {},
	leave = proc "c" (data: rawptr, keyboard: ^wl.Keyboard, serial: c.uint32_t, surface: ^wl.Surface) {
		context = s.odin_ctx

		// We stop hearing about this key once we lose keyboard focus, so the synthesized repeat
		// would otherwise keep firing forever while the window is in the background.
		s.repeat_key = .None
	},
	key = key_handler,
	modifiers = proc "c" (
		data: rawptr,
		keyboard: ^wl.Keyboard,
		serial: c.uint32_t,
		mods_depressed: c.uint32_t,
		mods_latched: c.uint32_t,
		mods_locked: c.uint32_t,
		group: c.uint32_t,
	) {
		context = s.odin_ctx

		if s.xkb_state == nil {
			return
		}

		// The last three arguments here are for depressed/latched/locked *layout* -- we only care
		// about the active layout group, so we leave depressed/latched layout at 0.
		xkb.state_update_mask(s.xkb_state, mods_depressed, mods_latched, mods_locked, 0, 0, group)
	},
	repeat_info = proc "c" (
		data: rawptr,
		keyboard: ^wl.Keyboard,
		rate: c.int32_t,
		delay: c.int32_t,
	) {
		context = s.odin_ctx
		s.repeat_rate = rate
		s.repeat_delay = delay
	},
}

key_handler :: proc "c" (
	data: rawptr,
	keyboard: ^wl.Keyboard,
	serial: c.uint32_t,
	t: c.uint32_t,
	key: c.uint32_t,
	state: c.uint32_t,
) {
	context = runtime.default_context()
	if serial != 0 {
		s.input_serial = u32(serial)
	}

	// Wayland emits evdev events, and the keycodes are shifted
	// from the expected xkb events... Just add 8 to it.
	keycode := key + 8

	switch state {
	case wl.KEYBOARD_KEY_STATE_RELEASED:
		key := key_from_xkeycode(keycode)

		if s.repeat_xkb_keycode == keycode {
			s.repeat_key = .None
		}

		if key != .None {
			append(&s.events, Event_Key_Went_Up {
				key = key,
			})
		}

	case wl.KEYBOARD_KEY_STATE_PRESSED:
		key := key_from_xkeycode(keycode)

		if key != .None {
			append(&s.events, Event_Key_Went_Down {
				key = key,
			})
		}

		_wl_append_typed_runes(keycode)

		if key != .None && s.repeat_rate > 0 {
			s.repeat_key = key
			s.repeat_xkb_keycode = keycode
			delay := time.Millisecond * time.Duration(s.repeat_delay)
			s.repeat_next_tick = time.tick_add(time.tick_now(), delay)
		}
	}
}

_wl_append_typed_runes :: proc(keycode: c.uint32_t) {
	if s.xkb_state == nil {
		return
	}

	buf: [32]u8
	n := xkb.state_key_get_utf8(
		s.xkb_state, xkb.Keycode(keycode), raw_data(buf[:]), c.size_t(len(buf)),
	)

	if n <= 0 {
		return
	}

	for r in string(buf[:min(int(n), len(buf))]) {
		if is_typable_rune(r) {
			append(&s.events, Event_Typed_Rune { typed = r })
		}
	}
}

pointer_listener := wl.Pointer_Listener {
	enter = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		serial: c.uint32_t,
		surface: ^wl.Surface,
		surface_x: wl.Fixed,
		surface_y: wl.Fixed,
	) {
		context = s.odin_ctx
		s.pointer_enter_serial = u32(serial)
		wl_apply_cursor()
	},
	leave = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		serial: c.uint32_t,
		surface: ^wl.Surface,
	) {

	},
	motion = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		time: c.uint32_t,
		surface_x: wl.Fixed,
		surface_y: wl.Fixed,
	) {
		context = s.odin_ctx
		
		// surface_x and surface_y are fixed point 24.8 variables. 
		// Just bitshift them to remove the decimal part and obtain 
		// a screen coordinate
		append(&s.events, Event_Mouse_Move {
			position = { math.floor(f32(surface_x >> 8) * s.scale), math.floor(f32(surface_y >> 8) * s.scale) }, 
		})
	},
	button = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		serial: c.uint32_t,
		time: c.uint32_t,
		button: c.uint32_t,
		state: c.uint32_t,
	) {
		context = s.odin_ctx
		if serial != 0 {
			s.input_serial = u32(serial)
		}

		btn: Mouse_Button
		switch button {
		case wl.POINTER_BTN_LEFT: btn = .Left
		case wl.POINTER_BTN_MIDDLE: btn = .Middle
		case wl.POINTER_BTN_RIGHT: btn = .Right
		}
	
		switch state {
		case wl.POINTER_BUTTON_STATE_RELEASED:
			append(&s.events, Event_Mouse_Button_Went_Up {
				button = btn,
			})
		case wl.POINTER_BUTTON_STATE_PRESSED: 
			append(&s.events, Event_Mouse_Button_Went_Down {
				button = btn,
			})
		}
	},
	axis = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		time: c.uint32_t,
		axis: c.uint32_t,
		value: wl.Fixed,
	) {
		context = s.odin_ctx

		// Wayland measures down and right as positive, so the vertical axis needs flipping.
		switch axis {
		case wl.POINTER_AXIS_VERTICAL_SCROLL:
			append(&s.events, Event_Mouse_Wheel {
				delta = f32(math.sign(value)) * -1,
			})

		case wl.POINTER_AXIS_HORIZONTAL_SCROLL:
			append(&s.events, Event_Mouse_Wheel_Horizontal {
				delta = f32(math.sign(value)),
			})
		}
	},
	frame = proc "c" (data: rawptr, pointer: ^wl.Pointer) {},
	axis_source = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		axis_source: c.uint32_t,
	) {},
	axis_stop = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		time: c.uint32_t,
		axis: c.uint32_t,
	) {},
	axis_discrete = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		axis: c.uint32_t,
		discrete: c.int32_t,
	) {},
	axis_value120 = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		axis: c.uint32_t,
		value120: c.int32_t,
	) {},
	axis_relative_direction = proc "c" (
		data: rawptr,
		pointer: ^wl.Pointer,
		axis: c.uint32_t,
		direction: c.uint32_t,
	) {},
}

fractional_scale_listener := wl.WP_Fractional_Scale_V1_Listener {
	preferred_scale = proc "c" (
		data: rawptr,
		self: ^wl.WP_Fractional_Scale_V1,
		scale: u32,
	) {
		context = s.odin_ctx
		scl := f32(scale)/120
		s.scale = scl
		s.screen_width = int(f32(s.last_configure_width) * s.scale)
		s.screen_height = int(f32(s.last_configure_height) * s.scale)

		if s.configured {
			wl.egl_window_resize(s.window, i32(s.screen_width), i32(s.screen_height), 0, 0)
		}

		// The cursor theme is loaded at a fixed physical size, so it needs reloading whenever
		// the scale changes. Only relevant without the cursor shape protocol - the compositor
		// handles its own DPI when we use that instead.
		if s.cursor_shape_device == nil {
			wl_load_cursor_theme()
		}

		// Makes any visible effect of the new scale (a rescaled custom cursor, or a reloaded
		// theme cursor) happen instantly rather than waiting for the next pointer move.
		wl_apply_cursor()

		append(&s.events, Event_Window_Scale_Changed {
			scale = scl,
			screen_width = s.screen_width,
			screen_height = s.screen_height,
		})
	},
}

WAYLAND_CLIPBOARD_MAX_BYTES :: 4 * 1024 * 1024
WAYLAND_CLIPBOARD_TRANSFER_TIMEOUT :: 250 * time.Millisecond

wl_clipboard_clear_mimes :: proc() {
	for mime in s.clipboard_mimes {
		free(raw_data(mime), s.allocator)
	}
	runtime.clear(&s.clipboard_mimes)
}

wl_clipboard_clear_pending_mimes :: proc() {
	for mime in s.clipboard_pending_mimes {
		free(raw_data(mime), s.allocator)
	}
	runtime.clear(&s.clipboard_pending_mimes)
}

data_device_listener := wl.Data_Device_Listener {
	data_offer = proc "c" (data: rawptr, device: ^wl.Data_Device, offer: ^wl.Data_Offer) {
		context = s.odin_ctx
		if s.clipboard_pending_offer != nil && s.clipboard_pending_offer != offer {
			wl.data_offer_destroy(s.clipboard_pending_offer)
			wl_clipboard_clear_pending_mimes()
		}
		s.clipboard_pending_offer = offer
		wl.add_listener(offer, &data_offer_listener, nil)
	},
	enter = proc "c" (data: rawptr, device: ^wl.Data_Device, serial: u32, surface: ^wl.Surface, x, y: wl.Fixed, offer: ^wl.Data_Offer) {},
	leave = proc "c" (data: rawptr, device: ^wl.Data_Device) {},
	motion = proc "c" (data: rawptr, device: ^wl.Data_Device, time: u32, x, y: wl.Fixed) {},
	drop = proc "c" (data: rawptr, device: ^wl.Data_Device) {},
	selection = proc "c" (data: rawptr, device: ^wl.Data_Device, offer: ^wl.Data_Offer) {
		context = s.odin_ctx
		selection_changed := s.clipboard_offer != offer
		if s.clipboard_offer != nil && s.clipboard_offer != offer {
			wl.data_offer_destroy(s.clipboard_offer)
		}
		if s.clipboard_pending_offer != nil && s.clipboard_pending_offer != offer {
			wl.data_offer_destroy(s.clipboard_pending_offer)
			wl_clipboard_clear_pending_mimes()
		}
		s.clipboard_offer = offer
		if selection_changed {
			wl_clipboard_clear_mimes()
		}
		if s.clipboard_pending_offer == offer {
			delete(s.clipboard_mimes)
			s.clipboard_mimes = s.clipboard_pending_mimes
			s.clipboard_pending_mimes = nil
			s.clipboard_mime_offer = offer
		} else if selection_changed {
			s.clipboard_mime_offer = offer
		}
		s.clipboard_pending_offer = nil
	},
}

data_offer_listener := wl.Data_Offer_Listener {
	offer = proc "c" (data: rawptr, offer: ^wl.Data_Offer, mime_type: cstring) {
		context = s.odin_ctx
		if offer == s.clipboard_pending_offer {
			append(&s.clipboard_pending_mimes, strings.clone(string(mime_type), s.allocator))
		} else if offer == s.clipboard_offer && offer == s.clipboard_mime_offer {
			append(&s.clipboard_mimes, strings.clone(string(mime_type), s.allocator))
		}
	},
	source_actions = proc "c" (data: rawptr, offer: ^wl.Data_Offer, source_actions: u32) {},
	action = proc "c" (data: rawptr, offer: ^wl.Data_Offer, dnd_action: u32) {},
}

wl_get_clipboard_text :: proc(allocator: runtime.Allocator) -> (string, bool) {
	if s.data_device == nil {
		return "", false
	}

	// data_offer and selection are queued separately. Dispatch before touching the offer so the
	// selected pointer and its MIME list are current.
	if wl.display_dispatch_pending(s.display) < 0 || s.clipboard_offer == nil {
		return "", false
	}
	if len(s.clipboard_mimes) == 0 {
		if wl.display_roundtrip(s.display) < 0 || s.clipboard_offer == nil {
			return "", false
		}
	}
	mime := ""
	for candidate in s.clipboard_mimes {
		if candidate == wl.MIME_TEXT_PLAIN_UTF8 {
			mime = candidate
			break
		}
		if candidate == wl.MIME_TEXT_PLAIN && mime == "" {
			mime = candidate
		}
	}
	if mime == "" {
		return "", false
	}

	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return "", false
	}
	read_fd := linux.Fd(fds[0])
	write_fd := linux.Fd(fds[1])
	defer linux.close(read_fd)
	defer linux.close(write_fd)
	flags, flags_err := linux.fcntl_getfl(read_fd, linux.F_GETFL)
	write_flags, write_flags_err := linux.fcntl_getfl(write_fd, linux.F_GETFL)
	if flags_err != .NONE || write_flags_err != .NONE ||
		linux.fcntl_setfl(read_fd, linux.F_SETFL, flags | {.NONBLOCK}) != .NONE ||
		linux.fcntl_setfl(write_fd, linux.F_SETFL, write_flags | {.NONBLOCK}) != .NONE {
		return "", false
	}

	wl.data_offer_receive(s.clipboard_offer, strings.clone_to_cstring(mime, frame_allocator), c.int32_t(write_fd))
	flush_deadline := time.tick_add(time.tick_now(), WAYLAND_CLIPBOARD_TRANSFER_TIMEOUT)
	for wl.display_flush(s.display) < 0 && time.tick_diff(flush_deadline, time.tick_now()) > 0 {
		pfd := posix.pollfd {
			fd = posix.FD(wl.display_get_fd(s.display)),
			events = {posix.Poll_Event_Bits.OUT},
		}
		if posix.poll(&pfd, 1, 10) < 0 {
			break
		}
	}
	if time.tick_diff(flush_deadline, time.tick_now()) <= 0 {
		return "", false
	}
	buffer := make([]u8, WAYLAND_CLIPBOARD_MAX_BYTES, s.allocator)
	used := 0
	deadline := time.tick_add(time.tick_now(), WAYLAND_CLIPBOARD_TRANSFER_TIMEOUT)
	for time.tick_diff(deadline, time.tick_now()) > 0 {
		if used == len(buffer) {
			free(raw_data(buffer), s.allocator)
			return "", false
		}
		n, read_err := linux.read(read_fd, buffer[used:])
		if n > 0 {
			used += n
			continue
		}
		if n == 0 {
			result := strings.clone(string(buffer[:used]), allocator)
			free(raw_data(buffer), s.allocator)
			return result, true
		}
		if read_err != .EINTR && read_err != .EAGAIN && read_err != .EWOULDBLOCK {
			free(raw_data(buffer), s.allocator)
			return "", false
		}

		fds := [2]posix.pollfd {
			{fd = posix.FD(read_fd), events = {posix.Poll_Event_Bits.IN}},
			{fd = posix.FD(wl.display_get_fd(s.display)), events = {posix.Poll_Event_Bits.IN}},
		}
		if posix.poll(&fds[0], 2, 10) < 0 {
			free(raw_data(buffer), s.allocator)
			return "", false
		}
		if .IN in fds[1].revents || .HUP in fds[1].revents || .ERR in fds[1].revents {
			if wl.display_dispatch(s.display) < 0 {
				free(raw_data(buffer), s.allocator)
				return "", false
			}
		}
		if .ERR in fds[0].revents || .NVAL in fds[0].revents {
			free(raw_data(buffer), s.allocator)
			return "", false
		}
	}
	free(raw_data(buffer), s.allocator)
	return "", false
}

wl_clipboard_clear_source :: proc() {
	if s.clipboard_source != nil {
		wl.data_source_destroy(s.clipboard_source)
		s.clipboard_source = nil
	}
	if s.clipboard_owned_text != nil {
		free(raw_data(s.clipboard_owned_text), s.allocator)
		s.clipboard_owned_text = nil
	}
}

wl_set_clipboard_text :: proc(text: string) -> bool {
	if s.data_device_manager == nil || s.data_device == nil || len(text) > WAYLAND_CLIPBOARD_MAX_BYTES {
		return false
	}
	wl_clipboard_clear_source()
	s.clipboard_owned_text = make([]u8, len(text), s.allocator)
	copy(s.clipboard_owned_text, text)
	s.clipboard_source = wl.data_device_manager_create_data_source(s.data_device_manager)
	if s.clipboard_source == nil {
		wl_clipboard_clear_source()
		return false
	}
	wl.add_listener(s.clipboard_source, &data_source_listener, nil)
	wl.data_source_offer(s.clipboard_source, wl.MIME_TEXT_PLAIN_UTF8)
	wl.data_source_offer(s.clipboard_source, wl.MIME_TEXT_PLAIN)
	if s.input_serial == 0 {
		wl_clipboard_clear_source()
		return false
	}
	wl.data_device_set_selection(s.data_device, s.clipboard_source, s.input_serial)
	if wl.display_flush(s.display) != 0 {
		wl_clipboard_clear_source()
		return false
	}
	return true
}

data_source_listener := wl.Data_Source_Listener {
	target = proc "c" (data: rawptr, source: ^wl.Data_Source, mime_type: cstring) {},
	send = proc "c" (data: rawptr, source: ^wl.Data_Source, mime_type: cstring, fd: c.int32_t) {
		context = s.odin_ctx
		write_fd := linux.Fd(fd)
		flags, flags_err := linux.fcntl_getfl(write_fd, linux.F_GETFL)
		if flags_err != .NONE || linux.fcntl_setfl(write_fd, linux.F_SETFL, flags | {.NONBLOCK}) != .NONE {
			linux.close(write_fd)
			return
		}
		if s.clipboard_owned_text != nil {
			bytes := s.clipboard_owned_text
			deadline := time.tick_add(time.tick_now(), WAYLAND_CLIPBOARD_TRANSFER_TIMEOUT)
			for len(bytes) > 0 && time.tick_diff(deadline, time.tick_now()) > 0 {
				n, err := linux.write(write_fd, bytes)
				if n > 0 {
					bytes = bytes[n:]
					continue
				}
				if err == .EINTR {
					continue
				}
				if err != .EAGAIN && err != .EWOULDBLOCK {
					break
				}
				pfd := posix.pollfd {
					fd = posix.FD(write_fd),
					events = {posix.Poll_Event_Bits.OUT},
				}
				if posix.poll(&pfd, 1, 10) < 0 {
					break
				}
			}
		}
		linux.close(write_fd)
	},
	cancelled = proc "c" (data: rawptr, source: ^wl.Data_Source) {
		context = s.odin_ctx
		wl_clipboard_clear_source()
	},
	dnd_drop_performed = proc "c" (data: rawptr, source: ^wl.Data_Source) {},
	dnd_finished = proc "c" (data: rawptr, source: ^wl.Data_Source) {},
	action = proc "c" (data: rawptr, source: ^wl.Data_Source, dnd_action: u32) {},
}

wl_shutdown :: proc() {
	wl_clipboard_clear_source()
	if s.clipboard_offer != nil {
		wl.data_offer_destroy(s.clipboard_offer)
		s.clipboard_offer = nil
	}
	if s.clipboard_pending_offer != nil {
		wl.data_offer_destroy(s.clipboard_pending_offer)
		s.clipboard_pending_offer = nil
	}
	s.clipboard_mime_offer = nil
	wl_clipboard_clear_mimes()
	wl_clipboard_clear_pending_mimes()
	delete(s.clipboard_mimes)
	delete(s.clipboard_pending_mimes)
	if s.data_device != nil {
		wl.data_device_release(s.data_device)
		s.data_device = nil
	}
	if s.data_device_manager != nil {
		wl.data_device_manager_release(s.data_device_manager)
		s.data_device_manager = nil
	}

	for it := hm.dynamic_iterator_make(&s.custom_cursors); cd, _ in hm.dynamic_iterate(&it) {
		wl.wp_viewport_destroy(cd.viewport)
		wl.surface_destroy(cd.surface)
		wl.buffer_destroy(cd.buffer)
		linux.munmap(cd.data, uint(cd.data_size))
	}
	hm.dynamic_destroy(&s.custom_cursors)

	// The cursor shape protocol is optional, so these are nil on compositors that lack it.
	if s.cursor_shape_device != nil {
		wl.cursor_shape_device_destroy(s.cursor_shape_device)
		s.cursor_shape_device = nil
	}

	if s.cursor_shape_manager != nil {
		wl.cursor_shape_manager_destroy(s.cursor_shape_manager)
		s.cursor_shape_manager = nil
	}

	// The theme is only loaded on compositors without the cursor shape protocol.
	if s.cursor_theme != nil {
		wl.cursor_theme_destroy(s.cursor_theme)
		s.cursor_theme = nil
	}

	if s.cursor_viewport != nil {
		wl.wp_viewport_destroy(s.cursor_viewport)
		s.cursor_viewport = nil
	}

	if s.cursor_surface != nil {
		wl.surface_destroy(s.cursor_surface)
		s.cursor_surface = nil
	}

	delete(s.events)

	if s.xkb_state != nil {
		xkb.state_unref(s.xkb_state)
	}

	if s.xkb_keymap != nil {
		xkb.keymap_unref(s.xkb_keymap)
	}

	if s.xkb_context != nil {
		xkb.context_unref(s.xkb_context)
	}
}

wl_get_window_render_glue :: proc() -> Window_Render_Glue {
	return s.window_render_glue
}

wl_get_events :: proc(events: ^[dynamic]Event) {
	wl.display_dispatch_pending(s.display)

	// Wayland compositors don't send repeat events -- we have to synthesize them ourselves from
	// the rate/delay reported by the keyboard's `repeat_info` event.
	if s.repeat_key != .None && s.repeat_rate > 0 {
		now := time.tick_now()
		interval := time.Second / time.Duration(s.repeat_rate)

		// Capped so that a long stall (a breakpoint, a slow loading frame) doesn't produce a huge
		// burst of repeats.
		REPEATS_PER_FRAME_MAX :: 32

		for _ in 0..<REPEATS_PER_FRAME_MAX {
			if time.tick_diff(s.repeat_next_tick, now) < 0 {
				break
			}

			append(&s.events, Event_Key_Repeat {
				key = s.repeat_key,
			})
			_wl_append_typed_runes(s.repeat_xkb_keycode)
			s.repeat_next_tick = time.tick_add(s.repeat_next_tick, interval)
		}

		// If we hit the cap then we're still behind, so skip the backlog instead of spreading it
		// out over the coming frames.
		if time.tick_diff(s.repeat_next_tick, now) >= 0 {
			s.repeat_next_tick = time.tick_add(now, interval)
		}
	}

	append(events, ..s.events[:])
	runtime.clear(&s.events)
}

wl_set_title :: proc(title: string) {
	wl.xdg_toplevel_set_title(s.toplevel, strings.clone_to_cstring(title, frame_allocator))
}

wl_get_screen_width :: proc() -> int {
	return s.screen_width
}

wl_get_screen_height :: proc() -> int {
	return s.screen_height
}

wl_set_position :: proc(x: int, y: int) {
	log.error("set_position not implemented when using wayland")
}

wl_get_position :: proc() -> Vec2 {
	log.error("get_position not implemented when using wayland")
	return {}
}

wl_set_screen_size :: proc(w, h: int) {
	s.screen_width = int(f32(w) * s.scale)
	s.screen_height = int(f32(h) * s.scale)
	s.last_configure_width = w
	s.last_configure_height = h

	if s.window_mode == .Windowed || s.window_mode == .Windowed_Resizable {
		s.last_configure_windowed_width = w
		s.last_configure_windowed_height = h
	}

	if s.configured {
		wl.egl_window_resize(s.window, i32(s.screen_width), i32(s.screen_height), 0, 0)
	}

	wl.wp_viewport_set_destination(s.viewport, i32(w), i32(h))
}

wl_get_window_scale :: proc() -> f32 {
	return s.scale
}

wl_set_window_mode :: proc(window_mode: Window_Mode) {
	s.window_mode = window_mode
	 
	switch window_mode {
	case .Windowed:
		wl.xdg_toplevel_unset_fullscreen(s.toplevel)
		w := i32(s.last_configure_windowed_width)
		h := i32(s.last_configure_windowed_height)
		wl.xdg_toplevel_set_max_size(s.toplevel, w, h)
		wl.xdg_toplevel_set_min_size(s.toplevel, w, h)

	case .Windowed_Resizable:
		wl.xdg_toplevel_unset_fullscreen(s.toplevel)
		wl.xdg_toplevel_set_max_size(s.toplevel, 0, 0)
		wl.xdg_toplevel_set_min_size(s.toplevel, 0, 0)

	case .Borderless_Fullscreen:
		wl.xdg_toplevel_set_fullscreen(s.toplevel, nil)
	}
}

wl_set_cursor_hidden :: proc(hidden: bool) {
	s.cursor_hidden = hidden
	wl_apply_cursor()
}

wl_is_cursor_hidden :: proc() -> bool {
	return s.cursor_hidden
}

locked_pointer_listener := wl.ZWP_Locked_Pointer_V1_Listener {
	locked = proc "c"(data: rawptr, lp: ^wl.ZWP_Locked_Pointer_V1) {
		context = s.odin_ctx
		s.locked_pointer = lp
		cx := f32(s.screen_width / 2)
		cy := f32(s.screen_height / 2)
		append(&s.events, Event_Mouse_Teleported { position = {cx, cy} })
	},
	unlocked = proc "c"(data: rawptr, lp: ^wl.ZWP_Locked_Pointer_V1) {
		context = s.odin_ctx
		s.locked_pointer = nil
	},
}


relative_pointer_listener := wl.ZWP_Relative_Pointer_V1_Listener {
	relative_motion = proc "c" (
		data: rawptr,
		rp: ^wl.ZWP_Relative_Pointer_V1,
		t_hi, t_lo: c.uint32_t,
		dx, dy, dx_unaccel, dy_unaccel: wl.Fixed,
	) {
		// Only used when pointer is locked
		if s.locked_pointer == nil {
			return
		}
		context = s.odin_ctx
		cx := f32(s.screen_width / 2)
		cy := f32(s.screen_height / 2)
		fdx := f32(dx_unaccel >> 8)
		fdy := f32(dy_unaccel >> 8)
		// Move relative to center, matching the warp-based platforms
		append(&s.events, Event_Mouse_Move {
			position = {cx + fdx, cy + fdy},
		})
		// Teleport back so next delta is also relative to center
		append(&s.events, Event_Mouse_Teleported { position = {cx, cy} })
	},
}

wl_set_mouse_locked :: proc(locked: bool) {
	if locked {
		if s.locked_pointer != nil {
			return
		}

		s.locked_pointer = wl.zwp_pointer_constraints_v1_lock_pointer(
			s.pointer_constraints, s.surface, s.pointer, nil,
			wl.ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_PERSISTENT,
		)
		wl.add_listener(s.locked_pointer, &locked_pointer_listener, nil)

		// Synthetic teleport to center, so karl2d has the correct "previous position".
		cx := f32(s.screen_width / 2)
		cy := f32(s.screen_height / 2)
		append(&s.events, Event_Mouse_Teleported { position = {cx, cy} })
	} else {
		if s.locked_pointer == nil {
			return
		}

		wl.zwp_locked_pointer_v1_destroy(s.locked_pointer)
		s.locked_pointer = nil
	}
}

wl_is_mouse_locked :: proc() -> bool {
	return s.locked_pointer != nil
}

// Loads the cursor theme sized for the current DPI scale, destroying the previous one if this is
// a reload. Only used as a fallback for compositors without wp_cursor_shape_manager_v1, since a
// themed cursor image is a fixed physical size and has to be reloaded whenever the scale changes.
wl_load_cursor_theme :: proc() {
	if s.cursor_theme != nil {
		wl.cursor_theme_destroy(s.cursor_theme)
	}

	theme_size := max(1, int(math.round(THEME_CURSOR_SIZE * s.scale)))
	s.cursor_theme = wl.cursor_theme_load(nil, c.int(theme_size), s.shm)
}

// Sets the OS cursor from s.cursor_hidden and s.current_cursor. They share the same pointer
// cursor, so every entry point goes through this instead of setting it independently. The pointer
// re-entering the window does too, since the compositor forgets the cursor when it leaves.
wl_apply_cursor :: proc() {
	// The fractional scale listener can fire during wl_init, before the pointer and the cursor
	// surface exist. Passing a nil surface to the compositor would mean "hide the cursor", and
	// attaching a buffer to one would dereference a nil proxy inside libwayland.
	if s.pointer == nil || s.cursor_surface == nil {
		return
	}

	if s.cursor_hidden {
		wl.pointer_set_cursor(s.pointer, s.pointer_enter_serial, nil, 0, 0)
		return
	}

	standard := Standard_Cursor.Default

	switch cur in s.current_cursor {
	case Standard_Cursor:
		standard = cur

	case Custom_Cursor:
		if cd := hm.get(&s.custom_cursors, cur); cd != nil {
			wl_point_at_cursor(cd, s.pointer_enter_serial)
			return
		}
		// Otherwise it was destroyed while on screen; fall through to the default cursor below.
	}

	// A standard cursor. Prefer the cursor shape protocol, which lets the compositor render it at
	// the correct size and DPI itself; the themed surface below is only a fallback for compositors
	// that don't support it.
	if s.cursor_shape_device != nil {
		wl.cursor_shape_device_set_shape(
			s.cursor_shape_device,
			s.pointer_enter_serial,
			wl_standard_cursor_shape(standard),
		)
		return
	}

	if s.cursor_theme == nil {
		return
	}

	name, fallback := linux_standard_cursor_names(standard)
	theme_cursor := wl.cursor_theme_get_cursor(s.cursor_theme, name)

	if theme_cursor == nil {
		theme_cursor = wl.cursor_theme_get_cursor(s.cursor_theme, fallback)
	}

	// The theme has no cursor under either name. Leaving whatever is already up is the best we can
	// do: the pointer keeps the cursor it had rather than blinking out of existence.
	if theme_cursor == nil || theme_cursor.image_count == 0 {
		return
	}

	image := theme_cursor.images[0]
	buf := wl.cursor_image_get_buffer(image)

	// The theme image is THEME_CURSOR_SIZE*scale physical pixels but the viewport set up in wl_init
	// maps it down to THEME_CURSOR_SIZE logical pixels, so the hotspot (in the image's own pixels)
	// has to be scaled down to match.
	wl.pointer_set_cursor(
		s.pointer,
		s.pointer_enter_serial,
		s.cursor_surface,
		c.int32_t(math.round(f32(image.hotspot_x) / s.scale)),
		c.int32_t(math.round(f32(image.hotspot_y) / s.scale)),
	)

	wl.surface_attach(s.cursor_surface, buf, 0, 0)
	wl.surface_commit(s.cursor_surface)
}

wl_create_custom_cursor :: proc(image: Image, hotspot: [2]int) -> Custom_Cursor {
	stride := image.width * 4
	size := stride * image.height

	fd, fd_err := linux.memfd_create("cursor", {})
	if fd_err != .NONE {
		log.errorf("Failed to create Wayland cursor: memfd failed with %v", fd_err)
		return {}
	}

	// The compositor dups the fd in shm_create_pool, so we don't have to keep ours around.
	defer linux.close(fd)

	if trunc_err := linux.ftruncate(fd, i64(size)); trunc_err != .NONE {
		log.errorf("Failed to create Wayland cursor: ftruncate failed with %v", trunc_err)
		return {}
	}

	data, mmap_err := linux.mmap(0, uint(size), {.READ, .WRITE}, {.SHARED}, fd, 0)
	if mmap_err != .NONE {
		log.errorf("Failed to create Wayland cursor: mmap failed with %v", mmap_err)
		return {}
	}

	// Convert to ARGB and premultiply alpha
	pixel_data := ([^]u32)(data)
	for i in 0..<len(image.pixels) {
		col := image.pixels[i]
		a := u32(col.a)
		r := u32(col.r) * a / 255
		g := u32(col.g) * a / 255
		b := u32(col.b) * a / 255
		pixel_data[i] = a << 24 | r << 16 | g << 8 | b
	}

	pool := wl.shm_create_pool(s.shm, c.int32_t(fd), c.int32_t(size))

	buffer := wl.shm_pool_create_buffer(
		pool, 0,
		c.int32_t(image.width), c.int32_t(image.height), c.int32_t(stride),
		wl.SHM_FORMAT_ARGB8888,
	)

	// The pool can go away immediately: the mapping stays alive until every buffer made from it
	// has been destroyed.
	wl.shm_pool_destroy(pool)

	surface := wl.compositor_create_surface(s.compositor)
	wl.surface_attach(surface, buffer, 0, 0)

	cursor := WL_Cursor {
		surface   = surface,
		hotspot   = hotspot,
		width     = image.width,
		height    = image.height,
		buffer    = buffer,
		data      = data,
		data_size = size,
		viewport  = wl.wp_viewporter_get_viewport(s.viewporter, surface),
	}

	wl_apply_cursor_scale(&cursor)

	handle, add_err := hm.add(&s.custom_cursors, cursor)

	if add_err != nil {
		log.errorf("Failed to create cursor. Error: %v", add_err)
		wl.wp_viewport_destroy(cursor.viewport)
		wl.surface_destroy(cursor.surface)
		wl.buffer_destroy(cursor.buffer)
		linux.munmap(cursor.data, uint(cursor.data_size))
		return {}
	}

	return handle
}

// A cursor image is sized in physical pixels, like everything else in Karl2D, but a Wayland surface
// is sized in logical pixels. Without this a 128x128 cursor would cover 256x256 physical pixels on
// a 2x display, i.e. twice the size of a 128x128 sprite drawn by the game.
//
// The viewport makes the compositor scale the buffer down to the logical size that the image's
// physical size corresponds to. We use a viewport rather than `wl_surface.set_buffer_scale`
// because the latter only takes integers, so it cannot express a fractional scale, and because it
// raises a protocol error unless the buffer size divides evenly by the scale, which would kill the
// game for something as arbitrary as an odd-sized cursor image.
wl_apply_cursor_scale :: proc(cursor: ^WL_Cursor) {
	// A destination of zero is a protocol error, so tiny cursors stay at one logical pixel.
	dest_width := max(1, int(math.round(f32(cursor.width) / s.scale)))
	dest_height := max(1, int(math.round(f32(cursor.height) / s.scale)))

	wl.wp_viewport_set_destination(cursor.viewport, i32(dest_width), i32(dest_height))
	wl.surface_commit(cursor.surface)

	cursor.built_for_scale = s.scale
}

// Puts `cursor` on screen. `serial` must come from the most recent pointer enter event. Used both
// when the game sets a cursor and when the pointer re-enters the window, which is its own path
// through the compositor and needs the same scaling applied.
wl_point_at_cursor :: proc(cursor: ^WL_Cursor, serial: u32) {
	// The scale can change while the game runs, for instance when the window is dragged to a
	// monitor with different DPI settings.
	if cursor.built_for_scale != s.scale {
		wl_apply_cursor_scale(cursor)
	}

	// The hotspot is in surface-local (logical) coordinates, but Karl2D takes it in physical
	// pixels, like the image it belongs to.
	wl.pointer_set_cursor(
		s.pointer,
		serial,
		cursor.surface,
		c.int32_t(math.round(f32(cursor.hotspot.x) / s.scale)),
		c.int32_t(math.round(f32(cursor.hotspot.y) / s.scale)),
	)
}

wl_set_cursor :: proc(cursor: Cursor) {
	// Reject a stale handle, so a programming error leaves the cursor alone.
	if handle, is_custom := cursor.(Custom_Cursor); is_custom {
		if hm.get(&s.custom_cursors, handle) == nil {
			log.errorf("Trying to set invalid cursor %v. It may have been destroyed.", handle)
			return
		}
	}

	s.current_cursor = cursor
	wl_apply_cursor()
}

wl_standard_cursor_shape :: proc(standard: Standard_Cursor) -> wl.WP_Cursor_Shape {
	switch standard {
	case .Default:     return .Default
	case .Text:        return .Text
	case .Hand:        return .Pointer
	case .Crosshair:   return .Crosshair
	case .Wait:        return .Wait
	case .Progress:    return .Progress
	case .Resize_EW:   return .Ew_Resize
	case .Resize_NS:   return .Ns_Resize
	case .Resize_NESW: return .Nesw_Resize
	case .Resize_NWSE: return .Nwse_Resize
	case .Move:        return .Move
	case .Not_Allowed: return .Not_Allowed
	}

	return .Default
}

wl_destroy_custom_cursor :: proc(custom_cursor: Custom_Cursor) {
	cd := hm.get(&s.custom_cursors, custom_cursor)

	if cd == nil {
		log.errorf(
			"Trying to destroy invalid cursor %v. It may already be destroyed.",
			custom_cursor,
		)
		return
	}

	// Detach from the surface before the buffer and its memory go away.
	wl.wp_viewport_destroy(cd.viewport)
	wl.surface_destroy(cd.surface)
	wl.buffer_destroy(cd.buffer)
	linux.munmap(cd.data, uint(cd.data_size))
	hm.remove(&s.custom_cursors, custom_cursor)

	// Falls back to the default if that was the cursor on screen.
	wl_apply_cursor()
}

wl_set_internal_state :: proc(state: rawptr) {
	assert(state != nil)
	s = (^WL_State)(state)
}

WL_Cursor :: struct {
	handle: Custom_Cursor,
	surface: ^wl.Surface,
	hotspot: [2]int,

	// Size of the image in physical pixels.
	width: int,
	height: int,

	// The compositor may read from the buffer at any point while it is attached to the surface, so
	// the buffer and its mapping have to stay alive for as long as the cursor does.
	buffer: ^wl.Buffer,
	data: rawptr,
	data_size: int,

	// Scales the surface down from physical to logical pixels, see `wl_apply_cursor_scale`.
	viewport: ^wl.WP_Viewport,
	built_for_scale: f32,
}

WL_State :: struct {
	allocator: runtime.Allocator,

	screen_width: int,
	screen_height: int,

	// The last width/height we've gotten from wayland: Keeping this separate from screen_width and
	// screen_height simplifies state management a bit.
	last_configure_width: int,
	last_configure_height: int,
	last_configure_windowed_width: int,
	last_configure_windowed_height: int,

	events: [dynamic]Event,
	window_mode: Window_Mode,

	odin_ctx: runtime.Context,
	
	display: ^wl.Display,
	surface: ^wl.Surface,
	compositor: ^wl.Compositor,
	window: ^wl.EGL_Window,
	toplevel: ^wl.XDG_Toplevel,
	viewporter: ^wl.WP_Viewporter,
	viewport: ^wl.WP_Viewport,
	decoration_manager: ^wl.ZXDG_Decoration_Manager_V1,
	fractional_scale_manager: ^wl.WP_Fractional_Scale_Manager_V1,

	xdg_base: ^wl.XDG_WM_Base,
	seat: ^wl.Seat,
	scale: f32,

	keyboard: ^wl.Keyboard,
	pointer: ^wl.Pointer,
	pointer_enter_serial: u32,
	input_serial: u32,
	cursor_hidden: bool,
	shm: ^wl.SHM,
	data_device_manager: ^wl.Data_Device_Manager,
	data_device: ^wl.Data_Device,
	clipboard_offer: ^wl.Data_Offer,
	clipboard_pending_offer: ^wl.Data_Offer,
	clipboard_mime_offer: ^wl.Data_Offer,
	clipboard_mimes: [dynamic]string,
	clipboard_pending_mimes: [dynamic]string,
	clipboard_source: ^wl.Data_Source,
	clipboard_owned_text: []u8,
	cursor_surface: ^wl.Surface,
	cursor_theme: ^wl.Cursor_Theme,

	// Scales the theme cursor surface down to THEME_CURSOR_SIZE. See wl_load_cursor_theme and
	// wl_apply_cursor.
	cursor_viewport: ^wl.WP_Viewport,

	pointer_constraints: ^wl.ZWP_Pointer_Constraints_V1,
	relative_pointer_manager: ^wl.ZWP_Relative_Pointer_Manager_V1,
	locked_pointer: ^wl.ZWP_Locked_Pointer_V1,
	relative_pointer: ^wl.ZWP_Relative_Pointer_V1,

	custom_cursors: hm.Dynamic_Handle_Map(WL_Cursor, Custom_Cursor),

	// The cursor most recently passed to wl_set_cursor. The zero value is Standard_Cursor.Default.
	current_cursor: Cursor,

	cursor_shape_manager: ^wl.WP_Cursor_Shape_Manager_V1,
	cursor_shape_device:  ^wl.WP_Cursor_Shape_Device_V1,

	// True if toplevel_listener.configure has run
	configured: bool,

	window_render_glue: Window_Render_Glue,

	// Used to translate key presses into typed text, taking the current keyboard layout into
	// account. `xkb_keymap`/`xkb_state` are (re)created whenever the compositor sends us a new
	// keymap.
	xkb_context: ^xkb.Context,
	xkb_keymap: ^xkb.Keymap,
	xkb_state: ^xkb.State,

	// Key repeat is synthesized by us -- see `wl_get_events` -- since Wayland compositors don't
	// send repeat events themselves.
	repeat_rate: c.int32_t,
	repeat_delay: c.int32_t,
	repeat_key: Keyboard_Key,
	repeat_xkb_keycode: c.uint32_t,
	repeat_next_tick: time.Tick,
}

s: ^WL_State
