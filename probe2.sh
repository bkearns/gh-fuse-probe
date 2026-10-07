#!/usr/bin/env bash
# Determine LazyFS metadata semantics for the promote/evict invariant:
# does an un-fsynced *rename* survive a clear-cache when a later dir fsync
# happens, and do unlinks persist without an explicit dir fsync?
set -uo pipefail
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq fuse3 libfuse3-dev pkg-config cmake g++ >/dev/null 2>&1
sudo sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
cd /tmp && rm -rf lazyfs
git clone --depth 1 --branch 0.3.1 https://github.com/dsrhaslab/lazyfs.git >/dev/null 2>&1
( cd /tmp/lazyfs/libs/libpcache && ./build.sh >/tmp/pc.log 2>&1 )
( cd /tmp/lazyfs/lazyfs && ./build.sh >/tmp/lz.log 2>&1 )
echo "build done"

run_case () {
  local name="$1"; shift
  local script="$1"
  rm -rf /tmp/lzroot /tmp/lzmnt; rm -f /tmp/faults.fifo
  mkdir -p /tmp/lzroot /tmp/lzmnt
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
  /tmp/lazyfs/lazyfs/build/lazyfs /tmp/lzmnt --config-path /tmp/lazyfs.toml \
     -o allow_other -o modules=subdir -o subdir=/tmp/lzroot -s -f >/tmp/lz.$name.out 2>&1 &
  local P=$!
  for i in $(seq 1 30); do grep -q "/tmp/lzmnt" /proc/mounts && break; sleep 0.5; done
  grep -q "/tmp/lzmnt" /proc/mounts || { echo "  MOUNT FAILED"; kill $P 2>/dev/null; return; }
  python3 -c "$script"
  python3 - <<'PY'
import os
fd=os.open("/tmp/faults.fifo", os.O_WRONLY|os.O_NONBLOCK)
os.write(fd, b"lazyfs::clear-cache\n"); os.close(fd)
PY
  sleep 1
  # unmount (kill FS to force clean remount of backing store)
  fusermount3 -u /tmp/lzmnt 2>/dev/null; kill $P 2>/dev/null; wait $P 2>/dev/null
  rm -f /tmp/faults.fifo; sync; sleep 0.5
  echo "  [$name] surviving files (recursive):"
  find /tmp/lzroot -type f -printf '    %P  [%s bytes]\n' 2>/dev/null | sort
}

echo "=== CASE A: rename with NO fsync, no later fsync (dirent durability of rename) ==="
A='
import os
os.makedirs("/tmp/lzmnt/d",exist_ok=True)
f=open("/tmp/lzmnt/d/A","wb");f.write(b"input-data");f.flush();os.fsync(f.fileno());f.close()
fd=os.open("/tmp/lzmnt/d",os.O_DIRECTORY);os.fsync(fd);os.close(fd)     # durable: A
os.rename("/tmp/lzmnt/d/A","/tmp/lzmnt/d/B")                            # promote rename, NOT fsynced
print("  rename A->B, no fsync after")
'
run_case A "$A"

echo "=== CASE B: rename, THEN a dir fsync (does the later fsync flush the rename?) ==="
B='
import os
os.makedirs("/tmp/lzmnt/d",exist_ok=True)
f=open("/tmp/lzmnt/d/A","wb");f.write(b"input-data");f.flush();os.fsync(f.fileno());f.close()
fd=os.open("/tmp/lzmnt/d",os.O_DIRECTORY);os.fsync(fd);os.close(fd)
os.rename("/tmp/lzmnt/d/A","/tmp/lzmnt/d/B")
fd=os.open("/tmp/lzmnt/d",os.O_DIRECTORY);os.fsync(fd);os.close(fd)     # later dir fsync
print("  rename A->B, then dir fsync")
'
run_case B "$B"

echo "=== CASE C: unlink WITHOUT a later dir fsync (does unlink persist?) ==="
C='
import os
os.makedirs("/tmp/lzmnt/d",exist_ok=True)
for n in ("A","B"):
    f=open("/tmp/lzmnt/d/"+n,"wb");f.write(b"x"+n.encode());f.flush();os.fsync(f.fileno());f.close()
fd=os.open("/tmp/lzmnt/d",os.O_DIRECTORY);os.fsync(fd);os.close(fd)     # durable: A and B
os.unlink("/tmp/lzmnt/d/A")                                             # unlink, NOT fsynced
print("  unlink A, no fsync after")
'
run_case C "$C"

echo "=== CASE D: rename(un-fsynced) + later unlink of OTHER file + dir fsync (the real promote/evict shape) ==="
D='
import os
os.makedirs("/tmp/lzmnt/d",exist_ok=True)
for n in ("IN1","IN2"):
    f=open("/tmp/lzmnt/d/"+n,"wb");f.write(b"input-"+n.encode());f.flush();os.fsync(f.fileno());f.close()
fd=os.open("/tmp/lzmnt/d",os.O_DIRECTORY);os.fsync(fd);os.close(fd)     # durable: 2 inputs
os.rename("/tmp/lzmnt/d/IN1","/tmp/lzmnt/d/OUT")                        # promote rename (unfsynced = OLD code)
# retire inputs: rename to .retired, fsync dir, remove, fsync dir  (mimics retire_inner)
os.rename("/tmp/lzmnt/d/IN2","/tmp/lzmnt/d/.retired-IN2")
fd=os.open("/tmp/lzmnt/d",os.O_DIRECTORY);os.fsync(fd);os.close(fd)
print("  promote rename (unfsynced) + retire rename + dir fsync")
'
run_case D "$D"
echo "=== PROBE2 DONE ==="
