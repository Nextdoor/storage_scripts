#!/bin/bash
#
# Script blatenly stolen from http://blog.rralcala.com/2014/08/using-bcache-in-ec2.html
#
# bcache       Bring up/down bcache
#
# chkconfig: - 10 10
# description: Activates/Deactivates all block device caching

rc=0
start() {
  if [ ! -e /sys/block/bcache0/bcache/cache ]; then
    /sbin/wipefs -a $EPHEMERAL_PARTITIONS
    /usr/sbin/make-bcache -C $EPHEMERAL_PARTITIONS
    for DEV in $EPHEMERAL_PARTITIONS; do
      echo $DEV > /sys/fs/bcache/register
    done
    sleep 1
    name=`basename /sys/fs/bcache/*-*-*`
    echo $name > /sys/block/bcache0/bcache/attach

  fi

  touch /var/lock/subsys/bcache
  return 0
}

stop() {
  rm -f /var/lock/subsys/bcache
  return 0
}

tune() {
  # Some performance tuning, we assume our ebs volume is always
  # going to be slower that local SSDs
  echo 0 > /sys/block/bcache0/bcache/sequential_cutoff
  echo $BCACHE_MODE > /sys/block/bcache0/bcache/cache_mode
  sleep 2
  echo 0 > /sys/block/bcache0/bcache/cache/congested_read_threshold_us
  echo 0 > /sys/block/bcache0/bcache/cache/congested_write_threshold_us
}

case "$1" in
  start)
    start
    tune
    rc=$?
    ;;
  stop)
    stop
    rc=$?
    ;;
  tune)
    tune
    rc=$?
    ;;
esac

exit $rc
