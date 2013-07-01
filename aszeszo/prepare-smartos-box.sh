#!/bin/bash

# Create VM with two disks, 1G and 40G ones, install SmartOS from the ISO to the
# bigger one, set networking to use DHCP. Run this script after the machine
# is rebooted. Also, extract both tools-*.tar.bz2 tarballs in /opt.

set -e

if [[ -z $1 ]]; then
    printf "\nUsage: $0 image_uuid [zone-hostname]\n\n"
    exit 1
fi

ZONE_IMAGE=$1
ZONE_HOSTNAME=$2

CDROM=$(disklist -r|head -1)
BOOTDISK=$(disklist -n|awk '{ print $1; exit }')

SetupBootDisk() {

  echo Mounting cdrom...
  mkdir /mnt-cdrom
  mount -F hsfs /dev/dsk/${CDROM}p0 /mnt-cdrom

  echo Setting up the boot disk...
  cat <<EOF | fdisk -F /dev/stdin /dev/rdsk/${BOOTDISK}p0
0 0 0 0 0 0 0 0 0 0
0 0 0 0 0 0 0 0 0 0
0 0 0 0 0 0 0 0 0 0
0 0 0 0 0 0 0 0 0 0
EOF
  NUMSECT=$(iostat -En $BOOTDISK | awk '/^Size:/ { sub("<",""); \
    print $3/512 - 2048 }')
  fdisk -A 12:128:0:0:0:0:0:0:2048:$NUMSECT /dev/rdsk/${BOOTDISK}p0
  echo y|mkfs -F pcfs -o fat=32 /dev/rdsk/${BOOTDISK}p0:c

  echo Mounting boot disk...
  mkdir /mnt-boot
  mount -F pcfs /dev/dsk/${BOOTDISK}p1 /mnt-boot

  echo Copying SmartOS platform boot files to the boot disk...
  rsync -a /mnt-cdrom/ /mnt-boot/

  echo "Installing GRUB..."
  grub --batch <<EOF >/dev/null 2>&1
device (hd0) /dev/dsk/${BOOTDISK}p0
root (hd0,0)
install /boot/grub/stage1 (hd0) (hd0,0)/boot/grub/stage2 p (hd0,0)/boot/grub/menu.lst
quit
EOF

  echo "Fixing GRUB kernel & module menu.lst entries..."
  sed -i '' -e 's%kernel /platform/%kernel (hd0,0)/platform/%' \
    -e 's%module /platform/%module (hd0,0)/platform/%' \
    /mnt-boot/boot/grub/menu.lst

  echo "Setting GRUB timeout to 0s..."
  sed -i '' 's/timeout=.*/timeout=0/' /mnt-boot/boot/grub/menu.lst

  umount /mnt-cdrom
  umount /mnt-boot

  rmdir /mnt-cdrom
  rmdir /mnt-boot
}

ImportImage() {

  if ! zoneadm list -ic | grep ^zone$ >/dev/null && \
    ! imgadm list | grep $ZONE_IMAGE >/dev/null; then
    echo "Importing dataset..."
    imgadm import $ZONE_IMAGE
  fi

}

CreateZone() {

  if ! zoneadm list -ic | grep ^zone$ >/dev/null; then

    echo "Creating zone..."

    if [[ -z $ZONE_HOSTNAME ]]; then
      ZONE_HOSTNAME=vagrant-$(imgadm show $ZONE_IMAGE | json name version | \
        tr -d \.|tr -d \\n)
    fi

    if imgadm show $ZONE_IMAGE | json name | grep sngl >/dev/null; then
      ZONE_BRAND=sngl
    else
      ZONE_BRAND=joyent
    fi

    cat <<EOF >/zones/zone.json
{
  "zonename": "zone",

  "hostname": "$ZONE_HOSTNAME",
  "alias": "$ZONE_HOSTNAME",

  "brand": "$ZONE_BRAND",
  "image_uuid": "$ZONE_IMAGE",

  "ram": 32768,
  "quota": 1024,

  "zonename": "zone",
  "dns_domain": "localdomain",

  "resolvers": [
    "8.8.8.8",
    "8.8.4.4"
  ],

  "nics": [
    {
      "nic_tag": "admin",
      "ip": "dhcp",
      "primary": 1
    }
  ]

}
EOF

  #  "tmpfs": 32768,
  #  "fs_allowed": "ufs,pcfs,tmpfs",

  vmadm create -f /zones/zone.json

  # remove zone resource limits
  zfs set quota=none zones/zone
  zonecfg -z zone "set autoboot=false; remove rctl name=zone.cpu-shares; remove rctl name=zone.zfs-io-priority; remove rctl name=zone.max-lwps; remove rctl name=zone.max-physical-memory; remove rctl name=zone.max-locked-memory; remove rctl name=zone.max-swap"

  fi
}

RemoveImage() {
  if zfs list zones/$ZONE_IMAGE >/dev/null 2>&1; then
    echo Removing zone image...
    zfs promote zones/zone
    imgadm delete $ZONE_IMAGE
    zfs destroy zones/zone@zone
  fi

}

ConfigureGZ() {


  # create GZ autostart scripts

  if ! [[ -f /opt/custom/bin/autostart.sh ]]; then
    echo Creating /opt/custom/bin/autostart.sh...
    mkdir -p /opt/custom/bin
    cat <<EOAUTOSTARTSH >/opt/custom/bin/autostart.sh
#!/bin/bash

[[ -f /opt/tools-vmware/setup.sh ]] && /opt/tools-vmware/setup.sh

# VBOX_HARDDISK

svcadm enable -s svc:/network/physical:default

if svcs svc:/network/physical:default | grep ^maintenance >/dev/null; then

    MAC=\$(dladm show-phys -m -p -o address|head -1)

    cat <<EOF >/usbkey/config
coal=true
admin_nic=\$MAC
admin_ip=127.0.0.2
admin_netmask=255.255.255.255
EOF

    sysinfo -u

    svcadm disable -s svc:/network/physical:default
    svcadm enable -s svc:/network/physical:default
fi

svcadm disable svc:/network/ntp:default


# this is to make smtp:sendmail SMF service start quicker
HOSTNAME=\$(hostname)
cat <<EOF >/etc/inet/hosts
::1 localhost
127.0.0.1 localhost loghost \${HOSTNAME} \${HOSTNAME}.localdomain
EOF

# power off GZ after zone is halted
for i in joyent joyent-minimal; do
    cp /usr/lib/brand/\$i/statechange /tmp/statechange-\$i
    sed -i '' 's%^exit 0%[[ "\$subcommand" == "post" \&\& \$cmd == 4 ]] \&\& svcadm enable -t poweroff%' /tmp/statechange-\$i
    echo '[[ "\$subcommand" == "pre" && \$cmd == 0 ]] && svcadm disable poweroff' >> /tmp/statechange-\$i
    echo exit 0 >>/tmp/statechange-\$i
    mount -F lofs /tmp/statechange-\$i /usr/lib/brand/\$i/statechange
done

NIC=\$(dladm show-phys -po link)
MAC=\$(dladm show-phys -m -p -o address|head -1)
FAKEMAC=\$(dd if=/dev/urandom bs=1 count=3 2>/dev/null | od -tx1 | head -1 | cut -d' ' -f2- | awk '{ print "00:0c:29:"\$1":"\$2":"\$3 }')
ZONE=\$(zoneadm list -ic|grep -v ^global\$|head -1)

/usr/sbin/ifconfig \$NIC down
/usr/sbin/ifconfig \$NIC ether \$FAKEMAC
/usr/sbin/zonecfg -z \$ZONE "set autoboot=false; select net physical=net0; set mac-addr=\$MAC; end"

# remove VirtualBox/VMware specific zone config used for shared folders
FSALLOWED_NOVBOXFS=\$(zonecfg -z zone info fs-allowed|awk '{ print \$2 }'|sed 's/vboxfs//;s/,\$//')
if [[ -z \$FSALLOWED_NOVBOXFS ]]; then
    zonecfg -z \$ZONE "clear fs-allowed"
else
    zonecfg -z \$ZONE "set fs-allowed=\$FSALLOWED_NOVBOXFS"
fi
zonecfg -z \$ZONE "remove fs dir=/mnt/hgfs"

if prtconf -v|grep VMware >/dev/null; then
  if [[ -f /opt/tools-vmware/setup.sh ]]; then
    zonecfg -z \$ZONE "add fs; set dir=/mnt/hgfs; set special=/hgfs; set type=lofs; end"
    /opt/tools-vmware/setup.sh
  fi
fi

if prtconf -v|grep VBOX >/dev/null; then
  if [[ -f /opt/tools-virtualbox/setup.sh ]]; then
    if [[ -z \$FSALLOWED_NOVBOXFS ]]; then
       zonecfg -z \$ZONE "set fs-allowed=vboxfs"
    else
       zonecfg -z \$ZONE "set fs-allowed=\${FSALLOWED_NOVBOXFS},vboxfs"
    fi
    /opt/tools-virtualbox/setup.sh
  fi
fi

while ! svcs svc:/system/zones:default | grep ^online\  >/dev/null; do
        sleep 1
done

/usr/sbin/zoneadm -z \$ZONE boot

EOAUTOSTARTSH

    chmod +x /opt/custom/bin/autostart.sh

  fi

  if ! [[ -f /opt/custom/bin/poweroff.sh ]]; then
    echo Creating /opt/custom/bin/poweroff.sh...
    cat <<EOF >/opt/custom/bin/poweroff.sh
#!/bin/sh
sleep 2 && /usr/sbin/poweroff
EOF
    chmod +x /opt/custom/bin/poweroff.sh
  fi

  if ! [[ -f /opt/custom/smf/autostart.xml ]]; then
    echo Creating /opt/custom/smf/autostart.xml...
    mkdir -p /opt/custom/smf
    cat <<EOSMF >/opt/custom/smf/autostart.xml
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">

<service_bundle type='manifest' name='autostart'>
<service
        name='autostart'
        type='service'
        version='1'>

        <create_default_instance enabled='true' />

        <single_instance />

        <dependency
                name='fs-joyent'
                grouping='require_all'
                restart_on='none'
                type='service'>
                <service_fmri value='svc:/system/filesystem/smartdc' />
        </dependency>

        <exec_method
                type='method'
                name='start'
                exec='/opt/custom/bin/autostart.sh'
                timeout_seconds='0'>
        </exec_method>

        <exec_method
                type='method'
                name='stop'
                exec=':true'
                timeout_seconds='0'>
        </exec_method>

        <property_group name='startd' type='framework'>
                <propval name='duration' type='astring' value='transient' />
        </property_group>

        <stability value='Unstable' />

</service>
</service_bundle>
EOSMF
  fi


  if ! [[ -f /opt/custom/smf/poweroff.xml ]]; then
    echo Creating /opt/custom/smf/poweroff.xml...
    mkdir -p /opt/custom/smf
    cat <<EOSMF >/opt/custom/smf/poweroff.xml
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">

<service_bundle type='manifest' name='poweroff'>
<service
        name='poweroff'
        type='service'
        version='1'>

        <create_default_instance enabled='false' />

        <single_instance/>

        <exec_method
                type='method'
                name='start'
                exec='/opt/custom/bin/poweroff.sh'
                timeout_seconds='0'>
        </exec_method>

        <exec_method
                type='method'
                name='stop'
                exec=':kill'
                timeout_seconds='0'>
        </exec_method>

        <stability value='Unstable' />

</service>
</service_bundle>
EOSMF
  fi

  # reset GZ config
  echo Resetting /usbkey/config...
  cat <<EOF >/usbkey/config
coal=true
admin_nic=ff:ff:ff:ff:ff:ff
admin_ip=127.0.0.2
admin_netmask=255.255.255.255
EOF


echo "Setting root's password to 'vagrant'..."
sed -i '' 's%^root:.*%root:$2a$04$q6gsOZZg2SsxTmTmgjR7CuylIGwVIp1F2/8zKeClDlbogWTLQA6C2:6445::::::%' /usbkey/shadow
chown root:sys /usbkey/shadow

}

CleanupGZ() {
  echo "Cleaning up GZ..."
  rm -f /var/ssh/ssh_host*
  rm -f /var/adm/messages.*
  rm -f /var/log/syslog.*
  cp /dev/null /var/adm/messages
  cp /dev/null /var/log/syslog
  cp /dev/null /var/adm/wtmpx
  cp /dev/null /var/adm/utmpx
}

ConfigureZone() {
  echo "Configuring Zone..."
  cat <<EOF >/zones/zone/root/root/configure.sh
#!/bin/bash

sed -i'' 's%^root:.*%root:\$2a\$04\$q6gsOZZg2SsxTmTmgjR7CuylIGwVIp1F2/8zKeClDlbogWTLQA6C2:6445::::::%' /etc/shadow

groupadd -g 1000 vagrant
useradd -g 1000 -u 1000 -m -d /home/vagrant -s /bin/bash vagrant
sed -i'' 's%^vagrant:.*%vagrant:\$2a\$04\$q6gsOZZg2SsxTmTmgjR7CuylIGwVIp1F2/8zKeClDlbogWTLQA6C2:6445::::::%' /etc/shadow

chown root:sys /etc/shadow

mkdir ~vagrant/.ssh
cat <<EOKEY >~vagrant/.ssh/authorized_keys
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key
EOKEY
chown -R 1000:1000 ~vagrant/.ssh
chmod 700 ~vagrant/.ssh
chmod 600 ~vagrant/.ssh/authorized_keys

usermod -P "Primary Administrator" vagrant

for sudoers in /etc/sudoers /opt/local/etc/sudoers /ec/etc/sudoers; do
  if [[ -f \$sudoers ]]; then
    if ! grep ^vagrant \$sudoers >/dev/null; then
      echo "vagrant ALL=(ALL) NOPASSWD: ALL" >>\$sudoers
    fi
  fi
done

rm -f /var/ssh/ssh_host* /ec/etc/ssh/ssh_host*
rm -f /var/ssh/ssh_host*
rm -f /var/adm/messages.*
rm -f /var/log/syslog.*
cp /dev/null /var/adm/messages
cp /dev/null /var/log/syslog
cp /dev/null /var/adm/wtmpx
cp /dev/null /var/adm/utmpx
rm -f /root/.bash_history /home/vagrant/.bash_history
unset HISTFILE
history -c

EOF

  zlogin zone /bin/bash /root/configure.sh
  rm /zones/zone/root/root/configure.sh

}

SetupBootDisk
ImportImage
CreateZone
RemoveImage

ConfigureZone

ConfigureGZ
CleanupGZ
