"""指纹等待：一个前台进程 + 一个读终端的线程，三个出口（按键 / 指纹有结果 / 窗口到点）。

关键约束（2026-10-28 实测于用户的真实 sudo）：指纹程序**必须在前台**运行，输出才会随结束落盘；
之前把它放到后台（subprocess.PIPE/DEFAULT 都试过）时，退出后读到的文件是空的 → 指纹结果被误判成“没认出来”。
所以这里改成：
  · 主线程前台跑指纹（subprocess.run，等它结束）；
  · 另一个线程读终端（关显示、关规范模式），看到回车 / Esc / Ctrl-C 就立刻返回“转密码”，并杀掉指纹；
  · 窗口到点同样返回“转密码”。
"""
import os, signal, subprocess, sys, threading, time

from fpearlypass import basics

MATCH, ENTER, WINDOW = "match", "enter", "window"


class FpWait:
    def __init__(self, tty_fd, fp_cmd, window_s=12.0, cancel_keys=b"\x03\x1b",
                 min_normal_s=5.0, fp_out=None):
        self.fd = tty_fd
        self.fp_cmd = fp_cmd
        self.window_s = window_s
        self.cancel_keys = cancel_keys
        self.min_normal_s = min_normal_s
        self.fp_out = fp_out
        self.cache = bytearray()       # 当前行的字符（不送出）
        self.cancelled = False
        self.reason = None
        self.max_retries = 0          # 不再重开：实测 sudo 会话下，被我们终止的一轮会让设备无法重新武装
        self._retries = 0
        self._stop = threading.Event()
        self._key_event = threading.Event()
        self.proc = None

    # ---- 按键线程 ----
    def _key_reader(self):
        while not self._stop.is_set():
            try:
                r = __import__("select").select([self.fd], [], [], 0.05)[0]
            except (OSError, ValueError):
                return
            if not r:
                continue
            data = basics.read_some(self.fd)
            for ch in data:
                if ch in b"\r\n":
                    self.reason = "enter"; self._key_event.set(); return
                if ch in self.cancel_keys:
                    self.cancelled = True; self.reason = "cancel"; self._key_event.set(); return
                self.cache += bytes([ch])

    # ---- 主流程 ----
    def run(self):
        basics.set_nonblock(self.fd)
        while basics.read_some(self.fd):     # 清残留
            pass
        orig = basics.get_termios(self.fd)
        basics.set_termios_raw_hidden(self.fd, orig)
        t = threading.Thread(target=self._key_reader, daemon=True)
        t.start()
        deadline = time.monotonic() + self.window_s
        try:
            outp = open(self.fp_out, "wb") if self.fp_out else subprocess.DEVNULL
            # 注意：stdin 必须继续是“终端的读端”，否则我们自己的终端句柄会失效
            self.proc = subprocess.Popen(self.fp_cmd, stdout=outp, stderr=subprocess.STDOUT)
            while True:
                if self._key_event.is_set():
                    self._kill_fp()
                    return ENTER
                if self.proc.poll() is not None:          # 指纹结束：稍等，让它把最后几个字节落盘
                    time.sleep(0.1)
                    if self._key_event.is_set():
                        return ENTER
                    verdict = self._fp_verdict()
                    if verdict == "retry":
                        self._kill_fp()
                        self.proc = self._start_fp()
                        continue
                    if verdict is not None:
                        return verdict
                    # 指纹不可用：不再反复起进程，安静等到窗口或按键
                    while not self._key_event.is_set() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    if self._key_event.is_set():
                        return ENTER
                    self.reason = "window"
                    return WINDOW
                if time.monotonic() >= deadline:
                    self._kill_fp()
                    self.reason = "window"
                    return WINDOW
                time.sleep(0.02)
        finally:
            self._stop.set()
            self._kill_fp()
            try:
                basics.restore_termios(self.fd, orig)
            except OSError:
                pass

    def _start_fp(self):
        outp = open(self.fp_out, "wb") if self.fp_out else subprocess.DEVNULL
        return subprocess.Popen(self.fp_cmd, stdout=outp, stderr=subprocess.STDOUT)

    def _kill_fp(self):
        try:
            if self.proc and self.proc.poll() is None:
                self.proc.kill()
        except OSError:
            pass

    def _fp_verdict(self):
        try:
            text = open(self.fp_out, "rb").read().decode("utf-8", "replace") if self.fp_out else ""
        except OSError:
            text = ""
        if "verify-match" in text:
            try:
                with open("/tmp/fp-early-trace.log", "a") as f:
                    import time as _t
                    f.write("%s verdict=match\n" % _t.strftime("%F %T"))
            except OSError:
                pass
            self.reason = "fingerprint"; return MATCH
        if "verify-no-match" in text:
            busy = ("failed to claim device" in text) or ("AlreadyInUse" in text)
            # 调试：把结论与耗时记下来（不含任何用户输入）
            try:
                with open("/tmp/fp-early-trace.log", "a") as f:
                    import time as _t
                    f.write("%s verdict=nomatch busy=%s retries=%d\n"
                            % (_t.strftime("%F %T"), busy, self._retries))
            except OSError:
                pass
            if self.max_retries > 0 and self._retries < self.max_retries and not busy and "Verify started" in text:
                # 按错了就**马上重新开始一轮验证**（不必等到窗口结束）：驱动的每一轮都是“等一次按下”，
                # 用户换对的手指再按一下就能过。
                self._retries += 1
                self.reason = "retry"
                return "retry"
            if busy:
                self.reason = "fingerprint-busy"
                return None          # 设备忙：结论不可信，继续等按键/窗口
            self.reason = "fingerprint-failed"; return ENTER
        # 既没匹配也没“不匹配”结论（设备忙 / 上一轮没结束块）→ 视为不可用，继续等按键或窗口
        self.reason = "fingerprint-error"
        return None
