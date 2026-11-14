#include "USBIPHostWire.h"

#include <cstring>

static void put32(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24u); p[1] = (uint8_t)(v >> 16u); p[2] = (uint8_t)(v >> 8u); p[3] = (uint8_t)v;
}
static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8u); p[1] = (uint8_t)v; }

bool ALKBuildUsbIpCommon(uint16_t opcode, uint32_t status, uint8_t *out, size_t capacity) {
  if (out == nullptr || capacity < 8u) return false;
  out[0] = 0x01u; out[1] = 0x11u; put16(out + 2u, opcode); put32(out + 4u, status); return true;
}

bool ALKBuildUsbIpDeviceRecord(const ALKUsbIpDeviceRecord &record, uint8_t *out, size_t capacity,
                               size_t *length) {
  if (out == nullptr || length == nullptr || capacity < 312u + record.configuration_length ||
      record.configuration_length > 256u || record.path == nullptr || record.busid == nullptr) return false;
  std::memset(out, 0, 312u + record.configuration_length);
  std::strncpy((char *)out, record.path, 255u);
  std::strncpy((char *)(out + 256u), record.busid, 31u);
  put32(out + 288u, record.busnum); put32(out + 292u, record.devnum); put32(out + 296u, record.speed);
  put16(out + 300u, record.vendor); put16(out + 302u, record.product); put16(out + 304u, record.bcd_device);
  out[306] = record.device_class; out[307] = record.device_subclass; out[308] = record.device_protocol;
  out[309] = record.configuration_value; out[310] = record.configuration_count; out[311] = record.interface_count;
  if (record.configuration_length != 0u && record.configuration != nullptr)
    std::memcpy(out + 312u, record.configuration, record.configuration_length);
  *length = 312u + record.configuration_length; return true;
}
