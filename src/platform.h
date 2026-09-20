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

/// Work the loop has to do on a clock rather than on a message, with the wait
/// that follows it: called before the loop blocks, and again after every wait
/// that elapses. Returns how many milliseconds the loop may block for - or 0 for
/// "nothing scheduled, block until a message arrives", which is what a daemon
/// with no timer running wants and what it costs when idle.
typedef uint32_t (*sb_timer)(void);

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
/// Serve until the process ends. `timer` may be NULL, and is the only thing that
/// ever makes this loop wake up on its own.
void sb_server_serve(uint32_t port, sb_handler handler, sb_timer timer);

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

/// Run `argv` (NULL-terminated, `argv[0]` is a filesystem path) detached from
/// this process: a session of its own, so launchd's process-group cleanup does
/// not reach it and it outlives the daemon that started it, and its standard
/// streams on `/dev/null`, since nobody is left to read them.
///
/// Returns the child's pid, or -1 when it could not be spawned. The child is
/// never waited for: this is for the helper daemons a command starts - the
/// ssh-agent of server mode - and not for commands.
int32_t sb_spawn_detached(const char* const argv[]);

/// Resolve an executable name to an absolute path, searching `PATH` followed by
/// the usual Homebrew prefixes. Returns false when it cannot be found.
bool sb_which(const char* name, char* out, size_t cap);

/// Copy environment variable `name` into `out`. Returns false when the variable
/// is unset, empty, or longer than `cap`.
bool sb_env(const char* name, char* out, size_t cap);

/* -- unix sockets --------------------------------------------------------- */

/// Send one message to a unix stream socket and read its reply.
///
/// `request_size` bytes of `request` are written in full, then the write side is
/// shut down; the reply is read until the peer closes, into `out`, which is
/// always NUL-terminated.
///
/// Returns the number of reply bytes, which is 0 for a peer that answers
/// nothing, or -1 when the socket could not be opened, connected, written to or
/// read. Exactly `cap` bytes means the reply did not fit, and is the caller's
/// signal to grow the buffer and ask again - the same convention the captured
/// output of a spawned process follows.
int64_t sb_socket_message(
    const char* path,
    const void* request,
    size_t request_size,
    char* out,
    size_t cap
);

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

/// The share of CPU time that was not idle since the previous call, as a
/// fraction of one. The first call has nothing to compare against and answers
/// zero.
double sb_cpu_load(void);

/// The share of the GPU the accelerator reports as busy, as a fraction of one -
/// zero when there is no accelerator to ask, as on a machine without one.
double sb_gpu_load(void);

/// Cumulative bytes the machine's links have received and transmitted, summed
/// over the interfaces that carry the user's traffic: loopback, the tunnels and
/// bridges that run over an already-counted link, and the radio's peer-to-peer
/// interfaces are left out, so that nothing is counted twice - and `awdl0` in
/// particular reports bursts that never left the machine.
///
/// The counters are cumulative, so they only mean anything as a difference
/// between two readings. Returns false when the interface list could not be
/// read.
bool sb_net_bytes(uint64_t* received, uint64_t* sent);

/// The link the machine is on, for the bar's link icon.
enum {
  /// No primary interface: nothing is connected.
  SB_NET_LINK_DISCONNECTED = 0,
  SB_NET_LINK_WIFI = 1,
  SB_NET_LINK_WIRED = 2,
};

/// Which of those the machine is on, from the system's own record of the primary
/// interface and the kernel's record of its media. No packet is sent and no
/// permission is asked for.
uint8_t sb_net_link(void);

/// Whether the system appearance is dark, read from the preference the system
/// records it in. Needs no Apple Event, so it needs no permission.
bool sb_dark_mode(void);

/// Open a URL with the user's default handler.
bool sb_open_url(const char* url);
