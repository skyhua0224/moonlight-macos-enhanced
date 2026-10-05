#include <asio.hpp>
#include <libusb-1.0/libusb.h>
#include "usbipdcpp/LibusbHandler/LibusbServer.h"
#include "usbipdcpp/LibusbHandler/tools.h"

#include <csignal>
#include <cstdio>
#include <chrono>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {

std::string json_escape(const std::string &value) {
  std::string result;
  for (unsigned char c : value) {
    switch (c) {
    case '"': result += "\\\""; break;
    case '\\': result += "\\\\"; break;
    case '\n': result += "\\n"; break;
    case '\r': result += "\\r"; break;
    case '\t': result += "\\t"; break;
    default: result += static_cast<char>(c); break;
    }
  }
  return result;
}

std::string descriptor(libusb_device_handle *handle, uint8_t index) {
  if (!handle || index == 0) return {};
  char buffer[256] = {};
  int length = libusb_get_string_descriptor_ascii(
      handle, index, reinterpret_cast<unsigned char *>(buffer), sizeof(buffer) - 1);
  return length > 0 ? std::string(buffer, static_cast<size_t>(length)) : std::string {};
}

bool claimable(libusb_device *device) {
  libusb_config_descriptor *config = nullptr;
  if (libusb_get_active_config_descriptor(device, &config) != LIBUSB_SUCCESS) return false;
  libusb_device_handle *handle = nullptr;
  bool result = libusb_open(device, &handle) == LIBUSB_SUCCESS;
  if (result) {
    for (int i = 0; i < config->bNumInterfaces; ++i) {
      uint8_t number = config->interface[i].altsetting[0].bInterfaceNumber;
      if (libusb_claim_interface(handle, number) != LIBUSB_SUCCESS) {
        result = false;
        break;
      }
      libusb_release_interface(handle, number);
    }
  }
  if (handle) libusb_close(handle);
  libusb_free_config_descriptor(config);
  return result;
}

int list_devices() {
  if (libusb_init(nullptr) != LIBUSB_SUCCESS) return 1;
  libusb_device **list = nullptr;
  ssize_t count = libusb_get_device_list(nullptr, &list);
  if (count < 0) {
    libusb_exit(nullptr);
    return 1;
  }
  std::cout << '[';
  bool first = true;
  for (ssize_t i = 0; i < count; ++i) {
    libusb_device_descriptor info {};
    if (libusb_get_device_descriptor(list[i], &info) != LIBUSB_SUCCESS ||
        info.bDeviceClass == LIBUSB_CLASS_HUB) continue;
    libusb_device_handle *handle = nullptr;
    libusb_open(list[i], &handle);
    std::string busid = usbipdcpp::get_device_busid(list[i]);
    char vidpid[12] = {};
    std::snprintf(vidpid, sizeof(vidpid), "%04x:%04x", info.idVendor, info.idProduct);
    if (!first) std::cout << ',';
    first = false;
    std::cout << "{\"busId\":\"" << json_escape(busid)
              << "\",\"vid\":" << info.idVendor
              << ",\"pid\":" << info.idProduct
              << ",\"vidPid\":\"" << vidpid << "\""
              << ",\"serial\":\"" << json_escape(descriptor(handle, info.iSerialNumber)) << "\""
              << ",\"manufacturer\":\"" << json_escape(descriptor(handle, info.iManufacturer)) << "\""
              << ",\"product\":\"" << json_escape(descriptor(handle, info.iProduct)) << "\""
              << ",\"claimable\":" << (claimable(list[i]) ? "true" : "false") << '}';
    if (handle) libusb_close(handle);
  }
  libusb_free_device_list(list, 1);
  libusb_exit(nullptr);
  std::cout << "\n";
  return 0;
}

volatile sig_atomic_t stopped = 0;
void stop_signal(int) { stopped = 1; }

int serve(const std::vector<std::string> &busids) {
  if (libusb_init(nullptr) != LIBUSB_SUCCESS) return 1;
  usbipdcpp::LibusbServer server({.skip_hub = true, .auto_bind_hotplug = false});
  for (const auto &busid : busids) {
    libusb_device *device = usbipdcpp::LibusbServer::find_by_busid(busid);
    if (!device || !claimable(device) ||
        server.bind_host_device(device) != usbipdcpp::DeviceOperationResult::Success) {
      std::cout << "ERROR {\"error\":\"device_bind_failed\",\"busid\":\""
                << json_escape(busid) << "\"}\n" << std::flush;
      return 2;
    }
  }
  asio::error_code error;
  error = server.start(asio::ip::tcp::endpoint(asio::ip::make_address("127.0.0.1", error), 0));
  if (error || server.get_server().endpoint().port() == 0) {
    std::cout << "ERROR {\"error\":\"listen_failed\"}\n" << std::flush;
    return 3;
  }
  std::signal(SIGTERM, stop_signal);
  std::signal(SIGINT, stop_signal);
  std::cout << "READY " << server.get_server().endpoint().port() << '\n' << std::flush;
  std::thread stdin_watcher([] { std::string line; while (std::getline(std::cin, line)) {} stopped = 1; });
  while (!stopped) std::this_thread::sleep_for(std::chrono::milliseconds(50));
  if (stdin_watcher.joinable()) stdin_watcher.detach();
  server.stop();
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  if (argc >= 3 && std::string(argv[1]) == "list" && std::string(argv[2]) == "--json") {
    return list_devices();
  }
  if (argc >= 4 && std::string(argv[1]) == "serve") {
    std::vector<std::string> busids;
    for (int i = 2; i + 1 < argc; ++i) if (std::string(argv[i]) == "--bind") busids.emplace_back(argv[++i]);
    if (busids.empty()) return 1;
    return serve(busids);
  }
  std::fprintf(stderr, "usage: moonlight-usbd list --json | serve --bind <busid>\n");
  return 1;
}
