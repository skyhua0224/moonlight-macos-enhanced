// Replays the wire touch events of the client (dump_wire_sequences) through Sunshine's real touch_update (cut out of
// src/platform/windows/input.cpp by extract.py) and checks what the host does with them:
//   - no "Unexpected new pointer" or any other warning or error;
//   - after every event, the touches the host holds live (and tells Windows about) are exactly the ones the client has
//     down, at most ten, in contiguous slots;
//   - the frame injected for a DOWN carries DOWN|INCONTACT, for an UP carries UP without INCONTACT, for a CANCEL
//     carries CANCELED; nothing is left live (and no repeat is pending) when the client has nothing down.
// The 50 ms refresh the host schedules is run before every event, the worst case for stale state.
//
// A negative control proves the check can fail: DOWN and MOVE of pointer 0 are removed and UP kept, as an older client did
// while input was paused, and the host must then report the warning from the recorded log. (Sunshine itself leaves the slot of
// a released pointer empty until its next compaction; that is the host's own lazy bookkeeping and is not judged here.)

#include "win_stub.h"

#include <cstdio>
#include <fstream>
#include <set>

#include "alkaidlab/gamestream_adapter/interaction_input_touch_wire.h"

std::vector<LogRecord> g_log;
thread_pool_util::ThreadPool task_pool;

namespace platf {
  static std::vector<Frame> g_frames;
  static int g_devicesCreated = 0;
  static int g_maxCount = 0;

  struct input_raw_t {
    HSYNTHETICPOINTERDEVICE (*fnCreateSyntheticPointerDevice)(UINT32, UINT32, UINT32);
    BOOL (*fnInjectSyntheticPointerInput)(HSYNTHETICPOINTERDEVICE, const POINTER_TYPE_INFO *, UINT32);
    void (*fnDestroySyntheticPointerDevice)(HSYNTHETICPOINTERDEVICE);
  };

  static HSYNTHETICPOINTERDEVICE fakeCreate(UINT32, UINT32 max, UINT32) {
    g_devicesCreated++;
    g_maxCount = (int) max;
    return (HSYNTHETICPOINTERDEVICE) 0x1000;
  }
  static BOOL fakeInject(HSYNTHETICPOINTERDEVICE, const POINTER_TYPE_INFO *info, UINT32 count) {
    Frame f;
    f.pointers.assign(info, info + count);
    g_frames.push_back(std::move(f));
    return 1;
  }
  static void fakeDestroy(HSYNTHETICPOINTERDEVICE) {}

  static bool inject_synthetic_pointer_input(input_raw_t *input, HSYNTHETICPOINTERDEVICE device, const POINTER_TYPE_INFO *pointerInfo, UINT32 count) {
    return input->fnInjectSyntheticPointerInput(device, pointerInfo, count);
  }

#include "extracted_touch.inc"
}  // namespace platf

struct Event { int type; uint32_t pid; float x, y; };
struct Scenario { std::string name; std::vector<Event> events; };

static std::vector<Scenario> load(const char *path) {
  std::vector<Scenario> out;
  std::ifstream in(path);
  std::string line;
  while (std::getline(in, line)) {
    if (line.rfind("scenario ", 0) == 0) {
      out.push_back({ line.substr(9), {} });
    }
    else if (line.rfind("E ", 0) == 0 && !out.empty()) {
      Event e {};
      unsigned t = 0, p = 0;
      sscanf(line.c_str(), "E %u %u %f %f", &t, &p, &e.x, &e.y);
      e.type = (int) t;
      e.pid = p;
      out.back().events.push_back(e);
    }
  }
  return out;
}

struct Result {
  bool ok = true;
  std::vector<std::string> problems;
  size_t warnings = 0;
  size_t events = 0;
};

static void problem(Result &r, const std::string &what) {
  r.ok = false;
  if (r.problems.size() < 5) r.problems.push_back(what);
}

static std::set<uint32_t> hostLive(platf::client_input_raw_t *raw) {
  std::set<uint32_t> live;
  for (UINT32 i = 0; i < raw->activeTouchSlots; i++) {
    auto &pi = raw->touchInfo[i].touchInfo.pointerInfo;
    if (pi.pointerFlags & POINTER_FLAG_INCONTACT) live.insert(pi.pointerId);
  }
  return live;
}

static Result run(const Scenario &s, bool dropFirstDownOfPointer0) {
  Result r;
  g_log.clear();
  platf::g_frames.clear();
  platf::g_devicesCreated = 0;
  task_pool = thread_pool_util::ThreadPool();
  platf::input_raw_t global { platf::fakeCreate, platf::fakeInject, platf::fakeDestroy };
  platf::input_t handle { &global };
  auto raw = std::make_unique<platf::client_input_raw_t>(handle);
  platf::touch_port_t port { 0, 0, 1920, 1080 };

  std::set<uint32_t> model;
  bool dropped = false;
  for (const Event &e : s.events) {
    // the older client dropped DOWN and MOVE while input was paused and let UP through
    if (dropFirstDownOfPointer0 && e.pid == 0 &&
        (e.type == ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_DOWN || e.type == ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_MOVE)) {
      dropped = true;
      continue;
    }
    // the host's 50 ms refresh fires between events
    if (task_pool.pending) {
      auto before = hostLive(raw.get());
      auto pending = task_pool.pending;
      task_pool.pending = nullptr;
      pending();
      if (before != hostLive(raw.get())) problem(r, "refresh changed the live set");
    }

    size_t framesBefore = platf::g_frames.size();
    platf::touch_input_t t { (uint8_t) e.type, 0xffff, e.pid, e.x, e.y, 0.0f, 0.0f, 0.0f };
    platf::touch_update(raw.get(), port, t);
    r.events++;

    // the model: what the client has down
    switch (e.type) {
      case ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_DOWN: model.insert(e.pid); break;
      case ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_UP:
      case ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_CANCEL: model.erase(e.pid); break;
      case ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_CANCEL_ALL: model.clear(); break;
      default: break;
    }
    if (dropped) {
      // the negative control: the model still counts the dropped DOWN, so only the warning is compared
      continue;
    }

    auto live = hostLive(raw.get());
    if (live != model) problem(r, "after event " + std::to_string(r.events) + " the host's live set differs from the client's");
    if (live.size() > 10) problem(r, "more than ten live touches");
    if (raw->activeTouchSlots > 10) problem(r, "activeTouchSlots > 10");
    if (platf::g_frames.size() == framesBefore && e.type != ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_CANCEL_ALL) {
      problem(r, "no frame injected for an event");
      continue;
    }
    if (platf::g_frames.size() > framesBefore) {
      const auto &frame = platf::g_frames.back();
      const POINTER_TYPE_INFO *p = nullptr;
      for (const auto &pt : frame.pointers) if (pt.touchInfo.pointerInfo.pointerId == e.pid) p = &pt;
      auto flags = p ? p->touchInfo.pointerInfo.pointerFlags : 0u;
      if (e.type == ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_DOWN &&
          !((flags & POINTER_FLAG_DOWN) && (flags & POINTER_FLAG_INCONTACT) && (flags & POINTER_FLAG_INRANGE))) problem(r, "DOWN frame without DOWN|INCONTACT|INRANGE");
      if (e.type == ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_UP && (!(flags & POINTER_FLAG_UP) || (flags & POINTER_FLAG_INCONTACT))) problem(r, "UP frame wrong");
      if (e.type == ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_CANCEL && !(flags & POINTER_FLAG_CANCELED)) problem(r, "CANCEL frame wrong");
      if (e.type == ALK_GAMESTREAM_INPUT_WIRE_TOUCH_EVENT_MOVE && !(flags & POINTER_FLAG_UPDATE)) problem(r, "MOVE frame without UPDATE");
    }
  }
  for (const auto &l : g_log) {
    if (l.level == "warning" || l.level == "error") {
      r.warnings++;
      if (!dropFirstDownOfPointer0) problem(r, l.level + ": " + l.text);
    }
  }
  if (!dropFirstDownOfPointer0) {
    if (!model.empty()) problem(r, "the scenario ends with touches down (test data)");
    // (the host may keep refreshing empty slots after a multi-finger gesture until the next touch: its own lazy compaction)
    if (!hostLive(raw.get()).empty()) problem(r, "a touch is still live on the host at the end");
  }
  return r;
}

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: replay <wire.txt>\n"); return 2; }
  auto scenarios = load(argv[1]);
  if (scenarios.empty()) { fprintf(stderr, "no scenarios\n"); return 2; }
  int failed = 0;
  size_t events = 0;
  for (const auto &s : scenarios) {
    Result r = run(s, false);
    events += r.events;
    if (!r.ok) {
      failed++;
      printf("FAIL %s\n", s.name.c_str());
      for (auto &p : r.problems) printf("   %s\n", p.c_str());
    }
  }
  printf("%zu scenarios, %zu events replayed through Sunshine touch_update, %d failed\n", scenarios.size(), events, failed);

  // negative control
  bool sawWarning = false;
  for (const auto &s : scenarios) {
    if (s.name != "3finger-staggered-up-in-order") continue;
    Result r = run(s, true);
    for (const auto &l : g_log)
      if (l.level == "warning" && l.text.find("Unexpected new pointer 0 for event 2") != std::string::npos) sawWarning = true;
    printf("negative control (DOWN and MOVE of pointer 0 removed, UP kept): %zu host warnings, \"Unexpected new pointer 0 for event 2\" %s\n",
           r.warnings, sawWarning ? "reproduced" : "NOT reproduced");
  }
  if (!sawWarning) failed++;
  return failed == 0 ? 0 : 1;
}
