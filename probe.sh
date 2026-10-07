#!/usr/bin/env bash
# Empirical FUSE/LazyFS capability probe for ubuntu-latest.
set -uo pipefail
echo "=== 0. environment ==="
uname -a; grep PRETTY /etc/os-release; id

echo
echo "=== 1. /dev/fuse ==="
ls -l /dev/fuse
echo
echo "=== 2. fuse3 userspace ==="
which fusermount fusermount3 mount.fuse
echo
echo "=== 3. install deps (sudo) ==="
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq fuse3 libfuse3-dev pkg-config cmake g++ >/dev/null 2>&1
echo "apt rc=$?"
grep -q user_allow_other /etc/fuse.conf || echo 'user_allow_other' | sudo tee -a /etc/fuse.conf >/dev/null
echo "fuse.conf allow_other: $(grep user_allow_other /etc/fuse.conf)"

echo
echo "=== 4. build LazyFS release 0.3.1 ==="
cd /tmp
git clone --depth 1 --branch 0.3.1 https://github.com/dsrhaslab/lazyfs.git 2>&1 | tail -1
cd /tmp/lazyfs/libs/libpcache && ./build.sh >/tmp/pc.log 2>&1; echo "libpcache rc=$?"
cd /tmp/lazyfs/lazyfs && ./build.sh >/tmp/lz.log 2>&1; echo "lazyfs rc=$?"; ls -l /tmp/lazyfs/lazyfs/build/lazyfs 2>&1

echo
echo "=== 5. correct config key is [filesystem] ==="
cat > /tmp/lazyfs.toml <<'TEOF'
[faults]
fifo_path="/tmp/faults.fifo"
[cache]
apply_eviction=false
[cache.simple]
custom_size="0.5GB"
blocks_per_page=1
[filesystem]
log_all_operations=false
logfile="/tmp/lazyfs.log"
TEOF
mkdir -p /tmp/lzroot /tmp/lzmnt
cd /tmp/lazyfs/lazyfs
./scripts/mount-lazyfs.sh -c /tmp/lazyfs.toml -m /tmp/lzmnt -r /tmp/lzroot -s 2>&1 | tail -3
sleep 2
grep "/tmp/lzmnt" /proc/mounts && echo "MOUNTED" || echo "LazyFS NOT MOUNTED"

echo
echo "=== 6. fault injection: durable vs un-fsynced ==="
mkdir -p /tmp/lzmnt/tbl
python3 - <<'PY'
import os,fcntl
d="/tmp/lzmnt/tbl"
# durable: write then fsync the file AND the directory entry
f=open(os.path.join(d,"durable.txt"),"wb"); f.write(b"DURABLE\n"); f.flush(); os.fsync(f.fileno()); f.close()
dfd=os.open(d,os.O_DIRECTORY); os.fsync(dfd); os.close(dfd)
# un-fsynced: write, no fsync at all
g=open(os.path.join(d,"lost.txt"),"wb"); g.write(b"UNFSYNCED\n"); g.flush(); g.close()
print("wrote durable.txt (fsynced) and lost.txt (not fsynced)")
PY
echo "--- before crash, mountpoint:"; ls /tmp/lzmnt/tbl
echo "--- trigger clear-cache (drops un-fsynced data):"
echo "lazyfs::clear-cache" > /tmp/faults.fifo; echo "clear-cache rc=$?"
sleep 1
echo "--- after clear, BACKING STORE (/tmp/lzroot):"; find /tmp/lzroot -type f | sort
echo "--- after clear, mount still shows (page cache):"; ls /tmp/lzmnt/tbl | sort

echo
echo "=== 7. unmount + remount clean (simulated power cycle) ==="
./scripts/umount-lazyfs.sh -m /tmp/lzmnt/ 2>&1 | tail -1
sleep 1
./scripts/mount-lazyfs.sh -c /tmp/lazyfs.toml -m /tmp/lzmnt -r /tmp/lzroot -s 2>&1 | tail -1
sleep 2
echo "--- POST-REMOUNT mountpoint contents:"
ls -la /tmp/lzmnt/tbl
echo "--- durable.txt exists? "; test -f /tmp/lzmnt/tbl/durable.txt && echo YES && cat /tmp/lzmnt/tbl/durable.txt || echo NO
echo "--- lost.txt exists?   "; test -f /tmp/lzmnt/tbl/lost.txt && echo "YES (fault did NOT drop it)" && cat /tmp/lzmnt/tbl/lost.txt || echo "NO (un-fsynced write correctly dropped)"
./scripts/umount-lazyfs.sh -m /tmp/lzmnt/ 2>&1 | tail -1
echo
echo "=== PROBE DONE ==="
