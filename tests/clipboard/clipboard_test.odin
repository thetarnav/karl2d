// Round-trip checks for the clipboard API.
//
// These tests open a window, so they only run where one can be created. Run with:
// odin test tests/clipboard -define:KARL2D_RENDER_BACKEND=nil -define:KARL2D_AUDIO_BACKEND=nil -define:ODIN_TEST_THREADS=1
package karl2d_clipboard_test

import k2 "../.."
import "base:runtime"
import "core:sync"
import "core:testing"

stable_allocator: runtime.Allocator
state: ^k2.State
setup_once: sync.Once

setup :: proc() {
	sync.once_do(&setup_once, proc() {
		stable_allocator = runtime.heap_allocator()
		context.allocator = stable_allocator

		state = k2.init(
			1280,
			720,
			"karl2d clipboard tests",
			allocator = stable_allocator,
		)

		// On Wayland the clipboard needs an input serial, which arrives via the keyboard
		// enter event when the window receives focus. Pump a few frames so that event is
		// processed before the tests touch the clipboard.
		for _ in 0..<10 {
			if !k2.update() {
				break
			}
		}
	})
}

//-------//
// TESTS //
//-------//

@(test)
set_and_get_clipboard_text_round_trips :: proc(t: ^testing.T) {
	setup()

	set_ok := k2.set_clipboard_text("Hello clipboard!")
	if !testing.expect(t, set_ok, "set_clipboard_text returned false") {
		return
	}

	text, get_ok := k2.get_clipboard_text(stable_allocator)
	if !testing.expect(t, get_ok, "get_clipboard_text returned false") {
		return
	}

	testing.expectf(t, text == "Hello clipboard!",
		"expected 'Hello clipboard!', got '%s'", text,
	)

	delete(text, stable_allocator)
}

@(test)
empty_string_round_trips :: proc(t: ^testing.T) {
	setup()

	set_ok := k2.set_clipboard_text("")
	if !testing.expect(t, set_ok, "set_clipboard_text returned false for empty string") {
		return
	}

	text, get_ok := k2.get_clipboard_text(stable_allocator)
	if !testing.expect(t, get_ok, "get_clipboard_text returned false for empty string") {
		return
	}

	testing.expectf(t, text == "", "expected empty string, got '%s'", text)

	delete(text, stable_allocator)
}

@(test)
unicode_text_round_trips :: proc(t: ^testing.T) {
	setup()

	// A mix of ASCII, Latin-1 supplement, CJK and emoji. All valid UTF-8.
	input := "héllo 世界 🎮"
	set_ok := k2.set_clipboard_text(input)
	if !testing.expect(t, set_ok, "set_clipboard_text returned false for unicode text") {
		return
	}

	text, get_ok := k2.get_clipboard_text(stable_allocator)
	if !testing.expect(t, get_ok, "get_clipboard_text returned false for unicode text") {
		return
	}

	testing.expectf(t, text == input, "expected '%s', got '%s'", input, text)

	delete(text, stable_allocator)
}

@(test)
set_twice_keeps_the_latest :: proc(t: ^testing.T) {
	setup()

	set_ok := k2.set_clipboard_text("first")
	if !testing.expect(t, set_ok, "set_clipboard_text returned false for 'first'") {
		return
	}

	set_ok = k2.set_clipboard_text("second")
	if !testing.expect(t, set_ok, "set_clipboard_text returned false for 'second'") {
		return
	}

	text, get_ok := k2.get_clipboard_text(stable_allocator)
	if !testing.expect(t, get_ok, "get_clipboard_text returned false") {
		return
	}

	testing.expectf(t, text == "second", "expected 'second', got '%s'", text)

	delete(text, stable_allocator)
}
