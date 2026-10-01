/* ============================================================================
 * pa_probe —— PXAT 协议独立探针（不依赖 fprintd / libfprint）
 *
 * 用途：直接和品识 PT2887-SS (2f0a:8020) 对话，验证帧格式与命令语义，
 *       快速迭代，无需重编 TOD 驱动。
 *
 * 编译：gcc -O2 -o pa_probe pa_probe.c $(pkg-config --cflags --libs libusb-1.0)
 * 用法：sudo ./pa_probe [a1|1f|a6|verify|all]
 * ==========================================================================*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>

#define VID 0x2f0a
#define PID 0x8020
#define EP_OUT 0x02
#define EP_IN  0x81
#define HDR    15
#define MAXF   256

#define CMD_SYSPARA 0xa1
#define CMD_LIST    0x1f
#define CMD_RECORD  0xa6
#define CMD_PREP    0xf2
#define CMD_VERIFY  0x33
#define CMD_POLL    0xf1

/* CRC-16/KERMIT */
static uint16_t crc16(const uint8_t *d, size_t n)
{
  uint16_t crc = 0;
  for (size_t i = 0; i < n; i++) {
    uint8_t b = d[i], r = 0;
    for (int k = 0; k < 8; k++) r |= ((b >> k) & 1) << (7 - k);
    crc ^= (uint16_t)r << 8;
    for (int k = 0; k < 8; k++)
      crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
  }
  uint16_t out = 0;
  for (int k = 0; k < 16; k++) out |= ((crc >> k) & 1) << (15 - k);
  return out;
}

static size_t build(uint8_t *buf, const uint8_t *payload, size_t plen)
{
  static const uint8_t pfx[7] = { 0xef, 0x01, 0xff, 0xff, 0x00, 0x00, 0x00 };
  /* inner_len 覆盖 [7] 之后的全部字节：7字节前缀 + 1字节长度 + payload + 2字节CRC */
  uint16_t inner = (uint16_t)(7 + 1 + plen + 2), crc;
  buf[0]='P'; buf[1]='X'; buf[2]='A'; buf[3]='T'; buf[4]=0xc0;
  buf[5]=(inner>>8)&0xff; buf[6]=inner&0xff;
  memcpy(buf+7, pfx, 7);
  buf[14]=(uint8_t)plen;
  if (plen) memcpy(buf+15, payload, plen);
  crc = crc16(payload, plen);
  buf[15+plen]=(crc>>8)&0xff; buf[15+plen+1]=crc&0xff;
  return HDR + plen + 2;
}

static void hexdump(const char *tag, const uint8_t *b, size_t n)
{
  printf("  %-14s(%3zu) ", tag, n);
  for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
  printf("\n");
}

/* 返回 payload 长度；-1 = 帧不合法 */
static int parse(const uint8_t *b, size_t n, const uint8_t **pay)
{
  if (n < HDR + 2) { printf("  !! 帧太短 %zu\n", n); return -1; }
  if (memcmp(b, "PXAT", 4) || b[4] != 0xc0) { printf("  !! 头部不对\n"); return -1; }
  size_t plen = b[14];
  if (HDR + plen + 2 != n) {
    printf("  !! 长度不符: [14]=%zu 实际帧长%zu 应为%zu\n", plen, n, HDR + plen + 2);
    return -1;
  }
  uint16_t want = ((uint16_t)b[15+plen] << 8) | b[15+plen+1];
  uint16_t got  = crc16(b + 15, plen);
  if (want != got) { printf("  !! CRC 不符 期望%04x 实算%04x\n", want, got); return -1; }
  *pay = b + 15;
  return (int)plen;
}

static libusb_device_handle *h;
static int xfer(const uint8_t *payload, size_t plen, const char *what, uint8_t *out, int *outlen)
{
  uint8_t frame[MAXF];
  size_t flen = build(frame, payload, plen);
  int n = 0, r;

  hexdump(what, payload, plen);
  r = libusb_bulk_transfer(h, EP_OUT, frame, (int)flen, &n, 2000);
  if (r) { printf("  !! 发送失败 %d (%s)\n", r, libusb_error_name(r)); return -1; }

  r = libusb_bulk_transfer(h, EP_IN, out, MAXF, &n, 3000);
  if (r) { printf("  !! 接收失败 %d (%s)\n", r, libusb_error_name(r)); return -1; }
  *outlen = n;
  hexdump("<- 原始帧", out, n);

  const uint8_t *pay;
  int pl = parse(out, n, &pay);
  if (pl >= 0) hexdump("   payload", pay, pl);
  return pl;
}

int main(int argc, char **argv)
{
  const char *mode = argc > 1 ? argv[1] : "all";
  uint8_t in[MAXF];
  int n, pl;

  int r = libusb_init(NULL);
  if (r) { fprintf(stderr, "libusb_init: %d\n", r); return 1; }

  h = libusb_open_device_with_vid_pid(NULL, VID, PID);
  if (!h) { fprintf(stderr, "打不开设备 %04x:%04x（被占用？需要 sudo）\n", VID, PID); return 1; }

  if (!strcmp (mode, "reset"))
    {
      printf ("== 复位设备 ==\n");
      r = libusb_reset_device (h);
      printf ("libusb_reset_device -> %d (%s)\n", r, libusb_error_name (r));
      /* 复位后等设备重新枚举 */
      usleep (1500000);
      r = libusb_reset_device (h);
      printf ("再复位一次 -> %d (%s)\n", r, libusb_error_name (r));
      libusb_close (h);
      libusb_exit (NULL);
      return 0;
    }

  if (libusb_kernel_driver_active(h, 0) == 1) libusb_detach_kernel_driver(h, 0);

  r = libusb_claim_interface(h, 0);
  if (r) { fprintf(stderr, "claim_interface: %d (%s)\n", r, libusb_error_name(r)); return 1; }

  printf("== 设备已打开 ==\n");

  if (!strcmp(mode, "a1") || !strcmp(mode, "all")) {
    uint8_t p = CMD_SYSPARA;
    printf("[a1 设备信息]\n");
    pl = xfer(&p, 1, "-> a1", in, &n);
    if (pl > 0) {
      printf("   状态=0x%02x\n", in[15]);
    }
  }

  if (!strcmp(mode, "1f") || !strcmp(mode, "all")) {
    uint8_t p = CMD_LIST;
    printf("\n[1f 读索引表]\n");
    pl = xfer(&p, 1, "-> 1f", in, &n);
    if (pl > 0) {
      const uint8_t *pay = in + 15;
      printf("   状态=0x%02x  表区长度=%d\n", pay[0], pl - 1);
      /* 逐位解出被占用的槽位（每个字节 LSB 优先） */
      printf("   占用槽位:");
      int cnt = 0;
      for (int i = 1; i < pl; i++)
        for (int b = 0; b < 8; b++)
          if (pay[i] & (1 << b)) { printf(" %d", (i - 1) * 8 + b); cnt++; }
      if (!cnt) printf(" (无)");
      printf("   共 %d 个\n", cnt);
    }
  }

  /* seq <op1> <op2> ...：先武装，再按顺序发这些命令，最后轮询看是否解除了"等手指"。
   * 用来验证抓包里麒麟驱动的开场初始化序列（a1 b1 a9 a1 b1 a1 b7 a7 fc）能否清状态。 */
  if (!strcmp (mode, "seq") && argc > 2)
    {
      uint8_t p, q, p2[2] = { CMD_VERIFY, 0x0a };

      printf ("[武装] ");
      p = CMD_PREP; xfer (&p, 1, "-> f2", in, &n);
      xfer (p2, 2, "-> 33 0a", in, &n);
      usleep (300000);
      q = CMD_POLL; pl = xfer (&q, 1, "-> f1", in, &n);
      printf ("    武装后: 0x%02x %s\n", pl > 0 ? in[15] : -1,
              (pl > 0 && in[15] == 0xf0) ? "(在等手指 ✓)" : "(没在等？)");

      for (int i = 2; i < argc; i++)
        {
          uint8_t op = (uint8_t) strtol (argv[i], NULL, 16);
          q = op; xfer (&q, 1, "-> ?", in, &n);
          usleep (150000);
        }

      for (int i = 0; i < 3; i++)
        {
          q = CMD_POLL; pl = xfer (&q, 1, "-> f1", in, &n);
          printf ("    之后轮询 #%d: 0x%02x%s\n", i + 1, pl > 0 ? in[15] : -1,
                  (pl > 0 && in[15] == 0xf0) ? "  (还在等手指)" : "  ★ 解除了!");
          usleep (200000);
        }
    }

  /* abort <hex>：先武装（f2 + 33 0a），确认在等手指，再发候选"中止"命令，
   * 看轮询是否不再回 f0 —— 用来找出中止命令的操作码。 */
  if (!strcmp(mode, "abort") && argc > 2)
    {
      uint8_t op = (uint8_t) strtol (argv[2], NULL, 16);
      uint8_t p, q, p2[2] = { CMD_VERIFY, 0x0a };

      printf ("[武装] ");
      p = CMD_PREP; xfer (&p, 1, "-> f2", in, &n);
      xfer (p2, 2, "-> 33 0a", in, &n);
      usleep (300000);

      q = CMD_POLL; pl = xfer (&q, 1, "-> f1", in, &n);
      printf ("    武装后轮询: 0x%02x%s\n", pl > 0 ? in[15] : -1,
              (pl > 0 && in[15] == 0xf0) ? "  (在等手指 ✓)" : "  (没在等？)");

      printf ("[发候选中止命令 0x%02x]\n", op);
      q = op; xfer (&q, 1, "-> ?", in, &n);
      usleep (300000);

      for (int i = 0; i < 3; i++)
        {
          q = CMD_POLL; pl = xfer (&q, 1, "-> f1", in, &n);
          printf ("    之后轮询 #%d: 0x%02x%s\n", i + 1, pl > 0 ? in[15] : -1,
                  (pl > 0 && in[15] == 0xf0) ? "  (还在等手指)" : "  ★ 不再是等手指");
          usleep (200000);
        }
    }

  /* poll [n]：只发 f1 轮询，不武装。用来看芯片当前是不是"在等手指"。
   * 刚复位完应该是别的状态；如果一直是 f0，说明有别的东西在武装它。 */
  if (!strcmp(mode, "poll"))
    {
      int times = argc > 2 ? atoi (argv[2]) : 3;
      for (int i = 0; i < times; i++)
        {
          uint8_t q = CMD_POLL;
          pl = xfer (&q, 1, "-> f1", in, &n);
          const char *s = "?";
          if (pl > 0 && in[15] == 0xf0) s = "在等手指（已武装）";
          else if (pl > 0 && in[15] == 0xf1) s = "匹配成功";
          else if (pl > 0 && in[15] == 0x00) s = "空闲/未武装";
          printf ("    #%d 状态=0x%02x  %s\n", i + 1, pl > 0 ? in[15] : -1, s);
          usleep (300000);
        }
    }

  /* enroll <槽位dec> [轮询次数]：按抓包里麒麟的序列试启录入，看芯片回什么。
   * 抓到的序列：f2 → 31 <槽位BE16> 0f 00 00 → f1 轮询 → a6 02 c0 00 40 → a5 ...
   * ★ 不会真录进去（不按手指就不会有模板），只是探响应格式。 */
  if (!strcmp(mode, "enroll") && argc > 2)
    {
      uint16_t slot = (uint16_t) atoi (argv[2]);
      int times = argc > 3 ? atoi (argv[3]) : 8;
      uint8_t p, q;
      uint8_t start[6] = { 0x31, 0, 0, 0x0f, 0x00, 0x00 };

      start[1] = (slot >> 8) & 0xff;
      start[2] = slot & 0xff;

      printf ("[f2 准备]\n");
      p = CMD_PREP; xfer (&p, 1, "-> f2", in, &n);

      printf ("[31 启动录入 → 槽位 %u]\n", slot);
      xfer (start, 6, "-> 31", in, &n);

      printf ("[f1 轮询]\n");
      for (int i = 0; i < times; i++) {
        uint8_t pl2;
        q = CMD_POLL;
        pl2 = (uint8_t) xfer (&q, 1, "-> f1", in, &n);
        if (pl2 > 0) {
          const uint8_t *pay = in + 15;
          printf ("    #%-2d 状态=0x%02x  整段=%s\n", i + 1, pay[0], "");
          printf ("         payload(%d): ", pl2);
          for (int k = 0; k < pl2; k++) printf ("%02x ", pay[k]);
          printf ("\n");
        }
        usleep (400000);
      }
    }

  /* enrollwatch <槽位> [轮询次数]：跑一次完整录入，只打印状态「变化」。
   * 目的：找出录入完成时芯片回哪个状态码。 */
  if (!strcmp(mode, "enrollwatch") && argc > 2)
    {
      uint16_t slot = (uint16_t) atoi (argv[2]);
      int times = argc > 3 ? atoi (argv[3]) : 800;
      uint8_t p, q;
      uint8_t start[6] = { 0x31, 0, 0, 0x0f, 0x00, 0x00 };
      int prev = -1, stage = 0;

      start[1] = (slot >> 8) & 0xff;
      start[2] = slot & 0xff;

      printf ("== 录入槽位 %u，最多 %d 次轮询 ==\n", slot, times);
      p = CMD_PREP;
      pl = xfer (&p, 1, "-> f2", in, &n);
      printf ("   f2 -> %s\n", pl > 0 ? "ok" : "失败");
      pl = xfer (start, 6, "-> 31 启动录入", in, &n);
      printf ("   31 -> 0x%02x %s\n\n", pl > 0 ? in[15] : -1,
              (pl > 0 && in[15] == 0x00) ? "(接受 ✓)" : "(!!)");

      printf ("   轮询中，请反复「按下 → 抬起」手指...\n\n");
      fflush (stdout);

      for (int i = 0; i < times; i++)
        {
          int st;
          q = CMD_POLL;
          pl = xfer (&q, 1, "-> f1", in, &n);
          st = (pl > 0) ? in[15] : -1;

          if (st != prev)
            {
              const char *mean =
                st == 0xe0 ? "等手指" :
                st == 0xe4 ? "手指放下" :
                st == 0xeb ? "采集中" :
                st < 0     ? "无响应" : "★ 新状态（可能是完成或错误！）";
              if (st == 0xe4 && prev == 0xe0) stage++;
              printf ("   [%4d] 0x%02x  %-28s  (第 %d 次采集)\n", i, st, mean, stage);
              fflush (stdout);
              prev = st;

              /* 出现任何非 e0/e4/eb 的状态，就是我们要找的答案，立刻停下 */
              if (st >= 0 && st != 0xe0 && st != 0xe4 && st != 0xeb)
                {
                  printf ("\n   ★★★ 出现新状态 0x%02x，停止观察 ★★★\n", st);
                  printf ("       payload: ");
                  for (int k = 0; k < pl; k++) printf ("%02x ", in[15 + k]);
                  printf ("\n");
                  break;
                }
            }
          usleep (300000);
        }

      printf ("\n== 结束时索引表 ==\n");
      q = CMD_LIST;
      pl = xfer (&q, 1, "-> 1f", in, &n);
      if (pl > 0)
        {
          const uint8_t *pay = in + 15;
          printf ("   占用槽位:");
          for (int i = 1; i < pl; i++)
            for (int b = 0; b < 8; b++)
              if (pay[i] & (1 << b)) printf (" %d", (i - 1) * 8 + b);
          printf ("\n");
        }
    }

  /* ★★ raw <十六进制字节...>：发一条**任意载荷**的命令，然后读一次响应。
   *
   *   为什么需要它：`seq` / `abort` 只能发**单字节**命令，而芯片的删除命令 `0c`
   *   是 5 字节载荷（`0c <槽位BE16> <??BE16>`），那两种模式根本发不出去。
   *
   *   用法： ./pa_probe raw 0c 00 13 00 01
   *
   *   ⚠️ 这是**万能写入通道** —— 参数给错就可能破坏芯片数据。
   *      探测写类命令时务必：① 先连读 3 次索引表确认目标槽位
   *      ② 只拿无关紧要的槽位试（本项目的规矩：绝不拿用户正在用的指纹做试验）。 */
  if (!strcmp(mode, "raw") && argc > 2) {
    uint8_t p[64];
    int len = 0;
    for (int i = 2; i < argc && len < (int) sizeof p; i++) {
      char *e;
      long v = strtol (argv[i], &e, 16);
      if (e == argv[i]) { fprintf(stderr, "参数不是十六进制: %s\n", argv[i]); return 1; }
      p[len++] = (uint8_t) v;
    }
    printf("\n[raw 发送 %d 字节] ", len);
    for (int i = 0; i < len; i++) printf("%02x ", p[i]);
    printf("\n");
    pl = xfer(p, (size_t) len, "-> raw", in, &n);
    if (pl > 0) {
      printf("    <<< 响应 payload (%d 字节): ", pl);
      for (int i = 0; i < pl && i < 24; i++) printf("%02x ", in[15 + i]);
      printf("\n    <<< 第一个字节 = 0x%02x %s\n",
             in[15], in[15] == 0x00 ? "(成功)" : "(非 0)");
    } else {
      printf("    <<< 没有响应（或读失败）\n");
    }
  }

  /* a6 [b1 b2 b3 b4]：读记录。默认 02 80 00 40（抓包里麒麟用的那种）。
   * 用不同参数试探，找出"怎么读指定槽位的记录"。 */
  if (!strcmp(mode, "a6")) {
    uint8_t p[5] = { CMD_RECORD, 0x02, 0x80, 0x00, 0x40 };
    if (argc > 2) p[1] = (uint8_t) strtol (argv[2], NULL, 16);
    if (argc > 3) p[2] = (uint8_t) strtol (argv[3], NULL, 16);
    if (argc > 4) p[3] = (uint8_t) strtol (argv[4], NULL, 16);
    if (argc > 5) p[4] = (uint8_t) strtol (argv[5], NULL, 16);
    printf("\n[a6 %02x %02x %02x %02x 读记录]\n", p[1], p[2], p[3], p[4]);
    pl = xfer(p, 5, "-> a6", in, &n);
    if (pl > 0) {
      const uint8_t *pay = in + 15;
      printf("    解析: 字段=[%02x %02x] 槽位=%u 长度=%u  数据前8字节=", pay[0], pay[1],
             (pay[2] << 8) | pay[3], (pay[4] << 8) | pay[5]);
      for (int k = 6; k < pl && k < 14; k++) printf("%02x", pay[k]);
      printf("\n");
    }
  }

  /* chain <槽位1> <槽位2> ...：依次 arm 每个槽位并轮询。
   * ★ 手指**一直按着不用抬** —— 用来回答一个决定设计的问题：
   *   每个新的 `33 <槽位>` 会不会让芯片重新检测到（仍按着的）手指？
   *   会 → 驱动的 identify/绑定可以"一次按住、自动走遍各槽位"；
   *   不会 → 只能每换一个槽位就要用户重按一次（UX 差一截）。 */
  if (!strcmp(mode, "chain") && argc > 2) {
    for (int a = 2; a < argc; a++) {
      uint8_t slot = (uint8_t) strtol(argv[a], NULL, 0);
      uint8_t p = CMD_PREP, p2[2] = { CMD_VERIFY, slot };

      printf("\n=== 目标槽位 %d ===\n", slot);
      xfer(&p, 1, "-> f2", in, &n);
      xfer(p2, 2, "-> 33", in, &n);
      for (int i = 0; i < 30; i++) {
        uint8_t q = CMD_POLL;
        pl = xfer(&q, 1, "-> f1", in, &n);
        /* f1 <槽位 BE16> <分数 BE16> —— 分数能区分"强匹配"和"勉强匹配"，
       * 判断误匹配风险时很有用。 */
      if (pl > 0 && in[15] == 0xf1) {
        if (pl >= 5)
          printf("   >>> 匹配成功!  槽位=%u  分数=%u\n",
                 ((unsigned) in[16] << 8) | in[17],
                 ((unsigned) in[18] << 8) | in[19]);
        else
          printf("   >>> 匹配成功!（响应只有 %d 字节，读不到分数）\n", pl);
        break;
      }
        if (pl > 0 && in[15] == 0xf2) { printf("   >>> 0xf2 不匹配\n"); break; }
        usleep(200000);
      }
    }
    printf("\n[收尾：f2 + f4 解除武装]\n");
    { uint8_t p3 = CMD_PREP; xfer(&p3, 1, "-> f2", in, &n); }
    { uint8_t ab = 0xf4; xfer(&ab, 1, "-> f4", in, &n); }
  }

  if (!strcmp(mode, "verify") || !strcmp(mode, "all")) {
    uint8_t p;
    /* ★★ 2026-09-29：`33` 的第二个字节是**目标槽位**，不是固定值！
     *   麒麟验「索引 N」就发 `33 (start_enroll_id + N)`：
     *     · 09-27 抓到的 `33 0a` 是它在验索引 0（= 槽位 10）
     *     · 用麒麟验索引 1 能匹配上槽位 11，而我们的驱动（写死 33 0a）匹配不上
     *   用法：`pa_probe verify [槽位]`，不给参数时仍旧是 10。 */
    uint8_t slot = 0x0a;
    if (!strcmp(mode, "verify") && argc > 2)
      slot = (uint8_t) strtol (argv[2], NULL, 0);
    uint8_t p2[2] = { CMD_VERIFY, slot };

    printf("\n[f2 验证准备]\n");
    p = CMD_PREP; xfer(&p, 1, "-> f2", in, &n);

    printf("\n[33 %02x 启动验证（目标槽位 %d）]\n", slot, slot);
    xfer(p2, 2, "-> 33", in, &n);

    printf("\n[f1 轮询（请把手指按在传感器上）]\n");
    for (int i = 0; i < 100; i++) {
      uint8_t q = CMD_POLL;
      pl = xfer(&q, 1, "-> f1", in, &n);
      /* f1 <槽位 BE16> <分数 BE16> —— 分数能区分"强匹配"和"勉强匹配"，
       * 判断误匹配风险时很有用。 */
      if (pl > 0 && in[15] == 0xf1) {
        if (pl >= 5)
          printf("   >>> 匹配成功!  槽位=%u  分数=%u\n",
                 ((unsigned) in[16] << 8) | in[17],
                 ((unsigned) in[18] << 8) | in[19]);
        else
          printf("   >>> 匹配成功!（响应只有 %d 字节，读不到分数）\n", pl);
        break;
      }
      if (pl > 0 && in[15] == 0xf2) { printf("   >>> 0xf2 = 按下了但匹配不上（立即返回）\n"); break; }
      if (pl > 0 && in[15] != 0xf0) { printf("   >>> 状态 0x%02x，停止\n", in[15]); break; }
      usleep(200000);
    }

    /* ★★ 收尾必须自己解除武装 —— 2026-09-29 踩过：verify 跑完不管，
     *    芯片一直停在 f0（黄灯常亮），用户跑来问"黄灯为啥一直亮"。
     *    f4 单发无效，必须先 f2。 */
    printf("\n[收尾：f2 + f4 解除武装]\n");
    p = CMD_PREP; xfer(&p, 1, "-> f2", in, &n);
    { uint8_t ab = 0xf4; xfer(&ab, 1, "-> f4", in, &n); }
  }

  libusb_release_interface(h, 0);
  libusb_close(h);
  libusb_exit(NULL);
  return 0;
}
