"""底层：termios 读写、pty、探测。只依赖标准库。"""
import fcntl, os, select, termios


def set_nonblock(fd):
    fcntl.fcntl(fd, fcntl.F_SETFL, fcntl.fcntl(fd, fcntl.F_GETFL) | os.O_NONBLOCK)


def read_some(fd, size=4096):
    """只读一次；读到 0 / 出错都返回 b""（调用方只在 n>0 时使用结果）。"""
    try:
        return os.read(fd, size)
    except OSError:
        return b""


def get_termios(fd):
    return termios.tcgetattr(fd)


def set_termios_raw_hidden(fd, tio):
    """关显示 + 关规范模式（规范模式会把没有回车的输入压在内核里不交付）。"""
    t = list(tio)
    t[6] = list(tio[6])
    t[3] &= ~(termios.ECHO | termios.ICANON)
    t[6][termios.VMIN] = b"\x00"
    t[6][termios.VTIME] = b"\x00"
    termios.tcsetattr(fd, termios.TCSANOW, t)


def restore_termios(fd, tio):
    termios.tcsetattr(fd, termios.TCSANOW, tio)
