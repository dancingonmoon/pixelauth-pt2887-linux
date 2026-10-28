#!/usr/bin/python3
"""助手入口（用户阶段）：由助手脚本以调用用户身份启动。

用法：run.py <tty> <窗口秒> <指纹命令...>
输出（stdout，供 shell 判断）：
  RESULT=match          指纹通过 → 助手退出码 0
  RESULT=enter / window / cancel   转入密码验证 → 助手退出码 1
提示语写终端（tty）。
"""
import os, sys

_here = os.path.dirname(os.path.abspath(__file__))          # .../fpearlypass
sys.path.insert(0, os.path.dirname(_here))                    # 其父目录（安装后 = /usr/local/lib/fp-earlypass）
from fpearlypass.session import FpWait, MATCH


def main():
    tty, window_s = sys.argv[1], float(sys.argv[2])
    fp_cmd = sys.argv[3:]
    fp_out = "/tmp/.fp-early-%d.out" % os.getpid()
    fd = os.open(tty, os.O_RDWR | os.O_NOCTTY)
    os.write(fd, "\n  请触摸电源键上的指纹传感器\n  如需改用密码，请按 Esc 或回车\n\n".encode())
    w = FpWait(fd, fp_cmd, window_s=window_s, fp_out=fp_out)

    def _trace(msg):
        with open("/tmp/fp-early-trace.log", "a") as f:
            import time as _t
            f.write("%s %s\n" % (_t.strftime("%F %T"), msg))
    # 每轮结束都记一行（只记原因与重试数，不记用户输入）
    _orig_verdict = w._fp_verdict
    def _v():
        r = _orig_verdict()
        _trace("轮次结论=%r retries=%d" % (r, w._retries))
        return r
    w._fp_verdict = _v
    try:
        result = w.run()
    finally:
        pass
    if result == MATCH:
        print("RESULT=match", flush=True)
        return 0
    msg = {"enter": "\n  已转入密码验证\n",
           "cancel": "\n  已转入密码验证\n",
           "window": "\n  指纹未通过，请改用密码\n"}.get(w.reason, "\n  指纹未通过，请改用密码\n")
    try:
        os.write(fd, msg.encode())
    except OSError:
        pass
    print("RESULT=%s" % w.reason, flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
