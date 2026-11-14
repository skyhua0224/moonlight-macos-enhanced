#include "USBIPHostWire.h"

#include <cassert>
#include <cstdint>

int main() {
  uint8_t common[8] = {};
  assert(ALKBuildUsbIpCommon(0x0005u, 0u, common, sizeof(common)));
  assert(common[0] == 0x01u && common[1] == 0x11u && common[2] == 0 && common[3] == 5);
  const uint8_t configuration[] = {9, 2, 9, 0, 1, 1, 0, 0x80, 50};
  ALKUsbIpDeviceRecord record = {"IOUSBHostDevice@00000001", "1-2", 2, 3, 3, 0x054c, 0x0ce6,
                                 0x0100, 0, 0, 0, 1, 1, 1, configuration, sizeof(configuration)};
  uint8_t wire[400] = {}; size_t length = 0;
  assert(ALKBuildUsbIpDeviceRecord(record, wire, sizeof(wire), &length));
  assert(length == 321 && wire[0] == 'I' && wire[256] == '1' && wire[257] == '-' && wire[258] == '2');
  assert(wire[288] == 0 && wire[291] == 2 && wire[300] == 0x05 && wire[301] == 0x4c &&
         wire[302] == 0x0c && wire[303] == 0xe6 && wire[309] == 1 && wire[310] == 1 && wire[311] == 1);
  return 0;
}
