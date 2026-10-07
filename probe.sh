#!/usr/bin/env bash
# Empirical FUSE/LazyFS capability probe for ubuntu-latest.
# Every potentially-blocking operation is guarded so the probe cannot hang.
set -uo pipefail
echo "=== 0. environment ==="; uname -r; grep PRETTY /etc/os-release; id -un
echo "=== 1. /dev/fuse ==="; ls -l /dev/fuse
echo "=== 2. fuse userspace ==="; which fusermount fusermount3
echo "=== 3. deps ==="
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq fuse3 libfuse3-dev pkg-config cmake g++ >/dev/null 2>&1
echo "apt rc=$?"
sudo sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
grep -qx user_allow_other /etc/fuse.conf || echo 'user_allow_other' | sudo tee -a /etc/fuse.conf >/dev/null
echo "/etc/fuse.conf: $(grep -c '^user_allow_other' /etc/fuse.conf) active user_allow_other line(s)"
echo "=== 4. build LazyFS 0.3.1 ==="
cd /tmp && rm -rf lazyfs
git clone --depth 1 --branch 0.3.1 https://github.com/dsrhaslab/lazyfs.git >/dev/null 2>&1; echo "clone rc=$?"
( cd /tmp/lazyfs/libs/libpcache && ./build.sh >/tmp/pc.log 2>&1 ); echo "libpcache rc=$?"
( cd /tmp/lazyfs/lazyfs && ./build.sh >/tmp/lz.log 2>&1 ); echo "lazyfs rc=$?"
ls -l /tmp/lazyfs/lazyfs/build/lazyfs
echo "=== 5. mount LazyFS (foreground) ==="
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
mkdir -p /tmp/lzroot /tmp/lzmnt; rm -f /tmp/faults.fifo
/tmp/lazyfs/lazyfs/build/lazyfs /tmp/lzmnt --config-path /tmp/lazyfs.toml \
   -o allow_other -o modules=subdir -o subdir=/tmp/lzroot -s -f >/tmp/lazyfs.stdout 2>&1 &
LZPID=$!
for i in $(seq 1 30); do grep -q "/tmp/lzmnt" /proc/mounts && break; sleep 0.5; done
grep "/tmp/lzmnt" /proc/mounts && echo "MOUNTED" || { echo "NOT MOUNTED"; cat /tmp/lazyfs.stdout; exit 9; }
echo "fifo: $(ls -l /tmp/faults.fifo 2>&1)"
echo "=== 6. durable(fsynced) vs un-fsynced write, then clear-cache ==="
mkdir -p /tmp/lzmnt/tbl
python3 - <<'PY'
import os
d="/tmp/lzmnt/tbl"
f=open(os.path.join(d,"durable.txt"),"wb"); f.write(b"DURABLE\n"); f.flush(); os.fsync(f.fileno()); f.close()
fd=os.open(d,os.O_DIRECTORY); os.fsync(fd); os.close(fd)
g=open(os.path.join(d,"lost.txt"),"wb"); g.write(b"UNFSYNCED\n"); g.flush(); g.close()
print("wrote durable.txt (fsynced) + lost.txt (not fsynced)")
PY
ls /tmp/lzmnt/tbl
# open the FIFO non-blocking to avoid blocking at open() if LazyFS isn't reading
python3 - <<'PY'
import os
fd=os.open("/tmp/faults.fifo", os.O_WRONLY|os.O_NONBLOCK)
os.write(fd, b"lazyfs::clear-cache\n"); os.close(fd)
print("sent clear-cache")
PY
echo "clear rc=$?"; sleep 1
echo "BACKING STORE after clear:"; find /tmp/lzroot -type f | sort
echo "mount still shows:"; ls /tmp/lzmnt/tbl | sort
echo "=== 7. unmount + remount clean (power cycle) ==="
fusermount3 -u /tmp/lzmnt; echo "umount rc=$?"
kill $LZPID 2>/dev/null; wait $LZPID 2>/dev/null; rm -f /tmp/faults.fifo
echo "mount entry after umount: $(grep -c '/tmp/lzmnt' /proc/mounts)"
/tmp/lazyfs/lazyfs/build/lazyfs /tmp/lzmnt --config-path /tmp/lazyfs.toml \
   -o allow_other -o modules=subdir -o subdir=/tmp/lzroot -s -f >/tmp/lazyfs2.stdout 2>&1 &
LZPID2=$!
for i in $(seq 1 30); do grep -q "/tmp/lzmnt" /proc/mounts && break; sleep 0.5; done
grep -q "/tmp/lzmnt" /proc/mounts && echo "REMOUNTED" || echo "REMOUNT FAILED"
echo "POST-REMOUNT contents:"; ls -la /tmp/lzmnt/tbl 2>&1
echo "durable.txt: $(test -f /tmp/lzmnt/tbl/durable.txt && cat /tmp/lzmnt/tbl/durable.txt || echo ABSENT)"
echo "lost.txt:    $(test -f /tmp/lzmnt/tbl/lost.txt && cat /tmp/lzmnt/tbl/lost.txt || echo 'ABSENT -- un-fsynced write dropped')"
fusermount3 -u /tmp/lzmnt 2>&1; kill $LZPID2 2>/dev/null
echo "=== PROBE DONE ==="
