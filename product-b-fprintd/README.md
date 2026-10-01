# 品识 PT2887-SS 指纹 —— 产品 B：fprintd（锁屏 / 登录界面 / sudo）

> **一句话**：让这台 Suma N50 的电源键指纹，在 GNOME 的**锁屏**、**登录界面**能用，
> 并且**能录入 / 删除指纹**、**能让 sudo 用指纹**。
>
> 版本见 `VERSION`。**在 Ubuntu 24.04.5 / 内核 6.8.0-138 / fprintd 1.94.3 上验证过。**
> （0.2.0 起包内自带打过「重新登记」修复补丁的 fprintd，见第 4.6 节。）

---

## ★ 适用范围（先看这里）

| | |
|---|---|
| **硬件** | Suma / 中科可控 天阔 N50；指纹模组 = 品识 PT2887-SS（USB `2f0a:8020`，电源键二合一）。同模组其它机型理论可用，**未验证**（欢迎反馈） |
| **系统** | Ubuntu 24.04.x（需要发行版的 libfprint TOD 支持：`libfprint-2-tod1`，1.94 系）。其它发行版理论可行、未验证 |
| **覆盖场景** | **GDM 登录 · GNOME 锁屏 · `sudo` · 录入 · 删除 · 重新登记**（全部实机验证） |
| **不需要** | 厂商二进制 —— 驱动是本仓库自写的；唯一用到网络的地方是**重编 fprintd 补丁**时下载 Ubuntu 源码（包内已带构建好的 .deb，通常用不上） |
| **定位** | **推荐路径**（作者机器当前形态：麒麟已退役，全部走本产品） |
| **限制** | 芯片 10 槽位全局共享（多用户会互挤）；GNOME 46 里"删单枚"要用本产品的命令（第 4.2 节）；完整清单见第 7 节 |

---

## 0. 先判断：我该读哪一节

```
./install.sh --status
```

| 你的情况 | 读 |
|---|---|
| 全新机器 / 系统刚重装 | 第 2、3 节 |
| 已经装过，想确认还好不好 | 第 6 节 |
| **想删指纹** | **第 4.2 节 ★ 先读（GNOME 里删不了单枚，要用命令）** |
| **想用 GNOME「重新登记该手指」** | 第 4.6 节（0.2.0 起已修复 ✓） |
| 系统重装过，想恢复指纹 | 第 5 节 |
| 想搞懂原理 | 第 8 节 |

**与产品 A 的关系**：产品 A 是"麒麟栈"（原来负责 sudo 和录入）。
**本产品装完就等于把 sudo 从麒麟切到 fprintd** —— 之后麒麟可以退役（见第 4.4 节）。
两个包都装同一个 PAM 助手路径，**以最后装的那个为准**。

---

## 1. 关键概念（读 3 分钟）

### 1.1 模板在芯片里，主机只记账

这是 **match-on-chip** 模组：指纹模板存在**芯片**里，主机只存"哪枚模板属于谁"。

> **系统重装不会丢模板**，丢的是主机侧的记录（`/var/lib/fprint/`）。重装后重新绑定即可。

### 1.2 芯片的槽位模型（理解报错的前提）

芯片有 **10 个槽位**（编号 10–19），**全局共享、不分用户**：

- 芯片有一张**索引表**（位图）：位 N 置位 = 槽位 N 有指纹
- 每个槽位还有一条 **64 字节的"记录"**：`00 | 槽位LE16 | 0x20 | 32字节随机数 | 28字节补零`
  那 32 字节是主机生成的 UUID，作用只是"芯片记录 ↔ 主机数据库"的对应关系 ——
  **不是模板、不是哈希**
- **索引和记录必须成对**：有索引没记录 → 芯片认不出；有记录没索引 → 同样没用
  （`checkup.sh` 会检查这个一致性）

### 1.3 能力矩阵

| 场景 | 谁负责 | 状态 |
|---|---|---|
| GDM 登录界面 | 本产品 | ✅ |
| GNOME 锁屏 | 本产品 | ✅ |
| `sudo` | 本产品的 PAM 助手 | ✅（认全部已录手指） |
| 录入指纹（GNOME 或命令行） | 本产品（驱动自己录，含写记录） | ✅ |
| **重新登记**（对已录手指重录一遍） | 本产品（含 fprintd 修复补丁） | ✅（0.2.0 起，见 4.6） |
| 删除**单枚**指纹 | ❌ GNOME 里坏的 → **用本产品的工具**（第 4.2 节） | ⚠️ |
| GNOME 图形提权弹窗 / `su` | 不管 | — |

---

## 2. 前置条件

- **硬件**：Suma / 中科可控 天阔 N50；指纹模组 USB `2f0a:8020`（电源键二合一）
- **系统**：Ubuntu 24.04.x；**必须能重启**（只在首次装内核参数时需要，若产品 A 已装过就不用）
- **必须已装**：`fprintd`（`sudo apt install fprintd libpam-fprintd`）
- **内核参数**：`8250.nr_uarts=2` —— 没有它厂商驱动枚举会失败。
  产品 A 的安装器会加；单独装本产品的话见第 6.2 节的症状表。
- **重编译才需要的包**（用包内预编译的 `.so` 则不需要）：
  `meson ninja-build gcc pkg-config libfprint-2-tod-dev`

---

## 3. 安装

```bash
tar -xzf pixelauth-fprintd-<版本>.tar.gz
cd pixelauth-fprintd-<版本>
sudo ./install.sh              # 加 --build 则现场重新编译驱动
```

装完它会自动跑一遍体检。

**重复运行安全**：已装过的东西会跳过，PAM 那两行不会重复插。

**第 5 步**会把你机器上的 fprintd 换成打过「重新登记」修复补丁的版本
（`1.94.3-1+pa1`，见第 4.6 节；加 `--no-fprintd-patch` 可跳过）。

### 装完验收

```bash
sudo -k && sudo true          # 应提示「请触摸电源键上的指纹传感器」
Super+L                       # 锁屏后用指纹解锁
sudo ./payload/checkup.sh     # 应全绿
```

---

## 4. 日常操作

### 4.1 录入新指纹

**方式一：命令行**（推荐，有提示、看得清）

```bash
fprintd-enroll -f right-index-finger
```

- 会让你**反复按压十几次**，跟着做
- 手指名：`right-index-finger` / `left-thumb` / `right-middle-finger` …（见 `fprintd-enroll --help`）
- 录完驱动会**自动把记录写进芯片**（这一步必不可少，否则芯片认不出）

**方式二：GNOME 设置 → 系统 → 用户 → 指纹 → 添加**

⚠️ **GNOME 里录入时看不到阶段提示**（上游行为，改不了）—— 你得凭经验反复按压。
功能是通的，但**命令行体验明显更好**。

> ### ✓ 录入时按错手指也不会删东西（0.1.0 时不是这样）
>
> **2026-10-01 已修复**：本产品 0.2.0 起自带「重新登记」修复补丁（第 4.6 节）。
> 录入前那次去重检查现在**只会带来两种结果**：
>
> - **按对了** → 正常继续（重新登记时：替换旧的，**槽位数不变**）
> - **按错了**（按的是别的已录手指）→ 报「指纹重复」、干净退出，**什么都不删** ✓
>
> **老版本（0.1.0 / 未打补丁的 fprintd）**：按错手指会把正在录的那一枚
> **从芯片里删掉** ✗（2026-09-30 实测事故）。升级到 0.2.0 即消除。

### 4.2 ★★ 删除指纹 —— 用本产品带的命令（GNOME 里没有"删单枚"这个功能）

> **⚠️⚠️ GNOME 46 的设置程序里根本没有"删一枚"的代码** —— 实测它的二进制里
> 只有"删全部"（`DeleteEnrolledFingers` / `DeleteEnrolledFingers2`），
> **没有单数版**（`DeleteEnrolledFinger`）。所以那颗"删除指纹"按钮
> 要么没反应、要么最终走 **全删** 那条路。
>
> **2026-09-30 实测事故**：就是这个操作把 3 枚指纹全删了。
> **记住：别在 GNOME 里点"删除指纹"。要删就用下面的命令。**

**删单枚 —— 一条命令（装完就在 PATH 里，不需要 sudo）**：

```bash
fprint-delete-finger                       # 不带参数：列出你的指纹（照着抄名字）
fprint-delete-finger right-middle-finger   # 删这一枚（会先让你确认）
```

- **装在哪**：`/usr/local/bin/fprint-delete-finger`（真身是同目录的
  `fprint-delete-finger.py`，短名是指向它的链接；写全名 .py 也能用）
- **不需要 sudo**：它走 D-Bus 的 `DeleteEnrolledFinger`，以你本人身份授权
- 只删你指定的那一枚 —— 实测日志确认过（`delete: 发 0c，目标槽位 N → ✅`）
- 手指名是 fprintd 的英文名（`left-thumb`、`right-middle-finger`…）；不带参数会列出来
- 包里有副本：`payload/fprint-delete-finger.py`（装了就不用它）

**为什么不用 `fprintd-delete`**：那个命令行也只能删**全部**（它对应旧接口
`DeleteEnrolledFingers`），**没有删单枚的选项** —— 和 GNOME 是同一个短板。

### 4.3 列出指纹

```bash
fprintd-list "$USER"
```

### 4.4 退役麒麟（可选，但推荐）

麒麟那套（`biometric-authentication`）在本产品装好后就没用了。
**而且它有害**：它每次被调用都会做一次同步，**把芯片里"不在它库里"的记录删掉** ——
也就是我们自录的指纹活不过它一次同步（实测毁过 5 个槽位）。

```bash
sudo systemctl disable --now biometric-authentication
```

代价：麒麟的录入方式（`biometric-auth-client enroll`）没了 —— 不需要了，
现在用 `fprintd-enroll` 录。想回退：`sudo systemctl enable --now biometric-authentication`。

### 4.5 临时停用指纹 sudo

```bash
sudo rm -f /usr/local/bin/pam-biometric-exec.sh
```

助手不在，PAM 那行会失败并**自动回退密码** —— **密码通道从头到尾没被动过**，
所以这一步永远是安全的。要恢复：重跑 `sudo ./install.sh`。

### 4.6 ★★ 「重新登记该手指」修复补丁（0.2.0 起自带）

**修的是什么**：在 GNOME 里对一枚已录手指点「重新登记该手指」时，原版 fprintd
（1.94.3，**上游最新版依然如此**）会**先删掉这枚旧记录（连芯片槽位一起）**，
然后才做去重检查；检查一失败（比如按错手指）就中止 —— **旧的没了、新的又没录上** ✗。
（2026-09-30 实测因此丢过指纹；芯片索引删掉后是**救不回来**的。）

**怎么修**：包内带一个 fprintd 小补丁（有效代码约 25 行，只动 `src/device.c`
的录入流程），把删除**推迟到去重检查通过之后**；匹配到"正在登记的那根手指"
不再判为重复。装好后：

- 按错手指 → 照旧报「重复」并中止，但**旧记录原封不动** ✓
- 按对自己 → 检查通过后才删旧、再真录入 → **替换而非新增，槽位数不变** ✓

```bash
# 看状态（已装？是不是 +pa1？）
sudo ./payload/fprintd-patch/install-fprintd-patched.sh status

# 手动打补丁 / 重新打（install.sh 已自动做，重复安全）
sudo ./payload/fprintd-patch/install-fprintd-patched.sh apply

# 回滚到原版 fprintd
sudo ./payload/fprintd-patch/install-fprintd-patched.sh revert
```

- 装的是 **`fprintd 1.94.3-1+pa1`** + **`libpam-fprintd 1.94.3-1+pa1`**（本地构建，
  **非官方包**），两个都 `apt-mark hold` 防被 apt 升级覆盖。
  想彻底卸载：`revert` + `sudo apt-mark unhold fprintd libpam-fprintd`
- **★ 两包必须同装同卸**：libpam-fprintd 的依赖是「fprintd (= 1.94.3-1)」**精确匹配**，
  只装/只回滚其中一个 → apt 报「已损坏个数 > 0」→ **所有更新（含安全更新）全部装不上**
  （2026-10-01 实际踩过，当日修复）。`apply` / `revert` / `build.sh` 已把两包绑在一起；
  `checkup.sh` 的 `[2b]` 节也会守护这条不变量。
- **验收工具**（需要一根一次性测试手指）：
  `./payload/tools/re-register-test.sh <victim手指> <另一根已录手指>` → 应 GREEN（victim 幸存）
- 若以后**手动**升级了 fprintd（或换了系统），补丁会丢 → 重跑 `apply`；
  要对**新版 fprintd** 重新构建：`./payload/fprintd-patch/build.sh`
  （自动下载源码；需要网络 + debhelper/dh-exec/libpam0g-dev/libpolkit-gobject-1-dev/libsystemd-dev）
- ⚠️ 残留窗口（已很窄）：去重检查通过之后、真录入完成之前如果**放弃**，
  旧记录仍会被替换掉。彻底关闭需要"原地更新"（后续工作）

---

## 5. 重装与迁移

### 5.1 重装系统后

芯片里的模板**不随重装丢** ✓，丢的是 `/var/lib/fprint/` 的主机记录 ✗。所以：

```bash
# 1) 装本产品
sudo ./install.sh

# 2) 把芯片里的模板重新绑定到手指名（每根按一次）
fprintd-enroll -f right-index-finger      # 这时走得是"绑定"：手指已在芯片里 → 按一下即可
fprintd-enroll -f left-index-finger

# 3) 验收
sudo ./payload/checkup.sh
```

**怎么知道该绑哪根**？不用知道 —— `fprintd-enroll` 会**遍历芯片里所有已占用槽位**，
你把要绑的那根手指按上去，匹配上就绑定成功（匹配不上会转去真录入）。
**万一手感不对，看日志**（第 6.4 节）。

### 5.2 备份什么

| 东西 | 能备份吗 | 说明 |
|---|---|---|
| 芯片模板 | ❌ | 在芯片里，取不出来。但**不随系统重装丢** |
| `/var/lib/fprint/` | ✅ | fprintd 的手指↔槽位对应关系。产品 A 的 `snapshot.sh` 会抓 |
| PAM/GRUB 配置 | ✅ | 同上（只作对照） |

**结论**：重装后**不需要重录**，重新绑定一次即可（每根按一下）。

### 5.3 换一台同款机器

**不能靠搬迁**（模板与设备 SN 绑定）。那台机器的芯片里可能是空的、也可能装着别人的模板：

```bash
# 1) 先看那台机器的芯片里有什么
sudo ./payload/checkup.sh            # 看 [1] 芯片侧那一节

# 2) 有别人的模板 → 用工具或 GNOME 删掉（★ 先确认那是不要的）

# 3) 按第 3、4.1 节正常装 + 录自己的指纹
```

**整机上限：10 枚指纹，全局共享、不分用户。**

---

## 6. 体检与故障排查

### 6.1 先跑体检

```bash
sudo ./payload/checkup.sh
```

逐层检查：硬件 → 芯片 → fprintd → sudo 接线 → 麒麟退役状态。每条失败带修复命令。

### 6.2 症状 → 判据 → 动作

| 症状 | 先看 | 多半是 |
|---|---|---|
| **装完/重装后指纹完全没反应** | `cat /sys/module/8250/parameters/nr_uarts` | 不是 2 → 内核参数没生效（多半**还没重启**） |
| 锁屏/登录没有指纹选项 | `fprintd-list $USER` | 一条记录都没有 → 需要绑定/录入 |
| 黄灯不亮、按了没反应 | `journalctl -u fprintd -n 50` | 设备被占用；或芯片索引被清空（看 6.3） |
| sudo 没有提示 | `tail -20 /tmp/bioauth-pam.log` | 助手缺失/不可执行（权限必须是 755 root:root） |
| **指纹录过却验不过** | `checkup.sh` 的 `[1] 芯片侧` | 索引没了，或记录是 `0x33` 占位符 |
| GNOME 里删指纹没反应（或变成全删） | — | GNOME 46 没实现"删单枚" → 用 `fprint-delete-finger`（第 4.2 节） |
| **sudo 只认列表第一根手指**（按别的没反应） | `grep -- '-f any' /usr/local/bin/pam-biometric-exec.sh` | 助手是旧版（没带 `-f any`）→ 重跑 `install.sh` |
| **apt 升级后「重新登记」又开始毁数据** | `dpkg -s fprintd \| grep Version` | fprintd 被换回原版 → `sudo ./payload/fprintd-patch/install-fprintd-patched.sh apply` |

### 6.3 芯片索引被清空怎么办

现象：`checkup.sh` 报「芯片索引是空的」，但 `fprintd-list` 还有记录。

**原因**：索引项被删了（GNOME 的"全删"、或麒麟的同步）。**记录字节还在，但没索引 = 芯片不去比它。**

**索引只能由芯片在录入时设置，主机写不回去**（实测：把原 UUID 用 `a5` 写回去，索引位不会回来）。
所以**只能重新绑定/录入**：

```bash
fprintd-enroll -f right-index-finger     # 手指还在芯片里 → 可能直接绑定成功
```

### 6.4 收集诊断信息

```bash
sudo ./payload/checkup.sh                     # 人看的
journalctl -u fprintd -b --no-pager | tail -80
cat /tmp/bioauth-pam.log                      # sudo 那次的完整过程
```

**想看驱动在做什么**（排查必备）：临时打开调试日志

```bash
sudo mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' | sudo tee /etc/systemd/system/fprintd.service.d/debug-log.conf
sudo systemctl daemon-reload && sudo systemctl restart fprintd
# 排查完删掉那个文件、再 daemon-reload + restart
```

---

## 7. 已知限制（诚实清单）

1. **（0.2.0 已修复）** 录入/重新登记时按错手指会删掉正在录的那一枚 ——
   原版 fprintd"先删后查"的行为；本产品的补丁已消除（第 4.6 节）。
   **未打补丁的机器上仍要按对再按**
2. **GNOME 46 没有"删单枚"功能**（上游缺失：按钮只能通向全删）→ 用 `fprint-delete-finger`（第 4.2 节）
3. **GNOME 里录入看不到阶段提示**（上游行为）→ 用命令行
4. **整机最多 10 枚指纹，全局共享、不分用户** —— 多用户会互相挤占
5. **模板与设备 SN 绑定** —— 换机器必须重录
6. **麒麟在跑的话，会删掉我们自录的指纹**（它同步时删"不认识的记录"）→ 建议退役（4.4）
7. **`clear_storage`（清空设备）会删掉所有槽位**，包括别的用户的 ——
   fprintd 很少调它，但知道一下
8. **PAM 助手提示是中文硬编码**，GNOME/GDM 那边跟随系统语言 —— 不完全一致
9. **开机登录的指纹窗口约 87 秒**（pam_fprintd 3 次 × 约 29 秒），过期后按一下键盘可重新开始
10. **指纹登录后 GNOME 可能要求输入密码解锁"登录钥匙环"** —— 上游 GDM 的固有行为
   （`gdm-fingerprint` 这个 PAM 服务里没有密码）

---

## 8. 原理（可跳过）

### 8.1 `33 <槽位>` —— 芯片不做 1:N

这是本驱动最关键的一条：`33` 命令的第二个字节是**目标槽位**，芯片**一次只比一个槽位**。

```
33 0a  → 拿手指和【槽位 10】比
33 0b  → 拿手指和【槽位 11】比
```

所谓"1:N 识别"要**主机自己循环**（麒麟就是循环它的每个索引）。
早期驱动把它写死成 `0x0a`，于是**永远只可能匹配槽位 10** —— 这是"加新指纹从来不成"的真正根因。

**附带行为**：芯片只在"手指**新落下**"那一刻检测一次。所以循环各槽位时**必须抬手重按**，
不能一直按着（重新 arm 会重置检测）。

### 8.2 `a5` —— 录入成功后必须写记录

芯片在 `31`（启动录入）时会把模板写好，但记录区里是 `0x33` 占位符，
**等主机用 `a5` 覆盖成真 UUID**。不写的话：

- 这枚指纹芯片认不出（永远验不过）
- 麒麟的同步会把它当"不认识的记录"删掉

载荷 69 字节：`a5 <槽位×0x40 BE16> 0040 00 <槽位LE16> 20 <32字节随机数> <28字节补零>`

### 8.3 `0c` —— 删除只清索引

载荷 `0c <槽位BE16> 00 01`，响应 `00` = 成功。

**实测语义**：**只删索引项，记录区的字节还留着**（`a6` 仍读得到）。
这解释了为什么会有"有记录、没索引"的槽位 —— 就是被它删的。

### 8.4 为什么 PAM 用 `sufficient`

```
auth sufficient pam_exec.so stdout /usr/local/bin/pam-biometric-exec.sh
```

- 助手返回 0（指纹通过）→ 放行
- 任何其他情况（没按/不匹配/超时/**助手本身坏了**）→ 继续走密码

**也就是说：指纹这一层永远不可能把人锁在外面。** 助手内部所有外部调用都套了 `timeout`。

---

## 9. 附录

### 9.1 装了什么

| 路径 | 作用 |
|---|---|
| `/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/libpixelauth_pt2887.so` | TOD 驱动 |
| `/usr/local/bin/pam-biometric-exec.sh` | PAM 助手（调 `fprintd-verify -f any`，认全部已录手指） |
| `/etc/pam.d/sudo`、`sudo-i` | 各插 1 行 |
| `/usr/local/bin/fprint-delete-finger`（及 `.py`） | 精确删单枚指纹（第 4.2 节） |
| `/usr/libexec/fprintd`（`fprintd 1.94.3-1+pa1`） | 打过「重新登记」修复补丁的 fprintd（dpkg 装，`apt-mark hold`） |
| `/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so`（`libpam-fprintd 1.94.3-1+pa1`） | PAM 指纹模块（与 fprintd **同版本族**；两包必须一起装/卸，见 4.6） |

### 9.2 编译驱动（可选）

```bash
sudo apt install meson ninja-build gcc pkg-config libfprint-2-tod-dev
cd payload/src
meson setup build && ninja -C build
sudo install -m 0755 build/libpixelauth_pt2887.so \
     /usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/
```

⚠️ `meson.build` 里**故意不写 libfprint 版本约束** —— noble 的 pkg-config 报的版本是
`1.94.7+tod1+tod1`，写 `>= 1.95` 会直接构建失败。

### 9.3 CHANGELOG

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.2.2 | 2026-10-01 | 修复「补丁漏装 libpam-fprintd → apt 依赖真空（已损坏个数>0，全部更新装不上）」：① apply 两包同装同 hold、revert 对称回滚 ② build.sh 收 libpam 产物与原版回滚包 ③ checkup 新增 [2b] apt 依赖完整性检查 ④ install.sh 幂等检查改为核对两包 |
| 0.2.1 | 2026-10-01 | 删除工具规范化：安装为 `/usr/local/bin/fprint-delete-finger`（免后缀短名）+ 文档写透"GNOME 46 没有删单枚功能"的实证与用法 |
| 0.2.0 | 2026-10-01 | ①「重新登记该手指」安全性修复（fprintd 补丁：删除推迟到检查通过后 + 同指豁免；RED/GREEN 实测验证）② sudo 助手改 `fprintd-verify -f any`，修复"只认第一根手指" ③ 新增 `tools/re-register-test.sh` 验收工具 ④ checkup 增加补丁与 `-f any` 检查 |
| 0.1.0 | 2026-09-30 | 首个打包版本：`33 <槽位>` 修正、`a5` 记录写入、`delete`/`clear_storage`、PAM 助手改走 fprintd |

---

## 10. 一页保命卡

```
sudo 进不去？
  Ctrl+Alt+F3 用密码登录 → sudo rm -f /usr/local/bin/pam-biometric-exec.sh
  （助手不在 = 自动回退密码；密码通道从没被动过）

指纹没反应？
  cat /sys/module/8250/parameters/nr_uarts     → 必须是 2
  fprintd-list $USER                            → 有没有记录
  sudo ./payload/checkup.sh                     → 哪一层红了

删指纹？
  ❌ 别在 GNOME 里点"删除指纹"（GNOME 46 没有删单枚功能，只会通向全删）
  ✅ fprint-delete-finger              （不带参数先列出所有名字）
  ✅ fprint-delete-finger <手指名>     （只删这一枚，不需要 sudo）

重新登记坏了？（升级/换系统后补丁丢了）
  sudo ./payload/fprintd-patch/install-fprintd-patched.sh status
  版本不是 +pa1 → apply 重新打上

只看不装：
  ./install.sh --status
```
