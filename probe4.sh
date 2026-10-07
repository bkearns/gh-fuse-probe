#!/usr/bin/env bash
# Can a HOSTED ubuntu-latest runner inject a metadata/directory-entry fault
# (the window E' hazard LazyFS cannot express)? Test dm-flakey + dm-log-writes
# on a loopback ext4 via sudo.
set -uo pipefail
echo "=== sudo? ==="; sudo -n true 2>&1 && echo "passwordless sudo YES" || echo "sudo needs password"
echo "=== tools ==="; which losetup dmsetup mkfs.ext4 mount 2>&1
echo "=== modules ==="; sudo modprobe dm_flakey 2>&1 && echo "dm_flakey loaded" || echo "dm_flakey FAILED"
sudo modprobe dm_log_writes 2>&1 && echo "dm_log_writes loaded" || echo "dm_log_writes FAILED"
grep -E "dm_flakey|dm_log_writes" /proc/modules 2>&1 | awk '{print $1}'

echo "=== loopback file ==="
dd if=/dev/zero of=/tmp/disk.img bs=1M count=64 status=none && echo "created 64M img"
LD=$(sudo losetup --find --show /tmp/disk.img); echo "loopdev=$LD"
sudo mkfs.ext4 -q -F "$LD" && echo "mkfs ok"

echo "=== dm-flakey target: drop writes after N seconds ==="
sudo dmsetup create flk --table "0 $(sudo blockdev --getsz $LD) flakey $LD 0 1000000 1" 2>&1 && echo "flakey created" || echo "flakey FAILED"
ls -l /dev/mapper/flk 2>&1

echo "=== mount it, write+fsync a dir entry, then crash (drop writes) ==="
sudo mkdir -p /mnt/flk
sudo mount /dev/mapper/flk /mnt/flk 2>&1 && echo "mounted" || echo "mount FAILED"
sudo bash -c 'mkdir -p /mnt/flk/d; echo hi > /mnt/flk/d/orig; sync'
# rename without fsync, then flip flakey to drop all writes (simulated power loss)
sudo bash -c 'mv /mnt/flk/d/orig /mnt/flk/d/new'
sudo dmsetup suspend flk && sudo dmsetup reload flk --table "0 $(sudo blockdev --getsz $LD) error" && sudo dmsetup resume flk
echo "=== remount clean (reload real table) ==="
sudo umount /mnt/flk 2>&1 || sudo umount -l /mnt/flk 2>&1
sudo dmsetup suspend flk && sudo dmsetup reload flk --table "0 $(sudo blockdev --getsz $LD) flakey $LD 0 1000000 1" && sudo dmsetup resume flk
sudo mount /dev/mapper/flk /mnt/flk 2>&1 && echo "remounted"
echo "--- post-crash contents of /mnt/flk/d:"; sudo ls -la /mnt/flk/d 2>&1
sudo umount /mnt/flk 2>/dev/null; sudo dmsetup remove flk 2>/dev/null; sudo losetup -d "$LD" 2>/dev/null
echo "=== PROBE4 DONE ==="
