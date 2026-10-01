# 品识 PT2887-SS 指纹（Suma N50 电源键）—— Ubuntu / 麒麟 两个可用方案

> 把 **Suma / 中科可控 天阔 N50** 上那颗 **品识 PT2887-SS** 指纹
> （电源键二合一，USB `2f0a:8020`，**match-on-chip**：模板存在芯片里）
> 在 Linux 上跑通的**两个产品**：
>
> - **产品 B：自写的 fprintd TOD 驱动**（★ 推荐，作者日常在用）
> - **产品 A：麒麟栈的 Ubuntu 部署方案**（历史与回退路径）
>
> 全部在真机上**逐项实测**：Ubuntu 24.04.5 / 内核 6.8.0-138 / fprintd 1.94.3 / GNOME 46。

---

## 两个方案怎么选（★ 各自的适用范围）

| | **B：fprintd** | **A：麒麟栈** |
|---|---|---|
| **目录** | [`product-b-fprintd/`](product-b-fprintd/) | [`product-a-kylin/`](product-a-kylin/) |
| **面向的系统** | 任意 Ubuntu 24.04.x（发行版自带 libfprint 的 TOD 支持） | 装有 / 愿意装麒麟 `biometric-authentication` 框架的 Ubuntu |
| **覆盖场景** | **GDM 登录 · 锁屏 · sudo · 录入 · 删除 · 重新登记** | sudo · 录入（麒麟 CLI） |
| **不覆盖** | —（GNOME 46 里"删除单枚"要用本产品命令，见其 README 第 4.2 节） | GNOME 锁屏 / 登录界面（那是 B 的活） |
| **依赖** | **无需厂商二进制**（驱动是本仓库自写的） | ⚠️ **需要自备厂商二进制**（本仓库不代发，见 A 的 README） |
| **内置的关键修复** | ① fprintd「重新登记该手指」安全补丁（不再"先删后查"毁数据）② sudo 认全部已录手指 | 安装器补齐 6 项已知缺口（PAM 接线 / GRUB 参数 / python 依赖 / 驱动符号链接 …） |
| **成熟度** | ★ 作者机器当前形态：麒麟已退役，**全部走它** | 历史路径（作者机器已退役） |

**怎么选**：新部署**直接用 B**。**A** 适合：要回退到麒麟栈、或研究厂商框架。
两者可以并存（互不干扰），B 装完即可退役 A（见 A 的 README 顶部）。

## 快速开始（B 路径，3 步）

```bash
git clone https://github.com/dancingonmoon/pixelauth-pt2887-linux
cd pixelauth-pt2887-linux
./make-package.sh b                     # 打成安装包（产物在 dist/）
tar -xzf dist/pixelauth-fprintd-*.tar.gz
cd pixelauth-fprintd-*/
sudo ./install.sh                       # 装驱动 + PAM 助手 + fprintd 补丁，并跑体检
```

装完验收：

```bash
sudo -k && sudo true      # 应提示「请触摸电源键上的指纹传感器」→ 按指纹
Super+L                   # 锁屏 → 按指纹解锁
sudo ./payload/checkup.sh # 应全绿
```

> 也可以下载本仓库 **Releases** 里打好的 `pixelauth-fprintd-<版本>.tar.gz`，免去自己打包。

前置条件（Ubuntu 24.04、`fprintd`、内核参数 `8250.nr_uarts=2` 等）与全部细节，
见 [product-b-fprintd/README.md](product-b-fprintd/README.md)（含**已知限制**和**故障排查**）。

## 硬件与已验证环境

| | |
|---|---|
| 整机 | Suma / 中科可控 天阔 N50（Hygon C86-4G） |
| 指纹模组 | **品识 PT2887-SS**，USB `2f0a:8020`，电源键二合一，芯片 10 槽位（10–19） |
| 系统 | Ubuntu 24.04.5 LTS，内核 6.8.0-138，fprintd 1.94.3，GNOME 46 |
| 同模组其它机型 | 驱动按 USB ID + PXAT 协议工作，**理论上通用**；未验证，欢迎反馈 |

**关于芯片的重要事实**：这是 **match-on-chip** 模组 —— 指纹模板存在**芯片**里，
主机只存"哪枚模板属于谁"。所以**系统重装不丢指纹**，重装后重新绑定即可（每根按一下）。

## 仓库结构

```
├── README.md               ← 你在这里
├── LICENSE                 ← MIT（自写代码）
├── NOTICE.md               ← 出处：厂商二进制不代发、fprintd 补丁的 GPL 说明
├── docs/
│   └── protocol-pxat.md    ← ★ PXAT 协议逆向笔记（想自己写驱动/调试这颗模组的看它）
├── product-b-fprintd/      ← ★ 推荐：fprintd 全链路（驱动源码 + 工具 + fprintd 补丁）
├── product-a-kylin/        ← 历史：麒麟栈（需自备厂商文件）
└── make-package.sh         ← 把产品打成可安装的 tar.gz（产物进 dist/）
```

## 本仓库不包含什么

- ❌ **厂商（品识）专有二进制**：麒麟框架文件、`libpixelauth_pa180k.so`、厂商安装包。
  产品 A 需要你**自备**（逐项清单在 `product-a-kylin/payload/stage/README-自备文件.md`）。
- ❌ 任何本机快照 / 用户数据。

（产品 B 所需的一切都在仓库里。）

## 许可与免责

- 自写代码（驱动、脚本、文档）：**MIT**，见 [LICENSE](LICENSE)
- fprintd 补丁及其 .deb：基于 GPL 上游，见 [NOTICE.md](NOTICE.md)
- **非厂商官方项目**。本仓库会安装内核外驱动、修改 PAM 与系统服务 —— 请在**你自己拥有**的
  设备上评估后使用；指纹是身份凭证，相关操作请谨慎。
