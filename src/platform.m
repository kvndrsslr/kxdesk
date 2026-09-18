#import <AppKit/AppKit.h>

#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>
#include <bootstrap.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/message.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char** environ;

#include "platform.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wsign-compare"
#include "sketchybar.h"
#pragma clang diagnostic pop

/* -- mach transport ------------------------------------------------------- */

uint32_t sb_bootstrap_lookup(const char* name) {
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

void sb_port_release(uint32_t port) {
  if (port) mach_port_deallocate(mach_task_self(), (mach_port_t)port);
}

uint32_t sb_server_register(const char* name) {
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

bool sb_server_publish(uint32_t port, const char* name) {
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

uint32_t sb_uid(void) {
  return (uint32_t)getuid();
}

/// Receive one message, waiting at most `timeout_ms` milliseconds. Returns false
/// when the wait elapsed instead, in which case no message was received and
/// there is nothing to destroy.
///
/// This is the vendored `mach_receive_message` with a timeout the caller picks;
/// its own timeout path is fixed at a second. The buffer is zeroed first, as
/// there, so that a failed receive leaves `address` NULL rather than stale.
static bool sb_server_receive(uint32_t port, struct mach_buffer* buffer,
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

void sb_server_serve(uint32_t port, sb_handler handler, sb_timer timer) {
  // A receive that blocks until a message arrives, or until the timer says it
  // has something to do. With no timer running the wait is infinite, so the idle
  // daemon wakes for nothing at all. SketchyBar's `k` shutdown marker arrives as
  // an ordinary 2-byte block - `env[0] == 'k'` - and is handed to the handler,
  // which records that the bar is gone. It is not a reason to exit: this process
  // outlives the bar and is expected to be serving again by the time the next
  // `apply` arrives.
  struct mach_buffer buffer;
  for (;;) {
    // Asked before the wait rather than after it, so the timer's own work - and
    // anything it has to show - happens before the loop commits to blocking.
    uint32_t wait_ms = timer ? timer() : 0;

    if (!sb_server_receive(port, &buffer, wait_ms)) continue;

    const char* env = buffer.message.descriptor.address;
    if (!env) continue;

    handler(env, (uint32_t)buffer.message.header.msgh_remote_port);
    mach_msg_destroy(&buffer.message.header);
  }
}

int32_t sb_post(uint32_t port, const char* argv, size_t len) {
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

uint32_t sb_port_copy(uint32_t port) {
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

int32_t sb_send(uint32_t port, const char* argv, size_t len, char* out, size_t cap,
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

/* -- process execution ---------------------------------------------------- */

int64_t sb_exec_capture(const char* const argv[], char* out, size_t cap) {
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

int32_t sb_exec_status(const char* const argv[]) {
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

bool sb_which(const char* name, char* out, size_t cap) {
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

  static const char* const prefixes[] = {"/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", NULL};
  for (size_t i = 0; prefixes[i]; ++i) {
    int written = snprintf(out, cap, "%s/%s", prefixes[i], name);
    if (written > 0 && (size_t)written < cap && access(out, X_OK) == 0) return true;
  }

  return false;
}

bool sb_env(const char* name, char* out, size_t cap) {
  const char* value = getenv(name);
  if (!value || !*value || strlen(value) >= cap) return false;
  strcpy(out, value);
  return true;
}

/* -- fonts ---------------------------------------------------------------- */

bool sb_app_font_path(char* out, size_t cap) {
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

/* -- battery -------------------------------------------------------------- */

bool sb_battery(int32_t* percent, bool* charging) {
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

/* -- clock ---------------------------------------------------------------- */

void sb_clock(char* icon, size_t icon_cap, char* label, size_t label_cap) {
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

/* -- JavaScript for Automation -------------------------------------------- */

double sb_cpu_load(void) {
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

double sb_gpu_load(void) {
  // Apple's GPU driver publishes a performance dictionary, and "Device
  // Utilization %" in it is the instantaneous figure the system's own tools
  // show. Unlike the CPU's tick counters there is nothing to difference here:
  // one read is the answer. Everything is IOKit, in this process - no fork, and
  // no permission to ask for.
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

bool sb_dark_mode(void) {
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

bool sb_open_url(const char* url) {
  NSString* text = [NSString stringWithUTF8String:url];
  if (!text) return false;

  NSURL* target = [NSURL URLWithString:text];
  if (!target) return false;

  return [[NSWorkspace sharedWorkspace] openURL:target];
}
