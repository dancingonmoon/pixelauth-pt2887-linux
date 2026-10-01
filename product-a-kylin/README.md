# 品识 PT2887-SS 指纹 —— 产品 A：麒麟栈（sudo 指纹 + 录入指纹）

> **一句话**：让这台 Suma N50 的电源键指纹，能用来通过 `sudo`，并且能录入新指纹。
>
> 版本见 `VERSION`。**在 Ubuntu 24.04.5 / 内核 6.8.0-138 / fprintd 1.94.3 上验证过。**

---

## ★ 适用范围（先看这里）

| | |
|---|---|
| **硬件** | Suma / 中科可控 天阔 N50；指纹模组 = 品识 PT2887-SS（USB `2f0a:8020`，电源键二合一）。同模组其它机型理论可用，**未验证** |
| **系统** | Ubuntu 24.04.x（麒麟 `biometric-authentication`框架可装在上面跑） |
| **覆盖场景** | 只有两件事：**`sudo` 指纹**、**录入新指纹**（麒麟 CLI） |
| **不覆盖** | GNOME 锁屏 / 登录界面（那是**产品 B** 的活）、GNOME 图形提权弹窗 |
| **需要自备** ⚠️ | **厂商二进制**（框架 + `libpixelauth_pa180k.so` + 厂商 .deb）——本仓库**不代发**，逐项清单与获取方法见 [`payload/stage/README-自备文件.md`](payload/stage/README-自备文件.md) |
| **定位** | **历史与回退路径**。作者机器已退役麒麟，日常全走产品 B；**新部署建议直接用产品 B** |

> 保留它的理由：① 产品 B 出问题时的回退方案；② 想研究厂商框架时的完整参考。
> ⚠️ 本仓库版**不含**厂商 .deb 与本机快照（`state-snapshot`）——与作者本地完整包的差异仅此而已。

---

## 0. 先判断：我该读哪一节？

```
sudo ./install.sh --status
```

它会告诉你这台机器现在是什么状态。然后：

| 你的情况 | 读 |
|---|---|
| 全新机器 / 系统刚重装 | 第 2、3 节（前置 + 安装） |
| 已经装过，想确认还好不好 | 第 6 节（体检与故障排查） |
| 系统重装过，想恢复指纹（**不用重录**） | 第 5 节 ★ |
| 换了一台同款机器 | 第 5.4 节 |
| 想搞懂原理 | 第 8 节 |

**⚠️ 这个产品只管 `sudo` 和"录入指纹"。** GNOME 的**锁屏 / 登录界面**是另一个产品（B：fprintd 驱动）管的，两个包独立安装、互不干扰。

---

### ★ 可以不要麒麟：配合产品 B 退役它（2026-09-30 起）

产品 B（fprintd）现在**自己就能录入指纹、也能接管 sudo**。装完产品 B 之后，
本产品的麒麟栈就只剩一个害处了：

> **麒麟每次被调用都会做一次同步，把芯片里"不在它库里"的记录删掉** ——
> 也就是产品 B 自己录的指纹活不过它一次同步（实测毁过 5 个槽位）。

**退役步骤**（顺序不能反）：

```
1) 先装产品 B（它的驱动能真录入、PAM 助手改走 fprintd）
2) 用 fprintd-enroll 重录/绑定你的指纹
3) sudo systemctl disable --now biometric-authentication
```

**⚠️ 第 1 步没做完就停麒麟 = 再也无法新增指纹**（麒麟是当时唯一的录入途径）。

退役后：本产品的框架/驱动/udev 都可以留着（不影响），但不再被使用；
`checkup.sh` 里那些"麒麟"检查项会变成过时的，改用产品 B 的 `checkup.sh`。

---

## 1. 关键概念（读 3 分钟，能省你几小时）

### 1.1 指纹模板在芯片里，不在硬盘上

这是 **match-on-chip** 模组：指纹模板存在**指纹芯片**里，主机只负责"搬运"和记账。
所以：

> **系统重装不会丢指纹模板。** 重装丢的是**主机侧的账本**（"哪枚模板属于哪个用户"）。

理解这一点，就能理解为什么会出现"明明录过却用不了"——**模板还在，账本丢了**。

### 1.2 主机侧有两个账本，都很小但缺一不可

| 账本 | 路径 | 丢了会怎样 |
|---|---|---|
| 麒麟账本 | `/var/lib/biometric-auth/biometric.db` | ★ **sudo 指纹静默失效**：`get-feature-list` 返回空 → PAM 助手直接回退密码，**不报任何错** |
| 厂商账本 | `/etc/pixelauth/` | 同上 |
| fprintd 记录 | `/var/lib/fprint/` | 产品 B 那半边失效（锁屏/登录） |

**这三个都很小（合计约 120 KB）** —— 第 5 节讲怎么给它们做快照。

### 1.3 能力矩阵

| 场景 | 谁负责 | 装哪个包 |
|---|---|---|
| `sudo` / `sudo -i` | **产品 A**（本包） | 本包 |
| 录入新指纹 | **产品 A**（本包） | 本包 |
| GNOME 锁屏 | 产品 B | product-b-fprintd |
| GDM 登录界面 | 产品 B | product-b-fprintd |
| GNOME 图形提权弹窗 / `su` | ❌ 都不管 | — |

---

## 2. 前置条件

- **硬件**：Suma / 中科可控 天阔 N50；指纹模组 USB `2f0a:8020`（电源键二合一）
- **系统**：Ubuntu 24.04.x（本包在 24.04.5 上验证）；**必须能重启**（改内核参数要用）
- **权限**：有 sudo
- **联网**：安装时会用 apt 补三个 Python 包（`python3-dbus`、`python3-gi`、`python3-prettytable`）。
  离线机器请先自行装好这三个，否则 `biometric-auth-client` 会一跑就报错。
- **磁盘**：约 20 MB

---

## 3. 安装

### 3.1 解包

```bash
tar -xzf pixelauth-kylin-<版本>.tar.gz
cd pixelauth-kylin-<版本>
```

### 3.2 跑安装器

```bash
sudo ./install.sh
```

它会按顺序做三件事，每一步都会打印在做什么：

| 步骤 | 内容 | 预期输出里能看到 |
|---|---|---|
| 1/3 | 框架 + 厂商驱动 + udev | `框架安装完成` / `驱动安装完成` |
| 2/3 | PAM 助手 + 接 PAM + 内核参数 | `✅ /etc/pam.d/sudo（1 行）` |
| 3/3 | 体检 | 大部分 ✅ |

**重复运行是安全的**：已装过的步骤会自动跳过。

### 3.3 ★ 重启

**必须重启。** 内核参数 `8250.nr_uarts=2` 只有重启才生效。
**重启前指纹用不了，这是预期的，不是装坏了。**

重启后确认参数生效：

```bash
cat /sys/module/8250/parameters/nr_uarts      # 应当是 2
```

### 3.4 录入第一枚指纹

```bash
biometric-auth-client enroll -d 100 -n "右手食指"
```

- 它会提示你**反复按压十几次**（每次"按下 → 抬起"），跟着做
- **建议同一根手指多角度多采几次**，小面积传感器对录入质量敏感
- 录完验证：`sudo -k && sudo true`，看到提示后按指纹

### 3.5 体检

```bash
sudo ./payload/checkup.sh
```

只读，不改任何东西。**目标是全绿。** 每一条失败都会带上修复命令。

---

## 4. 日常操作

```bash
# 列出某用户的指纹
biometric-auth-client get-feature-list -d 100 -u "$USER"

# 录入一枚新指纹
biometric-auth-client enroll -d 100 -n "左手食指"

# 删除某用户的第 N 枚（索引从 get-feature-list 里看）
biometric-auth-client clean -d 100 -u "$USER" -i <索引>

# 测试 sudo 指纹
sudo -k && sudo true
```

**临时停用 sudo 指纹**（随时可恢复）：

```bash
sudo /var/backups/biometric-integration-*/integration-rollback.sh
```

它会把 PAM 那两行删掉、助手删掉。**密码通道从头到尾没被动过**，所以这一步永远安全。

---

## 5. ★ 重装与迁移

### 5.1 重装前：抓一份状态快照（在**现在这台还正常的机器上**做）

```bash
sudo ./payload/snapshot.sh
```

生成 `state-snapshot.tar.gz`（几十 KB）+ `SNAPSHOT-INFO.txt`。

**抓到的是**：麒麟账本、厂商账本、fprintd 记录（恢复后直接生效），
外加 PAM/GRUB 配置与芯片记录（**只作对照**）。

**把这两个文件和安装包放在一起保管。**

### 5.2 重装后：先装，再恢复

```bash
# 1) 正常装（第 3 节）
sudo ./install.sh
sudo reboot

# 2) 恢复账本 —— 指纹立刻回来，不用重录
sudo ./payload/restore-state.sh

# 3) 验收
sudo ./payload/checkup.sh
sudo -k && sudo true
```

**为什么不用重录**：模板在芯片里，重装没动它。账本一恢复，两边就对上了。

### 5.3 如果没有快照怎么办

那就**重新录入**（第 3.4 节）。芯片里可能还留着旧模板（`checkup.sh` 会列出来），
它们对应的旧账本已经没了 —— 用 `clean` 清掉即可，不影响新录入。

### 5.4 换一台同款机器

**不能靠恢复快照**，因为那台机器的芯片里要么是空的、要么装着**别人的**模板
（模板与设备 SN 绑定，搬不过来）。步骤：

```bash
# 1) 先看那台机器的芯片里有什么
sudo ./payload/checkup.sh            # 看 [1] 芯片侧那一节

# 2) 有别人的模板 → 清掉（★ 确认那是不要的再用）
biometric-auth-client clean -d 100 -u <那台机器的用户名> -i -1

# 3) 按第 3 节正常装 + 录自己的指纹
```

**整机容量上限：10 枚指纹，全局共享、不分用户。**

---

## 6. 体检与故障排查

### 6.1 先跑体检

```bash
sudo ./payload/checkup.sh
```

它逐层检查：硬件 → 芯片 → 麒麟栈 → fprintd，每条失败都带修复命令。

### 6.2 症状 → 判据 → 动作

| 症状 | 先看 | 多半是 |
|---|---|---|
| `sudo` 后光标不动、没提示 | `tail -20 /tmp/bioauth-pam.log` | 服务没跑 / 助手缺失；`checkup.sh` 会指出 |
| 提示出来了，按了没反应 | 黄灯亮不亮 | 黄灯不亮 = 设备被占用或没枚举 |
| **指纹录过却怎么都验不过** | `checkup.sh` 的 `[1] 芯片侧` | 账本丢了（重装）或模板没记录支撑 |
| 装完枚举失败 | `cat /sys/module/8250/parameters/nr_uarts` | **还没重启**（不是装坏了） |
| 服务起不来 | `journalctl -u biometric-authentication -b \| tail -50` | 见日志 |
| 系统升级后失效 | `checkup.sh` | 逐层定位 |

### 6.3 万一 `sudo` 完全进不去

只有改坏 PAM 才可能发生（本包的集成脚本是事务性的，正常不会）。
**密码登录从头到尾没被动过**，所以：

```
Ctrl+Alt+F3      切到文字终端，用密码登录
sudo /var/backups/biometric-integration-*/integration-rollback.sh
```

### 6.4 收集诊断信息

```bash
sudo ./payload/snapshot.sh     # 它顺带抓了 state.txt / chip.txt，出问题时很有用
```

---

## 7. 已知限制（诚实清单）

1. **只覆盖 `sudo` 和 `sudo -i`** —— `su`、GNOME 图形提权、锁屏、登录界面都不管（那些是产品 B 或其他 PAM 服务的事）
2. **整机最多 10 枚指纹，全局共享、不分用户** —— 多个用户会互相挤占
3. **模板与设备 SN 绑定** —— 换机器必须重录，搬不过来
4. **PAM 助手用中文硬编码提示**，而 GNOME/GDM 那边跟随系统语言 —— 界面语言不完全一致
5. **`sudo` 时指纹窗口 12 秒**（`T_VERIFY=12`）—— 没按到自动回退密码
6. **麒麟框架是厂商二进制**，从麒麟 OEM ISO 里提取，非开源
7. **别跑 `pam-auth-update`** —— 系统里有个厂商的 `/usr/share/pam-configs/pam-biometric`（`Default: yes`、`Priority: 260`、`Conflicts: fprintd`），一旦启用会插进 `common-auth` 并顶掉别的指纹方案

---

## 8. 原理（可跳过）

### 8.1 为什么不用麒麟自带的 `pam_biometric.so`

它依赖整套 UKUI 桌面组件，在 GNOME 上跑不起来：

| 依赖 | 在 Ubuntu/GNOME |
|---|---|
| `org.ukui.UniauthBackend`（D-Bus 服务） | ❌ 不存在 |
| `polkit-ukui-authentication-agent-1` | ❌ 不存在 |
| `/var/lib/lightdm-data/`（LightDM 专用） | ❌ 我们是 GDM |

`bioauth` 一启动就因为找不到这些而退出，模块随即返回 `PAM_SYSTEM_ERR`。
**所以改用 `pam_exec` + 自写助手**：不依赖 UKUI、逻辑透明、随时可回滚。

### 8.2 内核参数 `8250.nr_uarts=2` 为什么必须

厂商驱动枚举设备时会扫 `/sys/class/tty/`，**不过滤 driver 类型**。
Ubuntu 默认造 32 个幽灵串口（`serial8250`），每个展开成 22 种 COS 类型：

```
32 × 22 + 9（真实设备）= 713   >   驱动容量 256   →   枚举失败（BUFFER_TOO_SMALL）
设成 2 之后：2 × 22 + 9 = 53   <   256           →   成功
```

### 8.3 为什么 sudo 用 `sufficient`

PAM 行是 `auth sufficient pam_exec.so stdout /usr/local/bin/pam-biometric-exec.sh`：

- 助手返回 0（指纹通过）→ **放行，不问密码**
- 返回非 0（没按 / 不匹配 / 超时 / 任何异常）→ `sufficient` 不满足 → **继续走后面的密码认证**

**也就是说：指纹这一层永远不可能把人锁在外面。** 助手内部所有外部调用都套了 `timeout`，最坏 12 秒必退。

---

## 9. 附录

### 9.1 它都装了什么（文件清单）

| 路径 | 作用 |
|---|---|
| `/usr/lib/biometric-authentication/biometric-authenticationd` | 守护进程 |
| `/usr/lib/biometric-authentication/drivers/pa180k/` | 厂商驱动（`.so.1.0.1` + `.so` 符号链接 + json） |
| `/usr/bin/biometric-auth-client` 等 3 个 | 命令行工具（其中 client 是 Python 脚本） |
| `/usr/lib/systemd/system/biometric-authentication.service` | 服务单元 |
| `/usr/share/dbus-1/system-services/org.ukui.Biometric.service` | D-Bus 激活文件 |
| `/etc/dbus-1/system.d/org.ukui.Biometric.conf` | D-Bus 策略 |
| `/etc/udev/rules.d/com.pixelauth.pa180k.rules` | 设备权限 |
| `/usr/local/bin/pam-biometric-exec.sh` | PAM 助手 |
| `/etc/pam.d/sudo`、`sudo-i` | 各插 1 行 |
| `/etc/default/grub` | 加 `8250.nr_uarts=2` |

**卸载**：`sudo /var/backups/biometric-<时间戳>/rollback.sh`（框架+驱动）
+ `sudo /var/backups/biometric-integration-<时间戳>/integration-rollback.sh`（PAM+GRUB）

### 9.2 来源与许可

- **麒麟 biometric 框架**（`libbiometric.so`、`biometric-authenticationd`、`biometric-auth-client`）：
  从麒麟桌面操作系统 V10 SP1 的 OEM 安装镜像里提取（`casper/filesystem.squashfs`），**非开源**。
- **品识 pa180k 驱动**（`libpixelauth_pa180k.so.1.0.1`）：麒麟 OEM 镜像里的
  `third-party/com.pixelauth.pa180k_1.0.1-4_amd64.deb`，**非开源**。
- **本包的脚本**：为在 Ubuntu 上跑通这套厂商栈而自写。

**用途限定：同款机器的自用迁移。** 再分发厂商二进制前请自行确认授权。

### 9.3 与厂商原版的差异

见 `payload/stage/CHANGES-FROM-VENDOR.txt`。目前有两处：
udev 规则用了修正版、补了一个厂商 stage 里没有的 D-Bus 激活文件。

### 9.4 CHANGELOG

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.1.0 | 2026-09-30 | 首个打包版本。从 2026-09-27 的手工安装整理而来 |

---

## 10. 一页保命卡（打印/截图存着）

```
指纹 sudo 装完进不去？
  1. Ctrl+Alt+F3            切文字终端，用密码登录
  2. sudo /var/backups/biometric-integration-*/integration-rollback.sh
  3. sudo reboot

装完指纹用不了？
  1. sudo ./payload/checkup.sh          看哪一层红了
  2. 内核参数生效了吗：cat /sys/module/8250/parameters/nr_uarts  → 2
  3. 账本还在吗：biometric-auth-client get-feature-list -d 100 -u $USER

什么都别动就能确认的：
  sudo ./install.sh --status       只读，什么都不装
```
