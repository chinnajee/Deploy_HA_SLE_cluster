#!/bin/sh
#########################################################
#
#
#########################################################
## DRBD OSCF2
#########################################################

if [ -f ../functions ] ; then
    . ../functions
else
    echo "! functions file needed! ; Exiting"
    exit 1
fi
check_load_config_file other

# SOME VARS
CIBNAME="drbd_ocfs2"
DRBDRESOURCE="ha2"
DRBDDEV="/dev/drbd0"
POOLDRBD="DRBD"
TARGETVD="vdd"
NODEA="ha1"
NODEB="ha2"
IPA=`grep ${NODEA} /var/lib/libvirt/dnsmasq/${NETWORKNAME}.hostsfile | cut -d , -f 2`
IPB=`grep ${NODEB} /var/lib/libvirt/dnsmasq/${NETWORKNAME}.hostsfile | cut -d , -f 2`

install_packages() {
    echo "############ START finstall_packages"
    pssh -h /etc/hanodes "zypper in -y drbd-kmp-default drbd drbd-utils"
}

drbd_ocfs2_cib() {
    echo "############ START drbd_ocfs2_cib"
    exec_on_node ${NODEA} "crm<<EOF
cib new ${CIBNAME}
verify
cib use live
cib commit ${CIBNAME}
exit
EOF"
}

disable_drbd() {
    echo "############ START disable_drbd"
    echo "- Disable drbd service on node"
    exec_on_node ${NODEA} "systemctl disable drbd"
    exec_on_node ${NODEB} "systemctl disable drbd"
}

create_vol_drbd() {
    echo "############ START create_vol_drbd"
    echo "- Create volume for DRBD device"
    virsh vol-create-as --pool ${POOLDRBD} --name ${POOLDRBD}A.qcow2 --format qcow2 --capacity 1G --allocation 1G --prealloc-metadata
    virsh vol-create-as --pool ${POOLDRBD} --name ${POOLDRBD}B.qcow2 --format qcow2 --capacity 1G --allocation 1G --prealloc-metadata
    virsh vol-list ${POOLDRBD}
    virsh pool-refresh --pool ${POOLDRBD}
}

delete_vol_drbd() {
    echo "############ START delete_vol_drbd"
    virsh vol-delete --pool ${POOLDRBD} ${POOLDRBD}A.qcow2
    virsh vol-delete --pool ${POOLDRBD} ${POOLDRBD}A.qcow2
}

attach_disk_to_node() {
    echo "############ START attach_disk_to_node"
    echo "- Attach volume to node"
    virsh attach-disk ${DISTRO}HA1 --live --cache none --type disk ${STORAGEP}/${POOLDRBD}/${POOLDRBD}A.qcow2 --target ${TARGETVD}
    virsh attach-disk ${DISTRO}HA2 --live --cache none --type disk ${STORAGEP}/${POOLDRBD}/${POOLDRBD}B.qcow2 --target ${TARGETVD}
}

detach_disk_from_node() {
    echo "############ START detach_disk_from_node"
    echo "- Detach volume from node"
    virsh detach-disk ${DISTRO}HA1 ${TARGETVD}
    virsh detach-disk ${DISTRO}HA2 ${TARGETVD}
}

create_drbd_resource() {
    echo "############ START create_drbd_resource"
    echo "- Create /etc/drbd.d/drbd.res file"
    exec_on_node ${NODEA} "cat >/etc/drbd.d/drbd.res<<EOF
resource drbd {
    device ${DRBDDEV};
    disk /dev/${TARGETVD};
    meta-disk internal;
    on ${NODEA} {
      address ${IPA}:7790;
    }
    on ${NODEB} {
      address ${IPB}:7790;
    }

EOF"
}

drbdconf_csync2() {
    echo "############ START drbdconf_csync2"
    echo "- Corosync2 drbd conf"
    exec_on_node ${NODEA} "grep /etc/drbd.conf /etc/csync2/csync2.cfg"
    if [ $? -eq 1 ]; then
    	exec_on_node ${NODEA} "perl -pi -e 's|}|\tinclude /etc/drbd.conf;\n\tinclude /etc/drbd.d;\n}|' /et
c/csync2/csync2.cfg"
    	exec_on_node ${NODEA} "csync2 -xv"
    else
        echo "- /etc/csync2/csync2.cfg already contains drbd files to sync"
    fi
}

finalize_DRBD_setup() {
    echo "############ START finalize_DRBD_setup"
    echo "- Initializes the metadata storage"
    exec_on_node ${NODEA} "drbdadm create-md drbd"
    exec_on_node ${NODEB} "drbdadm create-md drbd"
    echo "- Create the /dev/drbd"
    exec_on_node ${NODEA} "drbdadm up drbd"
    exec_on_node ${NODEB} "drbdadm up drbd"
    echo "- Create a new UUID to shorten the initial resynchronization of the DRBD resource"
    exec_on_node ${NODEA} "drbdadm new-current-uuid drbd/0"
    echo "- Make ${NODEA} primary"
    exec_on_node ${NODEA} "drbdadm primary drbd"
    echo "- Check the DRBD status"
    exec_on_node ${NODEA} "cat /proc/drbd"
    echo "- Start the resynchronization process on your intended primary node"
    exec_on_node ${NODEA} "drbdadm -- --overwrite-data-of-peer primary drbd"
}


configure_resources() {
    echo "############ START configure_resources"
    echo "- dual primary DRBD"
    exec_on_node ${NODEA} "crm<<EOF
configure primitive resDRBD ocf:linbit:drbd params drbd_resource=${DRBDRESOURCE} operations \$id='resDRBD-operations op monitor interval='20' role='Master' timeout='20' op monitor interval='30' role='Slave' timeout='20' 
configure ms msDRBD resDRBD configure meta resource-stickines='100' notify='true' master-max='2' interleave='true'
EOF"
    exec_on_node ${NODEB} "crm status"
}


##########################
##########################
### MAIN
##########################
##########################

echo "############ DRBD / OSCFS2 SCENARIO #############"
echo "  !! WARNING !! "
echo "  !! WARNING !! "
echo
echo " press [ENTER] twice OR Ctrl+C to abort"
read
read

install_packages
#drbd_ocfs2_cib
disable_drbd
create_pool DRBD
create_vol_drbd
attach_disk_to_node
drbdconf_csync2
finalize_DRBD_setup
#configure_resources

# restore initial conf
#detach_disk_from_node
#delete_vol_drbd
