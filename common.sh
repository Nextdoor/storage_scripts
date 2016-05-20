#!/bin/sh
#
# This is just a utility package -- meant to store a few useful functions that
# may be used by multiple scripts in this repo.
#
# Usage:
#   #!/bin/sh
#   . $( cd $( dirname -- "$0" ) > /dev/null ; pwd )/common.sh
#   <call_some_func>
#

VERSION=0.1.0

# Common variables that apply to every function in this file -- these will be
# explained to the user when this common.sh script is imported. No need to add
# them to your own help/documentation.
DRY=${DRY:-1}
VERBOSE=${VERBOSE:-0}

# discover_bcache(), create_bcache_vol()
ENABLE_BCACHE=${ENABLE_BCACHE:-0}
BCACHE_MODE=${BCACHE_MODE:-writethrough}

# discover_partitions()
FORCE=${FORCE:-0}
NO_PARTITIONS_EXIT_CODE=${NO_PARTITIONS_EXIT_CODE:-1}

# create_md_volume() 
BLOCK_SIZE=${BLOCK_SIZE:-512}
RAID_LEVEL=${RAID_LEVEL:-0}

# discover_md_conf()
MDADM_CONF_LOCATIONS="/etc/mdadm/mdadm.conf /etc/mdadm.conf"

# make_filesystem()
FS=${FS:-xfs}
MOUNT_POINT=${MOUNT_POINT:-/mnt}
MOUNT_OPTS=${MOUNT_OPTS:-defaults,noatime,nodiratime,nobootwait}

# Discover all available partitions -- but allow the user to override the list
# as well.
DISCOVERED_PARTITIONS=$(cat /proc/partitions | tail -n +3 | grep -v 'md' | awk '{print $4}' | tr '\n' ' ')
EXCLUDED_PARTITIONS=${EXCLUDED_PARTITIONS:-"/dev/xvda /dev/xvda1 /dev/sda /dev/sda1"}
PARTITIONS=${PARTITIONS:-$DISCOVERED_PARTITIONS}

# Stupid simple logger methods that wrap our log messages with some
# useful information.
error() { echo "ERROR: $@" 1>&2; exit 1; }
warn() { echo "WARN:  $@" 1>&2; }
info()  { echo "INFO:  $@"; }
debug() { if test 1 -eq $VERBOSE; then echo "DEBUG: $@"; fi }
dry_exec() {
  if test $DRY -eq 1; then
    info "Would have run: $@"
  else
    info "Running: $@"
    eval $@
  fi
}

# Checks that all of the Aptitude package dependencies are installed. If they
# aren't, it does an apt-get update and installs the missing packages.
#
# Args:
#   A list of packages to install through apt-get
#
install_apt_deps() {
  for dep in $@; do
    debug "Checking if $dep is installed..."
    if ! dpkg -s $dep > /dev/null 2>&1; then
      info "Package $dep is missing... will install it."
      missing="${dep} ${missing}"
    fi
  done

  # If no packages are missing, then exit this function
  if ! test "$missing"; then return; fi

  # Install the Apt dependencies now
  export DEBIAN_FRONTEND="noninteractive"
  export DEBCONF_NONINTERACTIVE="true"
  apt-get -qq update || warn "apt-get update failed ... attempting package install anyways"
  dry_exec apt-get -qq install $missing
}

# Creates the filesystem on the mdadm device, mounts it, and adds it to the
# fstab file for automatic mounts in the future.
#
# Expects:
#   FS: The filesystem type (ext4/xfs) to use
#   VOL: The /dev/<device> to format
#   MOUNT_POINT: Where to mount the device
#   MOUNT_OPTS: Any custom mounting options
#
make_filesystem() {
  # http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ssd-instance-store.html
  if test "${FS}" = "xfs"; then
    mkfs_opts="-K -f"
  elif test "${FS}" = "ext4"; then
    mkfs_opts="-E nodiscard"
  fi
  mnt_line="${VOL} ${MOUNT_POINT} ${FS} ${MOUNT_OPTS}"

  dry_exec "mkfs.${FS} ${mkfs_opts} ${VOL}"
  dry_exec "mount ${VOL} ${MOUNT_POINT} -o ${MOUNT_OPTS}"
  dry_exec "echo ${mnt_line} >> /etc/fstab"
}

# Checks whether or not bcache-tools is available. If its not, sets
# ENABLE_BCACHE to 0.
discover_bcache() {
  debug "Checking if make-bcache is available..."
  if ! test -f /usr/sbin/make-bcache; then
    warn "make_bcache not available, setting ENABLE_BCACHE=0"
    ENABLE_BCACHE=0
  fi
}

# Checks the partitions supplied by the user (or automatically discovers all
# available partitions) to see if they're available to be added to the RAID
# volume.
#
# A partition is available if it is:
#   * A valid block device
#   * Not currently mounted to the system as a volume
#
# Expects:
#   PARTITIONS: A space-separated list of partitions to validate
#   NO_PARTITIONS_EXIT_CODE: The exit code to throw in case no available
#                            partitions are found.
#
# Sets:
#   AVAILABLE_PARTITIONS: A space-separated list of partitions that passed
#
discover_partitions() {
  debug "Discovered partitions: ${PARTITIONS}"
  for part in $(echo $PARTITIONS); do
    # Strip out /dev/ if the user supplied it, and then we add it back in
    # ourselves. If they did not supply it, we just add it.
    part="/dev/$(echo $part | sed 's/\/dev\///g')"
    fail=0

    debug "Checking if ${part} is a block device"
    if ! test -b $part; then
      fail=1
      debug "${part} is not a block device!"
    fi

    debug "Checking if ${part} is in EXCLUDED_PARTITIONS: ${EXCLUDED_PARTITIONS}"
    if test "$(echo $EXCLUDED_PARTITIONS | grep $part)"; then
      fail=1
      debug="${part} is listed in the excluded partitions."
    fi

    if ! test "$FORCE"; then
      debug "Checking if ${part} has any existing partition tables"
      if blkid -po udev $part > /dev/null 2>&1; then
        fail=1
        debug "${part} already has a partition table, skipping!"
      fi
    fi
   
    if test $fail -eq 0; then
      AVAILABLE_PARTITIONS="${AVAILABLE_PARTITIONS} ${part}"
    fi
  done

  # If there are no available partitions found, then we let the user know and
  # we exit. Exit code is set to 0 though, because it may be that they've run
  # this script already and properly built their array.
  if ! test "$AVAILABLE_PARTITIONS"; then
    warn "No available partitions found -- exiting."
    exit $NO_PARTITIONS_EXIT_CODE
  fi
}

# Discover a list of our ephemeral -- instance store -- drives.
#
# Sets:
#   EPHEMERAL_PARTITIONS: A space-separated list of local ephemeral drives.
#
discover_ephemeral_partitions() {
  METAURL="http://169.254.169.254/2012-01-12/meta-data/block-device-mapping/"
  if test "$EPHEMERAL_PARTITIONS"; then
    info "Using user-supplied local cache volumes: ${EPHEMERAL_PARTITIONS}"
    return
  fi

  for BD in $(curl -s $METAURL | grep ephemeral); do
    SD=$(curl -s ${METAURL}${BD})
    XD=$(echo $SD | sed 's/sd/xvd/')
    DEV=/dev/${XD}
    EPHEMERAL_PARTITIONS="${DEV} ${EPHEMERAL_PARTITIONS}"
  done
}

# Discover the next available MD device ID thats available. After 10 tries,
# throw an error and bail.
#
# Sets:
#   MD_VOL: The first available /dev/md device found.
#
discover_md_vol() {
  for id in 0 1 2 3 4 5 6 7 8 9; do
    debug "Checking if /dev/md${id} is available..."
    if ! test -b /dev/md$id; then
      MD_VOL=/dev/md$id
      info "Destination MD Volume: ${MD_VOL}"
      return
    fi
  done

  error "No available /dev/mdX volumes available!"
}

# Discover the correct location of the mdadm.conf file... :sadface:
#
# Sets:
#   MD_CONF: The proper location for the mdadm.conf file.
#
discover_md_conf() {
  for conf in $MDADM_CONF_LOCATIONS; do
    debug "Checking if $conf exists..."
    if test -f $conf; then
      MD_CONF=$conf
      info "Destination mdadm.conf: $MD_CONF"
      return
    fi
  done

  error "Could not find proper mdadm.conf location!"
}

# Creates the actual MDADM volume, generates the mdadm.conf file and updates
# the initramfs with the copy of the new mdadm.conf file. This ensure that after
# a host reboot, the volume will still mount properly.
#
# Expects:
#   MD_VOL: The MDADM Volume Device ID to use
#   BLOCK_SIZE: The block/chunk size to write out to each drive before moving
#   on to the next drive in the array.
#   RAID_LEVEL: The RAID level to use -- 0, 1, etc.
#   VERSION: The version of this script -- used in naming the array.
#   AVAILABLE_PARTITIONS: The actual device list to add to the array.
#
# Sets:
#   VOL: The volume it just created (aka $MD_VOL)
create_md_volume() {
  PARTITION_COUNT=$(echo "${AVAILABLE_PARTITIONS}" | wc -w)
  info "Available partitions ($PARTITION_COUNT): ${AVAILABLE_PARTITIONS}"

  dry_exec "yes | mdadm --create --force --verbose ${MD_VOL} --chunk=${BLOCK_SIZE} --level=${RAID_LEVEL} --name=raid-setup-${VERSION} --raid-devices=${PARTITION_COUNT} ${AVAILABLE_PARTITIONS}"
  dry_exec "echo DEVICE partitions > ${MD_CONF}"
  dry_exec "mdadm --detail --scan >> ${MD_CONF}"

  # https://bruun.co/2012/06/06/software-raid-on-ec2-with-mdadm
  dry_exec "echo BOOT_DEGRADED=true > /etc/initramfs-tools/conf.d/mdadm.conf"

  # http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/disk-performance.html
  dry_exec "echo $((30*1024)) > /proc/sys/dev/raid/speed_limit_min"

  # Regenerate the initramfs with the above settings
  dry_exec "update-initramfs -u"

  VOL=${MD_VOL}
}

# Optionally wipe out the existing filesystems on the devices
#
# Args:
#   A list of /dev/<vol> paths to wipe
#
maybe_wipe() {
 if test "$FORCE" -eq 0; then
   return
 fi

 for dev in $@; do
   dry_exec "wipefs $dev && wipefs -a $dev"
 done
} 

# Optionally creates a /dev/bcache0 device using the local instance level
# ephemeral drives as caches and the already-created /dev/mdX device as
# the permanent store.
#
# Expects:
#   ENABLE_BCACHE: Whether or not to actually enable the bcache
#   BCACHE_MODE: writethrough/writeback/none
#   CACHE_DEVICE: A list of local ephemeral drives
#   BACKING_DEVICE: The /dev/mdX device
#
# Sets:
#   VOL: The new volume created
#
create_bcache_vol() {
  if test $ENABLE_BCACHE -eq 0; then
    info "Skipping /dev/bcache0 creation..."
    return
  fi

  # Wipe out the devices and configure them properly
  maybe_wipe $CACHE_DEVICE
  dry_exec "make-bcache -B $BACKING_DEVICE -C ${CACHE_DEVICE}"

  # Wait for the bcache device to show up in the OS...
  dry_exec "sleep 1"

  dry_exec "cat addons/bcache.sh | CACHE_DEVICE=\"${CACHE_DEVICE}\" BCACHE_MODE=\"${BCACHE_MODE}\" envsubst > /etc/init.d/bcache"
  dry_exec "chmod +x /etc/init.d/bcache"
  dry_exec "update-rc.d bcache defaults"
  dry_exec "/etc/init.d/bcache tune"

  # TODO: Make this dynamic if at some point it needs to be.
  VOL=/dev/bcache0
}

# Just mention that we were loaded up!
info "Storage Script Functions (v${VERSION}) loaded!"
info ""
info "The following settings can be overridden by setting environment variables."
info ""
info "The parameters below may or may not be used, depending on your environment:"
info "-----------"
info "DRY                     = ${DRY}"
info "ENABLE_BCACHE           = ${ENABLE_BCACHE}"
info "VERBOSE                 = ${VERBOSE}"
info "FORCE                   = ${FORCE}"
info "NO_PARTITIONS_EXIT_CODE = ${NO_PARTITIONS_EXIT_CODE}"
info "BLOCK_SIZE              = ${BLOCK_SIZE}"
info "RAID_LEVEL              = ${RAID_LEVEL}"
info "FS                      = ${FS}"
info "MOUNT_POINT             = ${MOUNT_POINT}"
info "MOUNT_OPTS              = ${MOUNT_OPTS}"
info "DISCOVERED_PARTITIONS   = ${DISCOVERED_PARTITIONS}"
info "EXCLUDED_PARTITIONS     = ${EXCLUDED_PARTITIONS}"
info "-----------"
info ""
