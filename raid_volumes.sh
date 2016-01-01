#!/bin/sh
#
# Utility script for automatically creating, formatting and mounting volumes
# into a single RAID volume. Designed to be used *after* all volumes on a host
# have been mounted and discovered.
#
# Supported Use Casess:
#   *RAID All Available Volumes*
# 
#
# Note about code style: This script has been written to be fully compatible
# with DASH and BASH. This allows it to be run anywhere, even if BASH or a more
# powerful shell is not available.

# Exit on any failure that was not intentionally caught
set -e

# Our script version!
VERSION=0.0.1

# A POSIX variable
OPTIND=1  # Reset in case getopts has been used previously in the shell.

# Defaults -- overrideable by setting them outside of this script
DRY=${DRY:-0}
INSTALL_DEPS=${INSTALL_DEPS:-1}
RAID_LEVEL=${RAID_LEVEL:-0}
FS=${FS:-ext4}
MDADM_CONF_LOCATIONS="/etc/mdadm/mdadm.conf /etc/mdadm.conf"
MOUNT_POINT=${MOUNT_POINT:-/mnt}
MOUNT_OPTS=${MOUNT_OPTS:-defaults,noatime,nodiratime,nobootwait}
VERBOSE=${VERBOSE:-0}

# Apt-package dependencies
APT_DEPS="mdadm xfsprogs"

# Discover all available partitions -- but allow the user to override the list
# as well.
DISCOVERED_PARTITIONS=$(cat /proc/partitions | tail -n +3 | grep -v 'md' | awk '{print $4}' | tr '\n' ',')
PARTITIONS=${PARTITIONS:-$DISCOVERED_PARTITIONS}

# Shows the user how to use the tool
help() {
  cat <<END
Version: ${VERSION}

Usage: $0 <options>

Options:
  -h  Show Help
  -d  Dry Run -- no real changes are made (default: DRY=${DRY})
  -D  Install system dependencies automatically? (default: INSTALL_DEPS=${INSTALL_DEPS})
  -l  The RAID Level (default: RAID_LEVEL=${RAID_LEVEL})
  -f  Filesystem type (default: FS=${FS})
  -o  The mount options (default: MOUNT_OPTS=${MOUNT_OPTS})
  -m  The mount point (default: MOUNT_POINT=${MOUNT_POINT})
  -p  A comma-separated list of the partitions to operate on.
      (default: ${PARTITIONS})
  -v  Set the script output verbosity (default: VERBOSE=${VERBOSE})

Environmental Options:
  You can override all of the above settings by setting environment variables
  instead of passing in commandline options. The variable names are listed
  above next to the defaults.

END
  exit 0
}

# Parse our options passed in by the user
while getopts "h?dDl:f:o:m:v" opt; do
  case "$opt" in
  d)
    DRY=1
    ;;
  D)
    INSTALL_DEPS=1
    ;;
  h|\?)
    help
    ;;
  f)
    FS=$OPTARG
    ;;
  l)
    RAID_LEVEL=$OPTARG
    ;;
  o)
    MOUNT_OPTS=$OPTARG
    ;;
  m)
    MOUNT_POINT=$OPTARG
    ;;
  p)
    PARTITIONS=$OPTARG
    ;;
  v)
    VERBOSE=1
    ;;
  esac
done
shift $((OPTIND-1))
[ "$1" = "--" ] && shift

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

# Checks the partitions supplied by the user (or automatically discovers all
# available partitions) to see if they're available to be added to the RAID
# volume.
#
# A partition is available if it is:
#   * A valid block device
#   * Not currently mounted to the system as a volume
#
discover_partitions() {
  debug "Discovered partitions: ${PARTITIONS}"
  for part in $(echo $PARTITIONS | sed "s/,/ /g"); do
    # Strip out /dev/ if the user supplied it, and then we add it back in
    # ourselves. If they did not supply it, we just add it.
    part="/dev/$(echo $part | sed 's/\/dev\///g')"
    fail=0

    debug "Checking if ${part} is a block device"
    if ! test -b $part; then
      fail=1
      debug "${part} is not a block device!"
    fi

    debug "Checking if ${part} has any existing partition tables"
    if blkid -po udev $part > /dev/null 2>&1; then
      fail=1
      debug "${part} already has a partition table, skipping!"
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
    exit 0
  fi

  PARTITION_COUNT=$(echo "${AVAILABLE_PARTITIONS}" | wc -w)
  info "Available partitions ($PARTITION_COUNT): ${AVAILABLE_PARTITIONS}"
}

# Discover the next available MD device ID thats available. After 10 tries,
# throw an error and bail.
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

# Checks that all of the Aptitude package dependencies are installed. If they
# aren't, it does an apt-get update and installs the missing packages.
install_apt_deps() {
  for dep in $APT_DEPS; do
    debug "Checking if $dep is installed..."
    if ! dpkg -s $dep > /dev/null 2>&1; then
      info "Package $dep is missing... will install it."
      missing="${dep} ${missing}"
    fi
  done

  # If no packages are missing, then exit this function
  if ! test "$missing"; then return; fi

  # Install the Apt dependencies now
  apt-get -qq update || warn "apt-get update failed ... attempting package install anyways"
  dry_exec apt-get -qq install $missing
}

# Creates the actual MDADM volume, generates the mdadm.conf file and updates
# the initramfs with the copy of the new mdadm.conf file. This ensure that after
# a host reboot, the volume will still mount properly.
create_volume() {
  dry_exec "yes | mdadm --create --force --verbose ${MD_VOL} --level=${RAID_LEVEL} --name=raid-setup-${VERSION} --raid-devices=${PARTITION_COUNT} ${AVAILABLE_PARTITIONS}"
  dry_exec "echo DEVICE partitions > ${MD_CONF}"
  dry_exec "mdadm --detail --scan >> ${MD_CONF}"
  dry_exec "update-initramfs -u"
}

# Creates the filesystem on the mdadm device, mounts it, and adds it to the
# fstab file for automatic mounts in the future.
make_filesystem() {

  # http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ssd-instance-store.html
  if test "${FS}" = "xfs"; then
    mkfs_opts="-K -f"
  elif test "${FS}" = "ext4"; then
    mkfs_opts="-E nodiscard"
  fi
  mnt_line="${MD_VOL} ${MOUNT_POINT} ${FS} ${MOUNT_OPTS}"

  dry_exec "mkfs.${FS} ${mkfs_opts} ${MD_VOL}"
  dry_exec "mount ${MD_VOL} ${MOUNT_POINT} -o ${MOUNT_OPTS}"
  dry_exec "echo ${mnt_line} >> /etc/fstab"
}

# Our main startup function
main() {
  info "Raid Setup Script: v${VERSION}"

  install_apt_deps
  discover_md_vol
  discover_md_conf
  discover_partitions
  create_volume
  make_filesystem
}

# GO!
main
