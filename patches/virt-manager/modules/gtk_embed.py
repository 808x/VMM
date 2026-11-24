# Copyright 2026
#
# This work is licensed under the GNU GPLv2 or later.
# See the COPYING file in the top-level directory.
"""Embed QEMU's GTK window into the virt-manager console.

The VM runs QEMU with `-display gtk` and a libvirt SPICE graphics
device.  SPICE still carries the agent, clipboard and USB channels; the
video is QEMU's own X11 toplevel, reparented into the console viewport.
"""

import ctypes
import ctypes.util
import os
import re
import time

import libvirt
import gi

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk
from gi.repository import GObject
from gi.repository import Gtk

try:
    gi.require_version("GdkX11", "3.0")
    from gi.repository import GdkX11
    GI_GDKX11_IMPORT_ERROR = None
except (ValueError, ImportError) as _e:
    GdkX11 = None
    GI_GDKX11_IMPORT_ERROR = str(_e)

from virtinst import log

from . import viewers as _vw
from .viewers import SpiceViewer


_EVENT_MASK = (1 << 17) | (1 << 15) | (1 << 16) | (1 << 9)
_SETMODE_INSERT = 0
_SETMODE_DELETE = 1
_UNLOCK_ATOM = b"_VIRTMGR_GTK_UNLOCK"

# Linux KEY_* codes for virDomainSendKey; the Send Key menu combos only.
_GDK_KEYVAL_NAME_TO_LINUX_KEYCODE = {
    "Control_L": 29, "Control_R": 97,
    "Shift_L": 42, "Shift_R": 54,
    "Alt_L": 56, "Alt_R": 100,
    "Meta_L": 125, "Meta_R": 126,
    "Super_L": 125, "Super_R": 126,
    "BackSpace": 14,
    "Delete": 111,
    "Escape": 1,
    "Print": 99,
}
for _i in range(1, 11):
    _GDK_KEYVAL_NAME_TO_LINUX_KEYCODE["F%d" % _i] = 58 + _i
_GDK_KEYVAL_NAME_TO_LINUX_KEYCODE["F11"] = 87
_GDK_KEYVAL_NAME_TO_LINUX_KEYCODE["F12"] = 88


# Module scope: a dynamically created Structure subclass corrupts
# weakref dealloc on CPython 3.13.
class _XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int),
        ("y", ctypes.c_int),
        ("width", ctypes.c_int),
        ("height", ctypes.c_int),
        ("border_width", ctypes.c_int),
        ("depth", ctypes.c_int),
        ("visual", ctypes.c_void_p),
        ("root", ctypes.c_ulong),
        ("class", ctypes.c_int),
        ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int),
        ("backing_store", ctypes.c_int),
        ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong),
        ("save_under", ctypes.c_int),
        ("colormap", ctypes.c_ulong),
        ("map_state", ctypes.c_int),
        ("all_event_masks", ctypes.c_ulong),
        ("your_event_mask", ctypes.c_ulong),
        ("do_not_propagate_mask", ctypes.c_ulong),
        ("override_redirect", ctypes.c_int),
    ]


_xget_attrs_instance = _XWindowAttributes()


class _XerrGuard:
    """Install a silent X error handler for the duration of a call.

    Raw Xlib calls are not covered by GDK's traps; an async BadWindow on a
    closing QEMU window reaches the default handler, which exits the
    process.  Callers must XSync before leaving.
    """

    def __init__(self):
        self._old = None

    def __enter__(self):
        lib = get_xlib()
        handler = ctypes.cast(lib._silent_handler, ctypes.c_void_p)
        self._old = lib.XSetErrorHandler(handler)
        return self

    def __exit__(self, *exc):
        if self._old:
            get_xlib().XSetErrorHandler(self._old)
            self._old = None
        return False


def get_xlib():
    lib = getattr(get_xlib, "_lib", None)
    if lib is not None:
        return lib
    lib = ctypes.CDLL(ctypes.util.find_library("X11"))
    libtype = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)

    @libtype
    def _silent_xerror_handler(_display, _ev):
        # Xlib requires 0 for handled errors.
        return 0

    lib._XerrPT = libtype
    lib._silent_handler = _silent_xerror_handler
    lib.XSetErrorHandler.argtypes = [ctypes.c_void_p]
    lib.XSetErrorHandler.restype = ctypes.c_void_p
    get_xlib._lib = lib
    return lib


def xerr_guard():
    return _XerrGuard()


def _xlib():
    lib = get_xlib()
    if getattr(lib, "_embed_ready", False):
        return lib

    lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
    lib.XOpenDisplay.restype = ctypes.c_void_p
    lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
    lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    lib.XDefaultRootWindow.restype = ctypes.c_ulong
    lib.XReparentWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                    ctypes.c_ulong, ctypes.c_int,
                                    ctypes.c_int]
    lib.XReparentWindow.restype = ctypes.c_int
    lib.XFlush.argtypes = [ctypes.c_void_p]
    lib.XUnmapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    lib.XMapWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    lib.XResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                  ctypes.c_int, ctypes.c_int]
    lib.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                   ctypes.c_int, ctypes.c_long]
    lib.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                ctypes.c_int]
    lib.XInternAtom.restype = ctypes.c_ulong
    lib.XChangeProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                    ctypes.c_ulong, ctypes.c_ulong,
                                    ctypes.c_int, ctypes.c_int,
                                    ctypes.c_void_p, ctypes.c_int]
    lib.XDeleteProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                    ctypes.c_ulong]
    lib.XGetGeometry.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                 ctypes.POINTER(ctypes.c_ulong),
                                 ctypes.POINTER(ctypes.c_int),
                                 ctypes.POINTER(ctypes.c_int),
                                 ctypes.POINTER(ctypes.c_uint),
                                 ctypes.POINTER(ctypes.c_uint),
                                 ctypes.POINTER(ctypes.c_uint),
                                 ctypes.POINTER(ctypes.c_uint)]
    lib.XGetGeometry.restype = ctypes.c_int
    lib.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                         ctypes.POINTER(_XWindowAttributes)]
    lib.XGetWindowAttributes.restype = ctypes.c_int
    lib.XSelectInput.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                 ctypes.c_long]
    lib.XChangeSaveSet.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                   ctypes.c_int]
    lib.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                               ctypes.POINTER(ctypes.c_long),
                               ctypes.POINTER(ctypes.c_long),
                               ctypes.POINTER(ctypes.POINTER(ctypes.c_long)),
                               ctypes.POINTER(ctypes.c_uint)]
    lib.XQueryTree.restype = ctypes.c_int
    lib.XGetWindowProperty.argtypes = [ctypes.c_void_p, ctypes.c_ulong,
                                       ctypes.c_ulong, ctypes.c_long,
                                       ctypes.c_long, ctypes.c_int,
                                       ctypes.c_ulong,
                                       ctypes.POINTER(ctypes.c_ulong),
                                       ctypes.POINTER(ctypes.c_int),
                                       ctypes.POINTER(ctypes.c_ulong),
                                       ctypes.POINTER(ctypes.c_ulong),
                                       ctypes.POINTER(ctypes.c_void_p)]
    lib.XGetWindowProperty.restype = ctypes.c_int
    lib.XFree.argtypes = [ctypes.c_void_p]
    lib._embed_ready = True
    return lib


def _xdisplay(gdk_display):
    if not isinstance(gdk_display, GdkX11.X11Display):
        return None
    ctypes.pythonapi.PyCapsule_GetPointer.restype = ctypes.c_void_p
    ctypes.pythonapi.PyCapsule_GetPointer.argtypes = [ctypes.py_object,
                                                      ctypes.c_char_p]
    ptr = ctypes.pythonapi.PyCapsule_GetPointer(gdk_display.__gpointer__, None)
    libgdk = ctypes.CDLL(ctypes.util.find_library("gdk-3"))
    libgdk.gdk_x11_display_get_xdisplay.argtypes = [ctypes.c_void_p]
    libgdk.gdk_x11_display_get_xdisplay.restype = ctypes.c_void_p
    return libgdk.gdk_x11_display_get_xdisplay(ptr)


def _set_unlock_atom(lib, xd, xid):
    atom = lib.XInternAtom(xd, _UNLOCK_ATOM, False)
    xa_window = lib.XInternAtom(xd, b"WINDOW", False) or 20
    root = lib.XDefaultRootWindow(xd)
    value = ctypes.c_ulong(xid)
    lib.XChangeProperty(xd, root, atom, xa_window, 32, 0,
                        ctypes.byref(value), 1)


def _window_alive(lib, xd, xid):
    root = ctypes.c_ulong()
    x = ctypes.c_int()
    y = ctypes.c_int()
    w = ctypes.c_uint()
    h = ctypes.c_uint()
    bw = ctypes.c_uint()
    depth = ctypes.c_uint()
    return bool(lib.XGetGeometry(xd, xid, ctypes.byref(root),
                                 ctypes.byref(x), ctypes.byref(y),
                                 ctypes.byref(w), ctypes.byref(h),
                                 ctypes.byref(bw), ctypes.byref(depth)))


def _window_size(lib, xd, xid):
    root = ctypes.c_ulong()
    x = ctypes.c_int()
    y = ctypes.c_int()
    w = ctypes.c_uint()
    h = ctypes.c_uint()
    bw = ctypes.c_uint()
    depth = ctypes.c_uint()
    if not lib.XGetGeometry(xd, xid, ctypes.byref(root),
                            ctypes.byref(x), ctypes.byref(y),
                            ctypes.byref(w), ctypes.byref(h),
                            ctypes.byref(bw), ctypes.byref(depth)):
        return None
    return (w.value, h.value)


def _window_map_state(lib, xd, xid):
    if not lib.XGetWindowAttributes(xd, xid,
                                    ctypes.byref(_xget_attrs_instance)):
        return 0
    return _xget_attrs_instance.map_state


class GtkEmbedSpiceViewer(SpiceViewer):
    """SPICE session with QEMU's GTK window as the video surface."""

    def __init__(self, vm, ginfo):
        if GI_GDKX11_IMPORT_ERROR:
            raise RuntimeError(
                "GTK console embedding requires GdkX11: %s"
                % GI_GDKX11_IMPORT_ERROR)

        SpiceViewer.__init__(self, vm, ginfo)

        self._qemu_pid = None
        self._qemu_xid = None
        self._reparented = False
        self._window_check_id = None
        self._gtk_viewport = None
        self._drawing_area = None
        self._resize_widget = None

        self._spice_gidx = None
        self._find_spice_graphics_device()

        # Start the session now so the DisplayChannel arrives while the
        # window is still hidden by the shim.
        self._create_spice_session()
        self._open_spice()

    ###################
    # Private helpers #
    ###################

    def _create_spice_session(self):
        if self._spice_session is not None:
            return
        if _vw.SPICE_GTK_IMPORT_ERROR:
            log.warning("SPICE not available: %s", _vw.SPICE_GTK_IMPORT_ERROR)
            return

        try:
            session = _vw.SpiceClientGLib.Session()
            _vw.SpiceClientGLib.set_session_option(session)
            gtk_session = _vw.SpiceClientGtk.GtkSession.get(session)
            gtk_session.set_property("auto-clipboard", True)
            _vw._SIGS.connect(session, "channel-new", self._channel_new_cb)
            self._spice_session = session

            try:
                self._usbdev_manager = \
                    _vw.SpiceClientGLib.UsbDeviceManager.get(session)
                _vw._SIGS.connect(self._usbdev_manager, "auto-connect-failed",
                                  self._usbdev_redirect_error)
                _vw._SIGS.connect(self._usbdev_manager, "device-error",
                                  self._usbdev_redirect_error)
                from .. import usb_redirect
                usb_redirect.ensure_cache(self._usbdev_manager)
                if self.config.get_auto_usbredir():
                    gtk_session.set_property("auto-usbredir", True)
            except Exception:
                self._usbdev_manager = None
                log.debug("Error initializing spice usb device manager",
                          exc_info=True)
        except Exception as e:
            log.error("Failed to create SPICE session: %s", e)

    def _find_spice_graphics_device(self):
        try:
            for gdev in self._vm.xmlobj.devices.graphics:
                if gdev.type == "spice":
                    self._spice_gidx = gdev.get_xml_idx()
                    break
        except Exception:
            pass

    def _init_display(self):
        display = Gtk.DrawingArea()
        display.set_size_request(640, 480)
        self._set_display(display)

    def _get_spice_fd_for_open(self):
        if self._spice_gidx is None:
            self._find_spice_graphics_device()
        if self._spice_gidx is None:
            return None
        if self._ginfo.need_tunnel():
            return self._tunnels.open_new()
        if self._vm.conn.is_remote():
            return None
        if not self._vm.conn.support.domain_open_graphics():
            return None
        try:
            return self._vm.open_graphics_fd(self._spice_gidx)
        except Exception:
            log.debug("Failed to get SPICE fd", exc_info=True)
            return None

    def _get_fd_for_open(self):
        # The session was opened in __init__; _open() must not reopen it.
        return None

    def _open_spice(self):
        if not self._spice_session:
            return
        fd = self._get_spice_fd_for_open()
        if fd is None:
            log.warning("No SPICE fd; USB and agent channels unavailable")
            return
        self._spice_session.open_fd(fd)

    def _channel_open_fd_request(self, channel, tls_ignore):
        if not self._tunnels:
            return
        channel.connect_after("channel-event", self._fd_channel_event_cb)
        fd = self._get_spice_fd_for_open()
        if fd is not None:
            try:
                channel.open_fd(fd)
            except Exception:
                log.error("SPICE channel.open_fd failed", exc_info=True)
        else:
            log.warning("No SPICE fd for channel")

    def _channel_new_cb(self, session, channel):
        if (isinstance(channel, _vw.SpiceClientGLib.DisplayChannel)
                and not self._display):
            if channel.get_property("channel-id") != 0:
                return
            self._channels.add(channel)
            _vw._SIGS.connect(channel, "open-fd",
                              self._channel_open_fd_request)
            self._init_gtk_display_reparent()
            return

        SpiceViewer._channel_new_cb(self, session, channel)

    def _agent_connected_cb(self, src, val):
        if val:
            self.emit("agent-connected")

    ##################################
    # GTK window discovery/reparent #
    ##################################

    def _init_gtk_display_reparent(self):
        self._init_display()
        self._qemu_pid = self._discover_qemu_pid()
        self._create_gtk_display_widget()
        self._arm_window_check()

    def _discover_qemu_pid(self):
        pid = self._read_pid_file(self._find_pid_file())
        if pid:
            try:
                os.kill(pid, 0)
                return pid
            except OSError:
                pass
        return self._find_qemu_pid_by_name()

    def _find_pid_file(self):
        name = self._vm.get_name()
        uid = os.getuid()
        for path in (
            "/var/run/libvirt/qemu/%s.pid" % name,
            "/var/run/libvirt/qemu/%s.pidfile" % name,
            "/run/libvirt/qemu/%s.pid" % name,
            "/run/user/%d/libvirt/qemu/run/%s.pid" % (uid, name),
            "/run/user/%d/libvirt/qemu/%s.pid" % (uid, name),
            "/run/user/%d/libvirt/qemu/%s.pidfile" % (uid, name),
        ):
            if os.path.isfile(path):
                return path
        return None

    def _read_pid_file(self, path):
        if not path:
            return None
        try:
            with open(path, "r", encoding="utf-8") as f:
                content = f.read().strip()
            return int(content) if content.isdigit() else None
        except OSError:
            return None

    def _find_qemu_pid_by_name(self):
        # A prefix match can hit another VM's pid file or process.
        guest_re = re.compile(r"^guest=%s(,|$)" % re.escape(self._vm.get_name()))
        skip = {os.getpid(), os.getppid()}
        try:
            for entry in os.listdir("/proc"):
                if not entry.isdigit() or int(entry) in skip:
                    continue
                try:
                    with open("/proc/%s/cmdline" % entry, "rb") as f:
                        cmdline = f.read()
                    if b"qemu-system" not in cmdline:
                        continue
                    if guest_re.search(cmdline.decode("utf-8", "ignore")):
                        return int(entry)
                except OSError:
                    continue
        except OSError:
            pass
        return None

    def _check_gtk_window(self):
        if self._reparented:
            return False
        # Re-discover both every tick: a domain restart gives QEMU a new
        # PID, hence a new window XID.
        pid = self._discover_qemu_pid() or self._qemu_pid
        xid = self._find_qemu_window_xid(pid) if pid else None
        if not xid:
            return True
        self._qemu_pid = pid
        self._qemu_xid = xid
        if self._reparent_gtk_window(map_window=True):
            self._window_check_id = None
            self.emit("connected")
            return False
        self._qemu_xid = None
        return True

    def _find_qemu_window_xid(self, pid):
        return self._find_qemu_window_xid_raw(pid)

    def _create_gtk_display_widget(self):
        self._gtk_viewport = Gtk.Viewport()
        self._gtk_viewport.set_shadow_type(Gtk.ShadowType.NONE)
        self._gtk_viewport.set_name("vmgr-embed-viewport")
        self._drawing_area = Gtk.DrawingArea()
        self._drawing_area.set_name("vmgr-embed-drawingarea")
        self._drawing_area.set_can_focus(True)
        self._gtk_viewport.add(self._drawing_area)
        self._gtk_viewport.show_all()

        # If the viewport X window dies while the QEMU window is still
        # inside it, QEMU's GDK exits on BadWindow.  Park it first.
        self._gtk_viewport.connect("unrealize", self._on_viewport_unrealize)

        self._display = self._drawing_area
        self.emit("add-display-widget", self._gtk_viewport)

        self._hook_viewport_resize(self._gtk_viewport)
        self._drawing_area.connect("focus-in-event", self._on_console_focus_event)
        self._drawing_area.connect("button-press-event", self._on_console_focus_event)
        self._gtk_viewport.connect("focus-in-event", self._on_console_focus_event)
        self._gtk_viewport.connect("button-press-event", self._on_console_focus_event)

    def _reparent_gtk_window(self, map_window=True):
        if not self._qemu_xid or not self._gtk_viewport:
            return False

        viewport = self._gtk_viewport
        # Never embed into an unrealized/hidden page: QEMU's first map
        # would be swallowed with no viewable parent, and the poll would
        # keep re-adopting a window nobody can see.
        if not viewport.get_realized():
            viewport.realize()
        gwin = viewport.get_window()
        if gwin is None:
            return False

        lib = _xlib()
        with xerr_guard():
            xd = _xdisplay(viewport.get_display())
            if not xd:
                return False
            lib.XUnmapWindow(xd, self._qemu_xid)
            if not lib.XReparentWindow(xd, self._qemu_xid,
                                       gwin.get_xid(), 0, 0):
                return False
            self._reparented = True

            lib.XSelectInput(xd, self._qemu_xid, _EVENT_MASK)
            # If this process dies, X moves the window to the nearest
            # surviving ancestor instead of destroying it with our tree.
            lib.XChangeSaveSet(xd, self._qemu_xid, _SETMODE_INSERT)
            lib.XFlush(xd)

            if map_window:
                # Lift the shim's map deferral before mapping, otherwise
                # QEMU's own map would be swallowed again.
                _set_unlock_atom(lib, xd, self._qemu_xid)
                alloc = viewport.get_allocation()
                if alloc.width > 1 and alloc.height > 1:
                    lib.XResizeWindow(xd, self._qemu_xid,
                                      alloc.width, alloc.height)
                lib.XMapWindow(xd, self._qemu_xid)
                lib.XFlush(xd)
                for _ in range(60):
                    if _window_map_state(lib, xd, self._qemu_xid) != 0:
                        break
                    time.sleep(0.05)
                lib.XSetInputFocus(xd, self._qemu_xid, 2, 0)
                lib.XFlush(xd)
                lib.XSync(xd, False)
        return True

    def _hook_viewport_resize(self, viewport):
        old = self._resize_widget
        if old is not None and old is not viewport:
            try:
                old.disconnect_by_func(self._on_viewport_size_allocate)
            except TypeError:
                pass
        try:
            viewport.disconnect_by_func(self._on_viewport_size_allocate)
        except TypeError:
            pass
        viewport.connect("size-allocate", self._on_viewport_size_allocate)
        self._resize_widget = viewport

    def _on_viewport_size_allocate(self, widget, allocation):
        if (self._qemu_xid and allocation.width > 1
                and allocation.height > 1):
            self._resize_qemu_window(widget)

    def _resize_qemu_window(self, viewport):
        if not self._qemu_xid or not self._reparented:
            return
        alloc = viewport.get_allocation()
        if alloc.width <= 1 or alloc.height <= 1:
            return
        lib = _xlib()
        with xerr_guard():
            xd = _xdisplay(viewport.get_display())
            if not xd:
                return
            lib.XResizeWindow(xd, self._qemu_xid, alloc.width, alloc.height)
            lib.XFlush(xd)

    def _on_console_focus_event(self, widget, *args):
        if not self._qemu_xid or not self._reparented:
            return False
        try:
            time.sleep(0.01)
            lib = _xlib()
            with xerr_guard():
                xd = _xdisplay(widget.get_display())
                if not xd:
                    return False
                lib.XSetInputFocus(xd, self._qemu_xid, 2, 0)
                lib.XFlush(xd)
                lib.XSync(xd, False)
        except Exception as e:
            log.debug("Focus handoff failed: %s", e)
        return False

    def _on_viewport_unrealize(self, viewport):
        ignore = viewport
        if self._reparented and self._qemu_xid:
            self._unreparent_gtk_window()
            # The console page can come back (page switch, domain restart).
            # Keep a poll armed so the window is re-embedded; _close and
            # _cleanup cancel it when the viewer really goes away.
            self._arm_window_check()

    def _arm_window_check(self):
        if self._window_check_id is None:
            self._window_check_id = GObject.timeout_add(
                500, self._check_gtk_window)

    def _cancel_window_check(self):
        if self._window_check_id:
            GObject.source_remove(self._window_check_id)
            self._window_check_id = None

    def _unreparent_gtk_window(self):
        if not self._reparented or not self._qemu_xid:
            return
        self._cancel_window_check()
        if self._resize_widget:
            try:
                self._resize_widget.disconnect_by_func(
                    self._on_viewport_size_allocate)
            except TypeError:
                pass
            self._resize_widget = None

        try:
            viewport = self._gtk_viewport
            lib = _xlib()
            with xerr_guard():
                xd = _xdisplay(viewport.get_display()) if viewport else None
                if xd and _window_alive(lib, xd, self._qemu_xid):
                    # Hand the window back to root before our tree dies.
                    lib.XChangeSaveSet(xd, self._qemu_xid, _SETMODE_DELETE)
                    lib.XUnmapWindow(xd, self._qemu_xid)
                    lib.XReparentWindow(xd, self._qemu_xid,
                                        lib.XDefaultRootWindow(xd), 0, 0)
                    _set_unlock_atom(lib, xd, self._qemu_xid)
                    lib.XMapWindow(xd, self._qemu_xid)
                    lib.XFlush(xd)
                    lib.XSync(xd, False)
        except Exception as e:
            log.error("Error unparenting QEMU window: %s", e)
        finally:
            self._reparented = False

    def _find_qemu_window_xid_raw(self, pid):
        lib = _xlib()
        disp = lib.XOpenDisplay(None)
        if not disp:
            log.error("Could not open X display for QEMU window search")
            return None
        try:
            with xerr_guard():
                root = lib.XDefaultRootWindow(disp)
                pid_atom = lib.XInternAtom(disp, b"_NET_WM_PID", True)
                name_atom = lib.XInternAtom(disp, b"WM_NAME", True)
                if not pid_atom or not name_atom:
                    return None

                def _prop(win, atom):
                    rtype = ctypes.c_ulong()
                    rfmt = ctypes.c_int()
                    nitems = ctypes.c_ulong()
                    after = ctypes.c_ulong()
                    data = ctypes.c_void_p()
                    if lib.XGetWindowProperty(
                            disp, win, atom, 0, 128, 0, 0,
                            ctypes.byref(rtype), ctypes.byref(rfmt),
                            ctypes.byref(nitems), ctypes.byref(after),
                            ctypes.byref(data)) != 0 or not data:
                        return None
                    try:
                        # Format 32 is an array of long, 8 bytes on LP64.
                        width = (ctypes.sizeof(ctypes.c_long)
                                 if rfmt.value == 32 else 1)
                        return ctypes.string_at(data, nitems.value * width)
                    finally:
                        lib.XFree(data)

                def _children(win):
                    rret = ctypes.c_long()
                    pret = ctypes.c_long()
                    wins = ctypes.POINTER(ctypes.c_long)()
                    nwins = ctypes.c_uint()
                    if lib.XQueryTree(disp, win, ctypes.byref(rret),
                                      ctypes.byref(pret), ctypes.byref(wins),
                                      ctypes.byref(nwins)) == 0:
                        return []
                    try:
                        return [wins[i] for i in range(nwins.value)]
                    finally:
                        lib.XFree(wins)

                toplevels = []
                for win in _children(root):
                    toplevels.append(win)
                    # Reparenting WMs wrap clients in a frame.
                    toplevels.extend(_children(win))

                prefix = ("QEMU (%s)" % self._vm.get_name()).encode()
                for win in toplevels:
                    raw_pid = _prop(win, pid_atom)
                    # Format 32 data is an array of long, 8 bytes on LP64.
                    if (not raw_pid or len(raw_pid) < ctypes.sizeof(ctypes.c_long)
                            or ctypes.c_ulong.from_buffer_copy(
                                raw_pid).value & 0xFFFFFFFF != pid):
                        continue
                    title = _prop(win, name_atom)
                    # Never attach to QEMU's 10x10 helper windows.
                    if title and title.startswith(prefix):
                        return int(win)
                return None
        except Exception as e:
            log.error("Error finding QEMU window: %s", e)
            return None
        finally:
            lib.XCloseDisplay(disp)

    #########################
    # Viewer API overrides #
    #########################

    def _is_open(self):
        return self._reparented and self._qemu_xid is not None

    def _close(self):
        self._unreparent_gtk_window()
        SpiceViewer._close(self)

    def _cleanup(self):
        self._unreparent_gtk_window()
        self._cancel_window_check()
        SpiceViewer._cleanup(self)

    def _open_host(self):
        # Session and fd are opened eagerly; DisplayChannel drives reparent.
        pass

    def _open_fd(self, fd):
        if fd is not None and self._spice_session:
            self._spice_session.open_fd(fd)

    def _connect_display_signals(self):
        pass

    def _set_grab_keys(self, keys):
        pass

    def _send_keys(self, keys):
        dom = self._vm.get_backend()
        keycodes = []
        for k in keys:
            code = _GDK_KEYVAL_NAME_TO_LINUX_KEYCODE.get(k)
            if code is None:
                log.warning("send-key: unknown key name %r", k)
                return False
            keycodes.append(code)
        try:
            dom.sendKey(libvirt.VIR_KEYCODE_SET_LINUX, 100, keycodes,
                        len(keycodes), 0)
        except Exception as e:
            log.debug("send-key failed: %s", e)
            return False
        return True

    def _set_username(self, cred):
        pass

    def _set_password(self, cred):
        pass

    def _get_scaling(self):
        return False

    def _set_scaling(self, scaling):
        pass

    def _set_resizeguest(self, val):
        pass

    def _get_resizeguest(self):
        return False

    def _get_resizeguest_warning(self):
        return _("GTK viewer does not support resize guest")

    def _get_preferred_size(self):
        if self._reparented and self._qemu_xid:
            try:
                lib = _xlib()
                with xerr_guard():
                    xd = _xdisplay(self._gtk_viewport.get_display())
                    size = _window_size(lib, xd, self._qemu_xid) if xd else None
                if size and size[0] > 1 and size[1] > 1:
                    return size
            except Exception:
                pass
        return self._desktop_resolution

    def _get_pixbuf(self):
        if not (self._reparented and self._qemu_xid):
            raise RuntimeError(_("The console is not running"))
        gwin = GdkX11.X11Window.foreign_new_for_display(
            self._gtk_viewport.get_display(), self._qemu_xid)
        try:
            pb = Gdk.pixbuf_get_from_window(
                gwin, 0, 0, gwin.get_width(), gwin.get_height())
        finally:
            gwin.destroy()
        if pb is None:
            raise RuntimeError(_("Unable to read the console pixels"))
        return pb
