#!/bin/sh
#
# This main setup script is meant to be called on a host once during its
# initial bootup and configuration. The script uses a silly "touch" file to
# ensure you don't run it again, as this script is *not idempotent!*
#
# The script automatically detects the cloud environment and calls the
# appropriate script based on that.

# Make sure this script hasn't run before (i.e., in a reboot)
if test -e '/etc/.volumeized'; then exit 0; fi

# Quiet this down for security purposes and fail on any exit code > 1
set -e +x

# Our existing RightScript uses prefixed-variable names that we want to
# deprecate in the future, but for now we want to make sure that if they are
# set, they get used. If they aren't set, we ignore them and let defaults
# take over.
set -a
DRY=${DRY:-1}
if test "$STORAGE_BLOCK_SIZE"; then BLOCK_SIZE=$STORAGE_BLOCK_SIZE; fi
if test "$STORAGE_RAID_LEVEL"; then RAID_LEVEL=$STORAGE_RAID_LEVEL; fi
if test "$STORAGE_FORCE_OVERWRITE"; then FORCE_OVERWRITE=$STORAGE_FORCE_OVERWRITE; fi
if test "$STORAGE_FSTYPE"; then FS=$STORAGE_FSTYPE; fi
if test "$STORAGE_NO_PARTITIONS_EXIT_CODE"; then
  NO_PARTITIONS_EXIT_CODE=$STORAGE_NO_PARTITIONS_EXIT_CODE
fi

# Discover what cloud we're in and run the appropriate storage script.
CURL="$(which curl) --connect-timeout 1 --fail --silent"
URL=http://169.254.169.254/latest/meta-data/ami-id/

/bin/echo -n "Discovering cloud provider ... "
if $CURL $URL 2>&1 > /dev/null; then
  /bin/echo "AWS!"
  ./setup_aws.sh
else
  echo "No matching provider found. Exiting."
  exit 1
fi

# Now that we're done, touch a file to mark that we've run this script, and
# never run it again
if ! test $DRY -eq 1; then
  touch /etc/.volumeized
fi
