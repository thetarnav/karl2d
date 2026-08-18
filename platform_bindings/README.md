In these folders I put additional bindings that some platforms may need etc.

## Linux native requirements

The bindings under `linux/` are Linux-only. They require the native development
dependencies for the backend in use:

- **X11:** existing Xlib development headers and the Xlib library (`libX11`).
- **Wayland:** the Wayland client library and a compositor-provided
  `wl_data_device_manager` global.

Clipboard operations are serviced by Karl2D's normal event/update loop; keep
calling `update()` so native events can be dispatched while an operation is in
progress. Unsupported sessions return `false`.

Windows uses the native Win32 clipboard binding in `platform_windows.odin`;
it does not use these Linux X11 or Wayland bindings.
