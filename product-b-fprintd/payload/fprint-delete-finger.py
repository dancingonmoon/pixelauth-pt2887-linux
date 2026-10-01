#!/usr/bin/python3
# ============================================================================
# 精确删除**一枚**指纹
#
# 为什么需要这个工具（2026-09-30 实测所得）：
#   GNOME 控制中心里"选一枚指纹 → 点删除"**是坏的** —— 第一次点它什么都不做
#   （日志里连 D-Bus 调用都没有，只有一次 ListEnrolledFingers），
#   而**再点一次**就会掉进"删除全部指纹"那条路，把该用户的指纹全删光。
#   实测事故：用户的 3 枚指纹就是这么没的。
#
#   而 fprintd 提供的命令行 `fprintd-delete` **只能删全部**（它对应
#   DeleteEnrolledFingers 这个旧接口），**没法删单枚**。
#
#   所以精确删单枚只能走 D-Bus 的 `DeleteEnrolledFinger` —— 就是这个脚本。
#
# 关键点：Claim 是**跟 D-Bus 连接绑定**的，三步必须走**同一个连接**。
#   用 busctl 分开调会失败（Claim 的连接一关，设备就被释放，
#   随后 Delete 会报"设备正由另一用户使用"）—— 这个坑也踩过。
#
# 用法（安装后位于 /usr/local/bin/，并带一个免后缀的短名）：
#   fprint-delete-finger                  # 列出可选的手指（照着抄名字）
#   fprint-delete-finger <手指名>         # 删这一枚（会先确认）
#   fprint-delete-finger <手指名> --yes   # 不问，直接删
#
#   真身是 /usr/local/bin/fprint-delete-finger.py；fprint-delete-finger 是指向它的链接。
#   **不需要 sudo** —— 走 D-Bus 的 DeleteEnrolledFinger，按你本人的身份授权。
#
# 手指名的写法就是 fprintd 的：right-index-finger、left-thumb、…
# ============================================================================
import sys
import dbus

BUS_NAME = "net.reactivated.Fprint"
DEV_PATH = "/net/reactivated/Fprint/Device/0"
IFC = "net.reactivated.Fprint.Device"


def usage():
    print(__doc__ or "", file=sys.stderr)
    sys.exit(2)


def main():
    argv = [a for a in sys.argv[1:]]
    assume_yes = "--yes" in argv or "-y" in argv
    argv = [a for a in argv if a not in ("--yes", "-y")]
    finger = argv[0] if argv else None

    bus = dbus.SystemBus()
    dev = bus.get_object(BUS_NAME, DEV_PATH)
    props = dbus.Interface(dev, "org.freedesktop.DBus.Properties")
    ifc = dbus.Interface(dev, IFC)

    user = __import__("getpass").getuser()

    # --- 先列出该用户已录入的手指 ---
    try:
        fingers = [str(f) for f in ifc.ListEnrolledFingers(user)]
    except dbus.DBusException as e:
        print(f"列不出来：{e.get_dbus_message()}", file=sys.stderr)
        return 1

    if not fingers:
        print(f"用户 {user} 没有已录入的指纹。")
        return 0

    if finger is None:
        print(f"用户 {user} 名下的指纹（选一个作为参数）：")
        for f in fingers:
            print(f"    {f}")
        print(f"\n用法： {sys.argv[0]} <手指名>")
        return 0

    if finger not in fingers:
        print(f"❌ 没有叫 '{finger}' 的指纹。可选：{', '.join(fingers)}", file=sys.stderr)
        return 1

    # --- 确认（默认要问，避免手滑）---
    if not assume_yes:
        print(f"将删除：{user} 的  {finger}")
        print("（只删这一枚，不会动别的）")
        try:
            ans = input("确认？(yes/no) ").strip()
        except EOFError:
            ans = ""
        if ans != "yes":
            print("已取消。")
            return 0

    # --- Claim → Delete → Release，同一个连接 ---
    try:
        ifc.Claim(user)
    except dbus.DBusException as e:
        print(f"❌ 认领设备失败：{e.get_dbus_message()}", file=sys.stderr)
        print("   （设备可能正被别的程序占用 —— 关掉 GNOME 设置的指纹页再试）", file=sys.stderr)
        return 1

    rc = 0
    try:
        ifc.DeleteEnrolledFinger(finger)
        print(f"✅ 已删除 {finger}")
    except dbus.DBusException as e:
        print(f"❌ 删除失败：{e.get_dbus_name()} {e.get_dbus_message()}", file=sys.stderr)
        rc = 1
    finally:
        try:
            ifc.Release()
        except dbus.DBusException:
            pass
    return rc


if __name__ == "__main__":
    sys.exit(main())
