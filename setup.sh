#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

export LIBVIRT_DEFAULT_URI=qemu:///system

source cluster.conf

declare -a NODES=("b" "m1" "a1" "a2" "a3")

NATNET="default"
BRNET="host-bridge"
NATBR="virbr0"
BRBR="br0"
GWY="192.168.122.1"
DNS="192.168.122.1"

declare -A nics
nics[bmac]="52:54:00:fe:b3:10"
nics[bip]="192.168.122.110"
nics[m1mac]="52:54:00:fe:b3:20"
nics[m1ip]="192.168.122.120"
nics[m1macx]="52:54:00:fe:b3:2a"
nics[m1ipx]="192.168.1.222"
nics[a1mac]="52:54:00:fe:b3:31"
nics[a1ip]="192.168.122.131"
nics[a2mac]="52:54:00:fe:b3:32"
nics[a2ip]="192.168.122.132"
nics[a3mac]="52:54:00:fe:b3:33"
nics[a3ip]="192.168.122.133"

function initialSetup() {
    local disk
    if [ ! -d ${image_dir} ]; then
        mkdir ${image_dir}
        pushd ${image_dir}
        curl https://stable.release.core-os.net/amd64-usr/${COREOS_VERSION}/coreos_production_qemu_image.img.bz2 | bunzip2 >coreos_production_qemu_image.img
        popd
    fi

    for node in ${NODES[@]}; do
        disk=${image_dir}/${node}-disk.qcow2
        if [ ! -f ${disk} ]; then
            qemu-img create -f qcow2 -b ${image_dir}/coreos_production_qemu_image.img ${disk} 15G
        fi
    done

    if [ ! -d ${domain_dir} ]; then
        mkdir -p ${domain_dir}
    fi

    # If running in enforcing SE mode
    #semanage fcontext -a -t virt_content_t ${domain_dir}
    #restorecon -R ${domain_dir}

}

function createIps() {
    for node in ${NODES[@]}; do
        virsh net-update --network "${NATNET}" add-last ip-dhcp-host \
            --xml "<host mac='${nics[${node}mac]}' ip='${nics[${node}ip]}' />" \
            --live --config >/dev/null 2>&1 || true
    done
    #for node in m1 p1; do
    #    virsh net-update --network "${BRNET}" add-last ip-dhcp-host \
    #        --xml "<host mac='${nics[${node}macx]}' ip='${nics[${node}ipx]}' />" \
    #        --live --config
    #done
}

function writeIgnition() {
    local ext_nic
    for node in ${NODES[@]}; do
        ext_nic=""
        if [[ "m1 p1" == *"${node}"* ]]; then
            ext_nic=",{ \"name\": \"00-eth1.network\", \"contents\": \"[Match]\nMACAddress=${nics[${node}macx]}\n\n[Network]\nAddress=${nics[${node}ipx]}\nDNS=${DNS}\" }"
        fi

        cat >${domain_dir}/${node}-provision.ign <<EOF
{
  "ignition": {
    "version": "2.0.0",
    "config": {}
  },
  "storage": {
    "files": [
      {
        "filesystem": "root",
        "path": "/etc/hostname",
        "contents": {
          "source": "data:,${node}",
          "verification": {}
        },
        "user": {},
        "group": {}
      }
    ]
  },
  "systemd": {},
  "networkd": {
    "units": [
      {
        "name": "00-eth0.network",
        "contents": "[Match]\nMACAddress=${nics[${node}mac]}\n\n[Network]\nAddress=${nics[${node}ip]}\nGateway=${GWY}\nDNS=${DNS}"
      }${ext_nic}
    ]
  },
  "passwd": {
    "users": [
      {
        "name": "core",
        "sshAuthorizedKeys": [
          "${sshkey}"
        ]
      }
    ]
  }
}
EOF
    done

}

function generateDomains() {

    local ram vcpus pub_bridge domain
    for node in ${NODES[@]}; do
        ram=2048
        vcpus=1
        pub_bridge=()
        domain=${domain_dir}/${node}-domain.xml
        if [[ "a1 a2 a3" == *"${node}"* ]]; then
            vcpus=2
        fi
        if [[ "m1 p1" == *"${node}"* ]]; then
            pub_bridge=(--network bridge=${BRBR},mac=${nics[${node}macx]})
        fi

        virt-install --connect qemu:///system \
            --import \
            --name ${node} \
            --ram ${ram} --vcpus ${vcpus} \
            --os-type=linux \
            --os-variant=virtio26 \
            --disk path=${image_dir}/${node}-disk.qcow2,format=qcow2,bus=virtio \
            --network bridge=${NATBR},mac=${nics[${node}mac]} ${pub_bridge[@]} \
            --vnc --noautoconsole \
            --print-xml >${domain}
        sed -ie 's|type="kvm"|type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0"|' ${domain}
        sed -i "/<\/devices>/a <qemu:commandline>\n  <qemu:arg value='-fw_cfg'/>\n  <qemu:arg value='name=opt/com.coreos/config,file=${domain_dir}/${node}-provision.ign'/>\n</qemu:commandline>" ${domain}
    done
}

function startDomains() {
    local domain
    for node in ${NODES[@]}; do
        domain=${domain_dir}/${node}-domain.xml
        virsh define ${domain}
        virsh start ${node}
    done
}

function cleanDomains() {
    local disk
    for node in ${NODES[@]}; do
        disk=${image_dir}/${node}-disk.qcow2
        virsh destroy ${node} || echo "ok"
        virsh undefine ${node} || echo "ok"
        rm -f ${disk} || echo "ok"
        virsh net-update --network ${NATNET} delete ip-dhcp-host --xml "<host mac='${nics[${node}mac]}' ip='${nics[${node}ip]}' />" --live --config || echo "ok"
    done
}

sshkey=$(cat ${PUBKEY})
domain_dir=/var/lib/libvirt/container-linux/dcos
image_dir=/var/lib/libvirt/images/container-linux

if [ "${1:-}" == "clean" ]; then
    cleanDomains
    echo "Done"
    exit 0
fi

initialSetup
createIps
writeIgnition
generateDomains
startDomains

sleep 1m

./dcos-parallel-install.sh

echo "Done"
