#+build linux

// Minimal X11 bindings for clipboard selection ownership and transfer.
package x11_clipboard

import X "vendor:x11/xlib"

foreign import x11 "system:X11"

// Xlib event and property constants needed by clipboard clients.
CURRENT_TIME      :: X.Time(X.CurrentTime)
NONE              :: X.XID(X.None)
ANY_PROPERTY_TYPE :: X.Atom(X.AnyPropertyType)
PROP_MODE_REPLACE :: i32(X.PropModeReplace)
PROPERTY_NOTIFY   :: X.EventType(.PropertyNotify)
SELECTION_CLEAR   :: X.EventType(.SelectionClear)
SELECTION_REQUEST :: X.EventType(.SelectionRequest)
SELECTION_NOTIFY  :: X.EventType(.SelectionNotify)

// Predefined atoms from X11/Xatom.h.
XA_PRIMARY   :: X.Atom(1)
XA_SECONDARY :: X.Atom(2)
XA_ATOM      :: X.Atom(4)
XA_STRING    :: X.Atom(31)
XA_CARDINAL  :: X.Atom(6)

@(default_calling_convention = "c")
foreign x11 {
	// Atom lookup.
	XInternAtom :: proc(display: ^X.Display, name: cstring, only_if_exists: b32) -> X.Atom ---

	// Selection ownership and transfer.
	XSetSelectionOwner :: proc(
		display:   ^X.Display,
		selection: X.Atom,
		owner:     X.Window,
		time:      X.Time,
	) ---
	XGetSelectionOwner :: proc(display: ^X.Display, selection: X.Atom) -> X.Window ---
	XConvertSelection :: proc(
		display:   ^X.Display,
		selection: X.Atom,
		target:    X.Atom,
		property:  X.Atom,
		requestor: X.Window,
		time:      X.Time,
	) ---

	// Window properties carry clipboard payloads and TARGETS responses.
	XGetWindowProperty :: proc(
		display:       ^X.Display,
		window:        X.Window,
		property:      X.Atom,
		long_offset:   int,
		long_length:   int,
		delete:        b32,
		req_type:      X.Atom,
		actual_type:   ^X.Atom,
		actual_format: ^i32,
		nitems:        ^uint,
		bytes_after:   ^uint,
		prop:          ^rawptr,
	) -> i32 ---
	XChangeProperty :: proc(
		display:   ^X.Display,
		window:    X.Window,
		property:  X.Atom,
		type:      X.Atom,
		format:    i32,
		mode:      i32,
		data:      rawptr,
		nelements: i32,
	) -> i32 ---
	XDeleteProperty :: proc(display: ^X.Display, window: X.Window, property: X.Atom) -> i32 ---

	// Selection replies are sent as ordinary X events.
	XSendEvent :: proc(
		display:    ^X.Display,
		window:     X.Window,
		propagate:  b32,
		event_mask: X.EventMask,
		event:      ^X.XEvent,
	) -> X.Status ---
	XFlush :: proc(display: ^X.Display) -> i32 ---
	XPending :: proc(display: ^X.Display) -> i32 ---
}
