#import <AppKit/AppKit.h>

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioHardwareTapping.h>
#include <CoreAudio/CATapDescription.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <bootstrap.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/message.h>
#include <math.h>
#include <net/if.h>
#include <net/if_media.h>
#include <net/route.h>
#include <netdb.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char** environ;

#include "platform.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#include "sketchybar.h"
#pragma clang diagnostic pop

uint32_t kx_bootstrap_lookup(const char* name) {
  mach_port_t bs_port;
  if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bs_port) != KERN_SUCCESS) {
    return 0;
  }

  mach_port_t port;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (bootstrap_look_up(bs_port, name, &port) != KERN_SUCCESS) {
    return 0;
  }
#pragma clang diagnostic pop

  return (uint32_t)port;
}

void kx_port_release(uint32_t port) {
  if (port) mach_port_deallocate(mach_task_self(), (mach_port_t)port);
}

uint32_t kx_server_register(const char* name) {
  mach_port_name_t task = mach_task_self();

  mach_port_t port;
  if (mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &port) != KERN_SUCCESS) {
    return 0;
  }

  struct mach_port_limits limits = { .mpl_qlimit = MACH_PORT_QLIMIT_LARGE };
  if (mach_port_set_attributes(task,
                               port,
                               MACH_PORT_LIMITS_INFO,
                               (mach_port_info_t)&limits,
                               MACH_PORT_LIMITS_INFO_COUNT) != KERN_SUCCESS) {
    return 0;
  }

  if (mach_port_insert_right(task, port, port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
    return 0;
  }

  mach_port_t bs_port;
  if (task_get_special_port(task, TASK_BOOTSTRAP_PORT, &bs_port) != KERN_SUCCESS) {
    return 0;
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (bootstrap_register(bs_port, (char*)name, port) != KERN_SUCCESS) {
    return 0;
  }
#pragma clang diagnostic pop

  return (uint32_t)port;
}

bool kx_server_publish(uint32_t port, const char* name) {
  if (!port || !name) return false;

  mach_port_t bs_port;
  if (task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bs_port) != KERN_SUCCESS) {
    return false;
  }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  kern_return_t rc = bootstrap_register(bs_port, (char*)name, (mach_port_t)port);
#pragma clang diagnostic pop
  return rc == KERN_SUCCESS;
}

uint32_t kx_uid(void) {
  return (uint32_t)getuid();
}

bool kx_self_path(char* out, size_t cap) {
  if (!out || cap == 0) return false;
  uint32_t size = (uint32_t)cap;
  if (_NSGetExecutablePath(out, &size) != 0) return false;
  out[cap - 1] = '\0';
  return true;
}

/// Receive one message, waiting at most `timeout_ms` milliseconds; false when the
/// wait elapsed instead, in which case no message was received and there is nothing
/// to destroy. This is the vendored `mach_receive_message` with a caller-chosen
/// timeout (its own is fixed at a second), and the buffer is zeroed first, as there,
/// so a failed receive leaves `address` NULL rather than stale.
static bool kx_server_receive(uint32_t port, struct mach_buffer* buffer,
                              uint32_t timeout_ms) {
  *buffer = (struct mach_buffer) { 0 };

  mach_msg_return_t rc = mach_msg(&buffer->message.header,
                                  MACH_RCV_MSG | (timeout_ms ? MACH_RCV_TIMEOUT : 0),
                                  0,
                                  sizeof(struct mach_buffer),
                                  (mach_port_t)port,
                                  timeout_ms ? (mach_msg_timeout_t)timeout_ms
                                             : MACH_MSG_TIMEOUT_NONE,
                                  MACH_PORT_NULL                  );

  if (rc != MACH_MSG_SUCCESS) {
    buffer->message.descriptor.address = NULL;
    return false;
  }

  return true;
}

void kx_server_serve(uint32_t port, kx_handler handler, kx_timer timer) {
  // A receive that blocks until a message arrives or the timer says it has
  // something to do; with no timer running the wait is infinite, so an idle daemon
  // wakes for nothing at all. SketchyBar's `k` shutdown marker arrives as an
  // ordinary 2-byte block and is handed to the handler, which records that the bar
  // is gone - not a reason to exit, since this process outlives the bar.
  struct mach_buffer buffer;
  for (;;) {
    // Asked before the wait rather than after it, so the timer's own work - and
    // anything it has to show - happens before the loop commits to blocking.
    uint32_t wait_ms = timer ? timer() : 0;

    if (!kx_server_receive(port, &buffer, wait_ms)) continue;

    const char* env = buffer.message.descriptor.address;
    if (!env) continue;

    handler(env, (uint32_t)buffer.message.header.msgh_remote_port);
    mach_msg_destroy(&buffer.message.header);
  }
}

int32_t kx_post(uint32_t port, const char* argv, size_t len) {
  if (!port || !argv) return -1;

  // The one-way half of the vendored header's send: no response port is named,
  // so the receiver's `msgh_remote_port` comes back as MACH_PORT_NULL and the
  // reply rules in `control.zig` know there is nowhere to answer.
  struct mach_message msg = { 0 };
  msg.header.msgh_remote_port = (mach_port_t)port;
  msg.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND
                                            & MACH_MSGH_BITS_REMOTE_MASK,
                                            0,
                                            0,
                                            MACH_MSGH_BITS_COMPLEX       );
  msg.header.msgh_size = sizeof(struct mach_message);
  msg.msgh_descriptor_count = 1;
  msg.descriptor.address = (void*)argv;
  msg.descriptor.size = (mach_msg_size_t)len;
  msg.descriptor.copy = MACH_MSG_VIRTUAL_COPY;
  msg.descriptor.deallocate = false;
  msg.descriptor.type = MACH_MSG_OOL_DESCRIPTOR;

  mach_msg_return_t rc = mach_msg(&msg.header,
                                  MACH_SEND_MSG,
                                  sizeof(struct mach_message),
                                  0,
                                  MACH_PORT_NULL,
                                  MACH_MSG_TIMEOUT_NONE,
                                  MACH_PORT_NULL                  );
  return rc == KERN_SUCCESS ? 0 : -1;
}

uint32_t kx_port_copy(uint32_t port) {
  if (!port) return 0;

  // A reference, rather than a second name: the send right is already in this
  // task under this name, and the receive loop's `mach_msg_destroy` will
  // deallocate one reference to it as soon as the handler returns.
  if (mach_port_mod_refs(mach_task_self(), (mach_port_t)port,
                         MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) {
    return 0;
  }

  return port;
}

int32_t kx_send(uint32_t port, const char* argv, size_t len, char* out, size_t cap,
                uint32_t timeout_ms) {
  if (!port) return -1;

  // This is the vendored header's send, written out so that nothing is shared
  // between callers: the header keeps the response in a static buffer, and
  // serialising that under a lock would let one slow response - SketchyBar
  // applies messages on its own thread - hold up every other sender.
  mach_port_name_t task = mach_task_self();
  mach_port_t response_port = MACH_PORT_NULL;
  if (mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &response_port) != KERN_SUCCESS) return -1;
  if (mach_port_insert_right(task, response_port, response_port,
                             MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
    mach_port_mod_refs(task, response_port, MACH_PORT_RIGHT_RECEIVE, -1);
    return -1;
  }

  struct mach_message msg = { 0 };
  msg.header.msgh_remote_port = (mach_port_t)port;
  msg.header.msgh_local_port = response_port;
  msg.header.msgh_id = response_port;
  msg.header.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND,
                                            MACH_MSG_TYPE_MAKE_SEND,
                                            0,
                                            MACH_MSGH_BITS_COMPLEX       );
  msg.header.msgh_size = sizeof(struct mach_message);
  msg.msgh_descriptor_count = 1;
  msg.descriptor.address = (void*)argv;
  msg.descriptor.size = (mach_msg_size_t)len;
  msg.descriptor.copy = MACH_MSG_VIRTUAL_COPY;
  msg.descriptor.deallocate = false;
  msg.descriptor.type = MACH_MSG_OOL_DESCRIPTOR;

  int32_t written = -1;
  if (mach_msg(&msg.header, MACH_SEND_MSG, sizeof(struct mach_message), 0,
               MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL) == KERN_SUCCESS) {
    struct mach_buffer buffer = { 0 };
    mach_msg_return_t received = mach_msg(&buffer.message.header,
                                          MACH_RCV_MSG | MACH_RCV_TIMEOUT,
                                          0,
                                          sizeof(struct mach_buffer),
                                          response_port,
                                          timeout_ms,
                                          MACH_PORT_NULL               );
    // -1 says the message was never sent, -2 says it was sent but this long
    // went by without an answer. The daemon answers from a worker task, so the
    // two are different failures and the caller reports them differently.
    written = -2;
    if (received == MACH_MSG_SUCCESS && buffer.message.descriptor.address) {
      const char* response = (const char*)buffer.message.descriptor.address;

      // The reply is a block, not a C string: SketchyBar answers with JSON and
      // the daemon answers with `OK\0<payload>`, so the whole thing has to be
      // copied and only the terminating NUL dropped. Going through `strlen`
      // would stop at the tag of a framed reply.
      size_t length = (size_t)buffer.message.descriptor.size;
      while (length > 0 && response[length - 1] == '\0') length--;

      if (out && cap > 0) {
        size_t copied = length < cap - 1 ? length : cap - 1;
        memcpy(out, response, copied);
        out[copied] = '\0';
      }
      written = (int32_t)length;
      mach_msg_destroy(&buffer.message.header);
    }
  }

  mach_port_mod_refs(task, response_port, MACH_PORT_RIGHT_RECEIVE, -1);
  mach_port_deallocate(task, response_port);
  return written;
}

int64_t kx_exec_capture(const char* const argv[], char* out, size_t cap) {
  if (cap == 0) return -1;

  int fds[2];
  if (pipe(fds) != 0) return -1;

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addclose(&actions, fds[0]);
  posix_spawn_file_actions_addclose(&actions, fds[1]);

  pid_t pid = 0;
  int rc = posix_spawn(&pid, argv[0], &actions, NULL, (char* const*)argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  close(fds[1]);

  if (rc != 0) {
    close(fds[0]);
    return -1;
  }

  int64_t total = 0;
  for (;;) {
    char scratch[16384];
    ssize_t n = read(fds[0], scratch, sizeof(scratch));
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (n == 0) break;

    if ((size_t)total < cap) {
      size_t take = cap - (size_t)total;
      if (take > (size_t)n) take = (size_t)n;
      memcpy(out + total, scratch, take);
    }
    total += n;
  }
  close(fds[0]);

  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }

  out[(size_t)total < cap ? (size_t)total : cap - 1] = '\0';
  return total;
}

int32_t kx_exec_status(const char* const argv[]) {
  if (!argv || !argv[0]) return -1;

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
  posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);

  pid_t pid = 0;
  int rc = posix_spawn(&pid, argv[0], &actions, NULL, (char* const*)argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  if (rc != 0) return -1;

  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }

  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return -1;
}

int32_t kx_spawn_detached(const char* const argv[]) {
  if (!argv || !argv[0]) return -1;

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  for (int fd = STDIN_FILENO; fd <= STDERR_FILENO; ++fd) {
    posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0);
  }

  posix_spawnattr_t attributes;
  posix_spawnattr_init(&attributes);
  posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSID);

  pid_t pid = 0;
  int rc = posix_spawn(&pid, argv[0], &actions, &attributes, (char* const*)argv, environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions);
  if (rc != 0) return -1;

  return (int32_t)pid;
}

bool kx_reap(int32_t pid) {
  if (pid <= 0) return true;

  int status = 0;
  pid_t reaped;
  do {
    reaped = waitpid((pid_t)pid, &status, WNOHANG);
  } while (reaped < 0 && errno == EINTR);

  // ECHILD is a child that is not this process's any more - reparented, or already
  // reaped by whoever started it - which is as gone as one reaped here.
  return reaped == (pid_t)pid || (reaped < 0 && errno == ECHILD);
}

bool kx_which(const char* name, char* out, size_t cap) {
  if (!name || !out || cap == 0) return false;

  if (strchr(name, '/') != NULL) {
    if (strlen(name) >= cap || access(name, X_OK) != 0) return false;
    strcpy(out, name);
    return true;
  }

  const char* path = getenv("PATH");
  if (path) {
    const char* start = path;
    for (;;) {
      const char* end = strchr(start, ':');
      size_t len = end ? (size_t)(end - start) : strlen(start);
      int written = len == 0 ? snprintf(out, cap, "./%s", name)
                             : snprintf(out, cap, "%.*s/%s", (int)len, start, name);
      if (written > 0 && (size_t)written < cap && access(out, X_OK) == 0) return true;
      if (!end) break;
      start = end + 1;
    }
  }

  // Tern installs its launcher here, and launchd's PATH has no home directory in
  // it; a user-local install is tried before the system-wide prefixes.
  const char* home = getenv("HOME");
  if (home && home[0]) {
    int written = snprintf(out, cap, "%s/.local/bin/%s", home, name);
    if (written > 0 && (size_t)written < cap && access(out, X_OK) == 0) return true;
  }

  static const char* const prefixes[] = {"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", NULL};
  for (size_t i = 0; prefixes[i]; ++i) {
    int written = snprintf(out, cap, "%s/%s", prefixes[i], name);
    if (written > 0 && (size_t)written < cap && access(out, X_OK) == 0) return true;
  }

  return false;
}

bool kx_env(const char* name, char* out, size_t cap) {
  const char* value = getenv(name);
  if (!value || !*value || strlen(value) >= cap) return false;
  strcpy(out, value);
  return true;
}

/* Connect to `path` and write `request` whole, for the two calls below that
 * differ only in what they read back. Returns the connected descriptor, or -1
 * at the first failure; the caller closes it. */
static int kx_unix_connect(const char* path, const void* request, size_t request_size) {
  if (!path || !request) return -1;

  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof(address.sun_path)) return -1;
  strcpy(address.sun_path, path);

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd == -1) return -1;

  /* A peer that has gone away must fail the write, not kill the daemon: on
   * macOS the per-socket option is how that is asked for (`MSG_NOSIGNAL` is
   * not available here, and the global `SIGPIPE` disposition is not this
   * function's to change). */
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));

  if (connect(fd, (const struct sockaddr*)&address, sizeof(address)) != 0) {
    close(fd);
    return -1;
  }

  size_t sent = 0;
  while (sent < request_size) {
    ssize_t n = send(fd, (const char*)request + sent, request_size - sent, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      return -1;
    }
    sent += (size_t)n;
  }

  return fd;
}

int64_t kx_socket_message(const char* path, const void* request, size_t request_size, char* out, size_t cap) {
  if (!out || cap == 0) return -1;

  int fd = kx_unix_connect(path, request, request_size);
  if (fd == -1) return -1;

  /* The peer reads the length it was given and stops there, so this is only for
   * one that reads on: the write side ends, exactly as yabai's own client ends
   * it. */
  shutdown(fd, SHUT_WR);

  int64_t total = 0;
  for (;;) {
    if ((size_t)total >= cap) break;

    ssize_t n = recv(fd, out + total, cap - (size_t)total, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      return -1;
    }
    if (n == 0) break;

    total += n;
  }
  close(fd);

  out[(size_t)total < cap ? (size_t)total : cap - 1] = '\0';
  return total;
}

int64_t kx_unix_reply(const char* path, const void* request, size_t request_size,
                      const void* terminator, size_t terminator_size,
                      char* out, size_t cap, uint32_t timeout_ms) {
  if (!out || cap == 0 || !terminator || terminator_size == 0) return -1;

  int fd = kx_unix_connect(path, request, request_size);
  if (fd == -1) return -1;

  /* Bounded, so a peer that accepts and then says nothing costs the caller a
   * wait instead of the daemon: without this the read would sit on a connection
   * the peer has no reason to close. */
  struct timeval timeout = {
      .tv_sec = (time_t)(timeout_ms / 1000),
      .tv_usec = (suseconds_t)((timeout_ms % 1000) * 1000),
  };
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

  const char* end = (const char*)terminator;
  int64_t total = 0;
  for (;;) {
    if ((size_t)total >= cap) break;

    ssize_t n = recv(fd, out + total, cap - (size_t)total, 0);
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      return -1;
    }
    if (n == 0) break;

    total += n;
    /* Every reply this is for ends with the terminator, so the read stops at the
     * end of the message rather than at the end of the connection. */
    if ((size_t)total >= terminator_size &&
        memcmp(out + total - terminator_size, end, terminator_size) == 0) {
      break;
    }
  }
  close(fd);

  out[(size_t)total < cap ? (size_t)total : cap - 1] = '\0';
  return total;
}


bool kx_ax_trusted(void) {
  /* The same question the engine's watchdog asks once a second. Asked here so
     that `kxdesk hotkey status` can answer it for the daemon's own code identity,
     which is the identity an Accessibility grant has to match: a grant given to an
     earlier build is a grant this process does not have. */
  return AXIsProcessTrusted();
}

bool kx_ax_request(void) {
  const void* keys[] = { (const void*)kAXTrustedCheckOptionPrompt };
  const void* values[] = { (const void*)kCFBooleanTrue };
  CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
  if (options == NULL) return AXIsProcessTrusted();

  /* The prompt is the system's own dialog and the answer to it arrives later, in
     the preferences domain - so the return value is today's grant, never the
     user's answer. */
  bool granted = AXIsProcessTrustedWithOptions(options);
  CFRelease(options);
  return granted;
}

void kx_run_loop_run(void) {
  CFRunLoopRun();
}

/* The private pieces yabai uses for the same job: the window id behind an
   accessibility element, and the window server's space queries. Neither is in a
   public header, and SkyLight has no linkable stub on disk - its image lives in the
   shared cache and only the SDK's `.tbd` names it - so each is resolved once, at
   first use. */
typedef AXError (*kx_ax_window_id)(AXUIElementRef element, uint32_t* window_id);
typedef int (*kx_sls_connection)(void);
typedef uint64_t (*kx_sls_active_space)(int connection);
typedef CFArrayRef (*kx_sls_display_spaces)(int connection);

static void* kx_wm_sls_image(void) {
  static void* image;
  static bool looked = false;
  if (!looked) {
    looked = true;
    image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
  }
  return image;
}

static AXError kx_wm_element_window(AXUIElementRef element, uint32_t* window_id) {
  static kx_ax_window_id get_window;
  static bool looked = false;
  if (!looked) {
    looked = true;
    /* Through the default search order rather than a framework name: every
       accessibility client, this one included, reaches these through the image
       AppKit has already loaded. */
    get_window = (kx_ax_window_id)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
  }
  if (get_window == NULL) return kAXErrorNotImplemented;
  return get_window(element, window_id);
}

/* A compact signature of the desk's spaces - the focused space, then every display's
   spaces in order - for telling whether a space appeared, disappeared or took the
   focus. The window server's *notifications* for these are private SPI whose
   numbering moves between macOS versions, and the four types yabai's table names
   deliver nothing on darwin 27; these two queries answer exactly, so the desk is
   compared instead of listened to. One Mach call, not a yabai query: nothing forks. */
bool kx_space_signature(char* out, size_t cap) {
  if (out == NULL || cap == 0) return false;

  static kx_sls_connection main_connection;
  static kx_sls_active_space active_space;
  static kx_sls_display_spaces display_spaces;
  static bool looked = false;
  if (!looked) {
    looked = true;
    main_connection = (kx_sls_connection)dlsym(kx_wm_sls_image(), "SLSMainConnectionID");
    active_space = (kx_sls_active_space)dlsym(kx_wm_sls_image(), "SLSGetActiveSpace");
    display_spaces = (kx_sls_display_spaces)dlsym(kx_wm_sls_image(), "SLSCopyManagedDisplaySpaces");
  }
  if (main_connection == NULL || active_space == NULL || display_spaces == NULL) return false;

  int connection = main_connection();
  CFArrayRef displays = display_spaces(connection);
  if (displays == NULL) return false;

  char buffer[256];
  size_t caret = 0;
  int written = snprintf(buffer, sizeof buffer, "%llu",
                         (unsigned long long)active_space(connection));
  bool ok = written > 0 && (size_t)written < sizeof buffer;
  if (ok) caret = (size_t)written;

  CFIndex count = CFArrayGetCount(displays);
  for (CFIndex i = 0; ok && i < count; i++) {
    NSDictionary* display = (__bridge NSDictionary*)CFArrayGetValueAtIndex(displays, i);
    NSArray* spaces = display[@"Spaces"];
    if ([spaces isKindOfClass:[NSArray class]]) {
      for (NSDictionary* space in spaces) {
        if (![space isKindOfClass:[NSDictionary class]]) continue;
        NSNumber* identifier = space[@"ManagedSpaceID"];
        if (![identifier isKindOfClass:[NSNumber class]]) continue;
        written = snprintf(buffer + caret, sizeof buffer - caret, ",%lld",
                           identifier.longLongValue);
        if (written < 0 || (size_t)written >= sizeof buffer - caret) {
          ok = false;
          break;
        }
        caret += (size_t)written;
      }
    }
    written = snprintf(buffer + caret, sizeof buffer - caret, "|");
    if (written < 0 || (size_t)written >= sizeof buffer - caret) ok = false;
    else caret += (size_t)written;
  }
  CFRelease(displays);

  if (!ok || caret + 1 > cap) return false;
  memcpy(out, buffer, caret);
  out[caret] = '\0';
  return true;
}

/* Applications the pipe observes at once. An application past this is simply not
   observed: its window changes still arrive as full refreshes from the window
   server and the workspace. */
#define KX_WM_MAX_APPS 96

/* A slot is never moved - the accessibility observer holds its address as the
   callback's context - so a detached application leaves a hole that the next one
   fills. `name` outlives the observer, because a callback already queued still
   reads it. */
typedef struct {
  pid_t pid; /* 0 for a free slot */
  char name[64];
  AXUIElementRef element;
  AXObserverRef observer;
} kx_wm_app;

static kx_wm_handler g_wm_handler = NULL;
static kx_wm_app g_wm_apps[KX_WM_MAX_APPS];
static NSMutableArray* g_wm_workspace_tokens;
static bool g_wm_started = false;

static void kx_wm_notify(const char* kind, uint32_t window_id, const char* app_name) {
  kx_wm_handler handler = g_wm_handler;
  if (handler == NULL) return;
  handler(kind, window_id, app_name);
}

static uint32_t kx_wm_window_id(AXUIElementRef element) {
  uint32_t window_id = 0;
  if (element == NULL) return 0;
  if (kx_wm_element_window(element, &window_id) != kAXErrorSuccess) return 0;
  return window_id;
}

static void kx_wm_ax_event(AXObserverRef observer, AXUIElementRef element,
                           CFStringRef notification, void* context) {
  kx_wm_app* app = context;
  const char* name = app != NULL ? app->name : "";

  if (CFEqual(notification, kAXCreatedNotification)) {
    uint32_t window_id = kx_wm_window_id(element);
    if (window_id != 0) return kx_wm_notify("created", window_id, name);
    return kx_wm_notify("changed", 0, "");
  }
  if (CFEqual(notification, kAXTitleChangedNotification)) {
    uint32_t window_id = kx_wm_window_id(element);
    if (window_id != 0) return kx_wm_notify("title", window_id, "");
    return kx_wm_notify("changed", 0, "");
  }
  /* Destroyed included: the header says the element a destroyed notification
     carries is already stale, so it is never queried. */
  kx_wm_notify("changed", 0, "");
}

static kx_wm_app* kx_wm_slot(pid_t pid, bool reserve) {
  kx_wm_app* free_slot = NULL;
  for (size_t i = 0; i < KX_WM_MAX_APPS; i++) {
    if (g_wm_apps[i].pid == pid) return &g_wm_apps[i];
    if (free_slot == NULL && g_wm_apps[i].pid == 0) free_slot = &g_wm_apps[i];
  }
  if (!reserve || free_slot == NULL) return NULL;
  free_slot->pid = pid;
  return free_slot;
}

/* Observe one application's windows, and schedule `attempts_left` more tries when
   the application could not answer yet.

   Every notification is registered on the application element: that is where this
   macOS delivers an application's window notifications, and window elements refuse
   all of them. Observed this way a title change names its window, a created window
   names its application, and everything else is one full refresh. */
static void kx_wm_attach(pid_t pid, const char* name, uint8_t attempts_left) {
  if (pid <= 0 || pid == getpid()) return;

  kx_wm_app* slot = kx_wm_slot(pid, true);
  if (slot == NULL || slot->observer != NULL) return;

  AXObserverRef observer = NULL;
  AXUIElementRef element = NULL;
  AXError first_error = kAXErrorSuccess;
  size_t added = 0;

  if (AXObserverCreate(pid, kx_wm_ax_event, &observer) != kAXErrorSuccess) {
    observer = NULL;
  } else if ((element = AXUIElementCreateApplication(pid)) != NULL) {
    /* A wedged application must not hold the main thread, which is also the hotkey
       engine's run loop: half a second is well past a responsive application's
       answer, so a slow one costs a missed event rather than a stalled keyboard. */
    AXUIElementSetMessagingTimeout(element, 0.5f);

    CFStringRef notifications[] = {
        kAXCreatedNotification,
        kAXFocusedWindowChangedNotification,
        kAXWindowMovedNotification,
        kAXWindowResizedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXUIElementDestroyedNotification,
    };
    for (size_t i = 0; i < sizeof notifications / sizeof notifications[0]; i++) {
      AXError error = AXObserverAddNotification(observer, element, notifications[i], slot);
      if (error == kAXErrorSuccess) added++;
      else if (first_error == kAXErrorSuccess) first_error = error;
    }
  }

  if (added == 0) {
    if (element != NULL) CFRelease(element);
    if (observer != NULL) CFRelease(observer);
    slot->pid = 0;

    /* Only an application that was busy, or not there yet, is worth asking again:
       one that supports none of these notifications never will, and three more
       tries would be three timeouts on the main thread. The helper processes of a
       browser's framework are exactly that. */
    /* A block captures scalars by value but not an array, so the name the retry
       reports with is a copy of its own. */
    if (attempts_left > 0 &&
        (first_error == kAXErrorCannotComplete || first_error == kAXErrorInvalidUIElement)) {
      char* copy = strdup(name != NULL ? name : "");
      if (copy != NULL) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
                         kx_wm_attach(pid, copy, attempts_left - 1);
                         free(copy);
                       });
      }
    }
    return;
  }

  snprintf(slot->name, sizeof slot->name, "%s", name != NULL ? name : "");
  slot->element = element;
  slot->observer = observer;
  CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer),
                     kCFRunLoopCommonModes);
}

static void kx_wm_detach(pid_t pid) {
  kx_wm_app* slot = kx_wm_slot(pid, false);
  if (slot == NULL) return;

  if (slot->observer != NULL) {
    CFRunLoopSourceRef source = AXObserverGetRunLoopSource(slot->observer);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRunLoopSourceInvalidate(source);
    CFRelease(slot->observer);
    slot->observer = NULL;
  }
  if (slot->element != NULL) {
    CFRelease(slot->element);
    slot->element = NULL;
  }
  slot->pid = 0;
  slot->name[0] = '\0';
}

/* Report every window an application already has as created.

   A window that comes up *with* its application is not announced: the created
   notification is what an application sends when it adds a window, not a roll call,
   and a client that attached during the launch is told nothing about the window the
   application restored. Reading them is what makes an application that opens with a
   window look like one that opened a window - which is the shape the Telegram rule
   reads, and one full refresh otherwise. */
static void kx_wm_report_windows(pid_t pid, const char* name) {
  AXUIElementRef element = AXUIElementCreateApplication(pid);
  if (element == NULL) return;
  AXUIElementSetMessagingTimeout(element, 0.5f);

  CFTypeRef windows = NULL;
  if (AXUIElementCopyAttributeValue(element, kAXWindowsAttribute, &windows) == kAXErrorSuccess &&
      windows != NULL) {
    CFArrayRef list = (CFArrayRef)windows;
    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
      uint32_t window_id = kx_wm_window_id((AXUIElementRef)CFArrayGetValueAtIndex(list, i));
      if (window_id != 0) kx_wm_notify("created", window_id, name);
    }
    CFRelease(windows);
  }
  CFRelease(element);
}

/* An application's name for the filter the Telegram rule uses, and -0- for one the
   workspace will not name. */
static const char* kx_wm_application_name(NSRunningApplication* application) {
  NSString* name = application.localizedName;
  return name != nil ? name.UTF8String : "";
}

/* The workspace's own notifications: launches and terminates drive the observers,
   and the rest are full refreshes. The display notification is spelled as a string
   because it is not in the SDK headers - the same spelling SketchyBar registers. */
static void kx_wm_observe_workspace(void) {
  NSNotificationCenter* center = [[NSWorkspace sharedWorkspace] notificationCenter];
  NSMutableArray* tokens = [NSMutableArray array];
  NSOperationQueue* main_queue = [NSOperationQueue mainQueue];

  void (^refresh)(NSNotification*) = ^(NSNotification* note) {
    kx_wm_notify("changed", 0, "");
  };

  [tokens addObject:[center addObserverForName:NSWorkspaceDidLaunchApplicationNotification
                                       object:nil
                                        queue:main_queue
                                   usingBlock:^(NSNotification* note) {
                                     NSRunningApplication* app =
                                         note.userInfo[NSWorkspaceApplicationKey];
                                     if (app == nil) return;
                                     kx_wm_attach(app.processIdentifier,
                                                  kx_wm_application_name(app), 3);
                                     kx_wm_report_windows(app.processIdentifier,
                                                          kx_wm_application_name(app));
                                   }]];
  [tokens addObject:[center addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                                       object:nil
                                        queue:main_queue
                                   usingBlock:^(NSNotification* note) {
                                     NSRunningApplication* app =
                                         note.userInfo[NSWorkspaceApplicationKey];
                                     if (app != nil) kx_wm_detach(app.processIdentifier);
                                   }]];
  /* Also the second chance for an application that refused to be observed when the
     pipe started: coming to the front is when its windows matter. */
  [tokens addObject:[center addObserverForName:NSWorkspaceDidActivateApplicationNotification
                                       object:nil
                                        queue:main_queue
                                   usingBlock:^(NSNotification* note) {
                                     NSRunningApplication* app =
                                         note.userInfo[NSWorkspaceApplicationKey];
                                     if (app != nil) {
                                       kx_wm_attach(app.processIdentifier,
                                                    kx_wm_application_name(app), 0);
                                     }
                                     refresh(note);
                                   }]];

  NSArray* changes = @[
    NSWorkspaceDidHideApplicationNotification,
    NSWorkspaceDidUnhideApplicationNotification,
    NSWorkspaceActiveSpaceDidChangeNotification,
    NSWorkspaceDidWakeNotification,
    @"NSWorkspaceActiveDisplayDidChangeNotification",
  ];
  for (NSString* name in changes) {
    [tokens addObject:[center addObserverForName:name
                                         object:nil
                                          queue:main_queue
                                     usingBlock:refresh]];
  }

  g_wm_workspace_tokens = tokens;
}

bool kx_wm_events_start(kx_wm_handler handler) {
  if (handler == NULL) return false;
  if (g_wm_started) return g_wm_handler == handler;
  g_wm_started = true;
  g_wm_handler = handler;

  /* Everything is registered on the main run loop and nowhere else: the
     accessibility sources and the workspace's main-queue delivery are both serviced
     by that one loop, and a registration made from a thread that never runs one
     would never deliver. */
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
    for (NSRunningApplication* app in [[NSWorkspace sharedWorkspace] runningApplications]) {
      kx_wm_attach(app.processIdentifier, kx_wm_application_name(app), 3);
    }
    kx_wm_observe_workspace();

  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
  return true;
}

bool kx_app_font_path(char* out, size_t cap) {
  // A descriptor match, rather than CTFontCreateWithName, because the latter
  // silently substitutes a different font when the requested one is missing.
  const void* keys[] = { kCTFontFamilyNameAttribute };
  const void* values[] = { CFSTR("sketchybar-app-font") };
  CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1,
                                                 &kCFTypeDictionaryKeyCallBacks,
                                                 &kCFTypeDictionaryValueCallBacks);
  if (!attributes) return false;

  CTFontDescriptorRef requested = CTFontDescriptorCreateWithAttributes(attributes);
  CFRelease(attributes);
  if (!requested) return false;

  CTFontDescriptorRef matched = CTFontDescriptorCreateMatchingFontDescriptor(requested, NULL);
  CFRelease(requested);
  if (!matched) return false;

  bool ok = false;
  CFURLRef url = (CFURLRef)CTFontDescriptorCopyAttribute(matched, kCTFontURLAttribute);
  CFRelease(matched);
  if (url) {
    CFStringRef path = CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle);
    CFRelease(url);
    if (path) {
      ok = CFStringGetCString(path, out, (CFIndex)cap, kCFStringEncodingUTF8);
      CFRelease(path);
    }
  }

  return ok;
}

bool kx_battery(int32_t* percent, bool* charging) {
  CFTypeRef blob = IOPSCopyPowerSourcesInfo();
  if (!blob) return false;

  bool ok = false;
  CFArrayRef sources = IOPSCopyPowerSourcesList(blob);
  if (sources && CFArrayGetCount(sources) > 0) {
    CFDictionaryRef description =
        IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(sources, 0));
    if (description) {
      CFNumberRef current = CFDictionaryGetValue(description, CFSTR(kIOPSCurrentCapacityKey));
      CFNumberRef max = CFDictionaryGetValue(description, CFSTR(kIOPSMaxCapacityKey));
      CFStringRef state = CFDictionaryGetValue(description, CFSTR(kIOPSPowerSourceStateKey));

      int current_value = 0;
      int max_value = 0;
      if (current) CFNumberGetValue(current, kCFNumberIntType, &current_value);
      if (max) CFNumberGetValue(max, kCFNumberIntType, &max_value);

      if (max_value > 0) {
        *percent = (int32_t)(((int64_t)current_value * 100 + max_value / 2) / max_value);
        *charging = state && CFEqual(state, CFSTR(kIOPSACPowerValue));
        ok = true;
      }
    }
  }

  if (sources) CFRelease(sources);
  CFRelease(blob);
  return ok;
}

void kx_clock(char* icon, size_t icon_cap, char* label, size_t label_cap) {
  static bool locale_ready = false;
  if (!locale_ready) {
    setlocale(LC_TIME, "");
    locale_ready = true;
  }

  time_t now = time(NULL);
  struct tm local;
  localtime_r(&now, &local);

  strftime(icon, icon_cap, "%a %d. %b", &local);
  strftime(label, label_cap, "%H:%M", &local);
}

double kx_cpu_load(void) {
  // Ticks are cumulative, so there is no "current" CPU usage to read: what is
  // asked for is the rate between two readings, which is why this remembers the
  // last one. Mach's own accounting is the source; nothing is forked.
  static host_cpu_load_info_data_t previous;
  static bool have_previous = false;

  host_cpu_load_info_data_t current;
  mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
  if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO,
                      (host_info_t)&current, &count) != KERN_SUCCESS) {
    return 0.0;
  }

  if (!have_previous) {
    previous = current;
    have_previous = true;
    return 0.0;
  }

  // The counters are 32-bit and wrap, so the differences are taken unsigned.
  natural_t busy = 0;
  natural_t total = 0;
  for (int i = 0; i < CPU_STATE_MAX; i++) {
    natural_t delta = current.cpu_ticks[i] - previous.cpu_ticks[i];
    total += delta;
    if (i != CPU_STATE_IDLE) busy += delta;
  }
  previous = current;

  if (total == 0) return 0.0;
  return (double)busy / (double)total;
}

double kx_gpu_load(void) {
  // "Device Utilization %" in the driver's performance dictionary is the
  // instantaneous figure the system's own tools show: unlike the CPU's tick
  // counters there is nothing to difference, one read is the answer. All IOKit, in
  // this process - no fork, no permission to ask for.
  io_iterator_t services = 0;
  if (IOServiceGetMatchingServices(kIOMainPortDefault,
                                   IOServiceMatching("IOAccelerator"),
                                   &services) != KERN_SUCCESS) {
    return 0.0;
  }

  double percent = 0.0;
  io_registry_entry_t accelerator = IOIteratorNext(services);
  if (accelerator) {
    CFTypeRef statistics = IORegistryEntryCreateCFProperty(accelerator,
                                                           CFSTR("PerformanceStatistics"),
                                                           kCFAllocatorDefault,
                                                           0);
    if (statistics && CFGetTypeID(statistics) == CFDictionaryGetTypeID()) {
      CFTypeRef utilization = CFDictionaryGetValue((CFDictionaryRef)statistics,
                                                   CFSTR("Device Utilization %"));
      if (utilization && CFGetTypeID(utilization) == CFNumberGetTypeID()) {
        CFNumberGetValue((CFNumberRef)utilization, kCFNumberDoubleType, &percent);
      }
    }
    if (statistics) CFRelease(statistics);
    IOObjectRelease(accelerator);
  }
  IOObjectRelease(services);

  return percent / 100.0;
}

/// The SMC's key-data structure, byte for byte: the kernel fills a reply through
/// this layout, so its 80-byte shape is the interface.
typedef struct {
  uint32_t key;
  struct {
    char major, minor, build, reserved;
    uint16_t release;
  } vers;
  struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
  } pLimitData;
  struct {
    uint32_t dataSize, dataType;
    char dataAttributes;
  } keyInfo;
  char result, status, data8;
  uint32_t data32;
  char bytes[32];
} kx_smc_key_data_t;

_Static_assert(sizeof(kx_smc_key_data_t) == 80, "the SMC user client's own layout");

/// The two commands a read takes: the key's metadata, then its bytes at the size
/// that metadata gives.
enum {
  kx_smc_read_bytes = 5,
  kx_smc_read_key_info = 9,
  /// The selector every one of those commands goes through.
  kx_smc_index = 2,
};

static io_connect_t kx_smc_connection = 0;
static bool kx_smc_opened = false;

/// Connect to the SMC once; the connection lives as long as the process. A key's
/// size and type never change either, so the round trip that asks for them is paid
/// once per key: the lists below are fifteen keys, which is what bounds the cache.
#define KX_SMC_KEY_CACHE 24
static struct {
  uint32_t key;
  /// Zero for a key this machine does not have, so it is not asked for again.
  uint32_t size;
} kx_smc_cache[KX_SMC_KEY_CACHE];
static size_t kx_smc_cache_count = 0;

static bool kx_smc_open(void) {
  if (kx_smc_opened) return kx_smc_connection != 0;
  kx_smc_opened = true;

  io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                     IOServiceMatching("AppleSMC"));
  if (!service) return false;
  kern_return_t opened = IOServiceOpen(service, mach_task_self(), 0,
                                       &kx_smc_connection);
  IOObjectRelease(service);
  if (opened != KERN_SUCCESS) {
    kx_smc_connection = 0;
    return false;
  }
  return true;
}

static uint32_t kx_smc_fourcc(const char* key) {
  return ((uint32_t)(uint8_t)key[0] << 24) | ((uint32_t)(uint8_t)key[1] << 16) |
         ((uint32_t)(uint8_t)key[2] << 8) | (uint32_t)(uint8_t)key[3];
}

static kern_return_t kx_smc_call(kx_smc_key_data_t* input,
                                 kx_smc_key_data_t* output) {
  size_t output_size = sizeof(*output);
  return IOConnectCallStructMethod(kx_smc_connection, kx_smc_index, input,
                                   sizeof(*input), output, &output_size);
}

/// A key's data size, or false when the machine has no such key.
static bool kx_smc_key_size(uint32_t key, uint32_t* size) {
  for (size_t i = 0; i < kx_smc_cache_count; i++) {
    if (kx_smc_cache[i].key == key) {
      *size = kx_smc_cache[i].size;
      return *size != 0;
    }
  }

  kx_smc_key_data_t input = {0};
  kx_smc_key_data_t output = {0};
  input.key = key;
  input.data8 = kx_smc_read_key_info;
  uint32_t found = 0;
  if (kx_smc_call(&input, &output) == KERN_SUCCESS && output.result == 0) {
    found = output.keyInfo.dataSize;
  }

  if (kx_smc_cache_count < KX_SMC_KEY_CACHE) {
    kx_smc_cache[kx_smc_cache_count].key = key;
    kx_smc_cache[kx_smc_cache_count].size = found;
    kx_smc_cache_count++;
  }
  *size = found;
  return found != 0;
}

/// One temperature sensor, as the little-endian float an `flt ` key carries.
/// False when the key is absent, the read failed, or it is not a four-byte float.
static bool kx_smc_temperature(const char* key, double* celsius) {
  uint32_t size = 0;
  if (!kx_smc_key_size(kx_smc_fourcc(key), &size)) return false;
  if (size != sizeof(float)) return false;

  kx_smc_key_data_t input = {0};
  kx_smc_key_data_t output = {0};
  input.key = kx_smc_fourcc(key);
  input.keyInfo.dataSize = size;
  input.data8 = kx_smc_read_bytes;
  if (kx_smc_call(&input, &output) != KERN_SUCCESS) return false;
  if (output.result != 0) return false;

  float value;
  memcpy(&value, output.bytes, sizeof(value));
  if (!isfinite(value)) return false;
  *celsius = (double)value;
  return true;
}

/// One bank of sensors, and whether it holds this cycle's readings. The SMC scans
/// its sensor array in halves: a half it has not scanned yet answers with one
/// repeated placeholder - 0, 2.2, 3.4 or 40 - rather than a temperature. A real
/// half never reports one identical value across its sensors, so a bank counts
/// only when at least `minimum` of its readings are in range and not all equal,
/// and its reading is then its hottest sensor.
static bool kx_smc_bank(const char* const* keys, size_t count, size_t minimum,
                        double* celsius) {
  double first = 0.0;
  double hottest = 0.0;
  size_t readings = 0;
  bool identical = true;

  for (size_t i = 0; i < count; i++) {
    double value;
    if (!kx_smc_temperature(keys[i], &value)) continue;
    if (!(value > 10.0 && value < 120.0)) continue;
    if (readings == 0) {
      first = value;
    } else if (value != first) {
      identical = false;
    }
    if (readings == 0 || value > hottest) hottest = value;
    readings++;
  }

  if (readings < minimum || identical) return false;
  *celsius = hottest;
  return true;
}

/// The M-series CPU core sensors, in the two halves the SMC scans: the `Tp0`
/// set, then the one the alternate cycle fills. On this M4 Pro the halves
/// alternate exactly, so whichever was just scanned is the one worth reading.
static const char* const kx_cpu_bank_a[] = {"Tp01", "Tp05", "Tp09", "Tp0D",
                                            "Tp0f"};
static const char* const kx_cpu_bank_b[] = {"Tp1t", "Tp2D", "Tp2X"};

/// The GPU's own sensors: the `Tg0D`/`Tg0P` pair the base M4 reports is absent
/// on this chip, and these are the ones that answer.
static const char* const kx_gpu_keys[] = {"Tg05", "Tg0X", "Tg0Y", "Tg0j",
                                          "Tg0k", "Tg0z", "Tg1V"};

bool kx_temperatures(double* cpu_celsius, double* gpu_celsius) {
  static double last_cpu = 0.0;
  static double last_gpu = 0.0;
  static bool have_cpu = false;
  static bool have_gpu = false;

  if (!kx_smc_open()) return false;

  // A bank that came back as a placeholder this second is not a reading: the last
  // real one is kept rather than letting the bar's number drop to a constant.
  double cpu = 0.0;
  double candidate = 0.0;
  bool fresh = false;
  if (kx_smc_bank(kx_cpu_bank_a, sizeof(kx_cpu_bank_a) / sizeof(kx_cpu_bank_a[0]),
                  3, &cpu)) {
    fresh = true;
  }
  if (kx_smc_bank(kx_cpu_bank_b, sizeof(kx_cpu_bank_b) / sizeof(kx_cpu_bank_b[0]),
                  3, &candidate)) {
    if (!fresh || candidate > cpu) cpu = candidate;
    fresh = true;
  }
  if (fresh) {
    last_cpu = cpu;
    have_cpu = true;
  }

  double gpu = 0.0;
  if (kx_smc_bank(kx_gpu_keys, sizeof(kx_gpu_keys) / sizeof(kx_gpu_keys[0]), 3,
                  &gpu)) {
    last_gpu = gpu;
    have_gpu = true;
  }

  if (!have_cpu || !have_gpu) return false;
  *cpu_celsius = last_cpu;
  *gpu_celsius = last_gpu;
  return true;
}

/// The tap's ring: the IOProc thread appends mono samples of the machine's output
/// audio, the receive loop takes the newest window out of it. A power of two, so
/// the wrap is a mask; 16384 samples is a third of a second at 48 kHz, far more
/// than the 1024-sample window a frame is drawn from, which is what makes a
/// window whole even when the reader arrives mid-buffer.
#define KX_AUDIO_RING (1u << 14)

static float kx_audio_ring[KX_AUDIO_RING];
/// Samples written so far, advanced by the IOProc thread alone; the release
/// store is what makes the samples before it visible to whoever reads the count.
static _Atomic uint64_t kx_audio_head;
/// Where the tap got to, and what `kx_audio_status()` reports; written only by
/// the thread that builds it.
static _Atomic uint8_t kx_audio_state = KX_AUDIO_OFF;
/// The rate the tap delivers at, 0 while it is not running.
static _Atomic double kx_audio_rate_hz;
static AudioObjectID kx_audio_tap = kAudioObjectUnknown;
static AudioObjectID kx_audio_device = kAudioObjectUnknown;
static AudioDeviceIOProcID kx_audio_proc = NULL;

/// A stream's format lives on the tap's own object until its aggregate device
/// exists, and on that device afterwards.
static const AudioObjectPropertyAddress kx_audio_tap_format = {
    kAudioTapPropertyFormat,
    kAudioObjectPropertyScopeGlobal,
    kAudioObjectPropertyElementMain,
};
static const AudioObjectPropertyAddress kx_audio_device_format = {
    kAudioDevicePropertyStreamFormat,
    kAudioObjectPropertyScopeInput,
    kAudioObjectPropertyElementMain,
};

/// Read a stream's format. False when it cannot be read, or is not the linear
/// PCM float the spectrum's arithmetic is written for: a machine that hands back
/// anything else gets a flat graph rather than a graph of whatever those bytes
/// mean as floats.
static bool kx_audio_read_format(AudioObjectID object, AudioObjectPropertyAddress address,
                                 AudioStreamBasicDescription* format) {
  UInt32 size = sizeof(*format);
  if (AudioObjectGetPropertyData(object, &address, 0, NULL, &size, format) != noErr) return false;

  const bool floating = (format->mFormatFlags & kAudioFormatFlagIsFloat) != 0 &&
                        (format->mFormatFlags & kAudioFormatFlagIsPacked) != 0 &&
                        format->mBitsPerChannel == 32;
  return floating && format->mSampleRate > 0;
}

/// The format the tapped stream is delivering now, whichever object records it.
static bool kx_audio_stream_format(AudioStreamBasicDescription* format) {
  if (kx_audio_device != kAudioObjectUnknown &&
      kx_audio_read_format(kx_audio_device, kx_audio_device_format, format)) {
    return true;
  }
  return kx_audio_read_format(kx_audio_tap, kx_audio_tap_format, format);
}

/// The machine's output device can change under a running tap - a headset is
/// plugged in and 48 kHz becomes 44.1 - and the spectrum's bands are placed in
/// Hz, so the rate is followed rather than remembered from the start.
static OSStatus kx_audio_format_changed(AudioObjectID object, UInt32 count,
                                        const AudioObjectPropertyAddress addresses[],
                                        void* context) {
  (void)count;
  (void)addresses;
  (void)context;

  AudioStreamBasicDescription format;
  const bool reads = kx_audio_stream_format(&format);
  atomic_store(&kx_audio_rate_hz, reads ? format.mSampleRate : 0.0);
  return noErr;
}

/// The tap's callback, on the HAL's realtime thread: no allocation, no lock, no
/// wait. The stream is mixed to mono and appended, and nothing else happens here.
static OSStatus kx_audio_io(AudioObjectID device, const AudioTimeStamp* now,
                            const AudioBufferList* input, const AudioTimeStamp* input_time,
                            AudioBufferList* output, const AudioTimeStamp* output_time,
                            void* context) {
  (void)device;
  (void)now;
  (void)input_time;
  (void)output;
  (void)output_time;
  (void)context;
  if (!input) return noErr;

  // A tap is a stereo stream, which the HAL hands over either interleaved in one
  // buffer or one channel per buffer; the mean of every channel covers both
  // without this having to ask which it is.
  for (UInt32 b = 0; b < input->mNumberBuffers; b++) {
    const AudioBuffer buffer = input->mBuffers[b];
    const float* frames = buffer.mData;
    const uint32_t channels = buffer.mNumberChannels;
    if (!frames || channels == 0) continue;

    const size_t count = buffer.mDataByteSize / (sizeof(float) * channels);
    for (size_t f = 0; f < count; f++) {
      float mono = 0.0f;
      for (uint32_t c = 0; c < channels; c++) mono += frames[f * channels + c];

      const uint64_t head = atomic_load_explicit(&kx_audio_head, memory_order_relaxed);
      kx_audio_ring[head & (KX_AUDIO_RING - 1)] = mono / (float)channels;
      atomic_store_explicit(&kx_audio_head, head + 1, memory_order_release);
    }
  }
  return noErr;
}

/// Tear down whatever a previous attempt built, so that a failure leaves nothing
/// half-made behind for the next one. Destroying the device takes its property
/// listener with it.
static void kx_audio_teardown(void) {
  if (kx_audio_device != kAudioObjectUnknown) {
    if (kx_audio_proc) {
      AudioDeviceStop(kx_audio_device, kx_audio_proc);
      AudioDeviceDestroyIOProcID(kx_audio_device, kx_audio_proc);
      kx_audio_proc = NULL;
    }
    AudioHardwareDestroyAggregateDevice(kx_audio_device);
    kx_audio_device = kAudioObjectUnknown;
  }
  if (kx_audio_tap != kAudioObjectUnknown) {
    AudioHardwareDestroyProcessTap(kx_audio_tap);
    kx_audio_tap = kAudioObjectUnknown;
  }
  atomic_store(&kx_audio_rate_hz, 0.0);
}

/// Build the tap and put it to work. It is an aggregate device with the tap as
/// its only stream: a global tap is not a device by itself, and the HAL delivers
/// a tap's samples to the client that runs an IOProc on the device carrying it.
static bool kx_audio_build(void) {
  // Every process's output, mixed to stereo, minus none: what the machine is
  // playing. Private, so no other application is offered it, and unmuted, so the
  // audio keeps coming out of the speakers while the bar reads it.
  CATapDescription* description =
      [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
  description.name = @"kxdesk spectrum";
  description.UUID = [NSUUID UUID];
  description.privateTap = YES;
  description.muteBehavior = CATapUnmuted;

  if (AudioHardwareCreateProcessTap(description, &kx_audio_tap) != noErr) return false;

  NSDictionary* aggregate = @{
    @kAudioAggregateDeviceNameKey : @"kxdesk spectrum",
    @kAudioAggregateDeviceUIDKey : description.UUID.UUIDString,
    @kAudioAggregateDeviceIsPrivateKey : @YES,
    @kAudioAggregateDeviceIsStackedKey : @NO,
    @kAudioAggregateDeviceTapAutoStartKey : @YES,
    @kAudioAggregateDeviceSubDeviceListKey : @[],
    @kAudioAggregateDeviceTapListKey : @[ @{
      @kAudioSubTapUIDKey : description.UUID.UUIDString,
      @kAudioSubTapDriftCompensationKey : @YES,
    } ],
  };
  if (AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate,
                                         &kx_audio_device) != noErr) {
    return false;
  }

  AudioStreamBasicDescription format;
  if (!kx_audio_stream_format(&format)) return false;
  atomic_store(&kx_audio_rate_hz, format.mSampleRate);

  if (AudioDeviceCreateIOProcID(kx_audio_device, kx_audio_io, NULL, &kx_audio_proc) != noErr) {
    return false;
  }
  if (AudioDeviceStart(kx_audio_device, kx_audio_proc) != noErr) return false;

  AudioObjectAddPropertyListener(kx_audio_device, &kx_audio_device_format,
                                 kx_audio_format_changed, NULL);
  return true;
}

bool kx_audio_start(void) {
  if (atomic_load(&kx_audio_state) == KX_AUDIO_RUNNING) return true;

  // Says where an attempt got to, which is what lets the caller wait for the
  // permission prompt this may put up instead of asking again and again.
  atomic_store(&kx_audio_state, KX_AUDIO_STARTING);
  kx_audio_teardown();
  atomic_store(&kx_audio_head, 0);

  /* The objects the tap is built from are released when this returns, and the
   * caller is a worker thread of the daemon's, which has no pool of its own to
   * drain them. */
  @autoreleasepool {
    if (kx_audio_build()) {
      atomic_store(&kx_audio_state, KX_AUDIO_RUNNING);
      return true;
    }
  }

  kx_audio_teardown();
  atomic_store(&kx_audio_state, KX_AUDIO_FAILED);
  return false;
}

uint8_t kx_audio_status(void) {
  return atomic_load(&kx_audio_state);
}

double kx_audio_rate(void) {
  return atomic_load(&kx_audio_rate_hz);
}

bool kx_audio_window(float* out, size_t count) {
  if (atomic_load(&kx_audio_state) != KX_AUDIO_RUNNING) return false;

  const uint64_t head = atomic_load_explicit(&kx_audio_head, memory_order_acquire);
  const size_t available = head < count ? (size_t)head : count;
  // Whatever the tap has not delivered yet is silence, so the frames before it
  // has started are a flat line rather than a jump.
  memset(out, 0, (count - available) * sizeof(float));
  for (size_t i = 0; i < available; i++) {
    out[count - available + i] = kx_audio_ring[(head - available + i) & (KX_AUDIO_RING - 1)];
  }
  return true;
}

/// Interface families whose bytes are not the user's traffic, by name prefix:
/// macOS gives an `awdl0` and an `en0` the same flags, so only the name tells them
/// apart. The tunnels (`utun`, `gif`, `stf`, `ipsec`) run over a link that is
/// counted itself; the radio's own (`awdl`, `llw`, `ap`) carry AirDrop beside the
/// same radio's `en0`, and `awdl0` reports transfers that never left the machine;
/// the bridges (`bridge`, `vmenet`) count their member ports a second time; and
/// `anpi`, `anri` and `nan` are interfaces the system keeps for itself.
static const char* const kx_virtual_links[] = {
    "awdl", "llw", "ap", "utun", "gif", "stf", "ipsec", "tun", "tap",
    "bridge", "vmenet", "anpi", "anri", "nan", NULL,
};

static bool kx_virtual_link(const char* name) {
  for (size_t i = 0; kx_virtual_links[i]; i++) {
    if (strncmp(name, kx_virtual_links[i], strlen(kx_virtual_links[i])) == 0) return true;
  }
  return false;
}

bool kx_net_bytes(uint64_t* received, uint64_t* sent) {
  // The 64-bit form of the interface list: the counters in the 32-bit `if_data`
  // would wrap after 4 GB, which a fast link reaches in seconds.
  int mib[6] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};

  // A few kilobytes on a machine with a few dozen interfaces, and read once a
  // second on the loop that also drives the bar, so it lives here rather than
  // being allocated per reading. A list that ever outgrows it fails the call,
  // and the tick after is asked again. Aligned for the message header the list
  // is walked as.
  static _Alignas(struct if_msghdr) char list[64 * 1024];
  size_t length = sizeof(list);
  if (sysctl(mib, 6, list, &length, NULL, 0) != 0) return false;

  uint64_t in = 0;
  uint64_t out = 0;
  for (size_t offset = 0; offset + sizeof(struct if_msghdr) <= length;) {
    struct if_msghdr* header = (struct if_msghdr*)(void*)(list + offset);
    if (header->ifm_msglen == 0) break;

    if (header->ifm_type == RTM_IFINFO2) {
      struct if_msghdr2* link = (struct if_msghdr2*)(void*)header;
      char name[IFNAMSIZ];
      if ((link->ifm_flags & IFF_UP) != 0 && (link->ifm_flags & IFF_LOOPBACK) == 0 &&
          if_indextoname(link->ifm_index, name) != NULL && !kx_virtual_link(name)) {
        in += link->ifm_data.ifi_ibytes;
        out += link->ifm_data.ifi_obytes;
      }
    }

    offset += header->ifm_msglen;
  }

  *received = in;
  *sent = out;
  return true;
}

uint8_t kx_net_link(void) {
  // The system's own answer to "what is the internet on": the primary
  // interface, from the store the network stack keeps its state in - the record
  // `scutil` prints. It is absent when nothing is connected, which is the whole
  // of the disconnected case.
  SCDynamicStoreRef store = SCDynamicStoreCreate(kCFAllocatorDefault, CFSTR("kxdesk"), NULL, NULL);
  if (!store) return KX_NET_LINK_DISCONNECTED;

  CFDictionaryRef global = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"));
  CFRelease(store);
  if (!global) return KX_NET_LINK_DISCONNECTED;

  char name[IFNAMSIZ] = {0};
  CFStringRef primary = CFDictionaryGetValue(global, CFSTR("PrimaryInterface"));
  const bool named = primary != NULL &&
                     CFStringGetCString(primary, name, sizeof(name), kCFStringEncodingUTF8);
  CFRelease(global);
  if (!named || name[0] == '\0') return KX_NET_LINK_DISCONNECTED;

  // Wi-Fi from anything else is the media the kernel reports for that
  // interface, and not its name: `en0` is the Wi-Fi on a laptop and the wire on
  // a desktop, and which one a machine has is nothing a lookup table here could
  // know. An interface that reports no media at all - a tunnel, say - is not
  // Wi-Fi, and the link it runs over is what the store named anyway.
  struct ifmediareq media;
  memset(&media, 0, sizeof(media));
  snprintf(media.ifm_name, sizeof(media.ifm_name), "%s", name);

  const int probe = socket(AF_INET, SOCK_DGRAM, 0);
  if (probe < 0) return KX_NET_LINK_WIRED;
  // `ifm_active` is what the interface is running as right now, where
  // `ifm_current` is what it is configured for - and the network type is the
  // high bits of it, `IFM_TYPE`, not the sub-type `IFM_TMASK` masks off.
  const bool wireless = ioctl(probe, SIOCGIFMEDIA, &media) == 0 &&
                        IFM_TYPE(media.ifm_active) == IFM_IEEE80211;
  close(probe);

  return wireless ? KX_NET_LINK_WIFI : KX_NET_LINK_WIRED;
}

bool kx_dark_mode(void) {
  // The appearance as the system records it, rather than through `System
  // Events`: an Apple Event to another application needs Automation (and, for
  // System Events, Accessibility) permission, and macOS asks again for every
  // new binary - so a tool that upgraded itself would have to be approved
  // again after each upgrade. Reading the preference needs nothing.
  CFStringRef style = CFPreferencesCopyValue(CFSTR("AppleInterfaceStyle"),
                                             kCFPreferencesAnyApplication,
                                             kCFPreferencesCurrentUser,
                                             kCFPreferencesAnyHost);
  if (!style) return false;  // unset is Light
  bool dark = CFStringCompare(style, CFSTR("Dark"), 0) == kCFCompareEqualTo;
  CFRelease(style);
  return dark;
}

bool kx_open_url(const char* url) {
  NSString* text = [NSString stringWithUTF8String:url];
  if (!text) return false;

  NSURL* target = [NSURL URLWithString:text];
  if (!target) return false;

  return [[NSWorkspace sharedWorkspace] openURL:target];
}

bool kx_browser_open(void) {
  @autoreleasepool {
    NSWorkspace* workspace = [NSWorkspace sharedWorkspace];

    /* Asking the workspace which application handles an `https` URL is the
     * system's own answer to "the default browser", and it follows a change the
     * user makes in System Settings without anything here being reconfigured. */
    NSURL* probe = [NSURL URLWithString:@"https://example.com"];
    NSURL* application_url = probe ? [workspace URLForApplicationToOpenURL:probe] : nil;
    NSString* identifier =
        application_url ? [NSBundle bundleWithURL:application_url].bundleIdentifier : nil;
    NSRunningApplication* target =
        identifier ? [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier].firstObject
                   : nil;

    /* No default could be read: fall back to the browser this machine uses,
     * by the bundle it ships under rather than by its display name. */
    if (!application_url) {
      application_url = [NSURL fileURLWithPath:@"/Applications/Zen.app"];
      target = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"app.zen-browser.zen"]
                   .firstObject;
    }

    /* A summon, not a toggle: an application already in front is left exactly
     * as it is, and one behind something else is raised. */
    if (target && target.processIdentifier == workspace.frontmostApplication.processIdentifier) {
      return true;
    }

    if (!application_url) return false;

    /* The raise is handed to the workspace instead of asked of the running
     * application: `activateWithOptions:` blocks this thread for a second on the
     * activation handshake - a launchd agent has no window-server connection to
     * activate from - while the workspace's launch-services client brings the
     * application forward in the time `open -a` takes, and returns at once. The
     * request is asynchronous either way: the caller has nothing to wait for. */
    NSWorkspaceOpenConfiguration* configuration = [NSWorkspaceOpenConfiguration configuration];
    [workspace openApplicationAtURL:application_url
                      configuration:configuration
                  completionHandler:nil];
    return true;
  }
}

bool kx_clipboard_set(const char* text) {
  if (!text) return false;

  /* The caller is a thread of its own that outlives this call many times over,
   * so the objects created here are released into a pool of their own rather
   * than into the thread's, which would only drain when the thread ends. */
  @autoreleasepool {
    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    if (!pasteboard) return false;

    NSString* string = [NSString stringWithUTF8String:text];
    if (!string) return false;

    [pasteboard clearContents];
    return [pasteboard setString:string forType:NSPasteboardTypeString];
  }
}

bool kx_display_name(uint32_t display_id, char* out, size_t cap) {
  @autoreleasepool {
    for (NSScreen* screen in [NSScreen screens]) {
      NSNumber* number = screen.deviceDescription[@"NSScreenNumber"];
      if (number.unsignedIntValue != display_id) continue;

      /* `localizedName` is what kitty prints and what a panel's `output_name`
       * takes, the system's own disambiguation of two displays sharing a name
       * included: a second BenQ is "BenQ PD2730S (2)" here as it is there. */
      const char* name = screen.localizedName.UTF8String;
      if (!name) return false;
      const size_t length = strlen(name);
      if (length + 1 > cap) return false;
      memcpy(out, name, length + 1);
      return true;
    }
    return false;
  }
}

bool kx_display_name_at(size_t index, char* out, size_t cap) {
  @autoreleasepool {
    NSArray<NSScreen*>* screens = [NSScreen screens];
    if (index >= screens.count) return false;

    const char* name = screens[index].localizedName.UTF8String;
    if (!name) return false;
    const size_t length = strlen(name);
    if (length + 1 > cap) return false;
    memcpy(out, name, length + 1);
    return true;
  }
}

bool kx_has_onscreen_window(int32_t pid) {
  @autoreleasepool {
    /* On screen only, which is the whole question: a window hidden the way
     * kitty hides a panel is one the window server no longer returns here. */
    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!windows) return false;

    bool found = false;
    const CFIndex count = CFArrayGetCount(windows);
    for (CFIndex index = 0; index < count; index++) {
      NSDictionary* window = (__bridge NSDictionary*)CFArrayGetValueAtIndex(windows, index);
      NSNumber* owner = window[(id)kCGWindowOwnerPID];
      if (owner.intValue != pid) continue;
      found = true;
      break;
    }

    CFRelease(windows);
    return found;
  }
}

/* ---- display of a panel's window --------------------------------------- */

/* A panel's `output_name` is matched against the monitors its process saw at
 * start-up, and a name that is not in that list is accepted and then ignored.
 * What actually happened is therefore only visible from the window server. */

/// The display whose screen holds this rectangle's centre, in the coordinates
/// `NSScreen` frames are in: `CGWindowList`' y runs down from the main display's
/// top-left edge, `NSScreen`' runs up from its bottom-left one.
static int64_t kx_display_of(CGRect bounds, double main_height) {
  const double x = CGRectGetMidX(bounds);
  const double y = main_height - CGRectGetMidY(bounds);

  for (NSScreen* screen in [NSScreen screens]) {
    const CGRect frame = screen.frame;
    if (x < CGRectGetMinX(frame) || x >= CGRectGetMaxX(frame)) continue;
    if (y < CGRectGetMinY(frame) || y >= CGRectGetMaxY(frame)) continue;
    return [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
  }
  return -1;
}

/// The largest window of `pid` in an already fetched list, or nil when the process
/// has none with an area: a quick access terminal's window is the big one, and its
/// helpers are small or empty.
static NSDictionary* kx_largest_window(CFArrayRef windows, int32_t pid) {
  NSDictionary* largest = nil;
  double best = 0;
  const CFIndex count = CFArrayGetCount(windows);
  for (CFIndex index = 0; index < count; index++) {
    NSDictionary* window = (__bridge NSDictionary*)CFArrayGetValueAtIndex(windows, index);
    if ([window[(id)kCGWindowOwnerPID] intValue] != pid) continue;

    CGRect bounds = CGRectZero;
    CGRectMakeWithDictionaryRepresentation(
        (__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds);
    const double area = bounds.size.width * bounds.size.height;
    if (area <= best) continue;
    best = area;
    largest = window;
  }
  return largest;
}

int32_t kx_panel_display(int32_t pid) {
  @autoreleasepool {
    NSArray<NSScreen*>* screens = [NSScreen screens];
    const double main_height = screens.count > 0 ? screens[0].frame.size.height : 0;

    CFArrayRef windows = CGWindowListCopyWindowInfo(
        kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID);
    if (!windows) return -1;

    NSDictionary* window = kx_largest_window(windows, pid);
    CGRect bounds = CGRectZero;
    if (window) {
      CGRectMakeWithDictionaryRepresentation(
          (__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &bounds);
    }
    CFRelease(windows);

    if (!window) return -1;
    return (int32_t)kx_display_of(bounds, main_height);
  }
}

/* ---- blackout overlay ------------------------------------------------- */

/* One helper process owns the overlay: `wm blackout` starts it, a second press
 * connects to its socket to stop it, and it ends by itself when focus leaves the
 * application it was started in. There is no second caller and no other thread,
 * so the state is file-scope. */

static int g_blackout_listener = -1;
static char g_blackout_socket[sizeof(((struct sockaddr_un*)0)->sun_path)];
static NSMutableArray<NSWindow*>* g_blackout_windows = nil;
static pid_t g_blackout_application = 0;

static void kx_blackout_teardown(void) {
  for (NSWindow* window in g_blackout_windows) [window orderOut:nil];
  g_blackout_windows = nil;
  if (g_blackout_listener >= 0) {
    close(g_blackout_listener);
    g_blackout_listener = -1;
  }
  if (g_blackout_socket[0] != '\0') {
    unlink(g_blackout_socket);
    g_blackout_socket[0] = '\0';
  }
}

static void kx_blackout_end(void) {
  kx_blackout_teardown();
  exit(0);
}

static int kx_blackout_connect(const char* path) {
  if (!path || path[0] == '\0' || strlen(path) >= sizeof(g_blackout_socket)) return -1;

  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) return -1;

  struct sockaddr_un address;
  memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  strcpy(address.sun_path, path);

  if (connect(fd, (struct sockaddr*)&address, sizeof(address)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

bool kx_blackout_stop(const char* socket_path) {
  int fd = kx_blackout_connect(socket_path);
  if (fd < 0) return false;
  close(fd);
  return true;
}

bool kx_blackout_run(uint32_t display_id, const char* socket_path) {
  @autoreleasepool {
    if (!socket_path || socket_path[0] == '\0' ||
        strlen(socket_path) >= sizeof(g_blackout_socket)) {
      return false;
    }

    /* The caller checks for a running overlay first. Checking again here closes
     * the gap before this process has a socket of its own: a press that raced
     * with the previous helper still turns the previous one off instead of
     * drawing a second overlay. */
    if (kx_blackout_stop(socket_path)) return true;

    unlink(socket_path);
    int listener = socket(AF_UNIX, SOCK_STREAM, 0);
    if (listener < 0) return false;

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strcpy(address.sun_path, socket_path);
    if (bind(listener, (struct sockaddr*)&address, sizeof(address)) != 0 ||
        listen(listener, 1) != 0) {
      close(listener);
      unlink(socket_path);
      return false;
    }

    g_blackout_listener = listener;
    strcpy(g_blackout_socket, socket_path);

    NSWorkspace* workspace = [NSWorkspace sharedWorkspace];
    g_blackout_application = workspace.frontmostApplication.processIdentifier;

    /* An accessory application may draw windows but never takes the keyboard;
     * the overlay itself is borderless and ignores the pointer, so the display
     * under it keeps behaving as it did. */
    NSApplication* application = [NSApplication sharedApplication];
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [application finishLaunching];

    g_blackout_windows = [NSMutableArray array];
    bool matched = false;
    for (NSScreen* screen in [NSScreen screens]) {
      NSNumber* number = screen.deviceDescription[@"NSScreenNumber"];
      if (number.unsignedIntValue == display_id) {
        matched = true;
        continue;
      }

      NSWindow* window = [[NSWindow alloc] initWithContentRect:screen.frame
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
      window.backgroundColor = [NSColor blackColor];
      window.opaque = YES;
      window.hasShadow = NO;
      window.ignoresMouseEvents = YES;
      /* Above the menu bar, the Dock and a native-fullscreen window, and present
       * on every Space including the fullscreen ones. */
      window.level = NSScreenSaverWindowLevel;
      window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                  NSWindowCollectionBehaviorStationary |
                                  NSWindowCollectionBehaviorFullScreenAuxiliary |
                                  NSWindowCollectionBehaviorIgnoresCycle;
      [window orderFrontRegardless];
      [g_blackout_windows addObject:window];
    }

    if (!matched) {
      kx_blackout_teardown();
      return false;
    }

    /* A connection is the stop signal: the second press connects and closes,
     * and there is no message to parse. */
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)g_blackout_listener, 0,
        dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
      int client = accept(g_blackout_listener, NULL, NULL);
      if (client >= 0) close(client);
      kx_blackout_end();
    });
    dispatch_resume(source);

    NSNotificationCenter* center = workspace.notificationCenter;

    /* Focus moving to another application is the end of the mode. */
    [center addObserverForName:NSWorkspaceDidActivateApplicationNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) {
                      NSRunningApplication* changed = note.userInfo[NSWorkspaceApplicationKey];
                      if (!changed) return;
                      pid_t pid = changed.processIdentifier;
                      if (pid == getpid() || pid == g_blackout_application) return;
                      kx_blackout_end();
                    }];

    /* An application that quits need not activate another one first - a last
     * window closing is enough - so its termination ends the mode too. */
    [center addObserverForName:NSWorkspaceDidTerminateApplicationNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification* note) {
                      NSRunningApplication* changed = note.userInfo[NSWorkspaceApplicationKey];
                      if (changed && changed.processIdentifier == g_blackout_application) {
                        kx_blackout_end();
                      }
                    }];

    /* The notification center only reports changes from this point on, so a
     * focus change during setup is caught by reading the state once more. The
     * helper itself never counts as a change. */
    NSRunningApplication* frontmost = workspace.frontmostApplication;
    if (frontmost.processIdentifier != getpid() &&
        frontmost.processIdentifier != g_blackout_application) {
      kx_blackout_end();
    }

    [application run];
    kx_blackout_teardown();
    return true;
  }
}

/* =========================================================================
 * The privacy guide: the panel that walks one drag into the Input Monitoring
 * list.
 *
 * TCC grants Input Monitoring to a code identity, and only the process that
 * wants to seize can ask for its own. So nothing here can query the grabber's
 * grant - the panel is told, by a socket probe the caller hands in, whether the
 * drag has landed yet.
 *
 * `anomalyco/hex`'s `native/permission_guide.m` is where this shape comes from:
 * a non-activating panel parked in the corner of the System Settings window, a
 * tile that begins a real dragging session for the bundle's URL, and a timer that
 * follows the window rather than assuming it stays where it was opened.
 * ====================================================================== */

typedef bool (*kx_guide_done)(void);

static NSPanel* g_guide_panel;
static NSTimer* g_guide_follow;
static dispatch_source_t g_guide_watch;
static _Atomic bool g_guide_granted;
static bool g_guide_closed_by_grant;
static NSString* g_guide_script;
static NSUInteger g_guide_requests;

static NSString* const kx_settings_bundle = @"com.apple.systempreferences";

/* The tile: what System Settings will list, and the source of the drag. */
@interface KxGuideTile : NSView <NSDraggingSource>
@property(nonatomic, strong) NSURL* bundle;
@property(nonatomic, strong) NSImage* icon;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, strong) NSEvent* pressed;
@end

@implementation KxGuideTile

- (BOOL)acceptsFirstMouse:(NSEvent*)event {
  return YES;
}

- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor];
}

- (void)drawRect:(NSRect)dirty {
  NSBezierPath* background =
      [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8];
  [[NSColor colorWithWhite:0.5 alpha:0.12] setFill];
  [background fill];
  [self.icon drawInRect:NSMakeRect(10, 6, 32, 32)];
  [self.name drawAtPoint:NSMakePoint(52, 14)
          withAttributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName : NSColor.labelColor,
          }];
}

- (void)mouseDown:(NSEvent*)event {
  self.pressed = event;
}

- (void)mouseDragged:(NSEvent*)event {
  if (self.pressed == nil) return;
  CGFloat dx = event.locationInWindow.x - self.pressed.locationInWindow.x;
  CGFloat dy = event.locationInWindow.y - self.pressed.locationInWindow.y;
  if (hypot(dx, dy) < 3) return;

  NSDraggingItem* item = [[NSDraggingItem alloc] initWithPasteboardWriter:self.bundle];
  NSBitmapImageRep* representation = [self bitmapImageRepForCachingDisplayInRect:self.bounds];
  [self cacheDisplayInRect:self.bounds toBitmapImageRep:representation];
  NSImage* snapshot = [[NSImage alloc] initWithSize:self.bounds.size];
  [snapshot addRepresentation:representation];
  [item setDraggingFrame:self.bounds contents:snapshot];

  NSDraggingSession* session = [self beginDraggingSessionWithItems:@[ item ]
                                                             event:self.pressed
                                                            source:self];
  session.animatesToStartingPositionsOnCancelOrFail = YES;
  session.draggingFormation = NSDraggingFormationNone;
  self.pressed = nil;
}

- (NSDragOperation)draggingSession:(NSDraggingSession*)session
    sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return NSDragOperationCopy;
}

@end

@interface KxGuideAction : NSObject
- (void)install:(id)sender;
- (void)close:(id)sender;
@end

static void kx_guide_end(bool granted);

@implementation KxGuideAction

- (void)install:(id)sender {
  if (g_guide_script != nil) {
    /* Terminal opened on the script, not `osascript`: a `.command` needs no
     * Automation grant and hands the user a real terminal, which is what the
     * password prompt inside it wants. */
    [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open"
                             arguments:@[ @"-a", @"Terminal", g_guide_script ]];
  }
  kx_guide_end(false);
}

- (void)close:(id)sender {
  kx_guide_end(false);
}

@end

static bool kx_guide_settings_open(void) {
  NSArray<NSRunningApplication*>* apps =
      [NSRunningApplication runningApplicationsWithBundleIdentifier:kx_settings_bundle];
  if (apps.count == 0) return NO;

  pid_t pid = apps.firstObject.processIdentifier;
  NSArray* windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  for (NSDictionary* window in windows) {
    if ([window[(id)kCGWindowOwnerPID] intValue] == pid &&
        [window[(id)kCGWindowLayer] integerValue] == 0) {
      return YES;
    }
  }
  return NO;
}

/* System Settings that is not running yet drops the pane in the URL while it
 * restores the pane it showed last, so after a cold launch the URL goes again
 * once its window is up and settled. */
static void kx_guide_open_pane(NSURL* url) {
  BOOL cold = [NSRunningApplication runningApplicationsWithBundleIdentifier:kx_settings_bundle]
                  .count == 0;
  NSUInteger request = ++g_guide_requests;
  [[NSWorkspace sharedWorkspace] openURL:url];
  if (!cold) return;

  __block NSUInteger polls = 0;
  [NSTimer scheduledTimerWithTimeInterval:0.1
                                  repeats:YES
                                    block:^(NSTimer* timer) {
                                      polls += 1;
                                      if (request != g_guide_requests || polls > 100) {
                                        [timer invalidate];
                                        return;
                                      }
                                      if (!kx_guide_settings_open()) return;
                                      [timer invalidate];
                                      for (NSNumber* delay in @[ @0.35, @1.2 ]) {
                                        dispatch_after(
                                            dispatch_time(DISPATCH_TIME_NOW,
                                                          (int64_t)(delay.doubleValue *
                                                                    NSEC_PER_SEC)),
                                            dispatch_get_main_queue(), ^{
                                              if (request == g_guide_requests) {
                                                [[NSWorkspace sharedWorkspace] openURL:url];
                                              }
                                            });
                                      }
                                    }];
}

/* The Settings window in the window server's coordinates, largest window first:
 * a pane's sheet is a window too. */
static CGRect kx_guide_settings_frame(void) {
  NSArray<NSRunningApplication*>* apps =
      [NSRunningApplication runningApplicationsWithBundleIdentifier:kx_settings_bundle];
  if (apps.count == 0) return CGRectNull;
  pid_t pid = apps.firstObject.processIdentifier;

  NSArray* windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  CGRect best = CGRectNull;
  for (NSDictionary* window in windows) {
    if ([window[(id)kCGWindowOwnerPID] intValue] != pid) continue;
    if ([window[(id)kCGWindowLayer] integerValue] != 0) continue;
    CGRect frame;
    if (!CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)window[(id)kCGWindowBounds], &frame)) {
      continue;
    }
    if (frame.size.width < 300 || frame.size.height < 200) continue;
    if (CGRectIsNull(best) ||
        frame.size.width * frame.size.height > best.size.width * best.size.height) {
      best = frame;
    }
  }
  return best;
}

/* The window server counts y down from the top of the primary display; AppKit
 * counts it up from the bottom of it. */
static NSRect kx_guide_appkit_frame(CGRect frame) {
  NSScreen* primary = NSScreen.screens.firstObject;
  if (primary == nil) return NSRectFromCGRect(frame);
  return NSMakeRect(frame.origin.x,
                    primary.frame.size.height - frame.origin.y - frame.size.height,
                    frame.size.width, frame.size.height);
}

static void kx_guide_follow_settings(void) {
  if (g_guide_granted) {
    kx_guide_end(true);
    return;
  }
  CGRect quartz = kx_guide_settings_frame();
  if (CGRectIsNull(quartz)) return;

  NSRect settings = kx_guide_appkit_frame(quartz);
  NSSize size = g_guide_panel.frame.size;
  NSScreen* screen = nil;
  for (NSScreen* candidate in NSScreen.screens) {
    if (NSIntersectsRect(candidate.frame, settings)) {
      screen = candidate;
      break;
    }
  }
  if (screen == nil) screen = NSScreen.mainScreen;
  NSRect visible = screen != nil ? screen.visibleFrame : settings;

  CGFloat x = NSMaxX(settings) - size.width - 16;
  CGFloat y = NSMinY(settings) + 16;
  x = MIN(MAX(x, NSMinX(visible) + 8), NSMaxX(visible) - size.width - 8);
  y = MIN(MAX(y, NSMinY(visible) + 8), NSMaxY(visible) - size.height - 8);
  [g_guide_panel setFrameOrigin:NSMakePoint(x, y)];
  [g_guide_panel orderFrontRegardless];
}

static void kx_guide_end(bool granted) {
  if (granted) g_guide_closed_by_grant = true;
  if (g_guide_follow != nil) {
    [g_guide_follow invalidate];
    g_guide_follow = nil;
  }
  if (g_guide_watch != nil) {
    dispatch_source_cancel(g_guide_watch);
    g_guide_watch = nil;
  }
  [g_guide_panel orderOut:nil];
  [NSApp stop:nil];
  /* `stop` only takes effect when the run loop next turns, and a panel waiting
   * for a drag has no events of its own to turn it. */
  NSEvent* wake = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                     location:NSZeroPoint
                                modifierFlags:0
                                    timestamp:0
                                 windowNumber:0
                                      context:nil
                                      subtype:0
                                        data1:0
                                        data2:0];
  [NSApp postEvent:wake atStart:YES];
}

bool kx_guide_run(const char* bundle_path, const char* instruction, const char* pane_url,
                  const char* install_script, bool (*done)(void)) {
  @autoreleasepool {
    if (instruction == NULL || pane_url == NULL) return false;

    g_guide_granted = false;
    g_guide_closed_by_grant = false;
    g_guide_script = install_script != NULL ? [NSString stringWithUTF8String:install_script] : nil;

    NSApplication* application = [NSApplication sharedApplication];
    /* An accessory may draw windows in front of another application and never
     * activates: the panel must not take the keyboard away from the System
     * Settings list the user is about to drag into. */
    [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [application finishLaunching];

    NSURL* pane = [NSURL URLWithString:[NSString stringWithUTF8String:pane_url]];
    if (pane != nil) kx_guide_open_pane(pane);

    bool draggable = bundle_path != NULL && bundle_path[0] != '\0';
    NSSize size = NSMakeSize(480, draggable ? 116 : 92);

    NSPanel* panel = [[NSPanel alloc]
        initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                    backing:NSBackingStoreBuffered
                      defer:NO];
    panel.floatingPanel = YES;
    panel.level = NSFloatingWindowLevel;
    panel.collectionBehavior =
        NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO;
    panel.releasedWhenClosed = NO;
    g_guide_panel = panel;

    NSView* content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
    content.wantsLayer = YES;
    content.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
    content.layer.cornerRadius = 20;
    content.layer.borderWidth = 1;
    content.layer.borderColor = [NSColor colorWithWhite:0 alpha:0.10].CGColor;

    NSString* text = [NSString stringWithUTF8String:instruction];
    NSTextField* line = [NSTextField labelWithString:text];
    line.frame = NSMakeRect(18, draggable ? 73 : 49, size.width - 96, 24);
    line.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    line.textColor = NSColor.labelColor;
    [content addSubview:line];

    KxGuideAction* actions = [[KxGuideAction alloc] init];

    NSButton* close = [NSButton buttonWithTitle:@"Close"
                                         target:actions
                                         action:@selector(close:)];
    close.frame = NSMakeRect(size.width - 74, size.height - 32, 56, 20);
    close.bordered = NO;
    close.font = [NSFont systemFontOfSize:12];
    close.contentTintColor = NSColor.secondaryLabelColor;
    [content addSubview:close];

    if (draggable) {
      NSURL* bundle = [NSURL fileURLWithPath:[NSString stringWithUTF8String:bundle_path]];
      KxGuideTile* tile =
          [[KxGuideTile alloc] initWithFrame:NSMakeRect(18, 16, size.width - 36, 44)];
      tile.bundle = bundle;
      tile.icon = [[NSWorkspace sharedWorkspace] iconForFile:bundle.path];
      tile.icon.size = NSMakeSize(32, 32);
      tile.name = bundle.URLByDeletingPathExtension.lastPathComponent;
      [content addSubview:tile];
    } else if (g_guide_script != nil) {
      NSButton* install = [NSButton buttonWithTitle:@"Install…"
                                             target:actions
                                             action:@selector(install:)];
      install.frame = NSMakeRect(18, 12, 110, 28);
      install.bezelStyle = NSBezelStyleRounded;
      install.controlSize = NSControlSizeSmall;
      [content addSubview:install];
    }

    panel.contentView = content;

    /* The grant, polled from a thread of its own: each probe is a socket round
     * trip, and the main thread is busy following the Settings window. */
    if (done != NULL) {
      g_guide_watch = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                             dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
      dispatch_source_set_timer(g_guide_watch, dispatch_time(DISPATCH_TIME_NOW, 0),
                                500ull * NSEC_PER_MSEC, 200ull * NSEC_PER_MSEC);
      dispatch_source_set_event_handler(g_guide_watch, ^{
        if (done()) g_guide_granted = true;
      });
      dispatch_resume(g_guide_watch);
    }

    g_guide_follow = [NSTimer scheduledTimerWithTimeInterval:0.12
                                                     repeats:YES
                                                       block:^(NSTimer* timer) {
                                                         kx_guide_follow_settings();
                                                       }];
    kx_guide_follow_settings();

    [application run];

    if (g_guide_follow != nil) {
      [g_guide_follow invalidate];
      g_guide_follow = nil;
    }
    if (g_guide_watch != nil) {
      dispatch_source_cancel(g_guide_watch);
      g_guide_watch = nil;
    }
    [g_guide_panel orderOut:nil];
    g_guide_panel = nil;
    g_guide_script = nil;
    return g_guide_closed_by_grant;
  }
}
