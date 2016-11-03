#!/usr/bin/env bash
# Generate a minimal filesystem for archlinux and load it into the local
# docker as "archlinux"
# requires root
set -e

hash pacstrap &>/dev/null || {
	echo "Could not find pacstrap. Run pacman -S arch-install-scripts"
	exit 1
}

hash expect &>/dev/null || {
	echo "Could not find expect. Run pacman -S expect"
	exit 1
}

DATE=$1
IMAGE_NAME="arch linux"
NAME="arch_linux"
DESC="Arch LINUX"
DOCS="https://docs.joyent.com/images/lx-brand-beta"
GUESTTOOLS=sdc-vmtools-lx-brand

export LANG="C.UTF-8"

ROOTFS=$(mktemp -d ${TMPDIR:-/var/tmp}/rootfs-archlinux-XXXXXXXXXX)
chmod 755 $ROOTFS

# packages to ignore for space savings
PKGIGNORE=(
    cryptsetup
    device-mapper
    dhcpcd
    iproute2
    jfsutils
    linux
    lvm2
    man-db
    man-pages
    mdadm
    nano
    netctl
    openresolv
    pciutils
    pcmciautils
    reiserfsprogs
    s-nail
    systemd-sysvcompat
    usbutils
    vi
    xfsprogs
)
IFS=','
PKGIGNORE="${PKGIGNORE[*]}"
unset IFS

arch="$(uname -m)"
case "$arch" in
	armv*)
		if pacman -Q archlinuxarm-keyring >/dev/null 2>&1; then
			pacman-key --init
			pacman-key --populate archlinuxarm
		else
			echo "Could not find archlinuxarm-keyring. Please, install it and run pacman-key --populate archlinuxarm"
			exit 1
		fi
		PACMAN_CONF=$(mktemp ${TMPDIR:-/var/tmp}/pacman-conf-archlinux-XXXXXXXXX)
		version="$(echo $arch | cut -c 5)"
		sed "s/Architecture = armv/Architecture = armv${version}h/g" './mkimage-archarm-pacman.conf' > "${PACMAN_CONF}"
		PACMAN_MIRRORLIST1='Server = http://pacman.nocsi.org/$arch/$repo'
		PACMAN_MIRRORLIST2='Server = http://mirrors.rutgers.edu/$repo/os/$arch'
		PACMAN_EXTRA_PKGS='archlinuxarm-keyring'
		EXPECT_TIMEOUT=1800 # Most armv* based devices can be very slow (e.g. RPiv1)
		ARCH_KEYRING=archlinuxarm
		DOCKER_IMAGE_NAME="armv${version}h/archlinux"
		;;
	*)
		PACMAN_CONF='./mkimage-arch-pacman.conf'
		PACMAN_MIRRORLIST1='Server = https://pacman.nocsi.org/archlinux/$repo/os/$arch'
		PACMAN_MIRRORLIST2='Server = https://mirrors.rutgers.edu/archlinux/$repo/os/$arch'
		PACMAN_EXTRA_PKGS=''
		EXPECT_TIMEOUT=60
		ARCH_KEYRING=archlinux
		DOCKER_IMAGE_NAME=archlinux
		;;
esac

export PACMAN_MIRRORLIST1
export PACMAN_MIRRORLIST2

expect <<EOF
	set send_slow {1 .1}
	proc send {ignore arg} {
		sleep .1
		exp_send -s -- \$arg
	}
	set timeout $EXPECT_TIMEOUT

	spawn pacstrap -C $PACMAN_CONF -c -d -G -i $ROOTFS base haveged openssh $PACMAN_EXTRA_PKGS --ignore $PKGIGNORE
	expect {
		-exact "anyway? \[Y/n\] " { send -- "n\r"; exp_continue }
		-exact "(default=all): " { send -- "\r"; exp_continue }
		-exact "installation? \[Y/n\]" { send -- "y\r"; exp_continue }
		-exact "delete it? \[Y/n\]" { send -- "y\r"; exp_continue }
	}
EOF

arch-chroot $ROOTFS /bin/sh -c 'rm -r /usr/share/man/*'
arch-chroot $ROOTFS /bin/sh -c "haveged -w 1024; pacman-key --init; pkill haveged; pacman -Rs --noconfirm haveged; pacman-key --populate $ARCH_KEYRING; pkill gpg-agent"
arch-chroot $ROOTFS /bin/sh -c "ln -s /usr/share/zoneinfo/UTC /etc/localtime"
echo 'en_US.UTF-8 UTF-8' > $ROOTFS/etc/locale.gen
arch-chroot $ROOTFS locale-gen

sed s/PasswordAuthentication\ yes/PasswordAuthentication\ no/ -i $ROOTFS/etc/ssh/sshd_config
sed s/UsePrivilegeSeparation\ sandbox/UsePrivilegeSeparation\ yes/ -i $ROOTFS/etc/ssh/sshd_config

cat << MOTD > $ROOTFS/etc/motd
   __        .                   .
 _|  |_      | .-. .  . .-. :--. |-
|_    _|     ;|   ||  |(.-' |  | |
  |__|   \`--'  \`-' \`;-| \`-' '  ' \`-'
                   /  ;  Instance (ARCH LINUX $DATE)
                   \`-'   $DOCS

MOTD

cat << PRODUCT > $ROOTFS/etc/product
Name: Joyent Instance
Image: $NAME $DATE
Documentation: $DOCS
Description: $DESC
PRODUCT


arch-chroot $ROOTFS /bin/sh -c 'echo $PACMAN_MIRRORLIST1 > /etc/pacman.d/mirrorlist'
arch-chroot $ROOTFS /bin/sh -c 'echo $PACMAN_MIRRORLIST2 >> /etc/pacman.d/mirrorlist'

git submodule init
git submodule update
mkdir --parents $ROOTFS/etc/systemd/system/multi-user.target.wants/
( cd $GUESTTOOLS
  ./install.sh -i $ROOTFS 
)

# udev doesn't work in containers, rebuild /dev
DEV=$ROOTFS/dev
rm -rf $DEV
mkdir -p $DEV
mknod -m 666 $DEV/null c 1 3
mknod -m 666 $DEV/zero c 1 5
mknod -m 666 $DEV/random c 1 8
mknod -m 666 $DEV/urandom c 1 9
mkdir -m 755 $DEV/pts
mkdir -m 1777 $DEV/shm
mknod -m 666 $DEV/tty c 5 0
mknod -m 600 $DEV/console c 5 1
mknod -m 666 $DEV/tty0 c 4 0
mknod -m 666 $DEV/full c 1 7
mknod -m 600 $DEV/initctl p
mknod -m 666 $DEV/ptmx c 5 2
ln -sf /proc/self/fd $DEV/fd

UNTEST=arch-rootfs-untested.tar.xz
tar --numeric-owner --xattrs --acls -C $ROOTFS -c . | xz -c -z - --threads=0 > $UNTEST
rm -rf $ROOTFS

echo "Testing filesystem..."
xzcat $UNTEST | docker import - archtest
docker run -t --rm archtest echo Success.
docker rmi archtest

echo "Creating local nocsi/archlinux"
xzcat $UNTEST | docker import - nocsi/$DOCKER_IMAGE_NAME
docker run --rm -t nocsi/$DOCKER_IMAGE_NAME echo Success.

echo "Approving filesystem..."
mv $UNTEST arch-rootfs-${DATE}.tar.xz
