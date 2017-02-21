# Usage:
# k8s-setup -F libvirt-caasp-url.profile

include "base-libvirt.profile"

#######################
# libvirt
#######################
volume_base = ""
volume_source = "http://download.suse.de/ibs/SUSE:/SLE-12-SP2:/Update:/Products:/CASP10/images/SUSE-CaaS-Platform-1.0-KVM-and-Xen.x86_64-1.0.0-Build8.6.qcow2"

# is the image an UEFI image? then you need a valid firmware
is_uefi_image = yes
firmware = "/usr/share/qemu/ovmf-x86_64-code.bin"
