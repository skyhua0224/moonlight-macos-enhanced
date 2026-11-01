#pragma once

#include <cstdint>

bool ALKRemoteUSBControlLengthIsBounded(uint16_t setupLength,
                                        uint32_t transferBufferLength,
                                        uint32_t providerCapacity);
