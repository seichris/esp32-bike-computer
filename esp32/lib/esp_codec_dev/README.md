# esp_codec_dev

This directory vendors the ESP-IDF `esp_codec_dev` component version 1.5.11
from Espressif's `esp-adf` commit
[`73befa9ebffdd6e5065b7145329f115910e13ab5`](https://github.com/espressif/esp-adf/tree/73befa9ebffdd6e5065b7145329f115910e13ab5/components/esp_codec_dev).

The PlatformIO library is a flattened subset containing the interfaces and
ES8311 implementation used by the Waveshare AMOLED 2.06 speaker. Local changes
preserve codec failure propagation and allow recovery after an unsuccessful
open or close operation. The upstream Apache-2.0 license is retained in
`LICENSE`.
