"""Clicks or types for the build machine's tests.

    python3 click.py click X Y     click at a screen point (top-left origin)
    python3 click.py type TEXT     type text into whatever has keyboard focus
    python3 click.py tripleclick X Y   triple-click, which selects all the text in a field
    python3 click.py key return    press Return (also: down, up, escape, delete, tab)
    python3 click.py drag X1 Y1 X2 Y2   press at one point, drag to the other, let go
"""
import ctypes
import sys
import time

cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
cg.CGEventKeyboardSetUnicodeString.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_uint16)]
cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]

if sys.argv[1] == "click":
    point = CGPoint(float(sys.argv[2]), float(sys.argv[3]))
    for kind in (5, 1, 2):  # mouse moved, left button down, left button up
        cg.CGEventPost(0, cg.CGEventCreateMouseEvent(None, kind, point, 0))
        time.sleep(0.1)
    print("clicked at", point.x, point.y)
elif sys.argv[1] == "type":
    for ch in sys.argv[2]:
        buf = (ctypes.c_uint16 * 1)(ord(ch))
        for down in (True, False):
            event = cg.CGEventCreateKeyboardEvent(None, 0, down)
            cg.CGEventKeyboardSetUnicodeString(event, 1, buf)
            cg.CGEventPost(0, event)
            time.sleep(0.04)
    print("typed", repr(sys.argv[2]))
elif sys.argv[1] == "tripleclick":
    point = CGPoint(float(sys.argv[2]), float(sys.argv[3]))
    cg.CGEventPost(0, cg.CGEventCreateMouseEvent(None, 5, point, 0))
    time.sleep(0.1)
    for count in (1, 2, 3):
        for kind in (1, 2):  # left button down, up
            event = cg.CGEventCreateMouseEvent(None, kind, point, 0)
            cg.CGEventSetIntegerValueField(event, 1, count)  # the click count (kCGMouseEventClickState)
            cg.CGEventPost(0, event)
        time.sleep(0.05)
    print("triple-clicked at", point.x, point.y)
elif sys.argv[1] == "key":
    code = {"return": 36, "down": 125, "up": 126, "escape": 53, "delete": 51, "tab": 48}[sys.argv[2]]
    for down in (True, False):
        cg.CGEventPost(0, cg.CGEventCreateKeyboardEvent(None, code, down))
        time.sleep(0.04)
    print("pressed", sys.argv[2])
elif sys.argv[1] == "drag":
    x1, y1, x2, y2 = (float(v) for v in sys.argv[2:6])
    start, end = CGPoint(x1, y1), CGPoint(x2, y2)
    cg.CGEventPost(0, cg.CGEventCreateMouseEvent(None, 5, start, 0))   # move there
    time.sleep(0.1)
    cg.CGEventPost(0, cg.CGEventCreateMouseEvent(None, 1, start, 0))   # press
    time.sleep(0.1)
    steps = 12
    for i in range(1, steps + 1):
        point = CGPoint(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps)
        cg.CGEventPost(0, cg.CGEventCreateMouseEvent(None, 6, point, 0))   # drag
        time.sleep(0.03)
    time.sleep(0.1)
    cg.CGEventPost(0, cg.CGEventCreateMouseEvent(None, 2, end, 0))     # let go
    print("dragged from", x1, y1, "to", x2, y2)
