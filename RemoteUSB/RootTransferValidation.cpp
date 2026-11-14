#include "RootTransferValidation.h"

bool ALKRemoteUSBControlLengthIsBounded(uint16_t setupLength,
                                        uint32_t transferBufferLength,
                                        uint32_t providerCapacity) {
  return static_cast<uint32_t>(setupLength) <= transferBufferLength &&
         static_cast<uint32_t>(setupLength) <= providerCapacity;
}
