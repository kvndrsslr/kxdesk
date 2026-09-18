// Platform layer for kxdesk.
//
// Everything that needs C, Objective-C or Mach lives here so that the Zig side
// stays pure logic. The thin mach transport wraps `vendor/sketchybar.h`, the
// upstream header from https://github.com/FelixKratz/SketchyBarHelper, which is
// compiled into this translation unit (the header only defines `static inline`
// functions, so including it here statically links it into the binary).
//
// The pieces not reused from that header are the server loop, which is
// rewritten around two names on one receive port, and the one-way post the
// daemon answers requests with. `sb_server_register()` and `sb_server_serve()`
// split `mach_server_begin()` in two so that the `mach_helper` property can be
// published after the service exists and before the loop starts.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/// Received block, valid only for the duration of the call: a NUL-separated
/// `key\0value\0...\0` event, a `CMD\0verb\0...` request, or SketchyBar's bare
/// `k` marker.
///
/// `reply_port` is where the sender expects an answer, and is 0 for SketchyBar's
/// one-way sends. The receive loop deallocates it as soon as the handler
/// returns, so a handler that answers from a worker task must first take a
/// reference with `sb_port_copy()`.
typedef void (*sb_handler)(const char* block, uint32_t reply_port);

/* -- mach transport ------------------------------------------------------- */

/// Resolve a bootstrap service to a send right, or 0. Each successful call
/// vends a new right: cache it and release it with `sb_port_release()`.
uint32_t sb_bootstrap_lookup(const char* name);

/// Release a right obtained from `sb_bootstrap_lookup()` or `sb_port_copy()`.
void sb_port_release(uint32_t port);

/// Register `name` in the bootstrap namespace. Returns the receive port or 0.
/// Must succeed before SketchyBar is told `mach_helper=<name>`.
uint32_t sb_server_register(const char* name);

/// Blocking event loop: receive, dispatch to `handler`, repeat. Never returns.
/// SketchyBar's `k` shutdown marker is handed to the handler like any other
/// block: by then the bar is gone, but the daemon outlives it, so ending the
/// process is the handler's business and not the loop's.
void sb_server_serve(uint32_t port, sb_handler handler);

/// Send a NUL-separated argument vector to a port, copying any response into
/// `out` (pass NULL to discard it). The buffer must end with two NUL bytes,
/// matching what the upstream header hands to SketchyBar.
///
/// Safe to call from several tasks at once: unlike the vendored header's
/// version, nothing here is shared between callers.
///
/// Returns the response length; -1 when the message could not be sent, and -2
/// when it was sent but nothing answered within `timeout_ms`.
int32_t sb_send(uint32_t port, const char* argv, size_t len, char* out, size_t cap,
                uint32_t timeout_ms);

/// Post a NUL-separated argument vector to a port without waiting for a reply.
/// This is how the daemon answers a request: SketchyBar's own sends work the
/// same way. `len` counts the trailing NUL bytes the receiver expects, and 0
/// is returned when the message was sent.
int32_t sb_post(uint32_t port, const char* argv, size_t len);

/// Take an extra reference to a send right, so that it outlives the mach
/// message that carried it: a request is answered from a worker task, long
/// after the receive loop destroyed the message whose `msgh_remote_port` names
/// the caller's response port. Release the reference with `sb_port_release()`.
/// Returns the port, or 0 when the reference could not be taken.
uint32_t sb_port_copy(uint32_t port);

/// Register an additional bootstrap name for a port that is already
/// registered, so that one receive port can serve two channels. Returns false
/// when the registration failed.
bool sb_server_publish(uint32_t port, const char* name);

/// Real user id of this process, for `launchctl` domain targets.
uint32_t sb_uid(void);


/* -- process execution ---------------------------------------------------- */

/// Run `argv` (NULL-terminated, `argv[0]` is a filesystem path) with stdout
/// captured into `out` and stderr discarded. Returns the total number of bytes
/// the child wrote - which may exceed `cap`, signalling truncation - or -1 if
/// the child could not be spawned. `out` is always NUL-terminated.
int64_t sb_exec_capture(const char* const argv[], char* out, size_t cap);

/// Run `argv` (NULL-terminated, `argv[0]` is a filesystem path) with its output
/// discarded and return its exit status. Returns -1 when the child could not be
/// spawned. Cheaper than capturing output for the many commands whose answer is
/// only their exit status.
int32_t sb_exec_status(const char* const argv[]);

/// Resolve an executable name to an absolute path, searching `PATH` followed by
/// the usual Homebrew prefixes. Returns false when it cannot be found.
bool sb_which(const char* name, char* out, size_t cap);

/// Copy environment variable `name` into `out`. Returns false when the variable
/// is unset, empty, or longer than `cap`.
bool sb_env(const char* name, char* out, size_t cap);

/// Filesystem path of the installed sketchybar-app-font, resolved through
/// CoreText so it is the same file the bar renders with. Returns false when the
/// font is not installed.
bool sb_app_font_path(char* out, size_t cap);

/* -- macOS platform services --------------------------------------------- */

/// Internal battery percentage and whether the machine is drawing from AC.
/// Returns false when there is no battery (desktop) or it cannot be read.
bool sb_battery(int32_t* percent, bool* charging);

/// Today's date icon (`%a %d. %b`) and the wall clock label (`%H:%M`),
/// formatted with the user's locale.
void sb_clock(char* icon, size_t icon_cap, char* label, size_t label_cap);

/// Compile a script for the named OSA language ("AppleScript" or "JavaScript")
/// and keep it resident. Returns NULL if that component is unavailable.
void* sb_osa_compile(const char* source, const char* language);

/// Run a compiled script. Its string result, if any, is copied into `out`;
/// pass a NULL `out` to just execute it. Returns false if the script errored.
bool sb_osa_run(void* script, char* out, size_t cap);

/// Open a URL with the user's default handler.
bool sb_open_url(const char* url);

/// Absolute path of this executable, for embedding in a `click_script`.
bool sb_self_path(char* out, size_t cap);
