/* Force-included for koffi on OHOS: OHOS musl (NDK 26.0.0.105) declares no statx() and no
 * STATX_* constants, but the kernel syscall exists (SYS_statx = 291). Provide the glibc/musl-1.2.5 API. */
#pragma once
#if defined(__OHOS__) && defined(__cplusplus)
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdint.h>
#ifndef STATX_TYPE
#define STATX_TYPE 0x00000001U
#define STATX_MODE 0x00000002U
#define STATX_NLINK 0x00000004U
#define STATX_UID 0x00000008U
#define STATX_GID 0x00000010U
#define STATX_ATIME 0x00000020U
#define STATX_MTIME 0x00000040U
#define STATX_CTIME 0x00000080U
#define STATX_INO 0x00000100U
#define STATX_SIZE 0x00000200U
#define STATX_BLOCKS 0x00000400U
#define STATX_BASIC_STATS 0x000007ffU
#define STATX_BTIME 0x00000800U
struct statx_timestamp { int64_t tv_sec; uint32_t tv_nsec, __pad; };
struct statx {
  uint32_t stx_mask, stx_blksize; uint64_t stx_attributes;
  uint32_t stx_nlink, stx_uid, stx_gid; uint16_t stx_mode, __pad0[1];
  uint64_t stx_ino, stx_size, stx_blocks, stx_attributes_mask;
  struct statx_timestamp stx_atime, stx_btime, stx_ctime, stx_mtime;
  uint32_t stx_rdev_major, stx_rdev_minor, stx_dev_major, stx_dev_minor;
  uint64_t __pad1[14];
};
static inline int statx(int dirfd, const char *path, int flags, unsigned mask, struct statx *buf) {
  return (int)syscall(SYS_statx, dirfd, path, flags, mask, buf);
}
#endif
#endif
