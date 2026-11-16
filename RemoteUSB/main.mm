#include "../core/network/usbip-core/include/alkaidlab/usbip_core/usbip_core.h"
#include "RootTransferValidation.h"
#include "USBIPHostWire.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <dispatch/dispatch.h>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

/* The provider uses Apple's host USB user client directly. The current macOS
 * application SDK exposes this API through IOUSBHostFamily/IOUSBLib; no
 * cross-platform USB wrapper is linked. Source basis:
 * ds5-apple-iousbhost-20261031 and ds5-apple-iousbhost-pipe-20261031. */

namespace {

struct DeviceContext {
  io_service_t service = IO_OBJECT_NULL;
  IOUSBDeviceInterface **device = nullptr;
  bool opened = false;
  IOUSBInterfaceInterface **interfaces[16] = {};
  size_t interface_count = 0;
};

struct UsbDeviceInfo {
  uint32_t struct_size = 0;
  char path[256] = {};
  char bus_id[32] = {};
  uint16_t vendor_id = 0;
  uint16_t product_id = 0;
  uint8_t device_class = 0;
  uint8_t device_speed = 0;
  uint8_t configuration_count = 0;
  uint8_t configuration[256] = {};
  uint16_t configuration_length = 0;
  uint8_t configuration_value = 0;
  uint8_t interface_count = 0;
  char serial[128] = {};
  char manufacturer[128] = {};
  char product[128] = {};
  bool claimable = false;
};

std::string json_escape(const char *value) {
  std::string result;
  if (value == nullptr)
    return result;
  for (const unsigned char c : std::string(value)) {
    if (c == '"')
      result += "\\\"";
    else if (c == '\\')
      result += "\\\\";
    else if (c == '\n')
      result += "\\n";
    else if (c == '\r')
      result += "\\r";
    else
      result += static_cast<char>(c);
  }
  return result;
}

bool string_descriptor(DeviceContext *context, UInt8 index, char *out,
                       size_t capacity) {
  if (index == 0 || out == nullptr || capacity < 2 ||
      context->device == nullptr)
    return false;
  UInt8 buffer[256] = {0};
  IOUSBDevRequest request = {};
  request.bmRequestType =
      USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
  request.bRequest = kUSBRqGetDescriptor;
  request.wValue = (kUSBStringDesc << 8) | index;
  request.wIndex = 0x0409;
  request.wLength = sizeof(buffer);
  request.pData = buffer;
  if ((*context->device)->USBDeviceOpen(context->device) != kIOReturnSuccess)
    return false;
  IOReturn result =
      (*context->device)->DeviceRequest(context->device, &request);
  (*context->device)->USBDeviceClose(context->device);
  if (result != kIOReturnSuccess || request.wLenDone < 2 ||
      buffer[1] != kUSBStringDesc)
    return false;
  size_t length = (buffer[0] - 2u) / 2u;
  if (length + 1 > capacity)
    length = capacity - 1;
  for (size_t index16 = 0; index16 < length; index16++)
    out[index16] = static_cast<char>(buffer[2 + index16 * 2]);
  out[length] = '\0';
  return true;
}

bool make_context(io_service_t service, DeviceContext *context) {
  if (context == nullptr)
    return false;
  IOCFPlugInInterface **plugin = nullptr;
  SInt32 score = 0;
  if (IOCreatePlugInInterfaceForService(service, kIOUSBDeviceUserClientTypeID,
                                        kIOCFPlugInInterfaceID, &plugin,
                                        &score) != kIOReturnSuccess ||
      plugin == nullptr)
    return false;
  HRESULT result = (*plugin)->QueryInterface(
      plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
      reinterpret_cast<LPVOID *>(&context->device));
  (*plugin)->Release(plugin);
  if (result != S_OK || context->device == nullptr)
    return false;
  context->service = service;
  return true;
}

void release_context(DeviceContext *context) {
  if (context == nullptr)
    return;
  if (context->device != nullptr) {
    for (size_t index = 0; index < context->interface_count; index++) {
      if (context->interfaces[index] != nullptr) {
        (*context->interfaces[index])->USBInterfaceClose(context->interfaces[index]);
        (*context->interfaces[index])->Release(context->interfaces[index]);
      }
    }
    context->interface_count = 0;
    if (context->opened)
      (*context->device)->USBDeviceClose(context->device);
    (*context->device)->Release(context->device);
  }
  if (context->service != IO_OBJECT_NULL)
    IOObjectRelease(context->service);
  *context = {};
}

static bool open_interfaces(DeviceContext *context) {
  if (context->interface_count != 0) return true;
  IOUSBFindInterfaceRequest request = {kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare,
                                       kIOUSBFindInterfaceDontCare, kIOUSBFindInterfaceDontCare};
  io_iterator_t iterator = IO_OBJECT_NULL;
  if ((*context->device)->CreateInterfaceIterator(context->device, &request, &iterator) != kIOReturnSuccess) return false;
  io_service_t service = IO_OBJECT_NULL;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL && context->interface_count < 16) {
    IOCFPlugInInterface **plugin = nullptr; SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID,
                                          kIOCFPlugInInterfaceID, &plugin, &score) == kIOReturnSuccess && plugin != nullptr) {
      IOUSBInterfaceInterface **interface = nullptr;
      HRESULT result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                                   reinterpret_cast<LPVOID *>(&interface));
      (*plugin)->Release(plugin);
      if (result == S_OK && interface != nullptr &&
          (*interface)->USBInterfaceOpenSeize(interface) == kIOReturnSuccess) {
        context->interfaces[context->interface_count++] = interface;
      } else if (interface != nullptr) {
        (*interface)->Release(interface);
      }
    }
    IOObjectRelease(service);
  }
  IOObjectRelease(iterator);
  return context->interface_count != 0;
}

bool read_info(void *opaque, UsbDeviceInfo *info) {
  DeviceContext *context = static_cast<DeviceContext *>(opaque);
  if (context == nullptr || context->device == nullptr || info == nullptr)
    return false;
  UInt16 vendor = 0, product = 0;
  UInt32 location = 0;
  UInt8 speed = 0, configurations = 0;
  UInt8 device_class = 0;
  if ((*context->device)->GetDeviceVendor(context->device, &vendor) !=
          kIOReturnSuccess ||
      (*context->device)->GetDeviceProduct(context->device, &product) !=
          kIOReturnSuccess ||
      (*context->device)->GetLocationID(context->device, &location) !=
          kIOReturnSuccess ||
      (*context->device)->GetDeviceSpeed(context->device, &speed) !=
          kIOReturnSuccess ||
      (*context->device)->GetDeviceClass(context->device, &device_class) !=
          kIOReturnSuccess ||
      (*context->device)
              ->GetNumberOfConfigurations(context->device, &configurations) !=
          kIOReturnSuccess)
    return false;
  memset(info, 0, sizeof(*info));
  info->struct_size = sizeof(*info);
  std::snprintf(info->bus_id, sizeof(info->bus_id), "mac-%08x", location);
  std::snprintf(info->path, sizeof(info->path), "IOUSBHostDevice@%08x", location);
  info->vendor_id = vendor;
  info->product_id = product;
  info->device_class = device_class;
  info->device_speed = speed;
  info->configuration_count = configurations;
  info->claimable = (*context->device)->USBDeviceOpen(context->device) == kIOReturnSuccess;
  if (info->claimable) (*context->device)->USBDeviceClose(context->device);
  UInt8 configuration = 0;
  IOUSBConfigurationDescriptorPtr descriptor = nullptr;
  if (configurations > 0 &&
      (*context->device)
              ->GetConfigurationDescriptorPtr(
                  context->device, 0, &descriptor) == kIOReturnSuccess &&
      descriptor != nullptr) {
    info->configuration_length = static_cast<UInt16>(descriptor->wTotalLength);
    if (info->configuration_length > sizeof(info->configuration))
      info->configuration_length = sizeof(info->configuration);
    memcpy(info->configuration, descriptor, info->configuration_length);
    configuration = descriptor->bConfigurationValue;
    info->configuration_value = descriptor->bConfigurationValue;
    info->interface_count = descriptor->bNumInterfaces;
  }
  (void)configuration;
  UInt8 manufacturer_index = 0, product_index = 0, serial_index = 0;
  (*context->device)->USBGetManufacturerStringIndex(context->device, &manufacturer_index);
  (*context->device)->USBGetProductStringIndex(context->device, &product_index);
  (*context->device)->USBGetSerialNumberStringIndex(context->device, &serial_index);
  string_descriptor(context, manufacturer_index, info->manufacturer, sizeof(info->manufacturer));
  string_descriptor(context, product_index, info->product, sizeof(info->product));
  string_descriptor(context, serial_index, info->serial, sizeof(info->serial));
  return true;
}

bool get_descriptor(void *opaque, uint8_t type, uint8_t index,
                    uint16_t language, uint8_t *out, uint32_t capacity,
                    uint32_t *length) {
  DeviceContext *context = static_cast<DeviceContext *>(opaque);
  if (context == nullptr || context->device == nullptr || out == nullptr ||
      length == nullptr || capacity > UINT16_MAX)
    return false;
  IOUSBDevRequest request = {};
  request.bmRequestType =
      USBmakebmRequestType(kUSBIn, kUSBStandard, kUSBDevice);
  request.bRequest = kUSBRqGetDescriptor;
  request.wValue = (static_cast<UInt16>(type) << 8) | index;
  request.wIndex = language;
  request.wLength = static_cast<UInt16>(capacity);
  request.pData = out;
  if ((*context->device)->USBDeviceOpenSeize(context->device) !=
      kIOReturnSuccess)
    return false;
  context->opened = true;
  IOReturn result =
      (*context->device)->DeviceRequest(context->device, &request);
  if (result != kIOReturnSuccess) {
    (*context->device)->USBDeviceClose(context->device);
    context->opened = false;
    return false;
  }
  *length = request.wLenDone;
  return true;
}

bool enumerate_one(const char *requested, DeviceContext **selected,
                   UsbDeviceInfo *selected_info) {
  CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
  if (matching == nullptr)
    return false;
  io_iterator_t iterator = IO_OBJECT_NULL;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) !=
      kIOReturnSuccess)
    return false;
  bool found = false;
  io_service_t service = IO_OBJECT_NULL;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    DeviceContext context = {};
    if (!make_context(service, &context)) {
      IOObjectRelease(service);
      continue;
    }
    UsbDeviceInfo info = {.struct_size = sizeof(info)};
    bool valid = read_info(&context, &info);
    bool match = valid && info.device_class != 9u && info.claimable &&
        (requested == nullptr || strcmp(requested, info.bus_id) == 0);
    if (match && selected != nullptr) {
      DeviceContext *heap = new DeviceContext(context);
      *selected = heap;
      if (selected_info != nullptr)
        *selected_info = info;
      context = {};
      found = true;
    }
    release_context(&context);
    if (found)
      break;
  }
  IOObjectRelease(iterator);
  return found;
}

int list_devices() {
  CFMutableDictionaryRef matching = IOServiceMatching(kIOUSBDeviceClassName);
  if (matching == nullptr)
    return 1;
  io_iterator_t iterator = IO_OBJECT_NULL;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) !=
      kIOReturnSuccess)
    return 1;
  std::cout << '[';
  bool first = true;
  io_service_t service = IO_OBJECT_NULL;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    DeviceContext context = {};
    if (make_context(service, &context)) {
      UsbDeviceInfo info = {.struct_size = sizeof(info)};
      if (read_info(&context, &info) && info.device_class != 9u) {
        if (!first)
          std::cout << ',';
        first = false;
        std::cout << "{\"busId\":\"" << json_escape(info.bus_id)
                  << "\",\"vid\":" << info.vendor_id
                  << ",\"pid\":" << info.product_id << ",\"vidPid\":\"";
        char vid_pid[10] = {};
        std::snprintf(vid_pid, sizeof(vid_pid), "%04x:%04x", info.vendor_id, info.product_id);
        std::cout << vid_pid << "\",\"serial\":\"" << json_escape(info.serial)
                  << "\",\"manufacturer\":\"" << json_escape(info.manufacturer)
                  << "\",\"product\":\"" << json_escape(info.product)
                  << "\",\"claimable\":" << (info.claimable ? "true" : "false")
                  << "}";
      }
      release_context(&context);
    } else {
      IOObjectRelease(service);
    }
  }
  IOObjectRelease(iterator);
  std::cout << "]\n";  // close the array: the app parses this with JSONDecoder (issue #86)
  std::cout.flush();
  return 0;
}

static uint32_t get_u32be(const uint8_t *p) {
  return ((uint32_t)p[0] << 24u) | ((uint32_t)p[1] << 16u) |
         ((uint32_t)p[2] << 8u) | p[3];
}
static void put_u32be(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24u);
  p[1] = (uint8_t)(v >> 16u);
  p[2] = (uint8_t)(v >> 8u);
  p[3] = (uint8_t)v;
}
static bool read_full_fd(int fd, void *buffer, size_t length) {
  uint8_t *p = static_cast<uint8_t *>(buffer);
  while (length != 0) {
    ssize_t n = read(fd, p, length);
    if (n <= 0)
      return false;
    p += n;
    length -= (size_t)n;
  }
  return true;
}
static bool write_full_fd(int fd, const void *buffer, size_t length) {
  const uint8_t *p = static_cast<const uint8_t *>(buffer);
  while (length != 0) {
    ssize_t n = write(fd, p, length);
    if (n <= 0)
      return false;
    p += n;
    length -= (size_t)n;
  }
  return true;
}
struct IsoWait { dispatch_semaphore_t semaphore; IOReturn result; };
static void IsoComplete(void *refcon, IOReturn result, void *) {
  IsoWait *wait = static_cast<IsoWait *>(refcon); wait->result = result; dispatch_semaphore_signal(wait->semaphore);
}
static bool write_common(int fd, uint16_t opcode, uint32_t status) {
  uint8_t h[8] = {};
  if (!ALKBuildUsbIpCommon(opcode, status, h, sizeof(h))) return false;
  return write_full_fd(fd, h, sizeof(h));
}
static bool write_device_record(int fd, const UsbDeviceInfo &info,
                                uint32_t index) {
  uint8_t record[600] = {}; size_t length = 0;
  ALKUsbIpDeviceRecord wire = {info.path, info.bus_id, index, index + 1u, info.device_speed,
                               info.vendor_id, info.product_id, 0x0100u, info.device_class, 0, 0,
                               info.configuration_value, info.configuration_count, info.interface_count,
                               info.configuration, info.configuration_length};
  if (!ALKBuildUsbIpDeviceRecord(wire, record, sizeof(record), &length)) return false;
  return write_full_fd(fd, record, length);
}
static bool perform_transfer(DeviceContext *context, const AlkUsbIpUrb *urb,
                             const uint8_t *out_data, uint8_t *in_data,
                             uint32_t capacity, uint32_t *actual,
                             int32_t *status) {
  if (context == nullptr || urb == nullptr || actual == nullptr ||
      status == nullptr)
    return false;
  if (!context->opened &&
      (*context->device)->USBDeviceOpenSeize(context->device) !=
          kIOReturnSuccess)
    return false;
  context->opened = true;
  if (urb->endpoint != 0) {
    if (!open_interfaces(context)) { *status = -1; return false; }
    const UInt8 endpoint = (UInt8)(urb->endpoint & 0x7fu);
    const UInt8 wanted_direction = urb->direction == 1u ? kUSBIn : kUSBOut;
    for (size_t index = 0; index < context->interface_count; index++) {
      IOUSBInterfaceInterface **interface = context->interfaces[index];
      UInt8 pipe_count = 0;
      if ((*interface)->GetNumEndpoints(interface, &pipe_count) != kIOReturnSuccess) continue;
      for (UInt8 pipe = 1; pipe <= pipe_count; pipe++) {
        UInt8 direction = 0, number = 0, transfer_type = 0, interval = 0; UInt16 max_packet = 0;
        if ((*interface)->GetPipeProperties(interface, pipe, &direction, &number, &transfer_type,
                                            &max_packet, &interval) != kIOReturnSuccess ||
            number != endpoint || direction != wanted_direction) continue;
        UInt32 size = urb->transfer_buffer_length;
        if (transfer_type == 1u) {
          UInt64 frame = 0; AbsoluteTime at = {};
          if ((*context->device)->GetBusFrameNumber(context->device, &frame, &at) != kIOReturnSuccess) {
            *status = -1; return false;
          }
          UInt32 count = urb->number_of_packets == UINT32_MAX ? 1u : urb->number_of_packets;
          if (count == 0u || count > ALK_USBIP_MAX_ISO_PACKETS) { *status = -1; return false; }
          std::vector<IOUSBIsocFrame> frames(count);
          for (UInt32 frameIndex = 0; frameIndex < count; frameIndex++) {
            frames[frameIndex].frReqCount = (UInt16)std::min<UInt32>(max_packet, size);
            frames[frameIndex].frActCount = 0;
            frames[frameIndex].frStatus = kIOReturnSuccess;
          }
          IsoWait wait = {dispatch_semaphore_create(0), kIOReturnError};
          IOReturn result = urb->direction == 1u
              ? (*interface)->ReadIsochPipeAsync(interface, pipe, in_data, frame, count, frames.data(), IsoComplete, &wait)
              : (*interface)->WriteIsochPipeAsync(interface, pipe, const_cast<uint8_t *>(out_data), frame, count, frames.data(), IsoComplete, &wait);
          if (result == kIOReturnSuccess)
            dispatch_semaphore_wait(wait.semaphore, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
          result = result == kIOReturnSuccess ? wait.result : result;
          uint32_t total = 0; for (const IOUSBIsocFrame &isoc : frames) total += isoc.frActCount;
          *actual = total; *status = result == kIOReturnSuccess ? 0 : (int32_t)result;
          return result == kIOReturnSuccess;
        }
        IOReturn result = urb->direction == 1u
            ? (*interface)->ReadPipe(interface, pipe, in_data, &size)
            : (*interface)->WritePipe(interface, pipe, const_cast<uint8_t *>(out_data), size);
        *actual = size; *status = result == kIOReturnSuccess ? 0 : (int32_t)result;
        return result == kIOReturnSuccess;
      }
    }
    *status = -1; return false;
  }
  IOUSBDevRequest request = {};
  request.bmRequestType = urb->setup[0];
  request.bRequest = urb->setup[1];
  request.wValue = (UInt16)urb->setup[2] | ((UInt16)urb->setup[3] << 8u);
  request.wIndex = (UInt16)urb->setup[4] | ((UInt16)urb->setup[5] << 8u);
  request.wLength = (UInt16)urb->setup[6] | ((UInt16)urb->setup[7] << 8u);
  if (!ALKRemoteUSBControlLengthIsBounded(request.wLength, urb->transfer_buffer_length, capacity)) {
    *actual = 0;
    *status = -1;
    return false;
  }
  request.pData =
      const_cast<uint8_t *>((urb->direction == 1u) ? in_data : out_data);
  IOReturn result =
      (*context->device)->DeviceRequest(context->device, &request);
  *actual = request.wLenDone;
  *status = result == kIOReturnSuccess ? 0 : (int32_t)result;
  (void)capacity;
  return result == kIOReturnSuccess;
}

class UsbIpHostServer {
public:
  UsbIpHostServer(DeviceContext *context, const UsbDeviceInfo &info)
      : context_(context), info_(info) {
    AlkUsbIpListenerCallbacks callbacks = {sizeof(callbacks), ALK_USBIP_CORE_ABI_VERSION, this, listenerEvent};
    (void)alk_usbip_listener_create(&callbacks, &listener_);
    AlkUsbIpProviderSchedule schedule = {sizeof(schedule), ALK_USBIP_CORE_ABI_VERSION, 128u, this,
                                         providerSubmit, providerUnlink, nullptr};
    (void)alk_usbip_provider_scheduler_create(&schedule, &scheduler_);
  }
  ~UsbIpHostServer() {
    alk_usbip_provider_scheduler_destroy(scheduler_);
    alk_usbip_listener_destroy(listener_);
    if (listen_fd_ >= 0)
      close(listen_fd_);
  }
  bool listen_on(const char *host, uint16_t requested, uint16_t *actual) {
    listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd_ < 0)
      return false;
    int reuse = 1;
    setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(requested);
    if (inet_pton(AF_INET, host, &address.sin_addr) != 1 ||
        bind(listen_fd_, (sockaddr *)&address, sizeof(address)) != 0 ||
        listen(listen_fd_, 4) != 0)
      return false;
    socklen_t length = sizeof(address);
    if (getsockname(listen_fd_, (sockaddr *)&address, &length) != 0)
      return false;
    *actual = ntohs(address.sin_port);
    return true;
  }
  void stop() {
    stopped_.store(true);
    if (listen_fd_ >= 0)
      shutdown(listen_fd_, SHUT_RDWR);
    int active = active_fd_.load();
    if (active >= 0) shutdown(active, SHUT_RDWR);
  }
  void serve() {
    while (!stopped_.load()) {
      int fd = accept(listen_fd_, nullptr, nullptr);
      if (fd < 0) {
        if (stopped_.load())
          break;
        continue;
      }
      active_fd_.store(fd);
      handle(fd);
      close(fd);
      active_fd_.store(-1);
    }
  }

private:
  static void listenerEvent(void *, AlkUsbIpListenerEvent, const AlkUsbIpUrb *, const AlkUsbIpCompletion *) {}
  static AlkUsbIpError providerSubmit(void *, const AlkUsbIpUrb *urb, AlkUsbIpCompletion *completion) {
    if (urb == nullptr || completion == nullptr) return ALK_USBIP_ERROR_INVALID_ARGUMENT;
    completion->sequence = urb->sequence; completion->status = 0; return ALK_USBIP_OK;
  }
  static AlkUsbIpError providerUnlink(void *, uint32_t sequence, AlkUsbIpCompletion *completion) {
    if (completion == nullptr) return ALK_USBIP_ERROR_INVALID_ARGUMENT;
    completion->sequence = sequence; completion->status = -104; return ALK_USBIP_OK;
  }
  void handle(int fd) {
    uint8_t header[8] = {};
    if (!read_full_fd(fd, header, sizeof(header)))
      return;
    uint16_t opcode = (uint16_t)((header[2] << 8u) | header[3]);
    if (opcode == ALK_USBIP_OP_REQ_DEVLIST) {
      if (!write_common(fd, ALK_USBIP_OP_REP_DEVLIST, 0))
        return;
      uint8_t count[4] = {0, 0, 0, 1};
      if (!write_full_fd(fd, count, 4))
        return;
      write_device_record(fd, info_, 0);
      return;
    }
    if (opcode != ALK_USBIP_OP_REQ_IMPORT)
      return;
    uint8_t busid[32] = {};
    if (!read_full_fd(fd, busid, sizeof(busid)))
      return;
    if (strncmp((const char *)busid, info_.bus_id, sizeof(info_.bus_id)) != 0) {
      write_common(fd, ALK_USBIP_OP_REP_IMPORT, 1);
      return;
    }
    if (!write_common(fd, ALK_USBIP_OP_REP_IMPORT, 0) ||
        !write_device_record(fd, info_, 0))
      return;
    (void)alk_usbip_listener_notify(listener_, ALK_USBIP_LISTENER_OPEN, nullptr, nullptr);
    AlkUsbIpRequestTracker *tracker = nullptr;
    if (alk_usbip_request_tracker_create(&tracker) != ALK_USBIP_OK)
      return;
    while (!stopped_.load()) {
      uint8_t command[48] = {};
      if (!read_full_fd(fd, command, sizeof(command)))
        break;
      uint32_t kind = get_u32be(command);
      uint32_t transfer = get_u32be(command + 24);
      uint32_t packets = get_u32be(command + 32);
      if (kind == ALK_USBIP_CMD_UNLINK) {
        uint32_t sequence = 0;
        if (alk_usbip_parse_unlink(command, sizeof(command), &sequence) !=
            ALK_USBIP_OK)
          break;
        AlkUsbIpCompletion completion = {sizeof(completion),
                                         ALK_USBIP_CORE_ABI_VERSION};
        if (alk_usbip_request_tracker_unlink(tracker, sequence, &completion) !=
            ALK_USBIP_OK)
          continue;
        (void)alk_usbip_provider_scheduler_unlink(scheduler_, sequence, &completion);
        (void)alk_usbip_listener_notify(listener_, ALK_USBIP_LISTENER_UNLINK, nullptr, &completion);
        uint8_t reply[64] = {};
        size_t reply_len = 0;
        if (alk_usbip_build_ret_unlink_ex(&completion, reply, sizeof(reply),
                                          &reply_len) == ALK_USBIP_OK)
          write_full_fd(fd, reply, reply_len);
        continue;
      }
      if (kind != ALK_USBIP_CMD_SUBMIT ||
          transfer > ALK_USBIP_MAX_TRANSFER_BYTES ||
          packets > ALK_USBIP_MAX_ISO_PACKETS)
        break;
      const uint32_t direction = get_u32be(command + 12);
      const size_t payload_len = direction == 0 ? transfer : 0;
      const size_t iso_len = (size_t)packets * ALK_USBIP_ISO_DESCRIPTOR_BYTES;
      std::vector<uint8_t> wire(sizeof(command) + payload_len + iso_len);
      memcpy(wire.data(), command, sizeof(command));
      if (payload_len &&
          !read_full_fd(fd, wire.data() + sizeof(command), payload_len))
        break;
      if (iso_len &&
          !read_full_fd(fd, wire.data() + sizeof(command) + payload_len,
                        iso_len))
        break;
      std::vector<AlkUsbIpIsoPacket> iso(packets);
      AlkUsbIpUrb urb = {sizeof(urb), ALK_USBIP_CORE_ABI_VERSION,
                         0,           0,
                         0,           0,
                         0,           0,
                         0,           0,
                         0,           {},
                         iso.data(),  packets};
      if (alk_usbip_parse_submit(wire.data(), wire.size(), &urb) !=
              ALK_USBIP_OK ||
          alk_usbip_request_tracker_submit(tracker, &urb) != ALK_USBIP_OK)
        break;
      (void)alk_usbip_provider_scheduler_submit(scheduler_, &urb);
      (void)alk_usbip_listener_notify(listener_, ALK_USBIP_LISTENER_SUBMIT, &urb, nullptr);
      std::vector<uint8_t> payload(transfer);
      uint32_t actual = 0;
      int32_t status = 0;
      perform_transfer(context_, &urb,
                       payload_len ? wire.data() + sizeof(command) : nullptr,
                       payload.data(), transfer, &actual, &status);
      AlkUsbIpCompletion completion = {sizeof(completion),
                                       ALK_USBIP_CORE_ABI_VERSION,
                                       status,
                                       actual,
                                       packets,
                                       false,
                                       urb.sequence,
                                       urb.device_id,
                                       urb.direction,
                                       urb.endpoint,
                                       iso.data(),
                                       packets,
                                       packets};
      alk_usbip_request_tracker_complete(tracker, urb.sequence, &completion);
      (void)alk_usbip_provider_scheduler_complete(scheduler_, urb.sequence, &completion);
      std::vector<uint8_t> reply(48 + actual + iso_len);
      size_t reply_len = 0;
      if (alk_usbip_build_ret_submit(&completion, payload.data(), actual,
                                     reply.data(), reply.size(),
                                     &reply_len) == ALK_USBIP_OK)
        write_full_fd(fd, reply.data(), reply_len);
    }
    (void)alk_usbip_listener_notify(listener_, ALK_USBIP_LISTENER_CLOSE, nullptr, nullptr);
    alk_usbip_request_tracker_destroy(tracker);
  }
  DeviceContext *context_;
  UsbDeviceInfo info_;
  int listen_fd_ = -1;
  std::atomic_bool stopped_ = false;
  std::atomic_int active_fd_ = -1;
  AlkUsbIpListener *listener_ = nullptr;
  AlkUsbIpProviderScheduler *scheduler_ = nullptr;
};
volatile sig_atomic_t stopped = 0;
void stop_signal(int) { stopped = 1; }

int serve(const char *bus_id, const char *listen_host, uint16_t listen_port, bool detach) {
  if (geteuid() != 0) {
    std::cout << "ERROR {\"error\":\"device_capture_requires_root\"}\n"
              << std::flush;
    return 4;
  }
  DeviceContext *context = nullptr;
  UsbDeviceInfo info = {};
  if (!enumerate_one(bus_id, &context, &info) || context == nullptr) {
    std::cout << "ERROR {\"error\":\"device_not_found\"}\n" << std::flush;
    return 2;
  }
  UsbIpHostServer server(context, info);
  uint16_t actual_port = 0;
  if (!server.listen_on(listen_host, listen_port, &actual_port)) {
    release_context(context);
    delete context;
    std::cout << "ERROR {\"error\":\"listen_failed\"}\n" << std::flush;
    return 3;
  }
  std::signal(SIGTERM, stop_signal);
  std::signal(SIGINT, stop_signal);
  std::cout << "READY " << actual_port << '\n' << std::flush;
  std::thread worker([&] { server.serve(); });
  std::string line;
  if (detach) {
    while (!stopped) std::this_thread::sleep_for(std::chrono::milliseconds(100));
  } else {
    while (!stopped) {
      fd_set set; FD_ZERO(&set); FD_SET(STDIN_FILENO, &set);
      timeval timeout = {0, 100000};
      int ready = select(STDIN_FILENO + 1, &set, nullptr, nullptr, &timeout);
      if (ready > 0 && !std::getline(std::cin, line)) break;
    }
  }
  server.stop();
  if (worker.joinable())
    worker.join();
  release_context(context);
  delete context;
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  if (argc >= 3 && std::string(argv[1]) == "list" &&
      std::string(argv[2]) == "--json")
    return list_devices();
  if (argc >= 4 && std::string(argv[1]) == "serve" &&
      std::string(argv[2]) == "--bind") {
    std::string listen_host = "127.0.0.1";
    uint16_t listen_port = 0;
    for (int index = 4; index + 1 < argc; index++)
      if (std::string(argv[index]) == "--listen") {
        std::string value(argv[index + 1]);
        size_t colon = value.rfind(':');
        if (colon != std::string::npos) {
          listen_host = value.substr(0, colon);
          listen_port = (uint16_t)std::strtoul(value.substr(colon + 1).c_str(),
                                               nullptr, 10);
        }
      }
    bool detach = false;
    for (int index = 4; index < argc; index++) if (std::string(argv[index]) == "--detach") detach = true;
    return serve(argv[3], listen_host.c_str(), listen_port, detach);
  }
  std::fprintf(stderr, "usage: moonlight-usbd list --json | serve --bind "
                       "<busid> [--listen host:port]\n");
  return 1;
}
