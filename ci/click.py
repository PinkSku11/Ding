"""Clicks the mouse at a screen point (top-left origin), for the build machine's tests."""
import ctypes
import sys
import time

cg = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]

point = CGPoint(float(sys.argv[1]), float(sys.argv[2]))
for kind in (5, 1, 2):  # mouse moved, left button down, left button up
    event = cg.CGEventCreateMouseEvent(None, kind, point, 0)
    cg.CGEventPost(0, event)  # 0 = HID event tap
    time.sleep(0.1)
print("clicked at", point.x, point.y)
