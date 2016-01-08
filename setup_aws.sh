#!/bin/sh
#
# Amazon-specific Storage Setup Script
#
# This script automatically sets up a /mnt volume on a host in the most
# efficient way possible based on the host type, underlying storage config,
# etc.
#
# This script is meant to be called by setup.sh, but can be called directly as
# well. Sane defaults are selected automatically, but settings can be
# overridden as well.
#
# ENVIRONMENT VARIABLES:
#   ENABLE_BCACHE
#     Set to "1" to enable the Block Cache with local SSD. Only applies
#     when using EBS storage as well.
#
#   BLOCK_SIZE
#     Set to any block size (in kbytes) to overwrite the default or
#     auto-detected block size.
#     
#   STORAGE_TYPE
#     Set to "ebs" to request EBS volumes as your primary backing store.
#
#   --- all options below only apply if STORAGE_TYPE=ebs ---
#
#   EBS_TYPE
#     "standard": General Magnetic Storage
#     "gp2": General Purpose SSD
#     "io2": Provisioned IOPS -- maxes out at 4000/volume
#
#   STORAGE_VOLCOUNT
#     The number of EBS volumes to create (total size will add up to
#     $STORAGE_SIZE)
#
#   STORAGE_SIZE
#     Number of gigabytes to provision in EBS storage.
#

# Exit on any failure that was not intentionally caught
set -e

# Misc defaults
CURL="$(which curl) --connect-timeout 1 --fail --silent"
APT_DEPS="bcache-tools gettext-base xfsprogs mdadm"

# Discover some information about this system
INSTANCE=$(${CURL} http://169.254.169.254/latest/meta-data/instance-type/)
INSTANCE_FAMILY=$(echo $INSTANCE | awk -F\. '{print $1}')

# Defaults based on our INSTANCE_FAMILY
case $INSTANCE_FAMILY in
  c3)
    echo "Loading up C3 Instance Family defaults"
    DEFAULT_BLOCK_SIZE=64
    DEFAULT_ENABLE_BCACHE=1
    ;;
  c4)
    echo "Loading up C4 Instance Family defaults"
    DEFAULT_BLOCK_SIZE=256  # no instance storage, so use EBS default
    DEFAULT_ENABLE_BCACHE=0
    ;;
  d2)
    # http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/d2-instances.html
    echo "Loading up D2 Instance Family defaults"
    DEFAULT_BLOCK_SIZE=2048
    DEFAULT_ENABLE_BCACHE=1
    ;;
  i2)
    # http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/i2-instances.html
    echo "Loading up I2 Instance Family defaults"
    DEFAULT_BLOCK_SIZE=4
    DEFAULT_ENABLE_BCACHE=1
    ;;
  *)
    echo 'No specific custom settings found, using defaults'
    DEFAULT_BLOCK_SIZE=512
    DEFAULT_ENABLE_BCACHE=0
esac

# Quick override -- if we're doing EBS storage, there are new defaults to use
if test "$STORAGE_TYPE" = "ebs"; then
  # https://www.datadoghq.com/blog/aws-ebs-provisioned-iops-getting-optimal-performance/
  DEFAULT_BLOCK_SIZE=256
fi

# Now gather our supplied defaults, or use the above ones
BLOCK_SIZE=${BLOCK_SIZE:-$DEFAULT_BLOCK_SIZE}
ENABLE_BCACHE=${ENABLE_BCACHE:-$DEFAULT_ENABLE_BCACHE}

# Source in our common functions
. $( cd $( dirname -- "$0" ) > /dev/null ; pwd )/common.sh

# Before we do anything, set up our dependencies, discover a few
# bits of evironment stuff, etc.
install_apt_deps ${APT_DEPS}
discover_md_vol
discover_md_conf
discover_bcache

# If we're asking for EBS storage, use our legacy volume grabber to
# create the volumes in EBS.
if test "$STORAGE_TYPE" = "ebs"; then
  # Get all of our EBS volumes created and tagged, then group them into
  # a single MDADM volume RAID device.

  # TODO: Rebuild EBS scripts with bash!
  virtualenv .venv && . .venv/bin/activate
  pip install -r requirements.txt
  python ./get_ebs_volumes.py \
          -t $EBS_TYPE \
          -c $STORAGE_VOLCOUNT \
          -S $STORAGE_SIZE
  PARTITIONS=$(cat /tmp/ebs_vols)
  echo "Set PARTITIONS=${PARTITIONS}"
  partprobe > /dev/null 2>&1 || echo "Done"
  # END TODO
fi

# Now -- at this point $PARTITIONS is either empty or populated. If its
# populated by the EBS code above, then discover_partitions() discover and
# use them. If it is empty, then discover_partitions() will discover all
# available partitions on the host and use them.
discover_partitions
discover_ephemeral_partitions

# Create a RAID volume with the partitions from discover_partitions().
create_md_volume

# If we've used EBS as our backing store, and if ENABLE_BCACHE is enabled
# then we create the bcache0 device. If NOT, then we simply move on with
# formatting /dev/md0.
case $STORAGE_TYPE in
  ebs)
    create_bcache_vol
    make_filesystem
    ;;
  *)
    make_filesystem
    ;;
esac
