#pragma once

#include <cstddef>
#include <cstdint>

struct ALKUsbIpDeviceRecord {
  const char *path;
  const char *busid;
  uint32_t busnum;
  uint32_t devnum;
  uint32_t speed;
  uint16_t vendor;
  uint16_t product;
  uint16_t bcd_device;
  uint8_t device_class;
  uint8_t device_subclass;
  uint8_t device_protocol;
  uint8_t configuration_value;
  uint8_t configuration_count;
  uint8_t interface_count;
  const uint8_t *configuration;
  size_t configuration_length;
};

bool ALKBuildUsbIpCommon(uint16_t opcode, uint32_t status, uint8_t *out, size_t capacity);
bool ALKBuildUsbIpDeviceRecord(const ALKUsbIpDeviceRecord &record, uint8_t *out, size_t capacity,
                               size_t *length);
