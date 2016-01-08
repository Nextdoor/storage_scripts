# Simple /mnt Volume Creation Scripts
This repository contains a series of scripts used to quickly and easily set up
a `/mnt` volume on a cloud host in the simplest and most performant way possible.

The purpose of the scripts is to create a single large storage volume using the
devices available to the host OS quickly and easily. Storage can use either the
local _instance level_ storage, or _remote persistant storage_ -- or both.

## Cloud Providers
This code works with the following Cloud Providers:

* Amazon Web Services

## Ephemeral or Persistant?
Most cloud providers have a concept of ephemeral and persistant storage. The
setup script in this repo can either create a single volume with all of your
ephemeral storage, or it can reach out to the cloud provider and request
persistant storage.

## Block Cache
New Linux kernels have a feature built in now that allows them to use local
fast (_SSD_) storage as a read/write cache for slower (_EBS_) storage devices.
Using this feature on certain server types can greatly increase your read/write
speeds to your volume while making minimal reliability sacrifices.

Please see
https://evilpiepirate.org/git/linux-bcache.git/tree/Documentation/bcache.txt
for more information on how this works, how to tune it, etc.

# Usage
Simply start up your cloud host, download the scripts, and run the
[setup.sh](./setup.sh) script. The default behavior on a host will be to create
a single `/mnt` volume with all of the discovered available volumes on the
system.

### Usage with RightScale
Just as an example, if [RightScale](http://www.rightscale.com) is your cloud
provider, this simple RightScript can be used to pull down the storage scripts
and execute them on bootup safely.

```bash
#!/bin/bash
set -e

# Stupid Hack: To make the variables show up in the script-editing ui in
# rightscale, we need to list them here:
#  $STORAGE_SCRIPT_BRANCH, $STORAGE_RAID_LEVEL, $STORAGE_FSTYPE,
#  $STORAGE_BLOCK_SIZE, $STORAGE_NO_PARTITIONS_EXIT_CODE,
#  $AWS_ACCESS_KEY_ID, $AWS_SECRET_ACCESS_KEY, $EBS_TYPE, $STORAGE_SIZE,
#  $STORAGE_TYPE, $STORAGE_VOLCOUNT, $ENABLE_BCACHE

echo "Downloading Storage-Scripts to $RS_ATTACH_DIR"

STORAGE_SCRIPT_BRANCH=${STORAGE_SCRIPT_BRANCH:-bcache}
URL=https://github.com/diranged/storage-scripts/tarball/${STORAGE_SCRIPT_BRANCH}

mkdir -p $RS_ATTACH_DIR && pushd $RS_ATTACH_DIR
sudo apt-get -qq update || echo "Ignoring apt-get update failure"
sudo apt-get -qq install parted curl python-pip python-virtualenv ca-certificates
curl --location --silent $URL | sudo tar zx --strip-components 1

DRY=0 VERBOSE=1 FORCE=1 sudo -E ./setup.sh
```

#### Simple Dry Run
```bash
root@ip-10-48-52-134:/tmp/storage# DRY=1 ./setup.sh
Discovering cloud provider ... AWS!
Loading up C3 Instance Family defaults
INFO:  Storage Script Functions (v0.1.0) loaded!
INFO:  
INFO:  The following settings can be overridden by setting environment variables.
INFO:  
INFO:  The parameters below may or may not be used, depending on your environment:
INFO:  -----------
INFO:  DRY                     = 1
INFO:  ENABLE_BCACHE           = 1
INFO:  VERBOSE                 = 0
INFO:  FORCE                   = 0
INFO:  NO_PARTITIONS_EXIT_CODE = 1
INFO:  BLOCK_SIZE              = 64
INFO:  RAID_LEVEL              = 0
INFO:  FS                      = xfs
INFO:  MOUNT_POINT             = /mnt
INFO:  MOUNT_OPTS              = defaults,noatime,nodiratime,nobootwait
INFO:  DISCOVERED_PARTITIONS   = xvda xvda1 xvdb xvdc 
INFO:  EXCLUDED_PARTITIONS     = /dev/xvda /dev/xvda1 /dev/sda /dev/sda1
INFO:  -----------
INFO:  
INFO:  Package xfsprogs is missing... will install it.
INFO:  Would have run: apt-get -qq install xfsprogs
INFO:  Destination MD Volume: /dev/md0
INFO:  Destination mdadm.conf: /etc/mdadm/mdadm.conf
INFO:  Available partitions (2):  /dev/xvdb /dev/xvdc
INFO:  Would have run: yes | mdadm --create --force --verbose /dev/md0 --chunk=64 --level=0 --name=raid-setup-0.1.0 --raid-devices=2  /dev/xvdb /dev/xvdc
INFO:  Would have run: echo DEVICE partitions > /etc/mdadm/mdadm.conf
INFO:  Would have run: mdadm --detail --scan >> /etc/mdadm/mdadm.conf
INFO:  Would have run: echo BOOT_DEGRADED=true > /etc/initramfs-tools/conf.d/mdadm.conf
INFO:  Would have run: echo 30720 > /proc/sys/dev/raid/speed_limit_min
INFO:  Would have run: update-initramfs -u
INFO:  Would have run: mkfs.xfs -K -f /dev/md0
INFO:  Would have run: mount /dev/md0 /mnt -o defaults,noatime,nodiratime,nobootwait
INFO:  Would have run: echo /dev/md0 /mnt xfs defaults,noatime,nodiratime,nobootwait >> /etc/fstab
```

#### Real Run
```bash
root@ip-10-48-52-134:/tmp/storage# DRY=0 ./setup.sh 
Discovering cloud provider ... AWS!
Loading up C3 Instance Family defaults
INFO:  Storage Script Functions (v0.1.0) loaded!
INFO:  
INFO:  The following settings can be overridden by setting environment variables.
INFO:  
INFO:  The parameters below may or may not be used, depending on your environment:
INFO:  -----------
INFO:  DRY                     = 0
INFO:  ENABLE_BCACHE           = 1
INFO:  VERBOSE                 = 0
INFO:  FORCE                   = 0
INFO:  NO_PARTITIONS_EXIT_CODE = 1
INFO:  BLOCK_SIZE              = 64
INFO:  RAID_LEVEL              = 0
INFO:  FS                      = xfs
INFO:  MOUNT_POINT             = /mnt
INFO:  MOUNT_OPTS              = defaults,noatime,nodiratime,nobootwait
INFO:  DISCOVERED_PARTITIONS   = xvda xvda1 xvdb xvdc 
INFO:  EXCLUDED_PARTITIONS     = /dev/xvda /dev/xvda1 /dev/sda /dev/sda1
INFO:  -----------
INFO:  
INFO:  Package xfsprogs is missing... will install it.
INFO:  Running: apt-get -qq install xfsprogs
Selecting previously unselected package xfsprogs.
(Reading database ... 45533 files and directories currently installed.)
Preparing to unpack .../xfsprogs_3.1.9ubuntu2_amd64.deb ...
Unpacking xfsprogs (3.1.9ubuntu2) ...
Processing triggers for man-db (2.6.7.1-1ubuntu1) ...
Setting up xfsprogs (3.1.9ubuntu2) ...
Processing triggers for libc-bin (2.19-0ubuntu6.6) ...
INFO:  Destination MD Volume: /dev/md0
INFO:  Destination mdadm.conf: /etc/mdadm/mdadm.conf
INFO:  Available partitions (2):  /dev/xvdb /dev/xvdc
INFO:  Running: yes | mdadm --create --force --verbose /dev/md0 --chunk=64 --level=0 --name=raid-setup-0.1.0 --raid-devices=2  /dev/xvdb /dev/xvdc
mdadm: /dev/xvdb appears to contain an ext2fs file system
    size=83874816K  mtime=Thu Jan  1 00:00:00 1970
mdadm: /dev/xvdc appears to contain an ext2fs file system
    size=83874816K  mtime=Thu Jan  1 00:00:00 1970
Continue creating array? mdadm: Defaulting to version 1.2 metadata
mdadm: array /dev/md0 started.
INFO:  Running: echo DEVICE partitions > /etc/mdadm/mdadm.conf
INFO:  Running: mdadm --detail --scan >> /etc/mdadm/mdadm.conf
INFO:  Running: echo BOOT_DEGRADED=true > /etc/initramfs-tools/conf.d/mdadm.conf
INFO:  Running: echo 30720 > /proc/sys/dev/raid/speed_limit_min
INFO:  Running: update-initramfs -u
update-initramfs: Generating /boot/initrd.img-3.13.0-65-generic
INFO:  Running: mkfs.xfs -K -f /dev/md0
meta-data=/dev/md0               isize=256    agcount=16, agsize=2621072 blks
         =                       sectsz=512   attr=2, projid32bit=0
data     =                       bsize=4096   blocks=41937152, imaxpct=25
         =                       sunit=16     swidth=32 blks
naming   =version 2              bsize=4096   ascii-ci=0
log      =internal log           bsize=4096   blocks=20480, version=2
         =                       sectsz=512   sunit=16 blks, lazy-count=1
realtime =none                   extsz=4096   blocks=0, rtextents=0
INFO:  Running: mount /dev/md0 /mnt -o defaults,noatime,nodiratime,nobootwait
INFO:  Running: echo /dev/md0 /mnt xfs defaults,noatime,nodiratime,nobootwait >> /etc/fstab
root@ip-10-48-52-134:/tmp/storage# df -h /mnt
Filesystem      Size  Used Avail Use% Mounted on
/dev/md0        160G   33M  160G   1% /mnt
root@ip-10-48-52-134:/tmp/storage# cat /proc/mdstat
Personalities : [raid0] 
md0 : active raid0 xvdc[1] xvdb[0]
      167749504 blocks super 1.2 64k chunks
      
unused devices: <none>
root@ip-10-48-52-134:/tmp/storage# 
```

## Global Environment Variables
These environment variables apply to any script in this repository.

* `DRY` (default: `1`)
   By default the scripts run in dry mode -- no changes are made! Set this to
   `0` to enact real change.
* `VERBOSE` (default: `0`)
   Enable verbose log output by setting this to `1`

# Ephemeral Storage
By default the scripts will mount and format all of your local instance storage
into a single RAID 0 volume. You have the following options available to you
though to customize this behavior.

* `RAID_LEVEL`/`STORAGE_RAID_LEVEL` (default: `0`)
   The RAID level for MDADM to use when creating the volume.
* `BLOCK_SIZE`/`STORAGE_BLOCK_SIZE` (default: `512`)
   The size of each chunk written out to a disk in the RAID group before moving on to the next disk.
* `FS`/`STORAGE_FSTYPE`: (default: `xfs`)
   The format of the filesystem -- `xfs` and `ext4` are supported today.
* `MOUNT_POINT` (default: `/mnt`)
* `MOUNT_OPTS` (default: `defaults,noatime,nodiratime,nobootwait`)
* `NO_PARTITIONS_EXIT_CODE`/`STORAGE_NO_PARTITIONS_EXIT_CODE` (default: `1`)
   The `exit code` to throw in the event that the script is unable to find any
   suitable volumes to RAID together. Defaults to `1`, but if you're running
   this script by default on-bootup, there may be cases where you know that
   there are no local volumes to create (like on Amazon _c4_ instances).
* `FORCE` (default: `0`)
   Whether or not to overwrite existing block device partition tables if
   they're found. Defaults to `0`, but this is again useful when formatting
   instance-level storage which often comes with a basic partition table
   already.
* `EXCLUDED_PARTITIONS` (default: `/dev/xvda /dev/xvda1 /dev/sda /dev/sda1`)
   A list of partitions to completely ignore when auto-detecting what is
   available for the filesystem creation.

## Amazon Web Services
The [setup.sh](./setup.sh) script automatically determins whether a host is
running in Amazon or not based on whether it can reach the meta-data service.
If it can, the volume configuration script [setup_aws.sh](./setup_aws.sh) is
used to configure the host.

### Auto-detected Performance Options
Several tuning options are automatically detected (_if you have not supplied
your own_) based on the instance-family of the host (`c3`, `c4`, `d2` etc) and 
the storage type (`ebs` vs `instance`).

#### Instance Family
* `BLOCK_SIZE`: **C3**: 64kb, **C4**: 256kb, **D2**: 2048kb, **I2**: 64kb
* `ENABLE_BCACHE`: **C3**: Yes, **C4**: No, **D2**: No, **I2**: Yes

#### Storage Type
* `BLOCK_SIZE`: **ebs**: 256kb

### Persistant EBS Storage
To enable creation of EBS volumes, the following environment variables must be
set up.

* `AWS_ACCESS_KEY_ID`: Credentials that have access to create, tag and mount
  EBS volumes to an instance.
* `AWS_SECRET_ACCESS_KEY`: Matching secret for the key above.
* `EBS_TYPE`: `standard`, `gp2` or `io2`
* `STORAGE_SIZE`: Total size of the final RAID volume you want.
* `STORAGE_TYPE`: Set this to `ebs`!
* `STORAGE_VOLCOUNT`: The number of EBS volumes you want to create -- generally
  1 or 2 is fine, but you may want more if you need more IOPS.
* `ENABLE_BCACHE` (default: `0`): If this is set to `1`, then see the [Block
  Cache](#block-cache) section
* `BCACHE_MODE` (default: `writethrough`): `writeback`, `writethrough`
