# qemu-embed-shim.so

Source: `qemu-embed-shim.c` (this directory).

No-op unless `VIRTMGR_HIDE_WINDOW` is set. It swallows `XMapWindow` and
`XMapSubwindows` (up to 64 windows), then replays them once the root
property `_VIRTMGR_GTK_UNLOCK` holds one of the swallowed window ids. The
virt-manager `reparent` patch sets that property after embedding.

Build (run by `install.sh` before the launchers are installed):

    cc -O2 -fPIC -shared -o qemu-embed-shim.so qemu-embed-shim.c \
       $(pkg-config --cflags --libs x11) -pthread

The build is reproducible with the reference toolchain:

    sha256 6e468e72e18de58b33d9b4d9f86a458576a53492c7f517a2f3c60d66432b5d8f

Inspect exports before trusting a replacement; both must be defined:

    nm -D --defined-only qemu-embed-shim.so
    # XMapSubwindows
    # XMapWindow
