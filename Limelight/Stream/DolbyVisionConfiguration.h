#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Dolby Vision ISOBMFF decoder configuration record, single-layer Profile 8.
// Level limits: https://ott.dolby.com/OnDelKits/Dolby_Vision_Online_Delivery_Kit/v1/Documentation/Specs/Visio_Profiles/help_files/topics/c_dovi_levels.html
static inline bool DVBuildProfile8Configuration(int width, int height, int fps,
                                               int bitrateKbps, uint8_t compatibility,
                                               uint8_t record[24]) {
    static const struct {
        uint64_t pixelsPerSecond;
        uint32_t maximumWidth;
        uint32_t highTierKbps;
    } levels[] = {
        {22118400, 1280, 50000}, {27648000, 1280, 50000},
        {49766400, 1920, 70000}, {62208000, 2560, 70000},
        {124416000, 3840, 70000}, {199065600, 3840, 130000},
        {248832000, 3840, 130000}, {398131200, 3840, 130000},
        {497664000, 3840, 130000}, {995328000, 3840, 240000},
        {995328000, 7680, 240000}, {1990656000, 7680, 480000},
        {3981312000, 7680, 800000}
    };
    if (record == NULL || width <= 0 || width > 7680 || height <= 0 || height > 7680 ||
        fps <= 0 || fps > 1000 || bitrateKbps < 0 ||
        (compatibility != 1 && compatibility != 4)) return false;
    const uint64_t rate = (uint64_t)width * (uint64_t)height * (uint64_t)fps;
    for (unsigned i = 0; i < sizeof(levels) / sizeof(levels[0]); i++) {
        if (rate > levels[i].pixelsPerSecond || (unsigned)width > levels[i].maximumWidth ||
            (unsigned)bitrateKbps > levels[i].highTierKbps) continue;
        const uint8_t level = (uint8_t)(i + 1);
        memset(record, 0, 24);
        record[0] = 1; // dv_version_major
        record[2] = 8 << 1; // dv_profile
        record[3] = (level << 3) | 0x05; // RPU and base layer, no enhancement layer
        record[4] = compatibility << 4;
        return true;
    }
    return false;
}
