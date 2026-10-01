# 出处与致谢（NOTICE）

## 本仓库包含什么、不包含什么

- ✅ **包含**：作者自写的 TOD 驱动源码（`product-b-fprintd/payload/src/`）、
  安装/体检/诊断/测试脚本、**对 fprintd 的本地补丁**（`re-register-fix.patch`）、
  以及补丁版 fprintd / libpam-fprintd 的构建产物（.deb）。
- ❌ **不包含**：厂商（品识 PixelAuth）的专有二进制 ——
  麒麟 `biometric-authentication` 框架文件、`libpixelauth_pa180k.so`、厂商安装包。
  **产品 A 的安装器需要使用者自备这些文件**（逐项清单见
  `product-a-kylin/payload/stage/README-自备文件.md`）。
- ❌ **不包含**任何本机快照、用户数据、密钥。

## 与上游的关系

- **fprintd / libfprint**（freedesktop.org，GPL-2.0-or-later / LGPL-2.1-or-later）：
  `re-register-fix.patch` 是针对 Ubuntu `fprintd 1.94.3-1` 的补丁（"重新登记该手指"
  不再先删后查）。随附的 `fprintd_1.94.3-1+pa1_amd64.deb` 与
  `libpam-fprintd_1.94.3-1+pa1_amd64.deb` 是**上游源码 + 本补丁重新构建的 GPL 衍生
  二进制**（`build.sh` 会从 Ubuntu 归档自动下载原始源码，可复现构建）。
  这些文件按 GPL-2.0-or-later 分发；补丁本身也欢迎提交给 fprintd 上游。
- **品识 / PixelAuth / PT2887-SS**：模组与厂商软件的商标及版权归其所有者。
  本仓库与厂商**无隶属关系**，是个人对**自有设备**的互操作研究与实现。

## 知识来源

`docs/protocol-pxat.md` 中的协议细节来自：对自有设备的 USB 抓包（usbmon）、
随附软件的公开日志与符号表观察、以及自有设备上的大量控制实验。
整理出来供互操作与学习研究使用。
