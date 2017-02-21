# Usage:
# k8s-setup -F libvirt-caasp-local.profile

include "base-libvirt.profile"

#######################
# libvirt
#######################
volume_base = "SUSE-CaaS-Platform-1.0-KVM-and-Xen.x86_64-1.0.0-Build8.6.qcow2"
volume_source = ""

# is the image an UEFI image? then you need a valid firmware
is_uefi_image = yes
firmware = "/usr/share/qemu/ovmf-x86_64-code.bin"
