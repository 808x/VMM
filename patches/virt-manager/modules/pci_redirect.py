#
# Copyright 2026
#
# This work is licensed under the GNU GPLv2 or later.
# See the COPYING file in the top-level directory.
"""PCI redirection: property-based curation, live/config toggle, dialog."""

import os
import re
import stat
import subprocess
import time
import xml.etree.ElementTree as ET

import libvirt

from gi.repository import GLib
from gi.repository import Gtk
from gi.repository import Pango

from virtinst import DeviceHostdev
from virtinst import Guest
from virtinst import log


# Curation is class/prog-if only.  No vendor strings, no addresses.
PCI_REDIRECT_BASE_CLASSES = (0x02, 0x03, 0xff)
PCI_REDIRECT_USB_SUBCLASS = 0x03
# USB host controllers; 0x40 is a USB4 tunnel endpoint, not a host.
PCI_USB_HOST_PROGIFS = (0x00, 0x10, 0x20, 0x30)

# Shown by default; the rest stays behind "Show other devices".
PCI_USEFUL_BASE_CLASSES = (0x01, 0x02, 0x03, 0x04, 0xff)

# Overridable for tests.
SYSFS_ROOT = "/sys"
PROC_ROOT = "/proc"

_PCI_COMPONENT_RE = re.compile(
    r"^([0-9a-fA-F]{4}):([0-9a-fA-F]{2}):([0-9a-fA-F]{2})\.([0-7])$")

# Session-mode helper: binds the IOMMU group to vfio-pci and restores
# the host drivers afterwards.  It repeats the host-critical check.
VMM_VFIO_CTL = "/usr/local/sbin/vmm-vfio-ctl"
_session_bound = set()


def _as_int(val):
    if val is None:
        return None
    try:
        return int(str(val), 0)
    except ValueError:
        return val


def hostdev_pci_addr(hostdev):
    return (_as_int(hostdev.domain), _as_int(hostdev.bus),
            _as_int(hostdev.slot), _as_int(hostdev.function))


def nodedev_pci_addr(nodedev):
    return hostdev_pci_addr(nodedev)


def nodedev_iommu_group(nodedev):
    """Number from <capability><iommuGroup>, if any.

    virtinst 5.1 does not expose an iommu_group property; newer versions
    may.  Fall back to the node XML so both work.
    """
    try:
        return nodedev.iommu_group
    except AttributeError:
        pass
    try:
        node = ET.fromstring(nodedev.get_xml()).find("./capability/iommuGroup")
        return int(node.get("number")) if node is not None else None
    except Exception:  # pragma: no cover
        return None


def pci_addr_str(addr):
    return "%04X:%02X:%02X.%X" % addr


def pci_addr_label(addr):
    return _("PCI %s") % pci_addr_str(addr)


def device_label(xmlobj, detailed=False):
    """Description-only for menus; detailed adds IDs and address."""
    vendor = str(xmlobj.vendor_name or "").strip()
    product = str(xmlobj.product_name or "").strip()
    desc = " ".join(x for x in (vendor, product) if x)

    addr = nodedev_pci_addr(xmlobj)
    if not desc:
        desc = pci_addr_label(addr)

    if detailed:
        vendor_id = str(xmlobj.vendor_id or "").replace("0x", "")
        product_id = str(xmlobj.product_id or "").replace("0x", "")
        if vendor_id and product_id:
            desc += " [%s:%s]" % (vendor_id, product_id)
        desc += " " + _("at %s") % pci_addr_str(addr)
    return desc


def nodedev_from_addr(conn, addr):

    try:
        for dev in conn.filter_nodedevs("pci"):
            if nodedev_pci_addr(dev.xmlobj) == addr:
                return dev
    except Exception:  # pragma: no cover
        log.debug("Error looking up PCI nodedev %s", addr, exc_info=True)
    return None


def _is_session_vm(vm):
    try:
        return "session" in (vm.conn.get_uri() or "")
    except Exception:  # pragma: no cover
        return False


def _host_driver_name(addr):
    path = os.path.join(SYSFS_ROOT, "bus", "pci", "devices",
                        pci_addr_str(addr), "driver")
    try:
        return os.path.basename(os.readlink(path))
    except OSError:
        return ""


def _run_vfio_helper(action, addr):
    """Run the root helper; False when it is not installed."""
    if not os.path.exists(VMM_VFIO_CTL):
        return False
    res = subprocess.run(
        ["sudo", "-n", VMM_VFIO_CTL, action, pci_addr_str(addr)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        timeout=120)
    if res.returncode != 0:
        msg = (res.stderr or res.stdout).strip()
        raise RuntimeError(msg or _("The vfio helper failed."))
    return True


def _release_session_vfio(addr):
    try:
        _run_vfio_helper("unbind", addr)
    except Exception:  # pragma: no cover
        log.warning("Could not restore the host driver for %s",
                    pci_addr_str(addr), exc_info=True)
    finally:
        _session_bound.discard(addr)


def hostdev_from_addr(conn, addr):

    dev = DeviceHostdev(conn)
    dev.type = "pci"
    dev.domain, dev.bus, dev.slot, dev.function = addr
    dev.mode = "subsystem"
    dev.managed = "yes"
    return dev


def _xml_pci_addrs(vm, flags):
    try:
        xml = vm.get_backend().XMLDesc(flags)
        guest = Guest(vm.conn.get_backend(), parsexml=xml)
        return [hostdev_pci_addr(d)
                for d in guest.devices.hostdev if d.type == "pci"]
    except Exception:  # pragma: no cover
        log.debug("Error reading PCI hostdevs (flags=%s)", flags,
                  exc_info=True)
        return []


def live_pci_addrs(vm):

    return _xml_pci_addrs(vm, 0)


def config_pci_addrs(vm):

    return _xml_pci_addrs(vm, libvirt.VIR_DOMAIN_XML_INACTIVE)


def state_pci_addrs(vm):

    if vm.is_active():
        return live_pci_addrs(vm)
    return config_pci_addrs(vm)


def _config_hostdev(vm, addr):
    try:
        xmlobj = Guest(vm.conn.get_backend(),
                       parsexml=vm.get_backend().XMLDesc(
                           libvirt.VIR_DOMAIN_XML_INACTIVE))
        for dev in xmlobj.devices.hostdev:
            if dev.type == "pci" and hostdev_pci_addr(dev) == addr:
                return dev
    except Exception:  # pragma: no cover
        log.debug("Error looking up PCI hostdev %s in config", addr,
                  exc_info=True)
    return None


def pci_class_code(nodedev):
    val = getattr(nodedev, "pci_class", None)
    if not val:
        return None
    try:
        return int(str(val), 0)
    except ValueError:  # pragma: no cover
        return None


def pci_class_base(nodedev):
    code = pci_class_code(nodedev)
    if code is None:
        return None
    return (code >> 16) & 0xFF


def pci_class_subclass(nodedev):
    code = pci_class_code(nodedev)
    if code is None:
        return None
    return (code >> 8) & 0xFF


def is_boot_vga(nodedev):
    """Host boot display; sysfs property, never a vendor/model name."""
    addr = nodedev_pci_addr(nodedev)
    if any(val is None for val in addr):
        return False
    path = "/sys/bus/pci/devices/%s/boot_vga" % pci_addr_str(addr)
    try:
        with open(path, "r", encoding="utf-8") as f:
            return f.read().strip() == "1"
    except OSError:
        return False


def pci_class_progif(nodedev):
    code = pci_class_code(nodedev)
    if code is None:
        return None
    return code & 0xFF


def is_usb_host(nodedev):
    return (pci_class_base(nodedev) == 0x0c and
            pci_class_subclass(nodedev) == PCI_REDIRECT_USB_SUBCLASS and
            pci_class_progif(nodedev) in PCI_USB_HOST_PROGIFS)


def is_useful_class(nodedev):
    if pci_class_base(nodedev) == 0x0c:
        return is_usb_host(nodedev)
    return pci_class_base(nodedev) in PCI_USEFUL_BASE_CLASSES


def is_redirectable_class(nodedev):
    base = pci_class_base(nodedev)
    if base == 0x0c:
        if not is_usb_host(nodedev):
            return False
    elif base not in PCI_REDIRECT_BASE_CLASSES:
        return False
    return not is_boot_vga(nodedev)


def _read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def _pci_addr_from_sysfs_path(path):
    """Return the last PCI address component of a sysfs path, or None."""
    try:
        path = os.path.realpath(path)
    except OSError:  # pragma: no cover
        return None
    for part in reversed(path.split(os.sep)):
        match = _PCI_COMPONENT_RE.match(part)
        if match:
            return tuple(int(val, 16) for val in match.groups())
    return None


def _sysfs_block_path(majmin):
    path = os.path.join(SYSFS_ROOT, "dev", "block", majmin)
    return path if os.path.exists(path) else None


def _unescape_mountpoint(path):
    for escaped, char in (("\\040", " "), ("\\011", "\t"),
                          ("\\012", "\n"), ("\\134", "\\")):
        path = path.replace(escaped, char)
    return path


def _mountinfo():
    """(major:minor, mountpoint) for mounts backed by a block device."""
    ret = []
    path = os.path.join(PROC_ROOT, "self", "mountinfo")
    for line in _read_text(path).splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        majmin = fields[2]
        if _sysfs_block_path(majmin) is None:
            continue
        ret.append((majmin, _unescape_mountpoint(fields[4])))
    return ret


def _swap_majmin(path, mounts):
    try:
        st = os.stat(path)
    except OSError:
        return None
    if stat.S_ISBLK(st.st_mode):
        return "%d:%d" % (os.major(st.st_rdev), os.minor(st.st_rdev))
    if not stat.S_ISREG(st.st_mode):
        return None

    # Swapfile: attribute it to the filesystem whose mount contains it.
    real = os.path.realpath(path)
    best = None
    for majmin, mountpoint in mounts:
        prefix = mountpoint.rstrip("/")
        if real == prefix or real.startswith(prefix + "/"):
            if best is None or len(prefix) > len(best[1]):
                best = (majmin, prefix)
    return best[0] if best else None


def host_critical_mounts():

    mounts = _mountinfo()
    entries = list(mounts)
    swaps = os.path.join(PROC_ROOT, "swaps")
    for line in _read_text(swaps).splitlines()[1:]:
        fields = line.split()
        if not fields:
            continue
        majmin = _swap_majmin(fields[0], mounts)
        if majmin:
            entries.append((majmin, "swap"))

    ret = {}
    for majmin, label in entries:
        path = _sysfs_block_path(majmin)
        if path is None:
            continue
        addr = _pci_addr_from_sysfs_path(path)
        if addr is not None:
            ret.setdefault(addr, set()).add(label)
    return ret


def host_critical_pci_addrs():
    """Controllers behind any mounted filesystem or active swap."""
    return set(host_critical_mounts())


def _critical_iommu_groups(devs, critical):

    groups = set()
    for dev in devs:
        try:
            if nodedev_pci_addr(dev.xmlobj) not in critical:
                continue
            group = nodedev_iommu_group(dev.xmlobj)
            if group is not None:
                groups.add(group)
        except Exception:  # pragma: no cover
            log.debug("Error inspecting PCI nodedev %s", dev, exc_info=True)
    return groups


def _list_pci_devices(vm, predicate):
    ret = []
    try:
        devs = vm.conn.filter_nodedevs("pci")
    except Exception:  # pragma: no cover
        log.debug("Error listing PCI nodedevs", exc_info=True)
        return ret

    for dev in devs:
        try:
            if dev.xmlobj.is_pci_bridge():
                continue
            if pci_class_base(dev.xmlobj) == 0x06:
                continue
            if predicate(dev.xmlobj):
                ret.append(dev)
        except Exception:  # pragma: no cover
            log.debug("Error inspecting PCI nodedev %s", dev, exc_info=True)

    def _addr_key(dev):
        return tuple(x if x is not None else -1
                     for x in nodedev_pci_addr(dev.xmlobj))

    # Descending: the dGPU on 01:00.0 sorts above the chipset iGPU;
    # attached out-of-set devices keep their natural position too.
    ret.sort(key=_addr_key, reverse=True)
    return ret


def list_redirectable_pci_devices(vm):

    visible = _classify_pci_devices(vm)[0]
    return [dev for dev in visible if is_redirectable_class(dev.xmlobj)]


def _classify_pci_devices(vm, attached=None):
    """Split into (visible, hidden); attached critical devices stay visible."""
    if attached is None:
        attached = set(state_pci_addrs(vm))

    critical = host_critical_pci_addrs()
    try:
        devs = vm.conn.filter_nodedevs("pci")
    except Exception:  # pragma: no cover
        log.debug("Error listing PCI nodedevs", exc_info=True)
        devs = []
    groups = _critical_iommu_groups(devs, critical)

    visible = []
    hidden = []
    for dev in _list_pci_devices(vm, lambda _xmlobj: True):
        xmlobj = dev.xmlobj
        addr = nodedev_pci_addr(xmlobj)
        group = nodedev_iommu_group(xmlobj)
        if addr in attached:
            visible.append(dev)
        elif is_boot_vga(xmlobj) or addr in critical or \
                (group is not None and group in groups):
            hidden.append(dev)
        else:
            visible.append(dev)

    if hidden:
        log.info("PCI redirect: hiding host-critical devices %s",
                 ", ".join(sorted(pci_addr_str(nodedev_pci_addr(dev.xmlobj))
                                  for dev in hidden)))
    return visible, hidden


def _wait_pci_gone(vm, addr, timeout=1.5):
    deadline = time.monotonic() + timeout
    while True:
        if addr not in live_pci_addrs(vm):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.1)


def _apply_toggle(vm, addr, want):
    """Attach/detach and return whether the requested state is real."""
    if vm.is_active():
        dev = hostdev_from_addr(vm.conn.get_backend(), addr)
        if want:
            bound = False
            if _is_session_vm(vm) and \
                    _host_driver_name(addr) != "vfio-pci":
                bound = _run_vfio_helper("bind", addr)
                if bound:
                    _session_bound.add(addr)
            try:
                vm.attach_device(dev)
                ok = addr in live_pci_addrs(vm)
            except Exception:
                if bound:
                    _release_session_vfio(addr)
                raise
            if not ok and bound:
                _release_session_vfio(addr)
            return ok

        # libvirt treats its unplug timeout as success even when the
        # guest never ACKed the eject.  Some guests (notably Windows
        # removing a USB controller) drop the device from their own view
        # but never complete the ACPI eject, leaving the hostdev in the
        # live XML and QEMU holding the vfio group.  Verify the XML, then
        # force the detach instead of leaving the host device bound.
        backend = vm.get_backend()
        flags = libvirt.VIR_DOMAIN_DEVICE_MODIFY_LIVE
        xml = dev.get_xml()
        try:
            backend.detachDeviceFlags(xml, flags)
        except libvirt.libvirtError as e:
            if "timed out" not in str(e).lower():
                raise
        if not _wait_pci_gone(vm, addr):
            log.debug("PCI detach of %s did not complete; forcing",
                      pci_addr_str(addr))
            backend.detachDeviceFlags(
                xml, flags | libvirt.VIR_DOMAIN_DEVICE_MODIFY_FORCE)
        ok = _wait_pci_gone(vm, addr)
        if ok and addr in _session_bound:
            _release_session_vfio(addr)
        return ok

    if want:
        vm.add_device(hostdev_from_addr(vm.conn.get_backend(), addr))
    else:
        dev = _config_hostdev(vm, addr)
        if dev is None:
            raise RuntimeError(_(
                "The device is not in the saved VM configuration."))
        vm.remove_device(dev)
    return (addr in config_pci_addrs(vm)) == want


def toggle_device(chk, vm, err, addr):
    """Apply, verify, then move the checkbox; returns True on success."""
    if getattr(chk, "_vmm_busy", False):
        return False

    want = chk.get_active()
    if want == (addr in state_pci_addrs(vm)):
        return True

    chk._vmm_busy = True
    chk._vmm_reverting = True
    chk.set_active(not want)
    chk._vmm_reverting = False
    chk.set_sensitive(False)

    ok = False
    try:
        if not _apply_toggle(vm, addr, want):
            if vm.is_active():
                if want:
                    raise RuntimeError(_(
                        "The device did not appear in the running VM."))
                raise RuntimeError(_(
                    "The guest did not release the device, so it is still "
                    "attached. It must support PCI hotplug and must not be "
                    "holding the device (for example an NVIDIA driver in "
                    "use). Unload the driver in the guest and try again."))
            raise RuntimeError(_(
                "The saved VM configuration was not updated."))
        ok = True
    except Exception as e:
        msg = str(e)
        if "Permission denied" in msg:
            msg += "\n\n" + _(
                "Session mode (qemu:///session) runs as your user and "
                "cannot unbind a host driver. Pre-bind the device to "
                "vfio-pci, or use qemu:///system.")
        err.show_err(_("Error redirecting PCI device: %s") % msg)
    finally:
        chk._vmm_reverting = True
        chk.set_active(want if ok else not want)
        chk._vmm_reverting = False
        chk.set_sensitive(True)
        chk._vmm_busy = False

    return ok


def device_tooltip(xmlobj, vm):
    bits = []
    if xmlobj is not None and xmlobj.driver_name:
        bits.append(_("Host driver: %(driver)s") %
                    {"driver": xmlobj.driver_name})
    group = nodedev_iommu_group(xmlobj) if xmlobj is not None else None
    if group is not None:
        bits.append(_("IOMMU group %(group)s") % {"group": group})
    if xmlobj is not None and xmlobj.pci_class:
        bits.append(_("class %(cls)s") % {"cls": xmlobj.pci_class})

    base = pci_class_base(xmlobj) if xmlobj is not None else None
    if base == 0x02:
        bits.append(_("Network controller: redirecting it removes host "
                      "networking until the guest releases it."))
    elif base == 0x01:
        bits.append(_("Storage controller: only redirect it if no host "
                      "filesystem or swap is using it."))
    elif base == 0x0c and is_usb_host(xmlobj):
        bits.append(_("USB controller: redirecting it moves every device "
                      "on this controller."))

    if not vm.is_active():
        bits.append(_("The VM is stopped: this changes its saved "
                      "configuration."))
    return "\n".join(bits)


class _InlineErr:
    """Inline error sink; a modal would stack over the dialog."""

    def __init__(self, infobar, label):
        self._infobar = infobar
        self._label = label

    def show_err(self, msg):
        self._label.set_text(msg)
        self._infobar.set_revealed(True)

    def clear(self):
        self._infobar.set_revealed(False)


def _build_inline_err():
    """Bounded inline error bar: never widens the dialog."""
    infobar = Gtk.InfoBar()
    infobar.set_message_type(Gtk.MessageType.ERROR)
    infobar.set_show_close_button(True)
    infobar.set_revealed(False)

    scroll = Gtk.ScrolledWindow()
    scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scroll.set_propagate_natural_width(False)
    scroll.set_propagate_natural_height(True)
    scroll.set_min_content_height(40)
    scroll.set_max_content_height(90)
    scroll.set_shadow_type(Gtk.ShadowType.NONE)

    label = Gtk.Label()
    label.set_line_wrap(True)
    label.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
    label.set_selectable(True)
    label.set_xalign(0)
    label.set_yalign(0)
    label.set_hexpand(True)
    label.set_max_width_chars(72)
    scroll.add(label)

    infobar.get_content_area().pack_start(scroll, True, True, 0)
    infobar.connect("response", lambda bar, _resp: bar.set_revealed(False))
    return infobar, _InlineErr(infobar, label)


def _dialog_toggled(chk, vm, inerr, addr):
    # set_active() during a revert emits "toggled"; keep the bar.
    if not getattr(chk, "_vmm_busy", False):
        inerr.clear()
    toggle_device(chk, vm, inerr, addr)


def show_pci_redirect_dialog(vm, parent, err):

    dialog = Gtk.Dialog(title="", parent=parent)
    dialog.set_modal(True)
    dialog.set_resizable(False)
    dialog.set_default_size(620, -1)

    content = dialog.get_content_area()
    content.set_spacing(6)
    content.set_border_width(6)

    heading = Gtk.Label()
    heading.set_markup("<b>%s</b>" % GLib.markup_escape_text(
        _("Select PCI devices for redirection")))
    heading.set_halign(Gtk.Align.CENTER)
    content.pack_start(heading, False, False, 0)

    scroll = Gtk.ScrolledWindow()
    scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scroll.set_propagate_natural_height(True)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
    box.set_border_width(6)
    scroll.add(box)
    content.pack_start(scroll, True, True, 0)

    infobar, inerr = _build_inline_err()
    content.pack_start(infobar, False, False, 0)

    attached = set(state_pci_addrs(vm))
    visible = _classify_pci_devices(vm, attached)[0]

    def _row(xmlobj, addr):
        chk = Gtk.CheckButton(
            label=device_label(xmlobj, detailed=True))
        chk.set_active(addr in attached)
        chk.set_tooltip_text(device_tooltip(xmlobj, vm))
        chk.connect("toggled", _dialog_toggled, vm, inerr, addr)
        box.pack_start(chk, False, False, 0)
        return chk

    useful = []
    other = []
    for dev in visible:
        if is_useful_class(dev.xmlobj):
            useful.append(dev)
        else:
            other.append(dev)

    useful_rows = []
    for dev in useful:
        useful_rows.append(
            _row(dev.xmlobj, nodedev_pci_addr(dev.xmlobj)))

    if other:
        reveal_other = Gtk.CheckButton(label=_("Show other PCI devices"))
        reveal_other.set_tooltip_text(_(
            "Reveals chipset and management functions. They are rarely "
            "useful in a guest."))
        box.pack_start(reveal_other, False, False, 0)
        other_rows = []

        def _toggle_other(btn, other=other, rows=other_rows):
            if btn.get_active():
                for dev in other:
                    chk = _row(dev.xmlobj,
                               nodedev_pci_addr(dev.xmlobj))
                    rows.append(chk)
                    chk.show()
            else:
                for chk in rows:
                    chk.destroy()
                rows.clear()

        reveal_other.connect("toggled", _toggle_other)

    if not visible:
        box.pack_start(
            Gtk.Label(label=_("No PCI devices found")),
            False, False, 0)

    dialog.add_button(Gtk.STOCK_CLOSE, Gtk.ResponseType.CLOSE)
    dialog.get_action_area().set_layout(Gtk.ButtonBoxStyle.EXPAND)
    dialog.set_default_response(Gtk.ResponseType.CLOSE)

    content.show_all()

    # Cap through "Show other" + one row, then scroll.
    if useful_rows:
        cap_rows = len(useful_rows) + (1 if other else 0) + 1
        _min, row_height = useful_rows[0].get_preferred_height()
        scroll.set_max_content_height((row_height + 4) * cap_rows)

    dialog.run()
    dialog.destroy()


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
