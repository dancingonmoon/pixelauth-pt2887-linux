/* ============================================================================
 * libfprint TOD 驱动：品识(PixelAuth) PT2887-SS 指纹模组
 *
 * 设备：USB VID 0x2f0a / PID 0x8020（曙光/中科可控 天阔 N50 电源键二合一指纹）
 * 形态：libfprint TOD 树外驱动（Ubuntu 的 libfprint 是 +tod1 分支构建）
 *
 * ── 协议来源：2026-09-27 用 usbmon 抓取麒麟驱动的真实流量解出 ──
 *
 *   帧结构（发往设备 / 设备返回，同构）：
 *     [0..4]   "PXAT" + 0xC0              5 字节
 *     [5..6]   BE16(内层长度)              = 10 + payload_len（★含末尾 2 字节 CRC）
 *     [7..13]  EF 01 FF FF 00 00 00       7 字节固定前缀
 *     [14]     payload_len (u8)           单字节
 *     [15..]   payload
 *     [末2]    BE16 CRC-16/KERMIT         只对 payload 算
 *
 *   ★ 2026-09-27 用独立探针 probe/pa_probe.c 实测确认：
 *     [5..6] 必须等于 7+1+plen+2。早期版本漏算 CRC 的 2 字节，
 *     设备一律回一个 9 字节的 NAK：50 58 41 54 c0 00 02 9f ff。
 *
 *   端点：0x02 OUT（主机→设备）/ 0x81 IN（设备→主机），均为 bulk
 *
 *   命令（OUT 的 payload 首字节）：
 *     0xa1        读设备信息（返回 39B：含 20B 0xff + 16 字符 SN）
 *     0x1f        读指纹索引表（返回 33B：状态 + 256 位位图）
 *     0xa6 xx..   读一条记录（a6 02 80 00 40 → 65B：状态 + 槽号 + 32B 数据）
 *     0xf2        验证准备
 *     0x33 0x0a   启动验证（参数 0x0a）
 *     0xf1        轮询验证状态
 *
 *   状态（IN 的 payload）：
 *     00          通用成功
 *     f0          等待手指
 *     f1          匹配成功（后跟 00 0a 00 64，0x64=100 疑似匹配分）
 *
 *   抓到的完整验证时序：
 *     →a1  ←39B   →1f ←33B   →a6 ←65B   →1f ←33B
 *     →f2  ←1B    →33 0a ←1B
 *     →f1  ←f0 (等待)  反复轮询
 *     →f1  ←f1 00 0a 00 64   ← 匹配成功
 *
 *   索引表（0x1f 响应）实测：
 *     payload[0]    = 状态（0x00 正常）
 *     payload[1..32]= 256 位位图，位 N 置位 = 槽位 N 已录入（每字节 LSB 优先）
 *     本机实测 payload = 00 00 04 00 ... → 只有槽位 10 被占用，
 *     与厂商 libpixelauth_pa180k.so 里 start_enroll_id=10 完全吻合。
 *
 *   另：0x1f 单独发即可，不需要先发 0xa1。
 * ============================================================================
 */

#include "drivers_api.h"
#include <gusb.h>

#define FP_COMPONENT "pixelauth_pt2887"

/* ---- 协议常量 ---- */
#define PA_EP_OUT        (0x02 | FPI_USB_ENDPOINT_OUT)
#define PA_EP_IN         (0x81 | FPI_USB_ENDPOINT_IN)
#define PA_HDR_LEN       15          /* PXAT+c0 | BE16 | 7字节前缀 | len */
#define PA_TIMEOUT_MS    3000        /* 单次 USB 传输超时（抓包看设备响应很快）*/
#define PA_POLL_DELAY_MS 200         /* 轮询间隔 */
/* ★★ 2026-09-29 实测修正：原来这里是 60（12 秒），导致"开机登录界面黄灯不亮"。
 *
 *   pam_fprintd 的默认值是 timeout=30 秒、max-tries=3（见 man pam_fprintd），
 *   而 /etc/pam.d/gdm-fingerprint 没有覆盖它们——所以登录界面本该有 3×30=90 秒
 *   的"等手指"窗口。
 *
 *   但**一次验证尝试的长度是由驱动决定的**：我们 12 秒就报 no-match，
 *   pam_fprintd 收到 no-match 立刻重试（抓到的日志：VerifyStop→VerifyStart→…×3），
 *   于是窗口缩水成 3×12 = 36 秒。用户走到电脑前时窗口已经过期，
 *   看到的就是"黄灯灭、按了没反应"；敲键盘会让 greeter 重开一次 PAM 会话，
 *   所以"一动键盘黄灯就亮"。
 *
 *   现在取 145×200ms = 29 秒，**略小于 pam_fprintd 的 30 秒超时**，
 *   这样每次尝试都由我们主动以 no-match 结束（这是已验证会触发重试的路径），
 *   总窗口 ≈ 3×29 = 87 秒。不要取到 30 秒以上——那会变成由 pam_fprintd
 *   的超时来结束，而"超时后会不会重试"没有实测过。 */
#define PA_POLL_MAX      145         /* 最多轮询次数（145×200ms = 29 秒）*/
#define PA_MAX_FRAME     128

#define PA_CMD_SYSPARA   0xa1
#define PA_CMD_LIST      0x1f
#define PA_CMD_ENROLL    0x31        /* 启动录入：31 <槽位BE16> 0f 00 00 */
#define PA_CMD_VERIFY    0x33
#define PA_CMD_PREP      0xf2
#define PA_CMD_POLL      0xf1
#define PA_CMD_ABORT     0xf4        /* 中止（★ 必须跟在 f2 后面，单发无效） */
/* ★★ 2026-09-30：写记录。录入成功后**必须**发这一条，否则记录区留着 0x33 占位符：
 *     ① 芯片认不出这枚指纹（我们自己录的全用不了，根因就是这个）
 *     ② 麒麟的 pabio_sync_invalid_device_record 会把它当"不认识的记录"删掉
 *   载荷精确格式（从 09-29 抓到的真实帧逐字节数出来的，共 **69 字节**）：
 *     a5 <地址BE16=槽位×0x40> <00 40> <00> <槽位LE16> <20> <32字节随机数> <28字节补零>
 *     └ 5 字节命令头 ─────────┘ └── 4 字节记录头 ──┘ └─ 数据 ─┘ └─ 补到 64 ─┘
 *   其中 `00 40` = 0x40 = 64 = 记录槽大小：4 头 + 32 数据 + 28 补零 = 64 ✓
 *   ★ 那 32 字节是**主机侧生成的随机数**，作用只是"芯片记录 ↔ 主机数据库"之间共享的
 *     一个 UUID（厂商库反汇编证实：srand(time(NULL)) + 32 次 rand()），
 *     **不是模板、不是哈希** —— 取任意随机数即可，不必和厂商算法一致。 */
#define PA_CMD_RECORD    0xa5
/* ★★ 2026-09-30：删除指纹。载荷 5 字节：`0c <槽位BE16> 00 01`，响应 1 字节 00=成功。
 *   语义已在**试验品槽位 12** 上实测确认（全程不碰用户正在用的槽位）：
 *     · 删前索引 10 11 12 → 删后 10 11 —— **只删指定槽位，没有误伤**
 *     · +0/+3/+8 秒三次读数一致（不是瞬时假象）
 *     · ★ 它只删**索引项**，记录区字节还留着（`a6` 仍读得到）
 *       —— 这正好解释了之前"槽位 11 有记录、没索引"的状态：就是被它删的。
 *   （`00 01` 那个字段的含义仍未确定，可能是计数或索引；照实测能用的写法发即可。） */
#define PA_CMD_DELETE    0x0c
#define PA_RECORD_SLOT   0x40        /* 记录槽大小：64 字节 */
#define PA_RECORD_DATA   0x20        /* 记录里真正有数据的部分：32 字节 */
#define PA_ST_WAITING    0xf0
#define PA_ST_MATCH      0xf1
/* ★★ 2026-09-29 实测认定：0xf2 = **手指按下去了但匹配不上**（不是"忙"，也不是"继续等"）。
 *   证据（finger-id.sh 5 根手指的对照实验，日志里的状态变化）：
 *     右手食指（芯片里有模板）  f0 → #7 f1     ✅ 匹配
 *     右手拇指 / 左手拇指 / 左手食指（都没模板） f0 → #8 f2   ❌
 *     右手中指                              f0 → #3 f4 → #4 f2 ❌
 *   而且它是**粘滞**的：一旦变成 f2 就不会回到 f0（对着同一根手指连按 145 次都是 f2）。
 *   在这之前驱动只认 f0/f1、把 f2 当噪音忽略 —— 于是每次"按了但不匹配"都要
 *   白等满整个 29 秒窗口才报超时。补上这一条后立刻上报，体验和可诊断性都好得多。 */
#define PA_ST_NO_MATCH   0xf2

/* 芯片的指纹槽位：厂商 JSON 里 start_enroll_id=10；索引表是 256 位位图 */
#define PA_START_SLOT      10
#define PA_SLOT_BYTES      32
#define PA_ENROLL_SLOT_MAX 19       /* 槽位区间 10..19（厂商 JSON: max_total_record_count=10） */

/* ------------------------------------------------------------------ 类型 */
struct _FpiDevicePixelauth
{
  FpDevice   parent;
  GUsbDevice *usb_dev;
  gboolean    opened;
  gboolean    is_identify;      /* verify 与 identify 共用一条状态机，靠它区分 */

  gint        enroll_slot;      /* 本次录入分配到的芯片槽位 */
  guint       enroll_stages;    /* 已完成的采集次数 */
  gint        last_state;       /* 上一次轮询到的芯片状态（用来识别状态变化） */

  /* ★★ 2026-09-29：`33 <字节>` 里的字节 = **目标槽位**（以前写死 0x0a=10）。
   *   芯片一次只比对**一个**槽位，1:N 要靠主机循环（麒麟就是这么做的）。
   *   cand_slots = 本次要依次尝试的槽位列表，cand_idx = 当前试到第几个。 */
  guint       target_slot;      /* 当前发出去的 33 里的槽位 */
  GArray     *cand_slots;       /* 候选槽位（guint） */
  guint       cand_idx;

  guint8      send_buf[PA_MAX_FRAME];
  guint8      recv_buf[PA_MAX_FRAME];
  gsize       recv_len;
  guint       poll_count;

  /* ★★ 2026-09-30：真正的"打断"标志。
   *   libfprint 调 cancel 只是**通知**驱动；驱动必须让正在跑的动作**尽快结束**，
   *   否则上层的 EnrollStop/VerifyStop 会一直不返回 ——
   *   GNOME 设置里的表现就是**页面一直转圈、关都关不掉**（实测踩到过）。
   *   以前这里是空实现，一次取消要等状态机自己跑满（最长 29 秒）才收尾。
   *   现在：cancel 置位这个标志 → 各处轮询循环下一次就判定结束（200 毫秒内）。 */
  gboolean    cancel_requested;
};

G_DECLARE_FINAL_TYPE (FpiDevicePixelauth, fpi_device_pixelauth,
                      FPI, DEVICE_PIXELAUTH, FpDevice)

G_DEFINE_TYPE (FpiDevicePixelauth, fpi_device_pixelauth, FP_TYPE_DEVICE)

/* 前向声明：verify/identify 共用的状态机要用到这些（定义在后面章节） */
static gint     pa_match_slot      (const guint8 *buf, gsize len);
static gint     pa_match_score     (const guint8 *buf, gsize len);
static FpFinger pa_slot_to_finger  (guint slot);
static FpPrint *pa_make_slot_print (FpDevice *device, gint slot, FpFinger finger);
static FpPrint *pa_find_in_gallery (GPtrArray *gallery, FpPrint *made, gint slot);
static void     pa_cand_reset      (FpiDevicePixelauth *self);
static void     pa_cand_add        (FpiDevicePixelauth *self, gint slot);
static gboolean pa_cand_next       (FpiDevicePixelauth *self);

/* ============================================================ 协议工具 */

/* CRC-16/KERMIT：poly 0x1021, init 0, refin=refout=true, xorout=0 */
static guint16
pa_crc16 (const guint8 *data, gsize len)
{
  guint16 crc = 0x0000;

  for (gsize i = 0; i < len; i++)
    {
      guint8 b = data[i];
      guint8 r = 0;

      for (int k = 0; k < 8; k++)          /* 反转输入字节 */
        r |= ((b >> k) & 1) << (7 - k);

      crc ^= (guint16) r << 8;
      for (int k = 0; k < 8; k++)
        crc = (crc & 0x8000) ? (guint16) ((crc << 1) ^ 0x1021) : (guint16) (crc << 1);
    }

  guint16 out = 0;
  for (int k = 0; k < 16; k++)             /* 反转输出 */
    out |= ((crc >> k) & 1) << (15 - k);

  return out;
}

/* 组装一整帧，返回总长度 */
static gsize
pa_build (guint8 *buf, const guint8 *payload, gsize plen)
{
  static const guint8 prefix[7] = { 0xef, 0x01, 0xff, 0xff, 0x00, 0x00, 0x00 };
  /* ★ 实测（2026-09-27 探针）：inner_len 覆盖 [7] 之后的**全部**字节，
   *   即 7 前缀 + 1 长度字节 + payload + 2 字节 CRC = 10 + plen。
   *   之前漏算 CRC 的 2 字节，设备一律回 NAK（9 字节 9f ff）。 */
  guint16 inner = (guint16) (7 + 1 + plen + 2);
  guint16 crc;

  g_assert (plen <= 255);
  g_assert (PA_HDR_LEN + plen + 2 <= PA_MAX_FRAME);

  buf[0] = 'P'; buf[1] = 'X'; buf[2] = 'A'; buf[3] = 'T'; buf[4] = 0xc0;
  buf[5] = (inner >> 8) & 0xff;
  buf[6] = inner & 0xff;
  memcpy (buf + 7, prefix, 7);
  buf[14] = (guint8) plen;
  if (plen && payload)
    memcpy (buf + 15, payload, plen);

  crc = pa_crc16 (payload, plen);           /* ★ 只对 payload 算 */
  buf[15 + plen]     = (crc >> 8) & 0xff;   /* ★ 大端 */
  buf[15 + plen + 1] = crc & 0xff;

  return PA_HDR_LEN + plen + 2;
}

/* 校验一个响应帧，成功则返回 payload 首字节（状态），失败返回 -1 */
static int
pa_parse (const guint8 *buf, gsize len)
{
  gsize plen;
  guint16 crc, want;

  if (len < PA_HDR_LEN + 2)
    return -1;
  if (memcmp (buf, "PXAT", 4) != 0 || buf[4] != 0xc0)
    return -1;

  plen = buf[14];
  if (PA_HDR_LEN + plen + 2 != len)
    return -1;

  want = ((guint16) buf[15 + plen] << 8) | buf[15 + plen + 1];
  crc  = pa_crc16 (buf + 15, plen);
  if (crc != want)
    {
      fp_warn ("CRC 不匹配: 期望 %04x 实算 %04x", want, crc);
      return -1;
    }

  return plen ? buf[15] : -1;
}

/* 与 pa_parse 同样的校验，但把整段 payload 交给调用者。
 * 成功返回 payload 长度(>=0) 并置 *payload；失败返回 -1。 */
static gssize
pa_payload (const guint8 *buf, gsize len, const guint8 **payload)
{
  gsize plen;
  guint16 crc, want;

  if (len < PA_HDR_LEN + 2)
    return -1;
  if (memcmp (buf, "PXAT", 4) != 0 || buf[4] != 0xc0)
    return -1;

  plen = buf[14];
  if (PA_HDR_LEN + plen + 2 != len)
    {
      fp_warn ("帧长不符: [14]=%zu 实际=%zu", plen, len);
      return -1;
    }

  want = ((guint16) buf[15 + plen] << 8) | buf[15 + plen + 1];
  crc  = pa_crc16 (buf + 15, plen);
  if (crc != want)
    {
      fp_warn ("CRC 不匹配: 期望 %04x 实算 %04x", want, crc);
      return -1;
    }

  *payload = buf + 15;
  return (gssize) plen;
}

/* ==================================================== USB 收发（异步） */

typedef struct {
  FpiSsm   *ssm;
  gboolean  is_send;
} PaXferData;

static void
pa_recv_cb (FpiUsbTransfer *transfer, FpDevice *device, gpointer user_data, GError *error)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  PaXferData *xd = user_data;
  FpiSsm *ssm = xd->ssm;

  g_free (xd);

  if (error)
    {
      fpi_ssm_mark_failed (ssm, error);
      return;
    }

  self->recv_len = transfer->actual_length;
  if (self->recv_len > PA_MAX_FRAME)
    self->recv_len = PA_MAX_FRAME;
  memcpy (self->recv_buf, transfer->buffer, self->recv_len);

  fpi_ssm_next_state (ssm);
}

static void
pa_send_cb (FpiUsbTransfer *transfer, FpDevice *device, gpointer user_data, GError *error)
{
  PaXferData *xd = user_data;
  FpiSsm *ssm = xd->ssm;

  g_free (xd);

  if (error)
    {
      fpi_ssm_mark_failed (ssm, error);
      return;
    }

  fpi_ssm_next_state (ssm);
}

/* 发一帧（SSM 会把状态推进到下一个 state） */
static void
pa_do_send (FpiSsm *ssm, FpDevice *device, const guint8 *payload, gsize plen)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  FpiUsbTransfer *t;
  PaXferData *xd;
  gsize total;

  total = pa_build (self->send_buf, payload, plen);

  t = fpi_usb_transfer_new (device);
  fpi_usb_transfer_fill_bulk_full (t, PA_EP_OUT, self->send_buf, total, NULL);
  xd = g_new0 (PaXferData, 1);
  xd->ssm = ssm;
  xd->is_send = TRUE;
  /* fpi_usb_transfer_submit() 会接管这个引用，完成后自行释放。
   * ★ 千万不要再 unref —— 之前多减了一次，导致
   *   "fpi_usb_transfer_unref: assertion 'self->ref_count' failed"，
   *   传输根本没发出去，SSM 却以为完成了。 */
  fpi_usb_transfer_submit (t, PA_TIMEOUT_MS, NULL, pa_send_cb, xd);
}

/* 收一帧（SSM 会在回调里推进状态） */
static void
pa_do_recv (FpiSsm *ssm, FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  FpiUsbTransfer *t;
  PaXferData *xd;

  t = fpi_usb_transfer_new (device);
  fpi_usb_transfer_fill_bulk (t, PA_EP_IN, PA_MAX_FRAME);
  xd = g_new0 (PaXferData, 1);
  xd->ssm = ssm;
  fpi_usb_transfer_submit (t, PA_TIMEOUT_MS, NULL, pa_recv_cb, xd);
  (void) self;
}

/* ==================================================== verify 状态机 */

/* ★ 状态机必须严格交替「发」和「收」：
 *   每个 V_SEND_* 之后的 V_RECV_* 只负责**发起**接收，
 *   真正的解析要放到再下一个状态（此时传输已完成、recv_buf 才是新数据）。
 *   之前把"发起接收"和"解析"写在同一个状态里，解析到的是上一轮的旧数据。 */
enum {
  /* ★ V_NEXT_SLOT 放在最前：每轮从候选列表里取下一个槽位；
   *   取不到就报"没匹配上"并结束。一次 f2（按下了但不匹配）就跳回这里换槽位。 */
  V_NEXT_SLOT,
  V_SEND_PREP, V_RECV_PREP,          /* f2  → 收，丢弃 */
  V_SEND_VERIFY, V_RECV_VERIFY,      /* 33 <目标槽位> → 收，丢弃 */
  V_SEND_POLL, V_RECV_POLL, V_PARSE_POLL,
  V_NUM_STATES
};

static void
verify_ssm_handler (FpiSsm *ssm, FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  FpPrint *print = NULL;
  int st;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case V_NEXT_SLOT:
      if (!pa_cand_next (self))
        {
          /* 候选槽位都试完了 → 没匹配上 */
          fp_dbg ("%s: 候选槽位试完，没匹配上",
                  self->is_identify ? "identify" : "verify");
          if (self->is_identify)
            fpi_device_identify_report (device, NULL, NULL, NULL);
          else
            fpi_device_verify_report (device, FPI_MATCH_FAIL, NULL, NULL);
          fpi_ssm_mark_completed (ssm);
          break;
        }
      self->poll_count = 0;
      fp_dbg ("%s: 目标槽位 → %d（第 %u 个候选）",
              self->is_identify ? "identify" : "verify",
              self->target_slot, self->cand_idx);
      fpi_ssm_next_state (ssm);
      break;

    case V_SEND_PREP:
      { guint8 p = PA_CMD_PREP; pa_do_send (ssm, device, &p, 1); }
      break;

    case V_RECV_PREP:
      pa_do_recv (ssm, device);
      break;

    case V_SEND_VERIFY:
      { guint8 p[2] = { PA_CMD_VERIFY, (guint8) self->target_slot };
        pa_do_send (ssm, device, p, 2); }
      break;

    case V_RECV_VERIFY:
      pa_do_recv (ssm, device);
      break;

    case V_SEND_POLL:
      { guint8 p = PA_CMD_POLL; pa_do_send (ssm, device, &p, 1); }
      break;

    case V_RECV_POLL:
      pa_do_recv (ssm, device);
      break;

    case V_PARSE_POLL:
      st = pa_parse (self->recv_buf, self->recv_len);
      fp_dbg ("轮询 #%u 状态=0x%02x", self->poll_count + 1, st);

      if (st == PA_ST_MATCH)
        {
          gint slot = pa_match_slot (self->recv_buf, self->recv_len);

          /* 芯片是在整个已录入集合里做 1:N 匹配的。
           * identify 要我们自己造一枚"匹配到的那枚"报回去；
           * verify 则把调用者给的那枚原样报回去。 */
          if (self->is_identify)
            {
              /* ★ 小心：identify_report 的签名和 verify_report **不一样**！
               *     identify_report(device, match, print, error)
               *   match = 候选列表里被匹配上的那枚（没有就是 NULL）
               *   print = 本设备产出的那枚
               *   它没有 result 参数；照 verify 的样子把 FPI_MATCH_SUCCESS
               *   当指针传进去会让 libgobject 立刻段错误，并带崩整个 fprintd。 */
              GPtrArray *gallery = NULL;
              FpPrint *found = NULL, *made;

              fpi_device_get_identify_data (device, &gallery);
              made = pa_make_slot_print (device, slot, pa_slot_to_finger (slot));
              found = pa_find_in_gallery (gallery, made, slot);

              fp_dbg ("identify: 匹配到槽位 %d（★ 分数 %d），候选 %u 枚，%s",
                      slot,
                      pa_match_score (self->recv_buf, self->recv_len),
                      gallery ? gallery->len : 0,
                      found ? "命中其中一枚" : "没有对应的候选");

              fpi_device_identify_report (device, found, made, NULL);
            }
          else
            {
              fpi_device_get_verify_data (device, &print);
              fp_dbg ("verify: 匹配到槽位 %d（★ 分数 %d）",
                      slot, pa_match_score (self->recv_buf, self->recv_len));
              fpi_device_verify_report (device, FPI_MATCH_SUCCESS, print, NULL);
            }
          fpi_ssm_mark_completed (ssm);
        }
      else if (st == PA_ST_NO_MATCH)
        {
          /* 手指按下了，但**这个槽位**匹配不上 → 换下一个候选槽位再试。
           *
           * ★ 重要：每换一个槽位都要重新 arm（f2 + 33），而**重新 arm 会重置
           *   手指检测** —— 实测 chain 10 11：槽位 10 收到 f2 后，槽位 11 全程
           *   回 f0（因为手指一直按着，芯片要的是"新的一次落下"）。
           *   所以这里下一次 arm 之后，用户需要**抬手重按**。 */
          fp_dbg ("轮询 #%u 状态=0xf2 → 槽位 %d 不匹配，换下一个候选",
                  self->poll_count + 1, self->target_slot);
          fpi_ssm_jump_to_state (ssm, V_NEXT_SLOT);
        }
      else if (self->cancel_requested || ++self->poll_count >= PA_POLL_MAX)
        {
          if (self->is_identify)
            fpi_device_identify_report (device, NULL, NULL, NULL);   /* 没匹配上 */
          else
            fpi_device_verify_report (device, FPI_MATCH_FAIL, NULL, NULL);
          fpi_ssm_mark_completed (ssm);
        }
      else
        {
          fpi_ssm_jump_to_state_delayed (ssm, V_SEND_POLL, PA_POLL_DELAY_MS);
        }
      break;

    default:
      g_assert_not_reached ();
    }
}

static void
verify_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);

  if (error && !g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED))
    fp_warn ("验证状态机失败: %s", error->message);

  pa_cand_reset (self);          /* 候选列表用完就释放 */

  if (self->is_identify)
    fpi_device_identify_complete (device, error);
  else
    fpi_device_verify_complete (device, error);
}

/* 造一个"芯片槽位"的 FpPrint。enroll / identify / list 都用它，
 * 保证三处描述一致，槽位可从描述里反推。 */
static FpPrint *
pa_make_slot_print (FpDevice *device, gint slot, FpFinger finger)
{
  FpPrint *print = fp_print_new (device);
  gchar *desc;

  g_object_ref_sink (print);     /* fp_print_new 返回浮动引用 */
  fpi_print_set_type (print, FPI_PRINT_RAW);
  fpi_print_set_device_stored (print, TRUE);
  fp_print_set_finger (print, finger);

  /* ★★ 必须给 print 一个"数据体"，否则 fprintd 存盘时会**段错误**：
   *   fp_print_serialize() 对 RAW 类型的 data 字段**不判空**，
   *   直接 g_variant_new_variant(NULL) → 断言失败 → 解引用 NULL。
   *   （反汇编确认：type==2 走细节点分支，否则无条件取 data 包 variant。）
   *   这个字段没有对应的 C 函数，只能通过这个可写的 GObject 属性设置。
   *   对 match-on-chip 设备而言，芯片槽位就是这枚 print 的全部身份 ——
   *   放槽位还有一个好处：fp_print_equal() 能靠它认出"是同一枚"，
   *   identify 才能报出匹配到的是候选列表里的哪一枚。 */
  g_object_set (print, "fpi-data", g_variant_new_uint32 ((guint32) slot), NULL);

  desc = g_strdup_printf ("PT2887-SS slot %d", slot);
  fp_print_set_description (print, desc);
  g_free (desc);

  return print;
}

/* 从一枚 print 的 fpi-data 里取回槽位；取不到返回 -1。 */
static gint
pa_print_slot (FpPrint *print)
{
  GVariant *v = NULL;
  gint slot = -1;

  if (!print)
    return -1;

  g_object_get (print, "fpi-data", &v, NULL);
  if (v)
    {
      if (g_variant_is_of_type (v, G_VARIANT_TYPE_UINT32))
        slot = (gint) g_variant_get_uint32 (v);
      g_variant_unref (v);
    }
  return slot;
}

/* 清空并重建候选槽位列表 */
static void
pa_cand_reset (FpiDevicePixelauth *self)
{
  if (self->cand_slots)
    {
      g_array_free (self->cand_slots, TRUE);
      self->cand_slots = NULL;
    }
  self->cand_idx = 0;
}

/* 往候选列表里加一个槽位（去重、只收录入区间的） */
static void
pa_cand_add (FpiDevicePixelauth *self, gint slot)
{
  guint s;

  if (slot < PA_START_SLOT || slot > PA_ENROLL_SLOT_MAX)
    return;
  if (!self->cand_slots)
    self->cand_slots = g_array_new (FALSE, FALSE, sizeof (guint));

  for (guint i = 0; i < self->cand_slots->len; i++)
    if (g_array_index (self->cand_slots, guint, i) == (guint) slot)
      return;

  s = (guint) slot;
  g_array_append_val (self->cand_slots, s);
}

/* 取下一个候选槽位；没有了返回 FALSE */
static gboolean
pa_cand_next (FpiDevicePixelauth *self)
{
  if (!self->cand_slots || self->cand_idx >= self->cand_slots->len)
    return FALSE;
  self->target_slot = g_array_index (self->cand_slots, guint, self->cand_idx);
  self->cand_idx++;
  return TRUE;
}

/* 在候选列表里找出"就是这一枚"。先按 fpi-data 里的槽位比（最可靠，
 * 不受用户给手指起的名字影响），再退回整体判等。 */
static FpPrint *
pa_find_in_gallery (GPtrArray *gallery, FpPrint *made, gint slot)
{
  if (!gallery)
    return NULL;

  for (guint i = 0; i < gallery->len; i++)
    {
      FpPrint *g = g_ptr_array_index (gallery, i);
      g_autoptr(GVariant) v = NULL;

      g_object_get (g, "fpi-data", &v, NULL);
      if (v && g_variant_is_of_type (v, G_VARIANT_TYPE_UINT32) &&
          (gint) g_variant_get_uint32 (v) == slot)
        return g;
    }

  for (guint i = 0; i < gallery->len; i++)
    {
      FpPrint *g = g_ptr_array_index (gallery, i);
      if (fp_print_equal (g, made))
        return g;
    }

  return NULL;
}

/* ==================================================== enroll 状态机（真·录入）
 *
 * 2026-09-28 用 probe/pa_probe enrollwatch 实测出的完整协议：
 *
 *   命令序列：  f2  →  31 <槽位BE16> 0f 00 00  →  f1 轮询 …
 *   芯片状态：  0xe0 = 等手指   0xe4 = 手指放下   0xeb = 采集中   0xe1 = 完成
 *   实测约 14 次有效按压后，芯片把模板写进槽位，索引表随之出现该槽位。
 *
 *   ★ 与厂商代码互相印证：libpixelauth_pa180k.so 里
 *     RecvParser_SKF::fpState2COSRet() 的状态表里**没有** 0xe1，走默认分支返回 0（成功）；
 *     验证成功的 0xf1 同样不在表里 —— 两者语义一致，互为佐证。
 *
 *   ★ 早先的版本只会"把芯片里已有的模板绑定到手指名"（复用旧指纹），
 *     所以从 GNOME 新增手指必然失败。这一版是真正的录入。
 */

#define PA_ENROLL_STAGES   14       /* 参考值：实测一次录入的按压次数 */
#define PA_ENROLL_POLL_MAX 1500     /* 1500 × 200ms ≈ 5 分钟录入窗口 */

/* 录入过程中芯片回的状态码 */
#define PA_ST_EN_WAIT  0xe0         /* 等手指 */
#define PA_ST_EN_DOWN  0xe4         /* 手指放下 */
#define PA_ST_EN_CAP   0xeb         /* 采集中 */
#define PA_ST_EN_DONE  0xe1         /* 完成 */

/* 先试「绑定」再走「真录入」——
 * ★ 为什么要有绑定这条路：截至 2026-09-28，我们自己的真录入虽然能跑完
 *   （芯片回 e1、索引表也占位），但录出来的**指纹不可用** ——
 *   麒麟驱动在录入后还会往槽位写一段 32 字节记录（`a5`），不写的话槽位里是
 *   0x33 填充，芯片不认。那段记录的来源还没破解。
 *   而麒麟栈自己录的模板是好用的。所以：**已经存在于芯片里的手指，
 *   我们直接绑定**（按一下匹配到槽位即可，不用重录）；只有芯片里没有的手指
 *   才走真录入。 */
/* ★★ 2026-09-29 实测：原来 60（12 秒）太短。
 *   `fprintd-enroll` 在进到这里之前，**libfprint 自己还要先做一次去重检查**
 *   （也是一次 arm + 等手指，走的是 verify 的 29 秒窗口）。用户按惯例在命令
 *   刚跑起来时不会立刻按，于是 12 秒的绑定窗口经常白过，然后**静默落到真录入**
 *   —— 结果就是又往芯片里留一个 `33 33…` 的垃圾槽位（当天实测复现过一次）。
 *   改成和 verify 一致的 145（29 秒）；配合下面"绑定失败直接报错"的闸。 */
#define PA_BIND_POLL_MAX   145      /* 绑定：145 × 200ms = 29 秒 */

enum {
  /* ★★ 2026-09-29 起顺序变成：先读索引表收集"已占用的槽位"，再逐个绑定。
   *   以前是「上来就 arm 槽位 10（写死的 33 0a）→ 超时就落进真录入」，
   *   两个毛病：① 永远只试槽位 10 ② 失败后往芯片里留垃圾槽位。 */
  E_SEND_LIST, E_RECV_LIST, E_PARSE_LIST,       /* 1f   收集已占用槽位 */
  E_SEND_BIND_PREP, E_RECV_BIND_PREP,           /* f2    绑定：准备 */
  E_SEND_BIND_GO,   E_RECV_BIND_GO,             /* 33 <槽位> 绑定：启动验证 */
  E_SEND_BIND_POLL, E_RECV_BIND_POLL, E_PARSE_BIND_POLL,
  E_SEND_PREP, E_RECV_PREP,                     /* f2    真录入：准备 */
  E_SEND_START, E_RECV_START,                   /* 31    真录入：启动 */
  E_SEND_POLL, E_RECV_POLL, E_PARSE_POLL,       /* f1    真录入：轮询 */
  E_SEND_RECORD, E_RECV_RECORD, E_PARSE_RECORD, /* a5    录入成功后写记录（关键一步） */
  E_NUM_STATES
};

/* 从匹配成功的轮询响应里取槽位：payload = f1 <槽位 BE16> <分数 BE16> */
static gint
pa_match_slot (const guint8 *buf, gsize len)
{
  const guint8 *pay = NULL;
  gssize plen = pa_payload (buf, len, &pay);

  if (plen < 3 || pay[0] != PA_ST_MATCH)
    return -1;

  return ((gint) pay[1] << 8) | pay[2];
}

/* 匹配响应里还带一个**分数**：payload = f1 <槽位BE16> <分数BE16>
 * 实测：真匹配时分数 = 100（满分），不匹配时芯片直接回 0xf2 不来这里。
 * 2026-09-30 加：原本这个字段被丢掉了，现在打进日志 ——
 * 为的是查清"明知道手指不匹配、去重检查却报匹配"那件事到底怎么回事：
 * 如果那种"匹配"的分数明显低于 100，就说明芯片确实会勉强匹配，
 * 那我们就可以在驱动里加一道"分数不够不算匹配"的门槛。
 * （只加日志、不改判断 —— 先把真相拿到，再决定怎么改。） */
static gint
pa_match_score (const guint8 *buf, gsize len)
{
  const guint8 *pay = NULL;
  gssize plen = pa_payload (buf, len, &pay);

  if (plen < 5 || pay[0] != PA_ST_MATCH)
    return -1;

  return ((gint) pay[3] << 8) | pay[4];
}

/* 绑定失败 → 转真录入。
 * 绑定有两条失败出路（① 超时：压根没手指 ② 收到 0xf2：按了但所有已占用槽位都不匹配），
 * 两条都要汇到这里：**说明这是一根新手指**，该真录入了。
 * 前提是索引表读到的那个空槽位还在（enroll_slot >= 0）。
 * 返回值：TRUE = 已经跳到 E_SEND_PREP；FALSE = 状态机已按"槽位满"结束。 */
static gboolean
pa_enroll_to_real (FpiSsm *ssm, FpDevice *device, FpiDevicePixelauth *self)
{
  if (self->enroll_slot < 0)
    {
      fp_warn ("enroll: 想转真录入，但芯片槽位已满");
      fpi_device_enroll_complete (device, NULL,
        fpi_device_error_new_msg (FP_DEVICE_ERROR_DATA_FULL,
                                  "芯片里的 10 个槽位都占满了，请先删掉一枚再录"));
      fpi_ssm_mark_completed (ssm);
      return FALSE;
    }

  self->poll_count = 0;
  self->last_state = -1;
  fp_dbg ("enroll: 这是一根新手指 → 真录入，写进空槽位 %d（录完会写 a5 记录）",
          self->enroll_slot);
  fpi_ssm_jump_to_state (ssm, E_SEND_PREP);
  return TRUE;
}

static void
enroll_ssm_handler (FpiSsm *ssm, FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  FpPrint *wanted = NULL;
  const guint8 *pay = NULL;
  int st;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case E_SEND_BIND_PREP:
      fpi_device_get_enroll_data (device, &wanted);
      fpi_device_enroll_progress (device, 0, wanted, NULL);
      { guint8 p = PA_CMD_PREP; pa_do_send (ssm, device, &p, 1); }
      break;

    case E_RECV_BIND_PREP:
      pa_do_recv (ssm, device);
      break;

    case E_SEND_BIND_GO:
      { guint8 p[2] = { PA_CMD_VERIFY, (guint8) self->target_slot };
        pa_do_send (ssm, device, p, 2); }
      break;

    case E_RECV_BIND_GO:
      pa_do_recv (ssm, device);
      break;

    case E_SEND_BIND_POLL:
      { guint8 p = PA_CMD_POLL; pa_do_send (ssm, device, &p, 1); }
      break;

    case E_RECV_BIND_POLL:
      pa_do_recv (ssm, device);
      break;

    case E_PARSE_BIND_POLL:
      st = pa_parse (self->recv_buf, self->recv_len);

      if (st == PA_ST_MATCH)
        {
          /* 芯片里有这枚指纹 → 直接绑定到请求的手指名 */
          gint slot = pa_match_slot (self->recv_buf, self->recv_len);
          FpPrint *out;

          /* ★★ 2026-09-29 修：`wanted` 是 handler 的**局部变量**，每进一次状态就
           *   重新初始化成 NULL —— 只有 E_SEND_BIND_PREP 那个状态里赋过值，
           *   跑到 E_PARSE_BIND_POLL 时早就是 NULL 了。于是下面复制用户名/日期的
           *   整块被跳过，存出来的记录**没有用户名**；fprintd 会把它塞进以设备名
           *   命名的目录，`fprintd-list <用户名>` 永远找不到。
           *   现象：enroll-completed，但 verify 报
           *   `Finger 'left-index-finger' not enrolled for user .`（用户名是空的）。
           *   必须在用之前重新取一次。 */
          fpi_device_get_enroll_data (device, &wanted);

          out = pa_make_slot_print (device, slot,
                                    wanted ? fp_print_get_finger (wanted)
                                           : (FpFinger) FP_FINGER_UNKNOWN);

          if (wanted)
            {
              const gchar *u = fp_print_get_username (wanted);
              const GDate *d = fp_print_get_enroll_date (wanted);

              if (u)
                fp_print_set_username (out, u);
              if (d && g_date_valid (d))
                fp_print_set_enroll_date (out, d);
              fp_dbg ("enroll: 绑定 print 上的 username=%s",
                      u ? u : "(空！)");
            }
          else
            {
              fp_warn ("enroll: 拿不到 enroll data，print 会没有用户名");
            }

          fp_dbg ("enroll: 手指已在芯片里（槽位 %d）→ 直接绑定", slot);
          fpi_device_enroll_complete (device, out, NULL);
          fpi_ssm_mark_completed (ssm);
        }
      else if (st == PA_ST_NO_MATCH)
        {
          /* 手指按下了但芯片里没有这枚模板 → 立刻报错，不必等满 29 秒。
           * （改动前这里会傻等到超时；21:01 那次实测 145 次轮询全是 f2。） */
          gint tried = self->target_slot;

          /* 换个候选槽位再试。★ 重新 arm 会重置手指检测，
           *   所以用户需要**抬手重按一次**（每次换槽位都会多打一行
           *   enroll-stage-passed，可以当作"请再按一次"的提示）。 */
          if (pa_cand_next (self))
            {
              self->poll_count = 0;
              fp_dbg ("enroll: 槽位 %d 不匹配 → 换槽位 %d（请抬手重按）",
                      tried, self->target_slot);
              fpi_ssm_jump_to_state (ssm, E_SEND_BIND_PREP);
            }
          else
            {
              /* 所有已占用槽位都比过了、都不匹配 → 这是一根新手指，转真录入。
               * （第一版只把"超时"那条改成转真录入、漏了这条"收到 f2"的 ——
               *   实测表现为"按新手指 → 3 次 stage-passed → 报错"，压根没进真录入。） */
              pa_enroll_to_real (ssm, device, self);
            }
        }
      else if (st < 0)
        {
          fpi_device_enroll_complete (device, NULL,
            fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO, "绑定阶段通信失败"));
          fpi_ssm_mark_completed (ssm);
        }
      else if (self->cancel_requested || ++self->poll_count >= PA_BIND_POLL_MAX)
        {
          /* ★★ 2026-09-30：**重新打开真录入**。
           *
           * 历史：09-29 这里曾经被改成直接报错（关闸），因为那时候我们的真录入
           * **不写 `a5` 记录** —— 芯片会给记录槽填 `0x33` 占位符，后果是
           *   ① 这个槽位验不过（芯片认不出）
           *   ② 被麒麟的 pabio_sync_invalid_device_record 当"不认识的记录"删掉
           *      （它拿记录里的 32 字节 UUID 跟麒麟自己的库比对，对不上就删）
           * 也就是说，「每录一次就往芯片里留一个定时炸弹」。
           *
           * 现在 `a5` 写入已经实现（见 E_SEND_RECORD），这条路安全了：
           * 录完就写记录，芯片认得、也不再是"无记录支撑"的槽位。
           * 所以恢复"绑定不成 → 走真录入"的原始设计。 */
          pa_enroll_to_real (ssm, device, self);
        }
      else
        {
          fpi_ssm_jump_to_state_delayed (ssm, E_SEND_BIND_POLL, PA_POLL_DELAY_MS);
        }
      break;

    /* ★ 从 E_SEND_LIST 到 E_PARSE_POLL 这一整段是"真·录入"，
     *   2026-09-29 起**暂时进不来**（上游的 E_PARSE_BIND_POLL 超时改成报错了）。
     *   保留代码不动，等 `a5` 记录写入实现好再打开 —— 否则每录一次都会在芯片里
     *   留一个"没有 UUID 记录支撑"的垃圾槽位，最后被麒麟清掉。 */
    case E_SEND_LIST:
      { guint8 p = PA_CMD_LIST; pa_do_send (ssm, device, &p, 1); }
      break;

    case E_RECV_LIST:
      pa_do_recv (ssm, device);
      break;

    case E_PARSE_LIST:
      {
        gssize plen = pa_payload (self->recv_buf, self->recv_len, &pay);

        if (plen < 1 + PA_SLOT_BYTES)
          {
            fpi_device_enroll_complete (device, NULL,
              fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO, "索引表响应异常"));
            fpi_ssm_mark_completed (ssm);
            break;
          }

        /* ★★ 收集**已占用**的槽位当作候选（不是找空位！）——
         *   绑定要回答的是"按下的这根手指在芯片里是哪个槽位"，
         *   所以要把每个已录入的槽位都试一遍。 */
        for (guint i = 1; i <= PA_SLOT_BYTES && (gssize) i < plen; i++)
          for (guint b = 0; b < 8; b++)
            if (pay[i] & (1 << b))
              pa_cand_add (self, (gint) ((i - 1) * 8 + b));

        /* ★★ 2026-09-30：**一次索引表读取，同时算出两样东西**：
         *   ① 已占用的槽位 → 绑定阶段的候选列表（挨个试，看手指是不是已有指纹）
         *   ② 第一个空槽位   → 真录入阶段要写进去的位置
         *   早先这两件事各读一次表，而且 E_PARSE_LIST 只做①、跳去绑定；
         *   于是"绑定失败→转真录入"会和它撞成死循环。合并成一次读取最省事。 */
        self->enroll_slot = -1;
        for (guint i = 1; i <= PA_SLOT_BYTES && (gssize) i < plen; i++)
          for (guint b = 0; b < 8; b++)
            {
              guint s = (i - 1) * 8 + b;

              if (s < PA_START_SLOT || s > PA_ENROLL_SLOT_MAX)
                continue;
              if (pay[i] & (1 << b))
                pa_cand_add (self, (gint) s);                  /* 已占用 → 绑定的候选 */
              else if (self->enroll_slot < 0)
                self->enroll_slot = (gint) s;                  /* 第一个空位 → 真录入用 */
            }

        fp_dbg ("enroll: 芯片里已占用 %u 个槽位，空槽位 → %d",
                self->cand_slots ? self->cand_slots->len : 0, self->enroll_slot);

        /* 一枚指纹都没有 → 没什么可绑的，直接进真录入 */
        if (!self->cand_slots || self->cand_slots->len == 0)
          {
            if (self->enroll_slot < 0)
              {
                fpi_device_enroll_complete (device, NULL,
                  fpi_device_error_new_msg (FP_DEVICE_ERROR_DATA_FULL,
                                            "芯片槽位已满（10 枚），请先删掉一枚"));
                fpi_ssm_mark_completed (ssm);
                break;
              }
            fp_dbg ("enroll: 芯片是空的 → 直接真录入");
            self->enroll_stages = 0;
            self->last_state = -1;
            fpi_ssm_jump_to_state (ssm, E_SEND_PREP);
            break;
          }

        self->enroll_stages = 0;
        self->last_state = -1;

        if (!pa_cand_next (self))
          {
            fpi_device_enroll_complete (device, NULL,
              fpi_device_error_new_msg (FP_DEVICE_ERROR_DATA_INVALID,
                                        "芯片里还没有已录入的指纹"));
            fpi_ssm_mark_completed (ssm);
            break;
          }
        self->poll_count = 0;
        fp_dbg ("enroll: 先试绑定，槽位 %d", self->target_slot);
      }
      fpi_ssm_jump_to_state (ssm, E_SEND_BIND_PREP);
      break;

    /* ↓↓↓ 以下是"真·录入"。2026-09-29 一度关闭（那时不写 a5 记录，会留垃圾槽位），
     *     2026-09-30 实现 a5 写入后重新打开。 */
    case E_SEND_PREP:
      /* 先报一次进度，让 GNOME 有机会弹出"请放手指" */
      fpi_device_get_enroll_data (device, &wanted);
      fpi_device_enroll_progress (device, 0, wanted, NULL);
      { guint8 p = PA_CMD_PREP; pa_do_send (ssm, device, &p, 1); }
      break;

    case E_RECV_PREP:
      pa_do_recv (ssm, device);
      break;

    case E_SEND_START:
      {
        guint8 p[6] = { PA_CMD_ENROLL, 0, 0, 0x0f, 0x00, 0x00 };
        p[1] = (guint8) ((self->enroll_slot >> 8) & 0xff);
        p[2] = (guint8) (self->enroll_slot & 0xff);
        fp_dbg ("enroll: 启动录入 → 槽位 %d", self->enroll_slot);
        pa_do_send (ssm, device, p, 6);
      }
      break;

    case E_RECV_START:
      pa_do_recv (ssm, device);
      break;

    case E_SEND_POLL:
      { guint8 p = PA_CMD_POLL; pa_do_send (ssm, device, &p, 1); }
      break;

    case E_RECV_POLL:
      pa_do_recv (ssm, device);
      break;

    case E_PARSE_POLL:
      st = pa_parse (self->recv_buf, self->recv_len);

      /* 一次采集结束（eb → e0）就记一个阶段，让 GNOME 的进度条动起来 */
      if (st == PA_ST_EN_WAIT && self->last_state == PA_ST_EN_CAP)
        {
          self->enroll_stages++;
          fpi_device_get_enroll_data (device, &wanted);
          fpi_device_enroll_progress (device,
                                      MIN (self->enroll_stages,
                                           PA_ENROLL_STAGES - 1),
                                      wanted, NULL);
          fp_dbg ("enroll: 第 %u 次采集完成", self->enroll_stages);
        }

      if (st != self->last_state)
        {
          const char *hint =
            st == PA_ST_EN_WAIT ? "等手指" :
            st == PA_ST_EN_DOWN ? "手指放下" :
            st == PA_ST_EN_CAP  ? "采集中" :
            st == 0xe6          ? "本次图像被拒（重复/不清晰），请换个位置再按" :
                                  "其它中间状态（继续）";
          fp_dbg ("enroll: 状态 → 0x%02x  %s（已完成 %u 次采集）",
                  st, hint, self->enroll_stages);
          self->last_state = st;
        }

      if (st == PA_ST_EN_DONE)
        {
          /* ★★ 2026-09-30：芯片说录入完成了 —— 但**还不能收工**。
           *   芯片此时只把模板写好了，记录区里还是 `0x33` 占位符；
           *   必须主机发一条 `a5` 把 32 字节 UUID 写进去，芯片才认这枚指纹。
           *   （不写会怎样：① 这枚指纹永远验不过 ② 麒麟的同步会把它删掉。
           *     2026-09-29 实测过：一次 fprintd-enroll 就凭空多出一个用不了的槽位。）
           *   所以这里转去 E_SEND_RECORD，写成功之后才真正 enroll_complete。 */
          fp_dbg ("enroll: 芯片采集完成（槽位 %d，%u 次采集）→ 写记录",
                  self->enroll_slot, self->enroll_stages);
          fpi_ssm_jump_to_state (ssm, E_SEND_RECORD);
        }
      else if (st < 0)
        {
          fpi_device_enroll_complete (device, NULL,
            fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                      "录入中与芯片通信失败"));
          fpi_ssm_mark_completed (ssm);
        }
      else
        {
          /* ★ 除了 e1（完成），其它状态一律**继续轮询**。
           *   芯片会把"这次图像不行，重来"这类中间状态也编码成状态码
           *   （实测见过 0xe6），它们**不是**会话结束。
           *   厂商的 RecvParser_SKF::fpState2COSRet() 也是同样的语义：
           *   状态表里没有的才算成功，表里的都是"继续"。
           *   早先把未知状态当致命错误，结果按了 7 次就被打断。 */
          if (self->cancel_requested || ++self->poll_count >= PA_ENROLL_POLL_MAX)
            {
              fpi_device_enroll_complete (device, NULL,
                fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
                  "录入超时。请把手指反复「按下→抬起」，"
                  "每次稍微挪动一下位置、按稳一点。"));
              fpi_ssm_mark_completed (ssm);
            }
          else
            {
              fpi_ssm_jump_to_state_delayed (ssm, E_SEND_POLL, PA_POLL_DELAY_MS);
            }
        }
      break;

    /* ---- a5：把 32 字节 UUID 记录写进芯片 ----------------------------------
     * 载荷（69 字节，与厂商逐字节一致）：
     *   a5 <地址BE16> <00 40> <00> <槽位LE16> <20> <32字节随机数> <28字节补零>
     * 地址 = 槽位 × 0x40（不是"基址+偏移"—— 那个 0x280 只是开始槽位=10 的巧合）。 */
    case E_SEND_RECORD:
      {
        guint32 slot = (guint32) self->enroll_slot;
        guint32 addr = slot * PA_RECORD_SLOT;
        guint8  buf[5 + 4 + PA_RECORD_DATA + 28];
        gsize   n = 0;
        GDateTime *now;
        guint32 seed;

        memset (buf, 0, sizeof buf);

        buf[n++] = PA_CMD_RECORD;                       /* a5 */
        buf[n++] = (guint8) ((addr >> 8) & 0xff);       /* 地址 高字节 */
        buf[n++] = (guint8) (addr & 0xff);              /* 地址 低字节 */
        buf[n++] = (guint8) ((PA_RECORD_SLOT >> 8) & 0xff);   /* 00 */
        buf[n++] = (guint8) (PA_RECORD_SLOT & 0xff);          /* 40 */

        buf[n++] = 0x00;                                /* rec[0] 固定 0 */
        buf[n++] = (guint8) (slot & 0xff);              /* rec[1..2] 槽位 LE16 */
        buf[n++] = (guint8) ((slot >> 8) & 0xff);
        buf[n++] = PA_RECORD_DATA;                      /* rec[3] = 0x20 */

        /* 32 字节随机数。作用只是"芯片记录 ↔ 主机数据库"之间的 UUID ——
         * 厂商用 srand(time(NULL))+rand()，我们换质量更好的 GLib 随机数即可
         * （芯片只做 32 字节 memcmp，不关心随机源）。 */
        now  = g_date_time_new_now_local ();
        seed = (guint32) g_date_time_to_unix (now);
        g_date_time_unref (now);
        {
          GRand *rnd = g_rand_new_with_seed (seed);
          for (guint i = 0; i < PA_RECORD_DATA; i++)
            buf[n++] = (guint8) g_rand_int_range (rnd, 0, 256);
          g_rand_free (rnd);
        }
        /* ★ 剩下的 28 字节零**也要发出去** —— 厂商的帧是 69 字节，
         *   补零是载荷的一部分（`00 40` = 64 = 4 头 + 32 数据 + 28 补零）。
         *   第一版这里写的是 `pa_do_send(..., n)`，而 n 当时只到 41 —— 补零发不出去，
         *   等于少发 28 字节。自查时发现，特此记下。 */
        n = sizeof buf;

        fp_dbg ("enroll: 写记录 a5 → 槽位 %u（地址 0x%04x），载荷 %zu 字节，UUID %02x%02x%02x%02x…",
                slot, addr, n, buf[9], buf[10], buf[11], buf[12]);
        pa_do_send (ssm, device, buf, (guint) n);
      }
      break;

    case E_RECV_RECORD:
      pa_do_recv (ssm, device);
      break;

    case E_PARSE_RECORD:
      {
        gint r = pa_parse (self->recv_buf, self->recv_len);
        FpPrint *out;

        if (r != 0x00)
          {
            /* 记录没写进去 —— 这枚指纹芯片是认不出的，宁可报错也别留给用户
             * 一个"看起来录好了、其实用不了"的结果。 */
            fp_warn ("enroll: 写记录失败（芯片回 0x%02x）—— 这枚指纹不可用", r);
            fpi_device_enroll_complete (device, NULL,
              fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
                "指纹已采集，但写芯片记录失败，这枚指纹不可用。请重试。"));
            fpi_ssm_mark_completed (ssm);
            break;
          }
        fp_dbg ("enroll: ✅ 记录写入成功，槽位 %d 现在可用了", self->enroll_slot);

        /* ★ 必须在这里重新取一次 enroll data：`wanted` 是 handler 的局部变量，
         *   每进一个状态就重置成 NULL（这个坑 2026-09-29 在绑定分支上踩过，
         *   当时表现为"记录没有用户名 → fprintd 找不到它"）。 */
        fpi_device_get_enroll_data (device, &wanted);
        out = pa_make_slot_print (device, self->enroll_slot,
                                  wanted ? fp_print_get_finger (wanted)
                                         : (FpFinger) FP_FINGER_UNKNOWN);
        if (wanted)
          {
            const gchar *u = fp_print_get_username (wanted);
            const GDate *d = fp_print_get_enroll_date (wanted);

            if (u)
              fp_print_set_username (out, u);
            if (d && g_date_valid (d))
              fp_print_set_enroll_date (out, d);
          }
        fp_dbg ("enroll: ✅ 完成，槽位 %d，共 %u 次采集，用户名 %s",
                self->enroll_slot, self->enroll_stages,
                wanted && fp_print_get_username (wanted)
                  ? fp_print_get_username (wanted) : "(空)");
        fpi_device_enroll_complete (device, out, NULL);
        fpi_ssm_mark_completed (ssm);
      }
      break;

    default:
      g_assert_not_reached ();
    }
}

static void
enroll_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);

  pa_cand_reset (self);          /* 候选列表用完就释放 */

  if (error)
    {
      fp_warn ("录入状态机失败: %s", error->message);
      fpi_device_enroll_complete (device, NULL, error);
    }
}

static void
pixelauth_enroll (FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);

  g_assert_cmpuint (fpi_device_get_current_action (device), ==,
                    FPI_DEVICE_ACTION_ENROLL);

  self->poll_count = 0;
  self->cancel_requested = FALSE;
  self->enroll_slot = -1;
  self->enroll_stages = 0;
  self->last_state = -1;
  pa_cand_reset (self);

  /* ★★ 现在只做「绑定」：先读索引表拿到芯片里已占用的槽位，
   *   再拿着调用者给的手指名，逐个槽位去试哪个匹配 —— 匹配上就把
   *   `手指名 ↔ 该槽位` 这条记录建出来。
   *   真·录入那条路已经关掉（见 E_PARSE_BIND_POLL 超时分支的说明）。 */
  fp_dbg ("enroll: 绑定模式（先读索引表收集已占用槽位）");
  fpi_ssm_start (fpi_ssm_new (device, enroll_ssm_handler, E_NUM_STATES),
                 enroll_ssm_done);
}

/* ==================================================== list 状态机（读索引表） */

enum { L_SEND_LIST, L_RECV_LIST, L_PARSE_LIST, L_NUM_STATES };

/* 槽位 → FpFinger。
 * 芯片槽位从 10 起（厂商 JSON 里的 start_enroll_id=10，实测第一枚就落在 10），
 * 顺序映射到 10 个手指枚举，保证「槽位 ↔ 手指」一一对应、可逆，
 * 这样 M3 的删除操作只要拿回手指就能算出槽位。 */
/* （槽位区间常量已提到文件顶部） */

static FpFinger
pa_slot_to_finger (guint slot)
{
  gint idx = (gint) slot - PA_START_SLOT;

  if (idx < 0 || idx > (FP_FINGER_LAST - FP_FINGER_FIRST))
    return FP_FINGER_UNKNOWN;

  return (FpFinger) (FP_FINGER_FIRST + idx);
}

static void
list_ssm_handler (FpiSsm *ssm, FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  const guint8 *pay = NULL;
  gssize plen;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case L_SEND_LIST:
      { guint8 p = PA_CMD_LIST; pa_do_send (ssm, device, &p, 1); }
      break;

    case L_RECV_LIST:
      pa_do_recv (ssm, device);
      break;

    case L_PARSE_LIST:
      {
        GPtrArray *prints;
        gchar hex[3 * 48 + 1] = { 0 };
        guint count = 0;

        plen = pa_payload (self->recv_buf, self->recv_len, &pay);
        if (plen < 1 + PA_SLOT_BYTES)
          {
            fpi_device_list_complete (device, NULL,
                                      fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO,
                                                                "索引表响应异常（payload %zd 字节）", plen));
            fpi_ssm_mark_completed (ssm);
            break;
          }

        for (gssize i = 0; i < plen && i < 48; i++)
          g_snprintf (hex + i * 2, 3, "%02x", pay[i]);
        fp_dbg ("索引表(%zd 字节): %s", plen, hex);

        /* payload[0] 是状态，payload[1..32] 是 256 位位图：
         * 位 N 置位 = 槽位 N 已录入指纹（每字节 LSB 优先）。 */
        prints = g_ptr_array_new_with_free_func (g_object_unref);
        for (guint i = 1; i <= PA_SLOT_BYTES && (gssize) i < plen; i++)
          {
            for (guint b = 0; b < 8; b++)
              {
                guint slot;
                FpPrint *print;

                if (!(pay[i] & (1 << b)))
                  continue;

                slot   = (i - 1) * 8 + b;
                /* 与 enroll/identify 共用同一个构造函数，
                 * 三处产出的 print 必须一模一样，fp_print_equal 才认得出来。 */
                print  = pa_make_slot_print (device, slot,
                                             pa_slot_to_finger (slot));
                g_ptr_array_add (prints, print);
                count++;
              }
          }

        fp_dbg ("list: 芯片内 %u 枚指纹", count);
        fpi_device_list_complete (device, prints, NULL);
        fpi_ssm_mark_completed (ssm);
      }
      break;

    default:
      g_assert_not_reached ();
    }
}

static void
list_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  /* 成功路径已经在 handler 里 complete 过了，这里只处理失败 */
  if (error)
    {
      fp_warn ("读索引表失败: %s", error->message);
      fpi_device_list_complete (device, NULL, error);
    }
}

/* -------------------------------------------------------------- 回调实现 */

static void
pixelauth_probe (FpDevice *device)
{
  FpDeviceClass *cls = FP_DEVICE_GET_CLASS (device);

  g_assert_cmpuint (fpi_device_get_current_action (device), ==,
                    FPI_DEVICE_ACTION_PROBE);

  fp_dbg ("probe: 按 id_table 匹配到 PT2887-SS");
  fpi_device_probe_complete (device, cls->id, cls->full_name, NULL);
}

static void
pixelauth_open (FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  GError *error = NULL;

  fp_dbg ("open");

  self->usb_dev = fpi_device_get_usb_device (device);
  if (self->usb_dev == NULL)
    {
      fpi_device_open_complete (device,
                                fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
                                                          "拿不到 GUsbDevice"));
      return;
    }

  g_usb_device_open (self->usb_dev, &error);
  if (error)
    {
      /* libfprint/GUsb 可能已经替我们打开了同一个 GUsbDevice 对象，
       * 此时会报 ALREADY_OPEN —— 那不是失败，当成成功继续。 */
      if (g_error_matches (error, G_USB_DEVICE_ERROR, G_USB_DEVICE_ERROR_ALREADY_OPEN))
        {
          fp_dbg ("设备此前已打开（ALREADY_OPEN），继续");
          g_clear_error (&error);
        }
      else
        {
          fpi_device_open_complete (device, error);
          return;
        }
    }

  /* 认领接口 0（设备只有这一个接口） */
  g_usb_device_claim_interface (self->usb_dev, 0, 0, &error);
  if (error)
    {
      if (g_error_matches (error, G_USB_DEVICE_ERROR, G_USB_DEVICE_ERROR_BUSY))
        {
          fp_dbg ("接口已被认领（BUSY），继续");
          g_clear_error (&error);
        }
      else
        {
          fpi_device_open_complete (device, error);
          return;
        }
    }

  self->opened = TRUE;
  fp_dbg ("设备已打开并认领接口 0");
  fpi_device_open_complete (device, NULL);
}

/* ============================================ 中止状态机（收尾 / 关灯）
 *
 * 2026-09-28 抓包查明（capture-abort.sh + probe/pcap_pxat.py）：
 *   麒麟在取消验证时发的是  f2 → f2 → f4 ，
 *   芯片随即从 0xf0（武装）变成 0xf3（空闲），**黄灯熄灭**。
 *   实测：单独发 f4 无效，**必须 f2 打头**；f2 发一次就够。
 *
 * 为什么必须做：芯片停在"武装"状态时黄灯常亮，而且 **USB 复位也清不掉**
 * （只有匹配成功或整机断电才行）。每次验证超时/被取消都会留下这个状态 ——
 * 用户为此困惑了好几次。在 close 时统一收尾，覆盖所有中断路径。
 */
enum { A_SEND_PREP, A_RECV_PREP, A_SEND_ABORT, A_RECV_ABORT, A_NUM_STATES };

static void
abort_ssm_handler (FpiSsm *ssm, FpDevice *device)
{
  switch (fpi_ssm_get_cur_state (ssm))
    {
    case A_SEND_PREP:
      { guint8 p = PA_CMD_PREP; pa_do_send (ssm, device, &p, 1); }
      break;

    case A_RECV_PREP:
      pa_do_recv (ssm, device);
      break;

    case A_SEND_ABORT:
      { guint8 p = PA_CMD_ABORT; pa_do_send (ssm, device, &p, 1); }
      break;

    case A_RECV_ABORT:
      pa_do_recv (ssm, device);
      break;

    default:
      g_assert_not_reached ();
    }
}

static void
abort_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  if (error)
    fp_dbg ("收尾中止没成功（%s）—— 设备可能已经断了，不影响关闭",
            error->message);
  else
    fp_dbg ("收尾中止完成，芯片应已回到空闲（黄灯灭）");

  fpi_device_close_complete (device, NULL);
}

static void
pixelauth_close (FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  GError *error = NULL;

  fp_dbg ("close：发中止收尾，别让芯片停在「武装」状态（否则黄灯常亮）");

  /* ★ 这里**不要**自己去 release_interface / close。
   *   GUsbDevice 是 libfprint 打开的（我们 open 时拿到的是 ALREADY_OPEN/BUSY），
   *   libfprint 在我们的 close 回调之后再统一释放。我们抢先关掉的话，
   *   它那边就会报 "Release failed with error: Device ... has not been opened"。
   *   驱动只管把状态清干净就行。 */
  self->opened = FALSE;

  /* 先发 f2 + f4 把芯片的会话收掉，再完成 close */
  fpi_ssm_start (fpi_ssm_new (device, abort_ssm_handler, A_NUM_STATES),
                 abort_ssm_done);
}

static void
pixelauth_verify (FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  FpPrint *print = NULL;
  gint slot;
  FpiSsm *ssm;

  g_assert_cmpuint (fpi_device_get_current_action (device), ==,
                    FPI_DEVICE_ACTION_VERIFY);

  self->poll_count = 0;
  self->cancel_requested = FALSE;
  self->is_identify = FALSE;
  pa_cand_reset (self);

  /* ★★ 2026-09-29：`33 <字节>` 里的字节是**目标槽位**，必须用被验证那枚的槽位。
   *   以前写死 0x0a（槽位 10）—— 结果驱动**永远只让芯片去比槽位 10**，
   *   槽位 11 上的左手食指不管怎么录都匹配不上。
   *   实测（test-slot-verify.sh，四条结果与预测完全一致）：
   *     左手食指 × 33 0b → 匹配成功 ；左手食指 × 33 0a → 0xf2
   *     右手食指 × 33 0a → 匹配成功 ；右手食指 × 33 0b → 0xf2
   *   槽位就存在 print 的 fpi-data 里（见 pa_make_slot_print）。 */
  fpi_device_get_verify_data (device, &print);
  slot = pa_print_slot (print);
  if (slot >= 0)
    {
      pa_cand_add (self, slot);
      fp_dbg ("verify: 目标槽位 %d（来自 print 的 fpi-data）", slot);
    }
  else
    {
      /* 兜底：print 里没有槽位信息时，仍然从槽位 10 开始试。
       * （正常路径不会走到这里 —— fprintd 存的记录一定带 fpi-data。） */
      pa_cand_add (self, PA_START_SLOT);
      fp_dbg ("verify: print 里没有槽位，兜底用槽位 %d", PA_START_SLOT);
    }

  ssm = fpi_ssm_new (device, verify_ssm_handler, V_NUM_STATES);
  fpi_ssm_start (ssm, verify_ssm_done);
}

static void
pixelauth_identify (FpDevice *device)
{
  /* ★★ 2026-09-29：芯片**不做** 1:N —— `33 <字节>` 里的字节就是目标槽位，
   *   一次只比一个。所谓"1:N"要主机自己循环（麒麟就是循环它的每个索引）。
   *   所以这里把 gallery 里每一枚的槽位收集成候选列表，逐个试。
   *
   *   注意：每换一个槽位要重新 arm，而**重新 arm 会重置手指检测**
   *   （实测 chain 10 11：槽位 10 收到 f2 后，槽位 11 全程 f0，
   *    因为手指一直按着、芯片要的是"新的一次落下"）。
   *   所以循环里每次 f2 之后，用户需要**抬手重按**。 */
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  GPtrArray *gallery = NULL;

  self->poll_count = 0;
  self->cancel_requested = FALSE;
  self->is_identify = TRUE;
  pa_cand_reset (self);

  fpi_device_get_identify_data (device, &gallery);
  if (gallery)
    for (guint i = 0; i < gallery->len; i++)
      pa_cand_add (self, pa_print_slot (g_ptr_array_index (gallery, i)));

  /* 兜底：候选里一个合法槽位都没有 → 扫整个录入区间（10..19）。
   * 正常不会走到（fprintd 传进来的候选都带 fpi-data）。 */
  if (!self->cand_slots)
    for (gint s = PA_START_SLOT; s <= PA_ENROLL_SLOT_MAX; s++)
      pa_cand_add (self, s);

  fp_dbg ("identify: 候选 %u 个槽位", self->cand_slots ? self->cand_slots->len : 0);

  fpi_ssm_start (fpi_ssm_new (device, verify_ssm_handler, V_NUM_STATES),
                 verify_ssm_done);
}

static void
pixelauth_cancel (FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);

  /* ★★ 2026-09-30 起**真打断**（原来是空实现）。
   *   为什么必须做：GNOME 里点"取消"→ fprintd 调 cancel → 这就是唯一的机会。
   *   以前什么都不做，状态机继续跑到自己的超时（最长 29 秒），
   *   期间 fprintd 的 Stop 调用不返回 → GNOME 页面一直转圈、窗口都关不掉。
   *   现在置位标志，各处轮询循环下一次就收尾（约 200 毫秒）。
   *
   *   只置标志、不去动状态机本身，是有意的 ——
   *   从 cancel 回调里直接 mark_failed 会走一条"非正常完成"的路径，
   *   风险比收益大；让状态机自己走到既有的结束分支最稳。 */
  self->cancel_requested = TRUE;
  fp_dbg ("cancel：已请求打断，状态机会在下一次轮询收尾");
}

static void
pixelauth_list (FpDevice *device)
{
  g_assert_cmpuint (fpi_device_get_current_action (device), ==,
                    FPI_DEVICE_ACTION_LIST);

  fp_dbg ("list: 读芯片索引表");
  fpi_ssm_start (fpi_ssm_new (device, list_ssm_handler, L_NUM_STATES),
                 list_ssm_done);
}

/* ============================================================================
 * 删除 —— delete（删一枚）与 clear_storage（清空）
 *
 * 命令：`0c <槽位 BE16> 00 01`，响应 00 = 成功。语义见 PA_CMD_DELETE 处的实测记录。
 *
 * clear_storage 的做法：先读索引表拿到所有已占用槽位，然后**逐个删**。
 *   没有去找"一条命令删光"的写法 —— 循环已知能用的命令，风险最低。
 *   ⚠️ 注意语义：clear_storage 是"清空设备"，会删掉**所有**槽位，
 *      包括别的用户的。fprintd 只在很有限的情况下调它。
 * ==========================================================================*/

enum { D_SEND_DEL, D_RECV_DEL, D_PARSE_DEL, D_NUM_STATES };

static void
pa_send_delete (FpiSsm *ssm, FpDevice *device, FpiDevicePixelauth *self)
{
  guint8 p[5];

  p[0] = PA_CMD_DELETE;
  p[1] = (guint8) ((self->target_slot >> 8) & 0xff);
  p[2] = (guint8) (self->target_slot & 0xff);
  p[3] = 0x00;
  p[4] = 0x01;

  fp_dbg ("delete: 发 0c，目标槽位 %u", self->target_slot);
  pa_do_send (ssm, device, p, 5);
}

static void
delete_ssm_handler (FpiSsm *ssm, FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  int st;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case D_SEND_DEL:
      pa_send_delete (ssm, device, self);
      break;

    case D_RECV_DEL:
      pa_do_recv (ssm, device);
      break;

    case D_PARSE_DEL:
      st = pa_parse (self->recv_buf, self->recv_len);
      if (st == 0x00)
        {
          fp_dbg ("delete: ✅ 槽位 %u 已删除", self->target_slot);
          fpi_device_delete_complete (device, NULL);
        }
      else
        {
          fp_warn ("delete: 芯片拒绝删除槽位 %u（回 0x%02x）", self->target_slot, st);
          fpi_device_delete_complete (device,
            fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
              "芯片拒绝删除槽位 %u（回 0x%02x）", self->target_slot, st));
        }
      fpi_ssm_mark_completed (ssm);
      break;

    default:
      g_assert_not_reached ();
    }
}

static void
delete_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  if (error)
    {
      fp_warn ("删除状态机失败: %s", error->message);
      fpi_device_delete_complete (device, error);
    }
}

static void
pixelauth_delete (FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  FpPrint *print = NULL;
  gint slot;

  g_assert_cmpuint (fpi_device_get_current_action (device), ==,
                    FPI_DEVICE_ACTION_DELETE);

  fpi_device_get_delete_data (device, &print);
  slot = pa_print_slot (print);
  if (slot < PA_START_SLOT || slot > PA_ENROLL_SLOT_MAX)
    {
      fp_warn ("delete: print 里没有有效槽位（fpi-data 缺失或越界）");
      fpi_device_delete_complete (device,
        fpi_device_error_new_msg (FP_DEVICE_ERROR_DATA_INVALID,
          "这枚指纹记录里没有芯片槽位信息，无法定位要删哪一枚"));
      return;
    }

  self->target_slot = (guint) slot;
  fp_dbg ("delete: 槽位 %d", slot);
  fpi_ssm_start (fpi_ssm_new (device, delete_ssm_handler, D_NUM_STATES),
                 delete_ssm_done);
}

/* ---- clear_storage：读索引表 → 逐个删 ---- */
enum { C_SEND_LIST, C_RECV_LIST, C_PARSE_LIST,
       C_SEND_DEL, C_RECV_DEL, C_PARSE_DEL, C_NUM_STATES };

static void
clear_ssm_handler (FpiSsm *ssm, FpDevice *device)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);
  const guint8 *pay = NULL;
  int st;

  switch (fpi_ssm_get_cur_state (ssm))
    {
    case C_SEND_LIST:
      { guint8 p = PA_CMD_LIST; pa_do_send (ssm, device, &p, 1); }
      break;

    case C_RECV_LIST:
      pa_do_recv (ssm, device);
      break;

    case C_PARSE_LIST:
      {
        gssize plen = pa_payload (self->recv_buf, self->recv_len, &pay);

        if (plen < 1 + PA_SLOT_BYTES)
          {
            fpi_device_clear_storage_complete (device,
              fpi_device_error_new_msg (FP_DEVICE_ERROR_PROTO, "索引表响应异常"));
            fpi_ssm_mark_completed (ssm);
            break;
          }

        pa_cand_reset (self);
        for (guint i = 1; i <= PA_SLOT_BYTES && (gssize) i < plen; i++)
          for (guint b = 0; b < 8; b++)
            if (pay[i] & (1 << b))
              pa_cand_add (self, (gint) ((i - 1) * 8 + b));

        fp_dbg ("clear: 芯片里有 %u 个槽位要清",
                self->cand_slots ? self->cand_slots->len : 0);
        fpi_ssm_next_state (ssm);
      }
      break;

    case C_SEND_DEL:
      if (!pa_cand_next (self))
        {
          fp_dbg ("clear: ✅ 全部清完");
          fpi_device_clear_storage_complete (device, NULL);
          fpi_ssm_mark_completed (ssm);
          break;
        }
      pa_send_delete (ssm, device, self);
      break;

    case C_RECV_DEL:
      pa_do_recv (ssm, device);
      break;

    case C_PARSE_DEL:
      st = pa_parse (self->recv_buf, self->recv_len);
      if (st != 0x00)
        {
          /* 一枚失败就停下报错 —— 不要把"清了一半"当成成功 */
          fp_warn ("clear: 删槽位 %u 失败（回 0x%02x），中止", self->target_slot, st);
          fpi_device_clear_storage_complete (device,
            fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL,
              "删除槽位 %u 时芯片报错（回 0x%02x），已中止", self->target_slot, st));
          fpi_ssm_mark_completed (ssm);
          break;
        }
      fp_dbg ("clear: 槽位 %u 已删", self->target_slot);
      fpi_ssm_jump_to_state (ssm, C_SEND_DEL);     /* 回到取下一个 */
      break;

    default:
      g_assert_not_reached ();
    }
}

static void
clear_ssm_done (FpiSsm *ssm, FpDevice *device, GError *error)
{
  FpiDevicePixelauth *self = FPI_DEVICE_PIXELAUTH (device);

  pa_cand_reset (self);
  if (error)
    {
      fp_warn ("清空状态机失败: %s", error->message);
      fpi_device_clear_storage_complete (device, error);
    }
}

static void
pixelauth_clear_storage (FpDevice *device)
{
  g_assert_cmpuint (fpi_device_get_current_action (device), ==,
                    FPI_DEVICE_ACTION_CLEAR_STORAGE);

  fp_dbg ("clear: 清空芯片里的全部指纹");
  fpi_ssm_start (fpi_ssm_new (device, clear_ssm_handler, C_NUM_STATES),
                 clear_ssm_done);
}

/* ------------------------------------------------------------------ 类 */

static const FpIdEntry id_table[] = {
  { .vid = 0x2f0a, .pid = 0x8020 },   /* 品识 PT2887-SS */
  { .vid = 0,      .pid = 0      },
};

static void
fpi_device_pixelauth_class_init (FpiDevicePixelauthClass *klass)
{
  FpDeviceClass *dev_class = FP_DEVICE_CLASS (klass);

  dev_class->id        = "pixelauth_pt2887";
  dev_class->full_name = "PixelAuth PT2887-SS Fingerprint Sensor";

  dev_class->type      = FP_DEVICE_TYPE_USB;
  dev_class->scan_type = FP_SCAN_TYPE_PRESS;
  dev_class->id_table  = id_table;

  /* 实测一次录入约需 14 次有效按压（见上面 enroll 段的注释） */
  dev_class->nr_enroll_stages = PA_ENROLL_STAGES;
  dev_class->temp_hot_seconds = -1;

  dev_class->probe    = pixelauth_probe;
  dev_class->open     = pixelauth_open;
  dev_class->close    = pixelauth_close;
  dev_class->cancel   = pixelauth_cancel;
  dev_class->verify   = pixelauth_verify;
  dev_class->identify = pixelauth_identify;
  dev_class->enroll   = pixelauth_enroll;
  dev_class->list     = pixelauth_list;
  /* ★★ 2026-09-30 新增：删除能力。
   *   加之前，GNOME 设置里点"删除指纹"必然失败（gnome-control-center 会调
   *   DeleteEnrolledFinger → 驱动没有 delete 回调）。
   *   命令语义已在试验品槽位 12 上实测确认，见 PA_CMD_DELETE 处。 */
  dev_class->delete        = pixelauth_delete;
  dev_class->clear_storage = pixelauth_clear_storage;

  fpi_device_class_auto_initialize_features (dev_class);

  /* ★ 关键：必须显式声明「本设备带存储」。
   *   auto_initialize 只根据 verify/identify/capture 推导能力，
   *   不会因为有 list 回调就认为设备有存储。不声明的话，
   *   fp_device_list_prints() 在入口处直接返回
   *   "Device has no storage"，我们的 list 根本不会被调用。 */
  dev_class->features |= FP_DEVICE_FEATURE_STORAGE | FP_DEVICE_FEATURE_STORAGE_LIST;
  /* ★★ 2026-09-30 新增：声明"能删"。
   *   声明了才会被允许调 delete/clear_storage；不声明的话 fprintd 侧直接被挡。 */
  dev_class->features |= FP_DEVICE_FEATURE_STORAGE_DELETE | FP_DEVICE_FEATURE_STORAGE_CLEAR;

  /* ★ 声明"设备原生支持重复检测"。
   *   否则 libfprint 在 enroll 前会用一个**通用**的重复检查：先跑一遍 identify，
   *   只要匹配上就判定重复并中止 enroll。可我们的模板本来就一直在芯片里
   *   （这正是"复用现有指纹"的前提），那个检查必然误判，enroll 永远进不来。
   *   芯片本身是 1:N 匹配、重复模板它自己会拒 —— 声明这个特性既是事实，
   *   也正好让 libfprint 跳过那套通用检查。 */
  dev_class->features |= FP_DEVICE_FEATURE_DUPLICATES_CHECK;
}

static void
fpi_device_pixelauth_init (FpiDevicePixelauth *self)
{
  self->usb_dev = NULL;
  self->opened = FALSE;
  self->recv_len = 0;
  self->poll_count = 0;
}

/* --------------------------------------------------- TOD 驱动唯一导出符号 */
G_MODULE_EXPORT GType
fpi_tod_shared_driver_get_type (void)
{
  return fpi_device_pixelauth_get_type ();
}
