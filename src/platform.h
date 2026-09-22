// Platform layer for kxdesk: everything that needs C, Objective-C or Mach, so the
// Zig side stays pure logic. The thin mach transport wraps `vendor/sketchybar.h`
// (the upstream header from https://github.com/FelixKratz/SketchyBarHelper, whose
// `static inline` functions are compiled into this translation unit).
//
// `kx_server_register()` and `kx_server_serve()` split its `mach_server_begin()` in
// two, so the `mach_helper` property can be published after the service exists and
// before the loop starts; the server loop itself is rewritten around two names on
// one receive port.

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
/// reference with `kx_port_copy()`.
typedef void (*kx_handler)(const char* block, uint32_t reply_port);

/// Work the loop has to do on a clock rather than on a message, with the wait
/// that follows it: called before the loop blocks, and again after every wait
/// that elapses. Returns how many milliseconds the loop may block for - or 0 for
/// "nothing scheduled, block until a message arrives", which is what a daemon
/// with no timer running wants and what it costs when idle.
typedef uint32_t (*kx_timer)(void);

/// Resolve a bootstrap service to a send right, or 0. Each successful call
/// vends a new right: cache it and release it with `kx_port_release()`.
uint32_t kx_bootstrap_lookup(const char* name);

/// Release a right obtained from `kx_bootstrap_lookup()` or `kx_port_copy()`.
void kx_port_release(uint32_t port);

/// Register `name` in the bootstrap namespace. Returns the receive port or 0.
/// Must succeed before SketchyBar is told `mach_helper=<name>`.
uint32_t kx_server_register(const char* name);

/// Serve until the process ends: receive, dispatch to `handler`, repeat. Never
/// returns; `timer` is the only thing that ever makes the loop wake up on its own.
/// SketchyBar's `k` shutdown marker arrives as an ordinary block, and ending the
/// process on it is the handler's business rather than the loop's - by then the
/// bar is gone, but the daemon outlives it.
void kx_server_serve(uint32_t port, kx_handler handler, kx_timer timer);

/// Send a NUL-separated argument vector to a port, copying any response into
/// `out` (pass NULL to discard it). The buffer must end with two NUL bytes,
/// matching what the upstream header hands to SketchyBar.
///
/// Safe to call from several tasks at once: unlike the vendored header's
/// version, nothing here is shared between callers.
///
/// Returns the response length; -1 when the message could not be sent, and -2
/// when it was sent but nothing answered within `timeout_ms`.
int32_t kx_send(uint32_t port, const char* argv, size_t len, char* out, size_t cap,
                uint32_t timeout_ms);

/// Post a NUL-separated argument vector to a port without waiting for a reply.
/// This is how the daemon answers a request: SketchyBar's own sends work the
/// same way. `len` counts the trailing NUL bytes the receiver expects, and 0
/// is returned when the message was sent.
int32_t kx_post(uint32_t port, const char* argv, size_t len);

/// Take an extra reference to a send right, so that it outlives the mach
/// message that carried it: a request is answered from a worker task, long
/// after the receive loop destroyed the message whose `msgh_remote_port` names
/// the caller's response port. Release the reference with `kx_port_release()`.
/// Returns the port, or 0 when the reference could not be taken.
uint32_t kx_port_copy(uint32_t port);

/// Register an additional bootstrap name for a port that is already
/// registered, so that one receive port can serve two channels. Returns false
/// when the registration failed.
bool kx_server_publish(uint32_t port, const char* name);

/// Real user id of this process, for `launchctl` domain targets.
uint32_t kx_uid(void);

/// Run `argv` (NULL-terminated, `argv[0]` is a filesystem path) with stdout
/// captured into `out` and stderr discarded. Returns the total number of bytes
/// the child wrote - which may exceed `cap`, signalling truncation - or -1 if
/// the child could not be spawned. `out` is always NUL-terminated.
int64_t kx_exec_capture(const char* const argv[], char* out, size_t cap);

/// Run `argv` (NULL-terminated, `argv[0]` is a filesystem path) with its output
/// discarded and return its exit status. Returns -1 when the child could not be
/// spawned. Cheaper than capturing output for the many commands whose answer is
/// only their exit status.
int32_t kx_exec_status(const char* const argv[]);

/// Run `argv` (NULL-terminated, `argv[0]` is a filesystem path) detached from
/// this process: a session of its own, so launchd's process-group cleanup does
/// not reach it and it outlives the daemon that started it, and its standard
/// streams on `/dev/null`, since nobody is left to read them.
///
/// Returns the child's pid, or -1 when it could not be spawned. The child is
/// never waited for: this is for the helper daemons a command starts - the
/// ssh-agent of server mode - and not for commands.
int32_t kx_spawn_detached(const char* const argv[]);

/// Resolve an executable name to an absolute path, searching `PATH` followed by
/// the usual Homebrew prefixes. Returns false when it cannot be found.
bool kx_which(const char* name, char* out, size_t cap);

/// Copy environment variable `name` into `out`. Returns false when the variable
/// is unset, empty, or longer than `cap`.
bool kx_env(const char* name, char* out, size_t cap);

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
int64_t kx_socket_message(
    const char* path,
    const void* request,
    size_t request_size,
    char* out,
    size_t cap
);

/// Send one message to a unix stream socket and read the reply up to a
/// terminator, for a peer that answers and stays connected.
///
/// `request_size` bytes of `request` are written in full, then the reply is read
/// into `out` until the `terminator_size` bytes of `terminator` have arrived, or
/// `timeout_ms` has gone by, or the peer closed first. `out` is always
/// NUL-terminated. This is `kx_socket_message` above for the peer that does not
/// close after answering - kitty keeps its remote control connection open, so
/// waiting for end of file would wait for a close that never comes.
///
/// Returns the number of reply bytes, which is 0 for a peer that answered
/// nothing, or -1 when the socket could not be opened, connected, written to or
/// read, or when nothing arrived before the timeout. Exactly `cap` bytes means
/// the reply did not fit and was cut, which is a reply this cannot use.
int64_t kx_unix_reply(
    const char* path,
    const void* request,
    size_t request_size,
    const void* terminator,
    size_t terminator_size,
    char* out,
    size_t cap,
    uint32_t timeout_ms
);

/// Connect to `host`:`port` over TCP and keep the descriptor, for a channel
/// that stays open. `kx_socket_message` above is one message and gone, which is
/// what yabai wants and the opposite of what kanata's server is: it broadcasts
/// its events to whoever is connected, whenever they happen.
///
/// `host` is an IPv4 literal or a name the resolver answers without a round
/// trip; the channel is a loopback one in practice.
///
/// The descriptor has `SO_NOSIGPIPE` set, like the unix socket above and for
/// the same reason: a peer that goes away must fail the read rather than kill
/// the daemon.
///
/// Returns the descriptor, or -1 when it could not be opened or connected -
/// the ordinary answer while the peer is not running yet, and the caller's cue
/// to try again.
int32_t kx_tcp_connect(const char* host, uint16_t port);

/// Read up to `cap` bytes from a descriptor `kx_tcp_connect` returned.
///
/// Returns the number of bytes read, 0 when the peer closed the connection, or
/// -1 on a read error. Blocks until one of those three happens: the caller is a
/// thread of its own, and a peer that goes away closes the socket, so there is
/// nothing here to time out on.
int64_t kx_tcp_read(int32_t fd, char* out, size_t cap);

/// Write all of `buffer` to a descriptor `kx_tcp_connect` returned.
///
/// Returns true when every byte went out, false when the peer went away first.
/// A short write is a failure rather than a partial success: kanata reads
/// newline-delimited JSON, and half a line is not a message. Blocks like the
/// read above, and for the same reason - a loopback peer that accepts the
/// connection accepts the message.
bool kx_tcp_write(int32_t fd, const void* buffer, size_t len);

/// Close a descriptor from `kx_tcp_connect`.
void kx_tcp_close(int32_t fd);

/// Filesystem path of the installed sketchybar-app-font, resolved through
/// CoreText so it is the same file the bar renders with. Returns false when the
/// font is not installed.
bool kx_app_font_path(char* out, size_t cap);

/// Internal battery percentage and whether the machine is drawing from AC.
/// Returns false when there is no battery (desktop) or it cannot be read.
bool kx_battery(int32_t* percent, bool* charging);

/// Today's date icon (`%a %d. %b`) and the wall clock label (`%H:%M`),
/// formatted with the user's locale.
void kx_clock(char* icon, size_t icon_cap, char* label, size_t label_cap);

/// The share of CPU time that was not idle since the previous call, as a
/// fraction of one. The first call has nothing to compare against and answers
/// zero.
double kx_cpu_load(void);

/// The share of the GPU the accelerator reports as busy, as a fraction of one -
/// zero when there is no accelerator to ask, as on a machine without one.
double kx_gpu_load(void);

/// Cumulative bytes the machine's links have received and transmitted, summed
/// over the interfaces that carry the user's traffic: loopback, the tunnels and
/// bridges that run over an already-counted link, and the radio's peer-to-peer
/// interfaces are left out, so that nothing is counted twice - and `awdl0` in
/// particular reports bursts that never left the machine.
///
/// The counters are cumulative, so they only mean anything as a difference
/// between two readings. Returns false when the interface list could not be
/// read.
bool kx_net_bytes(uint64_t* received, uint64_t* sent);

/// The link the machine is on, for the bar's link icon.
enum {
  /// No primary interface: nothing is connected.
  KX_NET_LINK_DISCONNECTED = 0,
  KX_NET_LINK_WIFI = 1,
  KX_NET_LINK_WIRED = 2,
};

/// Which of those the machine is on, from the system's own record of the primary
/// interface and the kernel's record of its media. No packet is sent and no
/// permission is asked for.
uint8_t kx_net_link(void);

/// Whether the system appearance is dark, read from the preference the system
/// records it in. Needs no Apple Event, so it needs no permission.
bool kx_dark_mode(void);

/// Open a URL with the user's default handler.
bool kx_open_url(const char* url);

/// Put `text` on the general pasteboard, replacing what was on it. Returns
/// false when the pasteboard could not be written - which is a pasteboard
/// problem, not a text one: the caller's text is already UTF-8 and NUL
/// terminated.
bool kx_clipboard_set(const char* text);
