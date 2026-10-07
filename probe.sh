#!/usr/bin/env bash
# Empirical FUSE/LazyFS capability probe for ubuntu-latest.
set -uo pipefail
echo "=== 0. environment ==="
uname -a; cat /etc/os-release | head -3; id

echo
echo "=== 1. /dev/fuse present? ==="
ls -l /dev/fuse 2>&1
stat -f -c '%F' /dev/fuse 2>&1

echo
echo "=== 2. fuse3 userspace present? ==="
which fusermount fusermount3 mount.fuse 2>&1

echo
echo "=== 3. can an UNPRIVILEGED process mount FUSE? (no sudo) ==="
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq fuse3 libfuse3-dev pkg-config cmake g++ >/dev/null 2>&1
echo "apt rc=$?"
echo 'user_allow_other' | sudo tee -a /etc/fuse.conf >/dev/null 2>&1; echo "/etc/fuse.conf tail: $(tail -1 /etc/fuse.conf)"

mkdir -p /tmp/backing /tmp/mnt
cat > /tmp/hello.c <<'CEOF'
#define FUSE_USE_VERSION 31
#include <fuse3/fuse.h>
#include <string.h>
#include <errno.h>
static int h_getattr(const char *p, struct stat *st, struct fuse_file_info *fi){(void)p;(void)fi;memset(st,0,sizeof *st);st->st_mode=S_IFDIR|0755;st->st_nlink=2;return 0;}
static int h_readdir(const char*p,void*b,fuse_fill_dir_t f,off_t o,struct fuse_file_info*fi,enum fuse_readdir_flags fl){(void)p;(void)o;(void)fi;(void)fl;f(b,".",NULL,0,0);f(b,"..",NULL,0,0);return 0;}
static struct fuse_operations ops={.getattr=h_getattr,.readdir=h_readdir};
int main(int c,char**v){return fuse_main(c,v,&ops,NULL);}
CEOF
gcc -O0 /tmp/hello.c -o /tmp/hello $(pkg-config --cflags --libs fuse3) 2>&1
echo "gcc rc=$?"
# unprivileged mount (fusermount is setuid root; the invoking user stays unprivileged)
/tmp/hello -f /tmp/mnt &
HP=$!
sleep 2
echo "--- mount table entry:"
grep "/tmp/mnt" /proc/mounts 2>&1 || echo "NOT IN /proc/mounts"
echo "--- ls mountpoint:"
ls -a /tmp/mnt 2>&1
echo "--- unprivileged unmount via fusermount3:"
fusermount3 -u /tmp/mnt 2>&1; echo "umount rc=$?"
grep "/tmp/mnt" /proc/mounts 2>&1 || echo "unmounted OK"
kill $HP 2>/dev/null

echo
echo "=== 4. build LazyFS from pinned release 0.3.1 ==="
cd /tmp
git clone --depth 1 --branch 0.3.1 https://github.com/dsrhaslab/lazyfs.git 2>&1 | tail -2
cd lazyfs/libs/libpcache && ./build.sh >/tmp/pc.log 2>&1; echo "libpcache rc=$?"; tail -3 /tmp/pc.log
cd /tmp/lazyfs/lazyfs && ./build.sh >/tmp/lz.log 2>&1; echo "lazyfs rc=$?"; tail -5 /tmp/lz.log

echo
echo "=== 5. mount LazyFS, drop un-fsynced writes, remount clean ==="
cat > /tmp/lazyfs.toml <<'TEOF'
[faults]
fifo_path="/tmp/faults.fifo"
[cache]
apply_eviction=false
[cache.simple]
custom_size="0.5GB"
blocks_per_page=1
[file system]
log_all_operations=true
logfile="/tmp/lazyfs.log"
TEOF
mkdir -p /tmp/lzroot /tmp/lzmnt
cd /tmp/lazyfs/lazyfs
./scripts/mount-lazyfs.sh -c /tmp/lazyfs.toml -m /tmp/lzmnt -r /tmp/lzroot -s 2>&1 | tail -5
sleep 2
grep "/tmp/lzmnt" /proc/mounts 2>&1 || echo "LazyFS NOT MOUNTED"
mkdir -p /tmp/lzmnt/tbl
# write a file, fsync it, then write an UN-fsynced file
echo DURABLE > /tmp/lzmnt/tbl/durable.txt
sync
echo "--- durable.txt written+synced"
echo UNFSYNCED > /tmp/lzmnt/tbl/lost.txt
echo "--- lost.txt written, NOT synced"
echo "--- trigger clear-cache (drop un-fsynced data):"
echo "lazyfs::clear-cache" > /tmp/faults.fifo 2>&1; echo "clear-cache rc=$?"
sleep 1
echo "--- after clear: backing store contents (root):"
find /tmp/lzroot -type f 2>&1
echo "--- after clear: mountpoint still shows:"
ls /tmp/lzmnt/tbl 2>&1
echo "--- unmount + remount clean:"
./scripts/umount-lazyfs.sh -m /tmp/lzmnt/ 2>&1 | tail -2
sleep 1
./scripts/mount-lazyfs.sh -c /tmp/lazyfs.toml -m /tmp/lzmnt -r /tmp/lzroot -s 2>&1 | tail -2
sleep 2
echo "--- post-remount: which files exist?"
ls -la /tmp/lzmnt/tbl 2>&1
echo "--- durable.txt content:"; cat /tmp/lzmnt/tbl/durable.txt 2>&1
echo "--- lost.txt content:"; cat /tmp/lzmnt/tbl/lost.txt 2>&1 || echo "lost.txt ABSENT (un-fsynced write dropped) as intended"
./scripts/umount-lazyfs.sh -m /tmp/lzmnt/ 2>&1 | tail -1
echo
echo "=== PROBE DONE ==="
