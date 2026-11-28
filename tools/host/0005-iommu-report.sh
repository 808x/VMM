#!/bin/bash
# VMM_PAGE: host
# VMM_FLAG: iommu-report
# VMM_NAME: IOMMU & VFIO readiness report
# VMM_DESC: Dump IOMMU groups, drivers and VFIO readiness into prefix/state; paste-ready.
# VMM_TICK: yes
# VMM_VAR: iommu_report
# VMM_SUDO: no
# VMM_PHASE: post
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/../lib.sh"

prefix=$(vmm_prefix)
section "iommu-report"

state="${VMM_STATE:-$prefix/state}"
mkdir -p "$state" 2>/dev/null || warn "cannot create $state"
report="$state/iommu-report.txt"

# The report must never fail the install: every probe is best-effort and
# absent sysfs entries are reported as findings, not errors.
: > "$report"

emit() {
    printf '%s\n' "$*" | tee -a "$report"
}

emit "VMM IOMMU & VFIO readiness report — $(date '+%Y-%m-%d %H:%M %Z')"
emit ""

# 1. Is the IOMMU even on?
iommu_on=0
if [ -d /sys/kernel/iommu_groups ] && [ -n "$(ls -A /sys/kernel/iommu_groups 2>/dev/null || true)" ]; then
    iommu_on=1
    emit "IOMMU: enabled ($(ls /sys/kernel/iommu_groups | wc -l) groups)"
else
    emit "IOMMU: NOT ACTIVE"
    emit "  - AMD: add 'iommu=pt' to the kernel command line"
    emit "  - Intel: add 'intel_iommu=on iommu=pt'"
    emit "  - Also enable VT-d/AMD-Vi in firmware setup"
fi

# 2. Vendor DMA remapping table, when boot messages are still available.
if command -v dmesg >/dev/null 2>&1; then
    dmar=$(dmesg 2>/dev/null | grep -m1 -E 'DMAR: IOMMU enabled|AMD-Vi: Found IOMMU' || true)
    [ -n "$dmar" ] && emit "firmware table: $dmar"
fi
emit ""

# 3. Groups: one line per group, devices with their current driver.
if [ "$iommu_on" = 1 ]; then
    emit "IOMMU groups (guest-assignable when a group holds one device):"
    for g in /sys/kernel/iommu_groups/*/devices/*; do
        gnum=${g#/sys/kernel/iommu_groups/}
        gnum=${gnum%%/*}
        dev=$(basename "$g")
        drv="none"
        [ -e "/sys/bus/pci/devices/$dev/driver" ] &&
            drv=$(basename "$(readlink -f "/sys/bus/pci/devices/$dev/driver")")
        name=$(cat "/sys/bus/pci/devices/$dev/vendor" "/sys/bus/pci/devices/$dev/device" 2>/dev/null |
            tr '\n' ' ' | awk '{ gsub(/^0x|0x/, ""); printf "0x%s:0x%s", $1, $2 }')
        printf '  group %-3s %-16s %-12s %s\n' "$gnum" "$dev" "$drv" "$name" | tee -a "$report"
    done
    emit ""

    # 4. Solo groups = the safe GPU/ NIC candidates r/VFIO asks about first.
    emit "solo groups (safe to hand to a guest):"
    for g in /sys/kernel/iommu_groups/*; do
        n=$(ls "$g/devices" 2>/dev/null | wc -l)
        [ "$n" = 1 ] || continue
        d=$(ls "$g/devices" | head -1)
        gnum=${g##*/}
        printf '  group %-3s %s\n' "$gnum" "$d" | tee -a "$report"
    done
else
    emit "IOMMU groups: none to list"
    emit ""
fi

# 5. vfio-pci state: module loaded, devices bound, and the VMM helper.
if [ -d /sys/module/vfio_pci ] || lsmod 2>/dev/null | grep -q '^vfio_pci'; then
    emit "vfio-pci: loaded"
    bound=0
    for d in /sys/bus/pci/drivers/vfio-pci/*:*/iommu_group; do
        [ -e "$d" ] || continue
        bdf=$(basename "$(dirname "$d")")
        grp=$(basename "$(readlink -f "$d" 2>/dev/null || true)")
        emit "  bound: $bdf (group ${grp:-?})"
        bound=$((bound + 1))
    done
    [ "$bound" = 0 ] && emit "  bound: no devices currently bound"
else
    emit "vfio-pci: not loaded"
fi
if [ -x /usr/local/sbin/vmm-vfio-ctl ]; then
    emit "helper: /usr/local/sbin/vmm-vfio-ctl installed (bind|unbind|status BDF)"
else
    emit "helper: vmm-vfio-ctl not installed (--tool=session-vfio adds it)"
fi
emit ""

# 6. Resizable BAR, when supported — the CPU-side check is lspci-only.
if command -v lspci >/dev/null 2>&1; then
    while IFS= read -r cap; do
        emit "ReBAR: $cap"
    done < <(lspci -vv 2>/dev/null | grep -B3 'Resizable BAR' | grep -E '^[0-9a-f:]{12}' | sort -u | head -5)
    [ -s "$report" ] && grep -q 'ReBAR' "$report" || emit "ReBAR: no controllers advertise it (fine; informational)"
else
    emit "ReBAR: lspci unavailable, skipped"
fi

emit ""
emit "full report: $report"
note "iommu-report: written $report"
