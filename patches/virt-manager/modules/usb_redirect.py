#
# Copyright 2026
#
# This work is licensed under the GNU GPLv2 or later.
# See the COPYING file in the top-level directory.
"""USB redirection menu helpers; state always read back from spice-gtk."""

import re

from gi.repository import GLib

from virtinst import log


# Spice appends " [vid:pid] at bus-port"; menus keep only the description.
_DESC_TAIL = re.compile(
    r"\s*\[[0-9a-fA-F]{4}:[0-9a-fA-F]{4}\](?:\s+at\s+\S+)?\s*$")


# Cache lives on the manager, so a new session gets a fresh one.
_CACHE_ATTR = "_vmm_usb_device_cache"


class _UsbDeviceCache:
    """Signal-fed device list.

    Do not call UsbDeviceManager.get_devices(): spice-gtk marks the
    container transfer-full and unrefs the elements, while PyGObject also
    assumes ownership.  Freeing the wrapper then frees a device the
    manager still lists, and the next get_description() reads freed
    memory.  Signal parameters are transfer-none and stay valid until
    the matching device-removed, which this cache follows.
    """

    def __init__(self, manager):
        # No back-reference: virt-manager disables the cyclic GC, so a
        # manager <-> cache cycle would leak a session on every reopen.
        self._devices = {}  # C pointer -> wrapper, insertion ordered
        manager.connect("device-added", self._on_added)
        manager.connect("device-removed", self._on_removed)

    def _on_added(self, _manager, device):
        if self._devices.setdefault(hash(device), device) is device:
            log.debug("usb_redirect: device-added %s", menu_label(device))

    def _on_removed(self, _manager, device):
        # Describe before dropping the cached wrapper: dropping a ref
        # here must not leave the description reading freed memory.
        desc = menu_label(device)
        if self._devices.pop(hash(device), None) is not None:
            log.debug("usb_redirect: device-removed %s", desc)

    def get_devices(self):
        return list(self._devices.values())


def ensure_cache(manager):
    """Install the signal-fed cache before the session starts connecting."""
    if manager is None:
        return None

    cache = getattr(manager, _CACHE_ATTR, None)
    if cache is not None:
        return cache

    try:
        cache = _UsbDeviceCache(manager)
        setattr(manager, _CACHE_ATTR, cache)
    except Exception:  # pragma: no cover
        log.debug("Error installing spice USB device cache", exc_info=True)
        return None
    return cache


def menu_label(device):
    desc = str(device.get_description() or "")
    return _DESC_TAIL.sub("", desc) or desc


def is_connected(manager, device):
    try:
        return bool(manager.is_device_connected(device))
    except Exception:  # pragma: no cover
        return False


def list_devices(manager):
    """Real USB devices, excluding the virtual shared CD."""
    if manager is None:
        return []

    cache = ensure_cache(manager)
    try:
        if cache is not None:
            devices = cache.get_devices()
        else:  # test doubles without GObject signals
            devices = manager.get_devices() or []
    except Exception:  # pragma: no cover
        log.debug("Error listing spice USB devices", exc_info=True)
        return []

    ret = []
    for dev in devices:
        try:
            if manager.is_device_shared_cd(dev):
                continue
        except Exception:  # pragma: no cover
            pass
        ret.append(dev)
    return ret


def device_tooltip(manager, device):
    desc = str(device.get_description() or "")
    if is_connected(manager, device):
        state = _("Redirected to the guest")
    else:
        state = _("Not redirected")
    return desc + "\n" + state


def _show_err(err, msg):
    try:
        err.show_err(msg)
    except Exception:  # pragma: no cover
        log.debug("Error showing USB redirect error", exc_info=True)


def _restore(chk, manager, device):
    try:
        chk._vmm_reverting = True
        chk.set_active(is_connected(manager, device))
    except Exception:  # pragma: no cover
        pass
    finally:
        chk._vmm_reverting = False
        try:
            chk.set_sensitive(True)
        except Exception:  # pragma: no cover
            pass
        chk._vmm_busy = False


def toggle_device(chk, manager, err, device):
    """Toggle, then trust only the manager's post-operation state."""
    if getattr(chk, "_vmm_busy", False):
        return False

    want = chk.get_active()
    if want == is_connected(manager, device):
        return True

    chk._vmm_busy = True
    chk._vmm_reverting = True
    chk.set_active(not want)
    chk._vmm_reverting = False
    chk.set_sensitive(False)

    def _finish(mgr, result, _data):
        msg = _("The device did not change state.")
        ok = False
        try:
            if want:
                mgr.connect_device_finish(result)
            else:
                mgr.disconnect_device_finish(result)
            ok = is_connected(mgr, device) == want
        except Exception as e:
            msg = str(e)

        _restore(chk, mgr, device)
        if not ok:
            _show_err(err, _("Error redirecting USB device: %s") % msg)
        return False

    try:
        if want:
            manager.connect_device_async(device, None, _finish, None)
        else:
            manager.disconnect_device_async(device, None, _finish, None)
    except Exception as e:  # pragma: no cover
        _restore(chk, manager, device)
        _show_err(err, _("Error redirecting USB device: %s") % e)
        return False
    return True


class MenuErrorSink:
    """Queue errors until the popup closes; a modal would stack over it."""

    def __init__(self, menu):
        self._menu = menu
        self._messages = []

    def show_err(self, msg):
        self._messages.append(msg)
        GLib.idle_add(self._flush_idle)

    def flush(self):
        if self._messages:
            GLib.idle_add(self._flush_idle)

    def _flush_idle(self):
        while self._messages:
            if self._menu.get_mapped():
                return False
            msg = self._messages.pop(0)
            err = getattr(self._menu._parent, "err", None)
            if err is None:
                log.error("%s", msg)
            else:
                err.show_err(msg)
            if self._messages:
                GLib.idle_add(self._flush_idle)
            return False
        return False
