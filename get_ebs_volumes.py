#!/usr/bin/python

# Before we do much, make sure that we have the right system tools
# installed. This is weird to do here, but this is a first-boot script
# so our requirements may not be installed.
import os

# Check if mdadm exists
import commands
import time
import sys
import socket
import stat
import optparse
import boto.ec2

# Defaults
VERSION = 1.0
DEFAULT_VOLTYPE = 'instance'
DEFAULT_MOUNTPOINT = '/mnt'
DEFAULT_RAIDTYPE = 0
DEFAULT_FSTYPE = 'ext4'
DEFAULT_EBS_DISK_NAMES_SD = ["/dev/sdf", "/dev/sdg", "/dev/sdh", "/dev/sdi", "/dev/sdj", "/dev/sdk", "/dev/sdl", "/dev/sdm", "/dev/sdn"]
DEFAULT_EBS_DISK_NAMES_XVD = ["/dev/xvdf", "/dev/xvdg", "/dev/xvdh", "/dev/xvdj", "/dev/xvdk", "/dev/xvdl", "/dev/xvdm", "/dev/xvdn", "/dev/xvdba", "/dev/xvdbb", "/dev/xvdbc", "/dev/xvdbd", "/dev/xvdbe"]
DEFAULT_EBS_COUNT = 4
DEFAULT_EBS_SIZE = 512
DEFAULT_MOUNTOPTS = 'defaults,noatime,nodiratime,nobootwait'

# First handle all of the options passed to us
usage = "usage: %prog -c <vol count> -S <disksize>"

parser = optparse.OptionParser(usage=usage, version=VERSION, add_help_option=True)
parser.set_defaults(verbose=True)
parser.add_option("-c", "--volcount", dest="volcount", default=DEFAULT_EBS_COUNT, help="number of EBS volumes to create")
parser.add_option("-S", "--volsize", dest="volsize", default=DEFAULT_EBS_SIZE, help="total size of the EBS volume to create")
parser.add_option("-t", "--ebstype", dest="ebstype", help="type of EBS volume: standard, io1 or gp2")
(options, args) = parser.parse_args()


def get_ebs_volumes(ebs_vol_list, volcount, volsize, volume_type='standard'):
    """Work with Amazon to create EBS volumes, tag them and attach them to the local host"""

    # How large will each volume be?
    individual_vol_size = int(volsize / volcount)

    # Some local instance ID info..
    zone = commands.getoutput("wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone")
    region = zone[:-1]
    instanceid = commands.getoutput("wget -q -O - http://169.254.169.254/latest/meta-data/instance-id")
    available_ebs_vol_list = []
    attached_ebs_vol_list = []

    # Open our EC2 connection
    print("INFO: Connecting to Amazon...")
    ec2 = boto.ec2.connect_to_region(region)

    # Make sure that the device list we got is good. If a device exists already,
    # remove it from the potential 'device targets'
    for potential_volume in ebs_vol_list:
        if os.path.exists(potential_volume):
            print("INFO: (%s) is already an attached EBS volume." % (potential_volume))
            attached_ebs_vol_list.append(potential_volume)
        else:
            print("INFO: (%s) is available as a disk target." % (potential_volume))
            available_ebs_vol_list.append(potential_volume)

    # Reverse our available_ebs_vol_list so that we can 'pop' from the beginning
    available_ebs_vol_list.reverse()

    # If we have any EBS volumes already mapped, then just pass them back. Do not create new ones,
    # and do not do anything with them. This script does not support handling multiple sets of EBS
    # volumes.
    if attached_ebs_vol_list.__len__() > 0:
        print("WARNING: EBS volumes are already attached to this host. Passing them back and not touching them.")
        return attached_ebs_vol_list

    # Make sure we have enough target devices available
    if volcount > available_ebs_vol_list.__len__():
        print("ERROR: Do not have enough local volume targets available to attach the drives.")
        sys.exit(1)

    # For each volume..
    for i in range(0, volcount):
        print("INFO: Requesting EBS volume creation (%s gb)..." % (individual_vol_size))

        # 30:1 GB:IOP ratio, with a max of 4000
        iops = individual_vol_size * 30
        if iops > 4000:
            iops = 4000

        if volume_type == 'io1':
            print("INFO: Requesting %s provisioned IOPS..." % iops)
            vol = ec2.create_volume(individual_vol_size, zone,
                                    volume_type=volume_type,
                                    iops=iops)
        else:
            vol = ec2.create_volume(individual_vol_size, zone,
                                    volume_type=volume_type)

        # Wait until the volume is 'available' before attaching
        while vol.status != u'available':
            time.sleep(1)
            print("INFO: Waiting for %s to become available..." % vol)
            vol.update()

        print("INFO: Volume %s status is now: %s..." % (vol, vol.status))

        # Grab a volume off of our stack of available vols..
        dest = available_ebs_vol_list.pop()

        # Attach the volume and wait for it to fully attach
        print("INFO: (%s) Attaching EBS volume to our instance ID (%s) to %s" % (vol.id, instanceid, dest))
        try:
            vol.attach(instanceid, dest.replace('xvd', 'sd'))
        except:
            time.sleep(5)
            vol.attach(instanceid, dest.replace('xvd', 'sd'))

    while not hasattr(vol.attach_data, 'instance_id'):
        time.sleep(1)
        vol.update()
        while not str(vol.attach_data.instance_id) == instanceid or not os.path.exists(dest) == True:
            print("INFO: (%s) Volume attaching..." % (vol.id))
            time.sleep(1)
            vol.update()

        # SLeep a few more seconds just to make sure the OS has seen the volume
        time.sleep(1)

        # Add the volume to our list of volumes that were created
        attached_ebs_vol_list.append(dest)
        print("INFO: (%s) Volume attached!" % (vol.id))

        # Now, tag the volumes and move on
        tags = {}
        tags["Name"] = "%s:%s" % (socket.gethostname(), dest)
        print("INFO: (%s) Taggin EBS volume with these tags: %s" % (vol.id, tags))
        ec2.create_tags(str(vol.id), tags)

    # All done. Return whatever volumes were created and attached.
    return attached_ebs_vol_list


def find_ebs_volumes(ebs_vol_list, ebs_volid_list):
    """Search Amazon for existing EBS Volume ids in our zone. If they exist,
    then mount them and return them. If they don't exist, we error out."""

    # Some local instance ID info..
    zone = commands.getoutput("wget -q -O - http://169.254.169.254/latest/meta-data/placement/availability-zone")
    region = zone[:-1]
    instanceid = commands.getoutput("wget -q -O - http://169.254.169.254/latest/meta-data/instance-id")
    available_ebs_vol_list = []
    attached_ebs_vol_list = []

    # Make sure that the device list we got is good. If a device exists already,
    # remove it from the potential 'device targets'
    for potential_volume in ebs_vol_list:
        if not os.path.exists(potential_volume):
            print("INFO: (%s) is available as a disk target." % (potential_volume))
            available_ebs_vol_list.append(potential_volume)

    # Reverse our available_ebs_vol_list so that we can 'pop' from the beginning
    available_ebs_vol_list.reverse()

    # Make sure we have enough target devices available
    if available_ebs_vol_list <= ebs_volid_list.__len__():
        print("ERROR: Do not have enough local volume targets available to attach the drives. Erroring out.")
        return False

    # Open our EC2 connection
    print("INFO: Connecting to Amazon...")
    ec2 = boto.ec2.connect_to_region(region)

    # For each volume..
    for ebs_volid in ebs_volid_list:
        print "INFO: (%s) Searching for EBS volume..." % (ebs_volid)
        vols = ec2.get_all_volumes(volume_ids=ebs_volid)
        vol = vols[0]

        # Check if the volume is attached. If it is, bail!
        if not str(vol.attach_data.status) == "None" \
            and not str(vol.attach_data.instance_id) == instanceid:
            print "ERROR: (%s) is attached to instance ID %s already. Exiting!" % (vol.id, vol.attach_data.instance_id)
            return False
        # If its attached, but to our host already then figure out
        # what device its attached to.
        elif not str(vol.attach_data.status) == "None" \
            and str(vol.attach_data.instance_id) == instanceid:
            print "WARNING: (%s) is already attached our instance ID at %s. Using that..." % (vol.id, vol.attach_data.device)
            dest = vol.attach_data.device
        else:
            ## Grab a volume off of our stack of available vols..
            dest = available_ebs_vol_list.pop()
            # Attach the volume and wait for it to fully attach
            print "INFO: (%s) Attaching EBS volume to our instance ID (%s) to %s" % (vol.id, instanceid, dest)
            vol.attach(instanceid, dest.replace('xvd','sd'))
            while not hasattr(vol.attach_data, 'instance_id'):
                time.sleep(1)
                vol.update()
            while not str(vol.attach_data.instance_id) == instanceid \
                or not os.path.exists(dest) == True:
                print "INFO: (%s) Volume attaching..." % (vol.id)
                time.sleep(1)
                vol.update()
            # Sleep a few more seconds just to make sure the OS has seen the volume
            time.sleep(1)

        # Check whether we are using /dev/xvd volumes or /dev/sd volumes. Amazon always returns a volume mount
        # point as '/dev/sdXXX' when sometimes its actually '/dev/xvdXXX'.
        if os.path.exists("/dev/xvda1"):
            dest = dest.replace('sd','xvd')
            print "INFO: (%s) Converting volume mount point to %s" % (vol.id, dest)

        # Add the volume to our list of volumes that were created
        attached_ebs_vol_list.append(dest)
        print "INFO: (%s) Volume attached!" % (vol.id)
 
        # Now, tag the volumes and move on
        tags = {}
        tags["Name"] = "%s-%s" % (socket.gethostname(), dest)
        print "INFO: (%s) Taggin EBS volume with these tags: %s" % (vol.id, tags)
        ec2.create_tags(str(vol.id), tags)

    # All done. Return whatever volumes were created and attached.
    return attached_ebs_vol_list
    
#### END FUNCTIONS ####

# Sanity check.. depending on our kernel, we use different volumes for EBS. Pick those here
if os.path.exists("/dev/sda1"):
    DEFAULT_EBS_DISK_NAMES=DEFAULT_EBS_DISK_NAMES_SD
else:
    DEFAULT_EBS_DISK_NAMES=DEFAULT_EBS_DISK_NAMES_XVD

# EBS volumes are created upon demand, mounted and raided. They will
# be labeled appropriately so that they are easily trackable.
vols = get_ebs_volumes(DEFAULT_EBS_DISK_NAMES, int(options.volcount), int(options.volsize), options.ebstype)
with open('/tmp/ebs_vols', 'a') as f:
    f.write(','.join(vols))
