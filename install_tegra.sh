#!/bin/sh

# This script is intended to be run on a Jetson TK1 board, from
# the root prompt of an INSTALL kernel (the ramdisk from which sysinst
# runs), and should work within those limitations.  There are LOTS
# of assumptions about the working environment. Proceed with caution.

# Jetson TK1 has an internal eMMC which will have
# the following layout by default:

#     start      size  index  contents
#     94208  29360128      1  GPT part - "APP"
#  29454336      8192      2  GPT part - "DTB"
#  29462528    131072      3  GPT part - "EFI"
#  29593600      8192      4  GPT part - "USP"
#  29601792      8192      5  GPT part - "TP1"
#  29609984      8192      6  GPT part - "TP2"
#  29618176      8192      7  GPT part - "TP3"
#  29626368      4096      8  GPT part - "WB0"
#  29630464   1142784      9  GPT part - "UDA"

# the "APP" partition contains the Linux4Tegra install,
# the others are all empty.

# This script formats the "EFI" partition, and
# installs boot.scr and the kernel (with .ub extension)
# there.  The assumption is that there is a single
# disk, wd0, which will be partitioned for pbulk builds.

# defaults.  Edit these.

bootwedge="EFI"
targetdisk=wd0
hostname=armbulk2.NetBSD.org
ipaddr="10.187.5.2/16"
defaultroute="10.187.0.1"
partition_basename=${hostname%.NetBSD.org}

# XXX these should be dynamic
rootsz="8G"
swapsz="16G"
# if we have to remove nullfs, squeeze these down
datasz="16G"
scratchsz="20G"
pkgsz="30G"
distsz="40G"

root_mtpt=/targetroot
setsdir=${root_mtpt}/INSTALL
#sets_url="http://ftp.netbsd.org/pub/NetBSD/NetBSD-7.0/evbarm-earmv7hf/binary/sets/"
sets_url="http://slash.lan:8080/sets/"
sets="base.tgz comp.tgz etc.tgz games.tgz man.tgz misc.tgz tests.tgz text.tgz"

kern_url=${sets_url}
kern=netbsd.gdb
kern_ub=netbsd.ub

# extra directories to create in /
extra_dirs="kern proc boot home bulk-data bulk-scratch distfiles packages"

export PATH=/usr/bin:/usr/sbin:/bin:/sbin

# unit number for dk device, for mknod
BLK=168
CHR=168

dehumanize_number()
{
  local size=$1
  local suffix=${size##*[0-9]}
  local m
  case ${suffix} in
    [kK]) m=1024 ;;
    [mM]) m=1048576 ;;
    [gG]) m=1073741824 ;;
    [tT]) m=1099511627776 ;;
    "")   m=1 ;;
    *)    echo "dehumanize_number: bad suffix ${suffix} for number ${size}"
          return 1 ;;
  esac

  echo "$(( ${size%%[kmgtKMGT]} * ${m} ))"
}

add()
{
  local arg
  local sum=0

  for arg do
    local num=$(dehumanize_number ${arg})
    sum=$((${sum} + ${num}))
  done

  echo $sum
}

mkdev()
{
  local unit=${1#dk}
  if [ ! -c /dev/rdk$unit ]; then
    mknod -m 640 -g operator -u root /dev/rdk$unit c $CHR $unit
  fi
  if [ ! -b /dev/dk$unit ]; then
    mknod -m 640 -g operator -u root /dev/dk$unit b $BLK $unit
  fi
}

# this is really naive, but hard to do right without dkctl changes
make_device_nodes()
{
  for i in dk0 dk1 dk2 dk3 dk4 dk5 dk6 dk7 dk8 dk9 dk10 dk11 dk12 dk13 dk14
  do
    mkdev $i
  done
}

sanity_check()
{
  # make sure disks are what we expect
  local sectors=$(drvctl -p ${targetdisk} disk-info/geometry/sectors-per-unit)
  local ssize=$(drvctl -p ${targetdisk} disk-info/geometry/sector-size)

  local need=$(add $rootsz $swapsz $datasz $scratchsz $pkgsz $distsz)
  local have=$(( $sectors * $ssize ))
  if [ $have -lt $need ]; then
    echo "disk $targetdisk is only $have bytes, need $need"
    return 1
  fi
  return 0
}

create_boot_partition()
{
}

partition_main_disk()
{
  # gpt(8) doesn't set exit codes.  Argh!
  gpt create -f ${targetdisk}  
  # just in case a gpt already existed, remove all partitions
  gpt remove -a ${targetdisk}
  gpt add -a 4096 -s ${rootsz} -l "${partition_basename}-root" -t ffs ${targetdisk}
  gpt add -a 4096 -s ${swapsz} -l "${partition_basename}-swap" -t swap ${targetdisk}
  gpt add -a 4096 -s ${datasz} -l "${partition_basename}-pbulk-data" -t ffs ${targetdisk}
  gpt add -a 4096 -s ${scratchsz} -l "${partition_basename}-pbulk-scratch" -t ffs ${targetdisk}
  gpt add -a 4096 -s ${pkgsz} -l "${partition_basename}-packages" -t ffs ${targetdisk}
  gpt add -a 4096 -s ${distsz} -l "${partition_basename}-distfiles" -t ffs ${targetdisk}

  # make the newly-added partitions into wedges for great justice
  dkctl ${targetdisk} makewedges
  make_device_nodes
}

format_partitions()
{
  newfs -V1 -O2 NAME="${partition_basename}-root"
  newfs -V1 -O2 -b4096 NAME="${partition_basename}-pbulk-data"
  # scratch will get re-newfsed every time anyway, but this 
  # won't hurt.
  newfs -V1 -O2 -b4096 NAME="${partition_basename}-pbulk-scratch"
  newfs -V1 -O2 NAME="${partition_basename}-packages"
  newfs -V1 -O2 NAME="${partition_basename}-distfiles"
}

create_setsdir()
{
  # assume setsdir is under root_mtpt
  mkdir -p ${root_mtpt}
  echo "mounting root wedge"
  mount NAME=${partition_basename}-root ${root_mtpt}
  mkdir -p ${setsdir}
}

fetch_sets()
{
  local s
  for s in ${sets}
  do
    ftp -o ${setsdir}/${s} ${sets_url}/${s}
  done
  ftp -o ${setsdir}/${kern} ${kern_url}/${kern}
  ftp -o ${setsdir}/${kern_ub} ${kern_url}/${kern_ub}
}

install_sets()
{
  local s d

  for s in ${sets}
  do
    echo tar -C ${root_mtpt} -xpzf ${setsdir}/${s}
    tar -C ${root_mtpt} -xpzf ${setsdir}/${s}
  done

  echo "making extra directories"
  for d in $extra_dirs
  do
    mkdir -p ${root_mtpt}/${d}
  done
}

chroot_script()
{
  cat > ${root_mtpt}/tmp/script.sh <<EOF
echo "Making devices in /dev..."
cd /dev && ./MAKEDEV all
echo "Creating boot.scr in /tmp..."
mkubootimage -A arm -C none -O netbsd -T script -a 0 -n "NetBSD/tegra boot" /tmp/boot.txt /tmp/boot.scr
EOF
}

make_fstab()
{
  cat > ${root_mtpt}/etc/fstab <<EOF
NAME=${partition_basename}-root	/		ffs	rw,discard	1 1
NAME=EFI	/boot		msdos	rw	1 1
kernfs		/kern		kernfs	rw
ptyfs		/dev/pts	ptyfs	rw
procfs		/proc		procfs	rw
tmpfs		/var/shm	tmpfs	rw,-m1777,-sram%25
NAME=${partition_basename}-swap	none		swap	sw	0 0

NAME=${partition_basename}-pbulk-data /bulk-data      ffs     rw,discard,log  1 2
NAME=${partition_basename}-packages     /packages       ffs     rw,discard      1 3
NAME=${partition_basename}-pbulk-scratch      /bulk-scratch   ffs     rw,discard,async,noatime,noauto 0 0

NAME=${partition_basename}-distfiles     /distfiles       ffs     rw,discard      1 4
EOF
}

make_rcconf()
{
  sed -i s,rc_configured=NO,rc_configured=YES, ${root_mtpt}/etc/rc.conf
  echo "hostname=${hostname}" >> ${root_mtpt}/etc/rc.conf
  echo "ifconfig_re0='${ipaddr}'" >> ${root_mtpt}/etc/rc.conf
  echo 'ifconfig_lo0="127.0.0.11 alias ; 127.0.0.12 alias ; 127.0.0.13 alias ; 127.0.0.14 alias ; 127.0.0.15 alias ; 127.0.0.16 alias ; 127.0.0.17 alias ; 127.0.0.18 alias ; 127.0.0.19 alias ; 127.0.0.20 alias ; 127.0.0.21 alias ; 127.0.0.22 alias ; 127.0.0.23 alias ; 127.0.0.24 alias ; 127.0.0.25 alias ; 127.0.0.26 alias ;  127.0.0.27 alias ; 127.0.0.28 alias"' >> ${root_mtpt}/etc/rc.conf
  echo "defaultroute=${defaultroute}" >> ${root_mtpt}/etc/rc.conf
  echo 'sshd=YES' >> ${root_mtpt}/etc/rc.conf
  echo ntpd=YES >> ${root_mtpt}/etc/rc.conf
  echo 'ntpd_flags="-g"' >> ${root_mtpt}/etc/rc.conf
  echo 'mdnsd=YES' >> ${root_mtpt}/etc/rc.conf
}

make_resolvconf()
{
}

make_boottxt()
{
  cat > ${root_mtpt}/tmp/boot.txt <<EOF
setenv bootargs root=wedge:${partition_basename}-root
fatload mmc 0:3 0x90000000 ${kern_ub}
bootm 0x90000000
EOF
}

install_kernel()
{
  mount -t msdos NAME=${bootwedge} /mnt
  cp ${setsdir}/${kern_ub} /mnt
  cp ${root_mtpt}/tmp/boot.scr /mnt
  cp ${root_mtpt}/tmp/boot.txt /mnt
  umount /mnt
  cp ${setsdir}/${kern} ${root_mtpt}/netbsd
}

configure()
{
  make_fstab
  make_rcconf
  make_resolvconf
  make_boottxt
  chroot_script
  chroot ${root_mtpt} sh /tmp/script.sh
}

cleanup()
{
  echo "unmounting ${root_mtpt}..."
  umount ${root_mtpt}
}

# Begin install
if ! sanity_check; then
  echo "Sanity check failed.  Exiting..."
  exit 1
fi

echo "This script is used to install NetBSD/evbarmv7hf on a single SSD"
echo "attached at wd0, for the purposes of building a pkgsrc bulk build"
echo "box.  IT WILL DESTROY ALL DATA ON THE DISK at wd0! DO NOT PROCEED"
echo "UNLESS YOU ARE WILLING TO ACCEPT THIS!"
echo
echo -n "if you answer 'OK' here, we will proceed and destroy your data:"
read ANSWER

if [ "$ANSWER" != "OK" ]; then
  echo "$ANSWER is not OK, aborting"
  exit 1
fi

trap cleanup INT QUIT HUP

create_boot_partition
partition_main_disk
format_partitions
create_setsdir
fetch_sets
install_sets
configure
install_kernel
cleanup
