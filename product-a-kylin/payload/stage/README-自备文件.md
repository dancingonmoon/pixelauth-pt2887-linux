# ⚠️ 本目录的厂商二进制需自备（本仓库不代发）

产品 A（麒麟栈）依赖厂商（品识）提供的**专有二进制**。出于版权考虑，
**GitHub 仓库版不含这些文件**；你需要用你**自己机器**附带的厂商安装包补齐。
（下面这些文本配置已随仓库提供，无需自备。）

## 缺哪些（共 6 个二进制）

| 本目录缺的文件（stage/ 下） | 安装后的去处 |
|---|---|
| `libbiometric.so.0.0.0` | `/usr/lib/x86_64-linux-gnu/` |
| `biometric-authenticationd` | `/usr/lib/biometric-authentication/` |
| `biometric-auth-client` | `/usr/bin/` |
| `biometric-config-tool` | `/usr/bin/` |
| `biometric-device-discover` | `/usr/bin/` |
| `drivers-pa180k/libpixelauth_pa180k.so.1.0.1` | `/usr/lib/biometric-authentication/drivers/pa180k/` |

> 符号链接（`libpixelauth_pa180k.so -> .so.1.0.1`、`libbiometric.so.0 -> .so.0.0.0`）
> 由安装器**自动创建**，无需自备。

## 从哪来

**首选**：厂商安装包 `com.pixelauth.pa180k_1.0.1-4_amd64.deb`
（随该机型的预装系统附带；也可向厂商/中科可控渠道索取）：

```bash
dpkg-deb -x com.pixelauth.pa180k_1.0.1-4_amd64.deb vendor-extract/
# 然后按上表「安装后的去处」在 vendor-extract/ 里找到对应文件，
# 拷进本目录（drivers-pa180k/ 那两个放 drivers-pa180k/ 子目录）
```

**备选**：从一台**已装好**麒麟指纹栈的机器上直接拷：

```bash
# 对照上表右列路径逐个拷贝即可
scp 那台机器:/usr/lib/biometric-authentication/drivers/pa180k/libpixelauth_pa180k.so.1.0.1 drivers-pa180k/
```

## 补齐后怎么检查

```bash
# 安装器自己会核对，缺什么直接列出来
sudo ../../install.sh
```

安装器在第 1 步会打印 `❌ 缺少源文件: …` 的完整清单 —— 补齐后重跑即可。

---

*如果你只是想把这颗指纹用起来，**不需要产品 A** —— 用产品 B（fprintd）不需要任何厂商文件，
见仓库根目录 README 的"两个方案怎么选"。*
