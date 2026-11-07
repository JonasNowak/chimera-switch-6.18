#ifndef _MACOS_COMPAT_H
#define _MACOS_COMPAT_H

#ifndef _UUID_T
#define _UUID_T
#endif

#ifndef O_LARGEFILE
#define O_LARGEFILE 0
#endif

#include <sys/types.h>

static inline ssize_t copy_file_range(int fd_in, off_t *off_in, int fd_out,
                                      off_t *off_out, size_t len,
                                      unsigned int flags) {
  (void)fd_in;
  (void)off_in;
  (void)fd_out;
  (void)off_out;
  (void)len;
  (void)flags;
  return -1;
}

#endif /* _MACOS_COMPAT_H */
