#include "../../Limelight/Input/DS5PadMix.h"

#include <math.h>
#include <stdio.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)
#define NEAR(a, b) (fabsf((a) - (b)) < 1e-6f)

int main(void) {
  float a, b;
  DS5PadMix mix = ds5_pad_mix_default();
  // Speaker, default: audible on both channels, whichever the pad takes; a one-sided source loses nothing.
  ds5_pad_mix_frame(&mix, false, 0.8f, 0.0f, &a, &b);
  CHECK(NEAR(a, 0.4f) && NEAR(b, 0.4f));
  ds5_pad_mix_frame(&mix, false, 0.0f, -0.6f, &a, &b);
  CHECK(NEAR(a, -0.3f) && NEAR(b, -0.3f));
  // Headset, default: stereo as is.
  ds5_pad_mix_frame(&mix, true, 0.8f, -0.2f, &a, &b);
  CHECK(NEAR(a, 0.8f) && NEAR(b, -0.2f));
  // The corrections, by name.
  mix = ds5_pad_mix_from_names("ch1", "swap");
  ds5_pad_mix_frame(&mix, false, 0.4f, 0.2f, &a, &b);
  CHECK(NEAR(a, 0.3f) && NEAR(b, 0.0f));
  ds5_pad_mix_frame(&mix, true, 0.4f, 0.2f, &a, &b);
  CHECK(NEAR(a, 0.2f) && NEAR(b, 0.4f));
  mix = ds5_pad_mix_from_names("ch2", "mono");
  ds5_pad_mix_frame(&mix, false, 0.4f, 0.2f, &a, &b);
  CHECK(NEAR(a, 0.0f) && NEAR(b, 0.3f));
  ds5_pad_mix_frame(&mix, true, 0.4f, 0.2f, &a, &b);
  CHECK(NEAR(a, 0.3f) && NEAR(b, 0.3f));
  // Unknown or missing names keep the defaults.
  mix = ds5_pad_mix_from_names("sideways", NULL);
  CHECK(mix.speaker == DS5_SPEAKER_MIX_BOTH && mix.headset == DS5_HEADSET_MIX_STEREO);
  mix = ds5_pad_mix_from_names(NULL, "both");
  CHECK(mix.speaker == DS5_SPEAKER_MIX_BOTH && mix.headset == DS5_HEADSET_MIX_STEREO);
  if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
  printf("ds5 pad mix tests passed\n");
  return 0;
}
