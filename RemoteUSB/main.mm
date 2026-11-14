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
        std::printf("%04x:%04x", info.vendor_id, info.product_id);
        std::cout << "\",\"serial\":\"" << json_escape(info.serial)
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
  std::cout << "\n";
  return 0;
}

