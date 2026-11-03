---
description: "Prebuilt system.node for OpenHarmony arm64 POSIX locks."
kind: "package-library"
---
# @deepseek-ai/node-addon-system-openharmony-arm64

English | [中文](README.zh.md)

This platform package supplies `bin/system.node`, a stable Node-API v8 addon used by `@deepseek-ai/node-addon-system/flock` on Node builds that report `process.platform === 'openharmony'`. It links only the OpenHarmony musl `libc.so` and contains no Landlock executable, JavaScript loader, or installation build script. The native workflow cross-builds it with the OpenHarmony NDK on Linux; no hosted runner executes it, so the [support matrix](../../docs/support-matrix.md) names its on-device verification owner. OpenHarmony loads only signed native code, so the deploying application signs the installed addon.
