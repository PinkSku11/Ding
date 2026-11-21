"""Clicks or types for the build machine's tests.

    python3 click.py click X Y     click at a screen point (top-left origin)
    python3 click.py type TEXT     type text into whatever has keyboard focus
    python3 click.py key end       Command-Right arrow: to the end of the text
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
cg.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
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
elif sys.argv[1] == "key" and sys.argv[2] == "end":
    for down in (True, False):
        event = cg.CGEventCreateKeyboardEvent(None, 124, down)   # right arrow
        cg.CGEventSetFlags(event, 0x100000)                      # with Command
        cg.CGEventPost(0, event)
        time.sleep(0.04)
    print("pressed Command-Right arrow")
