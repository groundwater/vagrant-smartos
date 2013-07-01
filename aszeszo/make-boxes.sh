#!/bin/bash

for i in smartos-base191 smartos-base191-64 smartos-ec11 smartos-sngl0990 smartos163; do
    rm -rf ~/.vagrant.d/boxes/$i
    mkdir -p ~/.vagrant.d/boxes/$i/virtualbox
    mkdir -p ~/.vagrant.d/boxes/$i/vmware_fusion
    printf "{\n  \"provider\": \"virtualbox\"\n}\n" >~/.vagrant.d/boxes/$i/virtualbox/metadata.json
    printf "{\n  \"provider\": \"vmware_fusion\"\n}\n" >~/.vagrant.d/boxes/$i/vmware_fusion/metadata.json
    MAC=$(grep MACAddress vb/$i.ovf | head -1 | sed 's/.*MACAddress=\"//;s/\".*//')
    cat Vagrantfile | sed s/@MAC@/$MAC/ >~/.vagrant.d/boxes/$i/virtualbox/Vagrantfile
    cp ~/.vagrant.d/boxes/$i/virtualbox/Vagrantfile ~/.vagrant.d/boxes/$i/vmware_fusion/Vagrantfile
    cp vb/$i.ovf ~/.vagrant.d/boxes/$i/virtualbox/box.ovf
    cat box.vmx | sed s/@NAME@/$i/ >~/.vagrant.d/boxes/$i/vmware_fusion/$i.vmx

    rsync -av $i/ ~/.vagrant.d/boxes/$i/virtualbox/
    rsync -av $i/ ~/.vagrant.d/boxes/$i/vmware_fusion/

done
