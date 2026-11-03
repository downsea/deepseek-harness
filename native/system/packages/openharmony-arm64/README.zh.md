---
description: "为 OpenHarmony arm64 POSIX 锁提供预编译 system.node。"
kind: "package-library"
---
# @deepseek-ai/node-addon-system-openharmony-arm64

[English](README.md) | 中文

此平台包提供 `bin/system.node`，供 `@deepseek-ai/node-addon-system/flock` 在报告 `process.platform === 'openharmony'` 的 Node 构建上使用的稳定 Node-API v8 addon。它只链接 OpenHarmony 的 musl `libc.so`，不包含 Landlock 可执行文件、JavaScript 加载器或安装构建脚本。Native 工作流在 Linux 上用 OpenHarmony NDK 交叉编译它；没有托管 runner 能执行它，因此由[支持矩阵](../../docs/support-matrix.md)指明其设备上验证的负责方。OpenHarmony 只加载已签名的原生代码，因此由部署方应用对安装后的 addon 签名。
