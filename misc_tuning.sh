#!/bin/sh
#
# Unsure if these are necssary -- putting them into a separate file for now for
# testing.


# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/disk-performance.html
echo $((30*1024)) > /proc/sys/dev/raid/speed_limit_min

# maybe http://blog.celingest.com/en/2014/01/23/squeezing-out-c3-instances-performance-in-aws/ ??
