package wayland

import "core:c"

WL_MIME_TEXT_PLAIN       :: "text/plain"
WL_MIME_TEXT_PLAIN_UTF8  :: "text/plain;charset=utf-8"
WL_MIME_TEXT_URI_LIST    :: "text/uri-list"
WL_MIME_TEXT_HTML        :: "text/html"

MIME_TEXT_PLAIN      :: WL_MIME_TEXT_PLAIN
MIME_TEXT_PLAIN_UTF8 :: WL_MIME_TEXT_PLAIN_UTF8
MIME_TEXT_URI_LIST   :: WL_MIME_TEXT_URI_LIST
MIME_TEXT_HTML       :: WL_MIME_TEXT_HTML

Data_Offer :: struct {
	using proxy: Proxy,
}

Data_Offer_Listener :: struct {
	offer:         proc "c" (data: rawptr, offer: ^Data_Offer, mime_type: cstring),
	source_actions: proc "c" (data: rawptr, offer: ^Data_Offer, source_actions: u32),
	action:         proc "c" (data: rawptr, offer: ^Data_Offer, dnd_action: u32),
}

data_offer_accept :: proc "c" (offer: ^Data_Offer, serial: u32, mime_type: cstring) {
	proxy_marshal_flags(offer, 0, nil, proxy_get_version(offer), 0, serial, mime_type)
}

data_offer_receive :: proc "c" (offer: ^Data_Offer, mime_type: cstring, fd: c.int32_t) {
	proxy_marshal_flags(offer, 1, nil, proxy_get_version(offer), 0, mime_type, fd)
}

data_offer_destroy :: proc "c" (offer: ^Data_Offer) {
	proxy_marshal_flags(offer, 2, nil, proxy_get_version(offer), MARSHAL_FLAG_DESTROY)
}

data_offer_finish :: proc "c" (offer: ^Data_Offer) {
	proxy_marshal_flags(offer, 3, nil, proxy_get_version(offer), 0)
}

data_offer_set_actions :: proc "c" (offer: ^Data_Offer, dnd_actions, preferred_action: u32) {
	proxy_marshal_flags(offer, 4, nil, proxy_get_version(offer), 0, dnd_actions, preferred_action)
}

data_offer_interface := Interface {
	"wl_data_offer",
	4,
	5,
	raw_data([]Message {
		{"accept", "us?s", raw_data([]^Interface{nil, nil, nil})},
		{"receive", "sh", raw_data([]^Interface{nil, nil})},
		{"destroy", "", raw_data([]^Interface{})},
		{"finish", "", raw_data([]^Interface{})},
		{"set_actions", "uu", raw_data([]^Interface{nil, nil})},
	}),
	3,
	raw_data([]Message {
		{"offer", "s", raw_data([]^Interface{nil})},
		{"source_actions", "u", raw_data([]^Interface{nil})},
		{"action", "u", raw_data([]^Interface{nil})},
	}),
}

Data_Source :: struct {
	using proxy: Proxy,
}

Data_Source_Listener :: struct {
	target:           proc "c" (data: rawptr, source: ^Data_Source, mime_type: cstring),
	send:             proc "c" (data: rawptr, source: ^Data_Source, mime_type: cstring, fd: c.int32_t),
	cancelled:        proc "c" (data: rawptr, source: ^Data_Source),
	dnd_drop_performed: proc "c" (data: rawptr, source: ^Data_Source),
	dnd_finished:     proc "c" (data: rawptr, source: ^Data_Source),
	action:           proc "c" (data: rawptr, source: ^Data_Source, dnd_action: u32),
}

data_source_offer :: proc "c" (source: ^Data_Source, mime_type: cstring) {
	proxy_marshal_flags(source, 0, nil, proxy_get_version(source), 0, mime_type)
}

data_source_destroy :: proc "c" (source: ^Data_Source) {
	proxy_marshal_flags(source, 1, nil, proxy_get_version(source), MARSHAL_FLAG_DESTROY)
}

data_source_set_actions :: proc "c" (source: ^Data_Source, dnd_actions: u32) {
	proxy_marshal_flags(source, 2, nil, proxy_get_version(source), 0, dnd_actions)
}

data_source_interface := Interface {
	"wl_data_source",
	4,
	3,
	raw_data([]Message {
		{"offer", "s", raw_data([]^Interface{nil})},
		{"destroy", "", raw_data([]^Interface{})},
		{"set_actions", "u", raw_data([]^Interface{nil})},
	}),
	6,
	raw_data([]Message {
		{"target", "?s", raw_data([]^Interface{nil})},
		{"send", "sh", raw_data([]^Interface{nil, nil})},
		{"cancelled", "", raw_data([]^Interface{})},
		{"dnd_drop_performed", "", raw_data([]^Interface{})},
		{"dnd_finished", "", raw_data([]^Interface{})},
		{"action", "u", raw_data([]^Interface{nil})},
	}),
}

Data_Device :: struct {
	using proxy: Proxy,
}

Data_Device_Listener :: struct {
	data_offer: proc "c" (data: rawptr, device: ^Data_Device, offer: ^Data_Offer),
	enter: proc "c" (
		data: rawptr,
		device: ^Data_Device,
		serial: u32,
		surface: ^Surface,
		x: Fixed,
		y: Fixed,
		offer: ^Data_Offer,
	),
	leave: proc "c" (data: rawptr, device: ^Data_Device),
	motion: proc "c" (data: rawptr, device: ^Data_Device, time: u32, x, y: Fixed),
	drop: proc "c" (data: rawptr, device: ^Data_Device),
	selection: proc "c" (data: rawptr, device: ^Data_Device, offer: ^Data_Offer),
}

data_device_start_drag :: proc "c" (
	device: ^Data_Device,
	source: ^Data_Source,
	origin: ^Surface,
	icon: ^Surface,
	serial: u32,
) {
	proxy_marshal_flags(device, 0, nil, proxy_get_version(device), 0, source, origin, icon, serial)
}

data_device_set_selection :: proc "c" (device: ^Data_Device, source: ^Data_Source, serial: u32) {
	proxy_marshal_flags(device, 1, nil, proxy_get_version(device), 0, source, serial)
}

data_device_release :: proc "c" (device: ^Data_Device) {
	proxy_marshal_flags(device, 2, nil, proxy_get_version(device), MARSHAL_FLAG_DESTROY)
}

data_device_interface := Interface {
	"wl_data_device",
	4,
	3,
	raw_data([]Message {
		{"start_drag", "?oo?ou", raw_data([]^Interface{&data_source_interface, &surface_interface, &surface_interface, nil})},
		{"set_selection", "?ou", raw_data([]^Interface{&data_source_interface, nil})},
		{"release", "", raw_data([]^Interface{})},
	}),
	6,
	raw_data([]Message {
		{"data_offer", "n", raw_data([]^Interface{&data_offer_interface})},
		{"enter", "uoff?o", raw_data([]^Interface{nil, &surface_interface, nil, nil, &data_offer_interface})},
		{"leave", "", raw_data([]^Interface{})},
		{"motion", "uff", raw_data([]^Interface{nil, nil, nil})},
		{"drop", "", raw_data([]^Interface{})},
		{"selection", "?o", raw_data([]^Interface{&data_offer_interface})},
	}),
}

Data_Device_Manager :: struct {
	using proxy: Proxy,
}

Data_Device_Manager_Listener :: struct {}

data_device_manager_create_data_source :: proc "c" (manager: ^Data_Device_Manager) -> ^Data_Source {
	return (^Data_Source)(proxy_marshal_flags(
		manager, 0, &data_source_interface, proxy_get_version(manager), 0, nil,
	))
}

data_device_manager_get_data_device :: proc "c" (
	manager: ^Data_Device_Manager,
	seat: ^Seat,
) -> ^Data_Device {
	return (^Data_Device)(proxy_marshal_flags(
		manager, 1, &data_device_interface, proxy_get_version(manager), 0, nil, seat,
	))
}

data_device_manager_release :: proc "c" (manager: ^Data_Device_Manager) {
	proxy_marshal_flags(manager, 2, nil, proxy_get_version(manager), MARSHAL_FLAG_DESTROY)
}

data_device_manager_interface := Interface {
	"wl_data_device_manager",
	4,
	3,
	raw_data([]Message {
		{"create_data_source", "n", raw_data([]^Interface{&data_source_interface})},
		{"get_data_device", "no", raw_data([]^Interface{&data_device_interface, &seat_interface})},
		{"release", "", raw_data([]^Interface{})},
	}),
	0,
	nil,
}

DATA_DEVICE_MANAGER_DND_ACTION_NONE :: 0
DATA_DEVICE_MANAGER_DND_ACTION_COPY :: 1
DATA_DEVICE_MANAGER_DND_ACTION_MOVE :: 2
DATA_DEVICE_MANAGER_DND_ACTION_ASK  :: 4
