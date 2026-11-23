#define _DEFAULT_SOURCE
#include <sys/ioctl.h>

int rules_haskell_set_controlling_tty(int fd) {
    return ioctl(fd, TIOCSCTTY, 0);
}
