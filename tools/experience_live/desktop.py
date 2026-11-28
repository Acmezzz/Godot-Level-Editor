"""Windows desktop input and unscaled client-area capture for the test windows."""
import ctypes
import sys
import time

from PIL import ImageGrab
import win32con
import win32gui
import win32process


def window(pid):
    matches = []

    def add(hwnd, _):
        if win32gui.IsWindowVisible(hwnd) and win32process.GetWindowThreadProcessId(hwnd)[1] == pid:
            a, b, c, d = win32gui.GetClientRect(hwnd)
            if c * d > 0 or win32gui.IsIconic(hwnd):
                matches.append((c * d, hwnd))

    win32gui.EnumWindows(add, None)
    return max(matches)[1]


def foreground(hwnd):
    if win32gui.IsIconic(hwnd):
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    win32gui.SetWindowPos(hwnd, win32con.HWND_TOPMOST, 0, 0, 0, 0, win32con.SWP_NOMOVE | win32con.SWP_NOSIZE)
    if win32gui.GetForegroundWindow() != hwnd:
        ctypes.windll.user32.keybd_event(win32con.VK_MENU, 0, 0, 0)
        ctypes.windll.user32.keybd_event(win32con.VK_MENU, 0, win32con.KEYEVENTF_KEYUP, 0)
        win32gui.SetForegroundWindow(hwnd)
    time.sleep(0.2)


def main():
    ctypes.windll.user32.SetProcessDPIAware()
    action, pid, *args = sys.argv[1:]
    hwnd = window(int(pid))
    foreground(hwnd)
    user = ctypes.windll.user32
    if action == 'key':
        keys = {'ENTER': win32con.VK_RETURN, 'ESC': win32con.VK_ESCAPE, 'TAB': win32con.VK_TAB,
                'F6': win32con.VK_F6, 'F5': win32con.VK_F5, 'SPACE': win32con.VK_SPACE}
        names = {'CTRL': win32con.VK_CONTROL, 'SHIFT': win32con.VK_SHIFT, 'ALT': win32con.VK_MENU, **keys}
        codes = [names[k] if k in names else ord(k) for k in args[0].split('+')]
        for code in codes:
            user.keybd_event(code, user.MapVirtualKeyW(code, 0), 0, 0)
        time.sleep(0.08)
        for code in reversed(codes):
            user.keybd_event(code, user.MapVirtualKeyW(code, 0), win32con.KEYEVENTF_KEYUP, 0)
    elif action == 'drag':
        x1, y1, x2, y2 = map(int, args)
        user.SetCursorPos(*win32gui.ClientToScreen(hwnd, (x1, y1)))
        time.sleep(0.08)
        user.mouse_event(win32con.MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
        for i in range(1, 11):
            p = (round(x1 + (x2 - x1) * i / 10), round(y1 + (y2 - y1) * i / 10))
            user.SetCursorPos(*win32gui.ClientToScreen(hwnd, p))
            time.sleep(0.02)
        user.mouse_event(win32con.MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    elif action in ['click', 'double', 'move']:
        user.SetCursorPos(*win32gui.ClientToScreen(hwnd, tuple(map(int, args))))
        time.sleep(0.06)
        for _ in range({'move': 0, 'click': 1, 'double': 2}[action]):
            user.mouse_event(win32con.MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
            time.sleep(0.04)
            user.mouse_event(win32con.MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
            time.sleep(0.06)
    elif action == 'type':
        import win32clipboard
        win32clipboard.OpenClipboard()
        win32clipboard.EmptyClipboard()
        win32clipboard.SetClipboardText(args[0], win32con.CF_UNICODETEXT)
        win32clipboard.CloseClipboard()
        user.keybd_event(win32con.VK_CONTROL, 0, 0, 0)
        user.keybd_event(ord('V'), 0, 0, 0)
        user.keybd_event(ord('V'), 0, win32con.KEYEVENTF_KEYUP, 0)
        user.keybd_event(win32con.VK_CONTROL, 0, win32con.KEYEVENTF_KEYUP, 0)
    elif action == 'scroll':
        x, y, delta = map(int, args)
        user.SetCursorPos(*win32gui.ClientToScreen(hwnd, (x, y)))
        user.mouse_event(win32con.MOUSEEVENTF_WHEEL, 0, 0, delta, 0)
    elif action == 'shot':
        _, _, w, h = win32gui.GetClientRect(hwnd)
        x, y = win32gui.ClientToScreen(hwnd, (0, 0))
        ImageGrab.grab((x, y, x + w, y + h), all_screens=True).save(args[0])


if __name__ == '__main__':
    main()
