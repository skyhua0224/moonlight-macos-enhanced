#include "../../Limelight/Input/DS5PadTwin.h"

#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)

int main(void) {
  char a[13], b[13];
  CHECK(ds5_serial_key("00:00:5E:00:53:08", a) && strcmp(a, "00005e005308") == 0);
  CHECK(ds5_serial_key("00-00-5e-00-53-08", b) && strcmp(a, b) == 0);
  CHECK(ds5_serial_key("00005E005308", b) && strcmp(a, b) == 0);
  CHECK(!ds5_serial_key("location-00141000", b));
  CHECK(!ds5_serial_key("02DA55000001x", b));
  CHECK(!ds5_serial_key("00005E0053", b));          // too short
  CHECK(!ds5_serial_key("00005E005308FF", b));      // too long
  CHECK(!ds5_serial_key(NULL, b));
  // Same pad on both transports: the USB one is kept, whichever came first.
  CHECK(ds5_twin_decide(true, true, false, true) == DS5_TWIN_IGNORE_NEW);    // Bluetooth after USB
  CHECK(ds5_twin_decide(true, true, true, false) == DS5_TWIN_REPLACE_OLD);   // USB after Bluetooth
  CHECK(ds5_twin_decide(true, true, true, true) == DS5_TWIN_IGNORE_NEW);     // the same transport twice
  CHECK(ds5_twin_decide(false, true, true, false) == DS5_TWIN_NONE);         // two different pads
  CHECK(ds5_twin_decide(true, false, false, true) == DS5_TWIN_NONE);         // the earlier device has gone
  if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
  printf("ds5 pad twin tests passed\n");
  return 0;
}
