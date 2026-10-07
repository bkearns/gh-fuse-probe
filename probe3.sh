#!/usr/bin/env bash
# Can LazyFS express "rename lost but unlink kept" (the window E' hazard)?
# Metadata durability, measured — with the mount root and `d` dirent made
# durable first so the measurement is not confounded by a lost parent dirent.
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
  local name="$1"; local script="$2"
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
  grep -q "/tmp/lzmnt" /proc/mounts || { echo "  [$name] MOUNT FAILED"; kill $P 2>/dev/null; return; }
  python3 -c "$script"
  python3 -c 'import os;fd=os.open("/tmp/faults.fifo",os.O_WRONLY|os.O_NONBLOCK);os.write(fd,b"lazyfs::clear-cache\n");os.close(fd)'
  sleep 1
  fusermount3 -u /tmp/lzmnt 2>/dev/null; kill $P 2>/dev/null; wait $P 2>/dev/null
  rm -f /tmp/faults.fifo; sync; sleep 0.5
  echo "  [$name] SURVIVORS:"
  find /tmp/lzroot -mindepth 1 -printf '    %P\n' 2>/dev/null | sort
}

DUR_ROOT='
import os
def fsync_dir(p):
    fd=os.open(p,os.O_DIRECTORY); os.fsync(fd); os.close(fd)
def mk(name,data="/tmp/lzmnt"):
    p=os.path.join(data,name); f=open(p,"wb"); f.write(b"X"*8); f.flush(); os.fsync(f.fileno()); f.close(); return p
'
echo "=== A: rename un-fsynced, NO later fsync ==="
run_case A "$DUR_ROOT
d='/tmp/lzmnt/d'; os.makedirs(d,exist_ok=True); fsync_dir('/tmp/lzmnt'); fsync_dir(d)
mk('d/A'); fsync_dir(d)
os.rename('/tmp/lzmnt/d/A','/tmp/lzmnt/d/B')
print('  wrote durable A, rename A->B (unfsynced)')"

echo "=== B: rename THEN dir fsync ==="
run_case B "$DUR_ROOT
d='/tmp/lzmnt/d'; os.makedirs(d,exist_ok=True); fsync_dir('/tmp/lzmnt'); fsync_dir(d)
mk('d/A'); fsync_dir(d)
os.rename('/tmp/lzmnt/d/A','/tmp/lzmnt/d/B'); fsync_dir(d)
print('  wrote durable A, rename A->B, fsync dir')"

echo "=== C: unlink with NO later dir fsync ==="
run_case C "$DUR_ROOT
d='/tmp/lzmnt/d'; os.makedirs(d,exist_ok=True); fsync_dir('/tmp/lzmnt'); fsync_dir(d)
mk('d/A'); fsync_dir(d)
os.unlink('/tmp/lzmnt/d/A')
print('  wrote durable A, unlink A (unfsynced)')"

echo "=== E: rename(unfsynced) + unlink OTHER(unfsynced), same dir, no intervening fsync [the 'neither' shape] ==="
run_case E "$DUR_ROOT
d='/tmp/lzmnt/d'; os.makedirs(d,exist_ok=True); fsync_dir('/tmp/lzmnt'); fsync_dir(d)
mk('d/IN1'); mk('d/IN2'); fsync_dir(d)
os.rename('/tmp/lzmnt/d/IN1','/tmp/lzmnt/d/OUT')     # promote rename, unfsynced
os.unlink('/tmp/lzmnt/d/IN2')                        # evict input, unfsynced
print('  rename IN1->OUT (unfsynced) + unlink IN2 (unfsynced)')"

echo "=== F: FIX shape - rename THEN dir fsync THEN unlink(unfsynced) ==="
run_case F "$DUR_ROOT
d='/tmp/lzmnt/d'; os.makedirs(d,exist_ok=True); fsync_dir('/tmp/lzmnt'); fsync_dir(d)
mk('d/IN1'); mk('d/IN2'); fsync_dir(d)
os.rename('/tmp/lzmnt/d/IN1','/tmp/lzmnt/d/OUT'); fsync_dir(d)
os.unlink('/tmp/lzmnt/d/IN2')
print('  rename IN1->OUT + fsync dir + unlink IN2 (unfsynced)')"
echo "=== PROBE3 DONE ==="
