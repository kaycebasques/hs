/*
 * Minimal hermetic libtinfo.so.6 stub for GHC's terminfo/haskeline runtime.
 *
 * GHC deb10 bindists dynamically import exactly these 8 symbols (versioned
 * NCURSES6_TINFO_5.0.19991023) solely for interactive terminal queries in
 * haskeline/GHCi. Returning error/NULL causes terminfo to cleanly fall back
 * to dumb-terminal mode in hermetic Bazel build actions with zero host
 * libtinfo6 / ncurses dependencies.
 */
#include <stddef.h>

int setupterm(const char *term, int fildes, int *errret) {
    (void)term;
    (void)fildes;
    if (errret != NULL) {
        *errret = -1;
    }
    return -1;
}

int del_curterm(void *oterm) {
    (void)oterm;
    return 0;
}

void *set_curterm(void *nterm) {
    (void)nterm;
    return NULL;
}

int tigetflag(const char *capname) {
    (void)capname;
    return -1;
}

int tigetnum(const char *capname) {
    (void)capname;
    return -2;
}

char *tigetstr(const char *capname) {
    (void)capname;
    return (char *)-1;
}

char *tparm(const char *str, ...) {
    (void)str;
    return NULL;
}

int tputs(const char *str, int affcnt, int (*putc_fn)(int)) {
    (void)str;
    (void)affcnt;
    (void)putc_fn;
    return 0;
}
