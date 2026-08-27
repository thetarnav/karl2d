// Clipboard example: set and get clipboard text.
//
// Press 1-4 to set predefined texts. The current clipboard contents are polled and shown
// each frame. On Wayland the window must have keyboard focus for the clipboard to work.
package karl2d_clipboard_example

import k2 "../.."
import "core:fmt"

last_set_ok: bool
last_set_label: string

init :: proc() {
	k2.init(720, 720, "Karl2D Clipboard")
}

step :: proc() -> bool {

	k2.update() or_return

	if k2.key_went_down(.N1) {
		last_set_ok = k2.set_clipboard_text("Hello from Karl2D!")
		last_set_label = "Hello from Karl2D!"
	}

	if k2.key_went_down(.N2) {
		last_set_ok = k2.set_clipboard_text("héllo 世界 🎮")
		last_set_label = "héllo 世界 🎮"
	}

	if k2.key_went_down(.N3) {
		last_set_ok = k2.set_clipboard_text("The quick brown fox jumps over the lazy dog")
		last_set_label = "The quick brown fox..."
	}

	if k2.key_went_down(.N4) {
		last_set_ok = k2.set_clipboard_text("")
		last_set_label = "(empty)"
	}

	k2.clear(k2.LIGHT_BLUE)

	y: f32 = 20

	k2.draw_text("Clipboard Example", {20, y}, 40, k2.DARK_BLUE)
	y += 60

	k2.draw_text("Press 1: Set \"Hello from Karl2D!\"", {20, y}, 28, k2.BLACK)
	y += 35
	k2.draw_text("Press 2: Set \"héllo 世界 🎮\"", {20, y}, 28, k2.BLACK)
	y += 35
	k2.draw_text("Press 3: Set \"The quick brown fox...\"", {20, y}, 28, k2.BLACK)
	y += 35
	k2.draw_text("Press 4: Set empty string", {20, y}, 28, k2.BLACK)
	y += 50

	// Poll the clipboard contents every frame.
	text, ok := k2.get_clipboard_text(context.temp_allocator)

	if ok {
		display := text
		if len(display) == 0 {
			display = "(empty)"
		}
		k2.draw_text(fmt.tprintf("Clipboard: \"%s\"", display), {20, y}, 28, k2.DARK_GREEN)
	} else {
		k2.draw_text("Clipboard: (unavailable)", {20, y}, 28, k2.DARK_RED)
	}
	y += 50

	if len(last_set_label) > 0 {
		k2.draw_text(
			fmt.tprintf("Last set: \"%s\" -> %v", last_set_label, last_set_ok),
			{20, y}, 24, k2.DARK_GRAY,
		)
	}

	k2.present()
	free_all(context.temp_allocator)
	return true
}

shutdown :: proc() {
	k2.shutdown()
}

main :: proc() {
	init()
	for step() {}
	shutdown()
}
