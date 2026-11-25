/*
 * qemu-embed-shim.c - hold QEMU's X maps until virt-manager reparents.
 *
 * Active only when VIRTMGR_HIDE_WINDOW is set.  Swallows XMapWindow and
 * XMapSubwindows, then replays them when the root property
 * _VIRTMGR_GTK_UNLOCK names one of the swallowed windows AND that window
 * is no longer a direct child of the root window (i.e. virt-manager has
 * reparented it into the console viewport).  Replaying before reparenting
 * makes the QEMU window flash as a standalone toplevel.
 *
 * Reconstructed from the validated qemu-virtmgr-shim.so: the only
 * functional difference from the original source is the XQueryTree
 * reparent check in reader(); XCloseDisplay() is deliberately omitted.
 *
 * Build:
 *   cc -O2 -fPIC -shared -o qemu-embed-shim.so qemu-embed-shim.c \
 *      $(pkg-config --cflags --libs x11) -pthread
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xlib.h>

#define MAX_SWALLOWED 64
#define UNLOCK_ATOM "_VIRTMGR_GTK_UNLOCK"

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t reader_tid;
static Window swallowed[MAX_SWALLOWED];
static int nswallowed;
static int unlocked;
static int started;
static int (*real_XMapWindow)(Display *, Window);
static int (*real_XMapSubwindows)(Display *, Window);

static int hiding(void)
{
    return getenv("VIRTMGR_HIDE_WINDOW") != NULL;
}

static void *reader(void *arg)
{
    Display *d = XOpenDisplay(NULL);
    Atom atom;
    Window root;

    if (!d)
        return NULL;
    atom = XInternAtom(d, UNLOCK_ATOM, False);
    root = DefaultRootWindow(d);
    for (;;) {
        Atom type;
        int fmt;
        unsigned long n, after;
        unsigned char *p = NULL;
        Window w = 0;
        int matched = 0;

        pthread_mutex_lock(&lock);
        if (unlocked) {
            pthread_mutex_unlock(&lock);
            break;
        }
        pthread_mutex_unlock(&lock);

        if (XGetWindowProperty(d, root, atom, 0, 4, False, AnyPropertyType,
                               &type, &fmt, &n, &after, &p) == Success &&
            p && n > 0) {
            w = *(Window *)p;
            XFree(p);
            pthread_mutex_lock(&lock);
            for (int i = 0; i < nswallowed; i++) {
                if (w && swallowed[i] == w) {
                    matched = 1;
                    break;
                }
            }
            pthread_mutex_unlock(&lock);
        } else if (p) {
            XFree(p);
        }

        if (matched && w) {
            Window qroot = 0, parent = 0, *kids = NULL;
            unsigned int nkids = 0;

            if (XQueryTree(d, w, &qroot, &parent, &kids, &nkids)) {
                if (kids)
                    XFree(kids);
                /* Only replay once the window has been reparented out of
                 * the root by virt-manager's console viewer. */
                if (parent && parent != qroot) {
                    pthread_mutex_lock(&lock);
                    unlocked = 1;
                    pthread_mutex_unlock(&lock);
                    break;
                }
            }
        }
        usleep(50000);
    }

    {
        Window copy[MAX_SWALLOWED];
        int n;

        pthread_mutex_lock(&lock);
        n = nswallowed;
        memcpy(copy, swallowed, (size_t)n * sizeof(*copy));
        pthread_mutex_unlock(&lock);
        if (!real_XMapWindow)
            real_XMapWindow = dlsym(RTLD_NEXT, "XMapWindow");
        fprintf(stderr, "virtmgr-shim: unlock received, replaying %d swallowed map(s)\n", n);
        for (int i = 0; i < n; i++) {
            if (real_XMapWindow)
                real_XMapWindow(d, copy[i]);
            XFlush(d);
            fprintf(stderr, "virtmgr-shim: replayed map for window 0x%lx\n",
                    (unsigned long)copy[i]);
        }
        XFlush(d);
    }
    return NULL;
}

static int swallow(Display *d, Window w)
{
    int held = 0;

    if (!hiding() || !w)
        return 0;
    pthread_mutex_lock(&lock);
    if (!unlocked) {
        if (!started) {
            started = 1;
            pthread_create(&reader_tid, NULL, reader, NULL);
        }
        if (nswallowed < MAX_SWALLOWED)
            swallowed[nswallowed++] = w;
        held = 1;
    }
    pthread_mutex_unlock(&lock);
    return held;
}

int XMapWindow(Display *d, Window w)
{
    if (!real_XMapWindow)
        real_XMapWindow = dlsym(RTLD_NEXT, "XMapWindow");
    if (swallow(d, w)) {
        fprintf(stderr, "virtmgr-shim: swallowed XMapWindow(0x%lx)\n",
                (unsigned long)w);
        return 1;
    }
    return real_XMapWindow(d, w);
}

int XMapSubwindows(Display *d, Window w)
{
    if (!real_XMapSubwindows)
        real_XMapSubwindows = dlsym(RTLD_NEXT, "XMapSubwindows");
    if (swallow(d, w)) {
        fprintf(stderr, "virtmgr-shim: swallowed XMapSubwindows(0x%lx)\n",
                (unsigned long)w);
        return 1;
    }
    return real_XMapSubwindows(d, w);
}
