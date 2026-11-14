#include "RootTransferValidation.h"

#include <cassert>

int main() {
  assert(ALKRemoteUSBControlLengthIsBounded(64, 64, 64));
  assert(!ALKRemoteUSBControlLengthIsBounded(65, 64, 128));
  assert(!ALKRemoteUSBControlLengthIsBounded(65, 128, 64));
  assert(!ALKRemoteUSBControlLengthIsBounded(0xffffu, 1024, 1024));
  return 0;
}
