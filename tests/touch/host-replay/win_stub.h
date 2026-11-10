// Just enough of the Win32 pointer-injection API and of Sunshine's logging/task pool for Sunshine's real
// touch_update (extracted from src/platform/windows/input.cpp by extract.py) to compile and run on Linux.
// The flag values are the Windows SDK's.
#pragma once

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <sstream>
#include <string>
#include <string_view>
#include <vector>
#include <algorithm>
#include <memory>
#include <utility>

using namespace std::literals;

typedef uint32_t UINT32;
typedef int32_t LONG;
typedef int BOOL;
typedef uint32_t DWORD;
typedef void *HSYNTHETICPOINTERDEVICE;
#define ARRAYSIZE(a) (sizeof(a) / sizeof((a)[0]))

enum { PT_POINTER = 1, PT_TOUCH = 2, PT_PEN = 3 };
#define POINTER_FEEDBACK_DEFAULT 1
#define POINTER_FLAG_NONE 0x00000000
#define POINTER_FLAG_NEW 0x00000001
#define POINTER_FLAG_INRANGE 0x00000002
#define POINTER_FLAG_INCONTACT 0x00000004
#define POINTER_FLAG_PRIMARY 0x00002000
#define POINTER_FLAG_CANCELED 0x00008000
#define POINTER_FLAG_DOWN 0x00010000
#define POINTER_FLAG_UPDATE 0x00020000
#define POINTER_FLAG_UP 0x00040000
#define TOUCH_MASK_NONE 0x00000000
#define TOUCH_MASK_CONTACTAREA 0x00000001
#define TOUCH_MASK_ORIENTATION 0x00000002
#define TOUCH_MASK_PRESSURE 0x00000004

struct POINT { LONG x, y; };
struct RECT { LONG left, top, right, bottom; };
struct POINTER_INFO {
  UINT32 pointerType;
  UINT32 pointerId;
  UINT32 pointerFlags;
  POINT ptPixelLocation;
};
struct POINTER_TOUCH_INFO {
  POINTER_INFO pointerInfo;
  UINT32 touchMask;
  RECT rcContact;
  UINT32 orientation;
  UINT32 pressure;
};
struct POINTER_PEN_INFO { POINTER_INFO pointerInfo; };
struct POINTER_TYPE_INFO {
  UINT32 type;
  POINTER_TOUCH_INFO touchInfo;
};

inline DWORD GetLastError() { return 0; }

// Logging: records every line with its level.
struct LogRecord { std::string level; std::string text; };
extern std::vector<LogRecord> g_log;
struct LogLine {
  explicit LogLine(const char *level): level_(level) {}
  ~LogLine() { g_log.push_back({ level_, os_.str() }); }
  template <class T> LogLine &operator<<(const T &v) { os_ << v; return *this; }
  std::string level_;
  std::ostringstream os_;
};
#define BOOST_LOG(level) LogLine(#level)

// The task pool: tasks are recorded; the replay runs the pending repeat itself (worst case, before every event).
namespace thread_pool_util {
  struct ThreadPool {
    using task_id_t = void *;
    struct pushed_t { task_id_t task_id; };
    template <class F, class... Args>
    pushed_t pushDelayed(F &&f, std::chrono::milliseconds, Args &&...args) {
      pending = [=]() mutable { f(args...); };
      pendingId = (task_id_t)(++counter);
      return { pendingId };
    }
    void cancel(task_id_t id) { if (id == pendingId) { pending = nullptr; pendingId = nullptr; } }
    std::function<void()> pending;
    task_id_t pendingId = nullptr;
    uintptr_t counter = 0;
  };
}
extern thread_pool_util::ThreadPool task_pool;

namespace platf {
  struct client_input_t { virtual ~client_input_t() = default; };
  // The global input handle: .get() is the input_raw_t the replay owns.
  struct input_t { void *raw; void *get() const { return raw; } };
  struct touch_port_t { int offset_x, offset_y, width, height; };
  struct touch_input_t {
    uint8_t eventType;
    uint16_t rotation;
    uint32_t pointerId;
    float x, y;
    float pressureOrDistance;
    float contactAreaMajor, contactAreaMinor;
  };
  struct pen_input_t {};

  // One recorded call of InjectSyntheticPointerInput: the frame Windows would get.
  struct Frame { std::vector<POINTER_TYPE_INFO> pointers; };
}
