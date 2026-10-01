#!/usr/bin/python3
# ============================================================================
# 「重新登记该手指」测试 —— D-Bus 部分（由 re-register-test.sh 调用）
#
# 复刻 gnome-control-center 在"重新登记该手指"时发的调用序列：
#     Claim(user) → EnrollStart(<victim>) → （去重检查期间用户按 <press>）…
# 然后等流程自己结束（enroll-duplicate / enroll-failed / 超时后 EnrollStop）。
#
# 用法: re-register-test.py <user> <victim> <press>
# 退出码: 0 = 流程正常跑完（不管业务结果）；2 = 环境问题（认领失败等）
# ============================================================================
import sys

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BUS_NAME = "net.reactivated.Fprint"
DEV_PATH = "/net/reactivated/Fprint/Device/0"
IFC = "net.reactivated.Fprint.Device"
TIMEOUT = 120  # 秒：等用户按手指（去重检查 + 完整录入都算在内）


def main():
    if len(sys.argv) != 4:
        print("用法: re-register-test.py <user> <victim> <press>", file=sys.stderr)
        return 2
    user, victim, press = sys.argv[1:4]

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    dev = bus.get_object(BUS_NAME, DEV_PATH)
    ifc = dbus.Interface(dev, IFC)

    state = {"done": False, "result": None}
    loop = GLib.MainLoop()

    def on_status(result, done):
        result = str(result)
        state["result"] = result
        print(f"    [EnrollStatus] {result}" + ("  ← 完成" if done else ""), flush=True)
        if done:
            state["done"] = True
            loop.quit()
        return False

    bus.add_signal_receiver(on_status, signal_name="EnrollStatus",
                            dbus_interface=IFC, path=DEV_PATH)

    try:
        ifc.Claim(user)
    except dbus.DBusException as e:
        print(f"❌ 认领设备失败：{e.get_dbus_message()}", file=sys.stderr)
        print("   （关掉 GNOME 设置的指纹页再试；或等 30 秒让 fprintd 释放设备）",
              file=sys.stderr)
        return 2

    try:
        print(f"  → EnrollStart({victim})   （= GNOME「重新登记该手指」）", flush=True)
        ifc.EnrollStart(victim)

        print()
        print(f"  ★★★ 现在开始按【{press}】：每 1~2 秒按一下、抬起再按，")
        print(f"      直到看到「流程结束」（最多等 {TIMEOUT} 秒）。")
        print()

        GLib.timeout_add_seconds(TIMEOUT, lambda: (loop.quit(), False)[1])
        loop.run()

        if not state["done"]:
            print("  （等不到完成信号，尝试 EnrollStop 收尾）", flush=True)
            try:
                ifc.EnrollStop()
            except dbus.DBusException:
                pass
        print(f"  → 流程结束：最后状态 = {state['result']}", flush=True)
    except dbus.DBusException as e:
        print(f"❌ EnrollStart 出错：{e.get_dbus_name()} {e.get_dbus_message()}",
              file=sys.stderr)
        return 2
    finally:
        try:
            ifc.Release()
        except dbus.DBusException:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
