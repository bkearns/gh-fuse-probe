#!/usr/bin/env bash
# Faithful negative-control experiment for window E':
# mirror engine.rs promote+evict under LazyFS, in BOTH the fixed (dir fsync
# after the promote rename) and unfixed (no dir fsync) variants, and crash.
# If both variants leave the promoted output discoverable, a LazyFS crash
# cannot distinguish the fix from the bug -> the test cannot fail -> vacuous.
set -uo pipefail
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq fuse3 libfuse3-dev pkg-config cmake g++ >/dev/null 2>&1
sudo sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf
cd /tmp && rm -rf lazyfs
git clone --depth 1 --branch 0.3.1 https://github.com/dsrhaslab/lazyfs.git >/dev/null 2>&1
( cd /tmp/lazyfs/libs/libpcache && ./build.sh >/tmp/pc.log 2>&1 )
( cd /tmp/lazyfs/lazyfs && ./build.sh >/tmp/lz.log 2>&1 )
echo "build done"

run_variant () {
  local variant="$1"   # "fixed" or "unfixed"
  local script="$2"
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
     -o allow_other -o modules=subdir -o subdir=/tmp/lzroot -s -f >/tmp/lz.$variant.out 2>&1 &
  local P=$!
  for i in $(seq 1 30); do grep -q "/tmp/lzmnt" /proc/mounts && break; sleep 0.5; done
  grep -q "/tmp/lzmnt" /proc/mounts || { echo "  [$variant] MOUNT FAILED"; kill $P 2>/dev/null; return; }
  python3 -c "$script"
  # simulate a crash: kill LazyFS (never unmount cleanly) then remount
  kill -9 $P 2>/dev/null; wait $P 2>/dev/null
  fusermount3 -uz /tmp/lzmnt 2>/dev/null
  rm -f /tmp/faults.fifo; sleep 0.5
  /tmp/lazyfs/lazyfs/build/lazyfs /tmp/lzmnt --config-path /tmp/lazyfs.toml \
     -o allow_other -o modules=subdir -o subdir=/tmp/lzroot -s -f >/tmp/lz.$variant.out2 2>&1 &
  local P2=$!
  for i in $(seq 1 30); do grep -q "/tmp/lzmnt" /proc/mounts && break; sleep 0.5; done
  echo "  [$variant] POST-CRASH sstables/test_table contents:"
  ls -1 /tmp/lzmnt/sstables/test_table 2>/dev/null | sed 's/^/      /' | head -20
  # discoverable generations = names with -Data.db (flat) or dirs holding Data.db
  local out_gen in_gen
  out_gen=$(find /tmp/lzmnt/sstables/test_table -maxdepth 2 -name '*-Data.db' 2>/dev/null | grep -c .
  )
  echo "      => discoverable -Data.db files: $out_gen"
  fusermount3 -u /tmp/lzmnt 2>/dev/null; kill $P2 2>/dev/null; wait $P2 2>/dev/null
}

# the promote+evict shape, faithful to engine.rs
# fixed:   rename output -> fsync table dir -> retire inputs (rename/.retired, fsync, rm, fsync)
# unfixed: rename output -> retire inputs (NO dir fsync first)
SCRIPT='
import os
def fsd(p):
    fd=os.open(p,os.O_DIRECTORY); os.fsync(fd); os.close(fd)
def mkf(p):
    f=open(p,"wb"); f.write(b"SSTABLE-DATA-"*4); f.flush(); os.fsync(f.fileno()); f.close()
tbl="/tmp/lzmnt/sstables/test_table"
os.makedirs(tbl,exist_ok=True); fsd("/tmp/lzmnt"); fsd("/tmp/lzmnt/sstables"); fsd(tbl)
# two durable input generations (as after two flushes)
for g in ("1","2"):
    mkf(os.path.join(tbl,"%s-Data.db"%g)); mkf(os.path.join(tbl,"%s-TOC.txt"%g))
fsd(tbl)
import os as _o
FIXED = _o.environ.get("VARIANT","fixed")=="fixed"
# promote: staged dir already holds generation 3 (content fsynced by flush_files)
stg=os.path.join(tbl,".staging-3"); os.makedirs(stg,exist_ok=True)
mkf(os.path.join(stg,"3-Data.db")); mkf(os.path.join(stg,"3-TOC.txt")); fsd(stg)
os.rename(stg, os.path.join(tbl,"3"))
if FIXED:
    fsd(tbl)                      # <-- the fix: fsync_promoted_directory
# evict inputs (retire_inner: rename -> .retired, fsync, remove, fsync)
for g in ("1","2"):
    os.rename(os.path.join(tbl,"%s-Data.db"%g), os.path.join(tbl,".retired-%s"%g+"-Data.db"))
fsd(tbl)
for r in os.listdir(tbl):
    if r.startswith(".retired-"):
        p=os.path.join(tbl,r)
        if os.path.isfile(p): os.unlink(p)
fsd(tbl)
print("  promote+evict done (VARIANT=%s)"%FIXED)
'
echo "=== VARIANT=fixed ==="
VARIANT=fixed run_variant fixed "$SCRIPT"
echo "=== VARIANT=unfixed ==="
VARIANT=unfixed run_variant unfixed "$SCRIPT"
echo "=== PROBE5 DONE ==="
