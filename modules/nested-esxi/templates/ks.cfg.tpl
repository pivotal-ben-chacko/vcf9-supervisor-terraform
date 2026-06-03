# ESXi kickstart for unattended install.
# The installer (weasel) reads this from /ks.cfg on the boot ISO.
# Rendered per-host by Terraform's templatefile().

# Required: accept EULA
vmaccepteula

# Root password — sets root@<hostname>'s password to var.root_password
# (--iscrypted=false means plain text; the installer crypts it before write)
rootpw ${root_password}

# Wipe and install on the first VMFS disk. With nested ESXi having only one
# disk (the 80 GB vmdk we attach), this is unambiguous.
clearpart --firstdisk --overwritevmfs
install --firstdisk --overwritevmfs

# Network: static. nameserver takes a single arg; we pass the LAN3 gateway.
# This becomes vmk0 on vSwitch0/Management Network after first boot.
network --bootproto=static \
  --ip=${ip_addr} \
  --netmask=${netmask} \
  --gateway=${gateway} \
  --nameserver=${dns} \
  --hostname=${hostname}

# Reboot the VM after install completes.
reboot --noeject

# ─────────────────────────────────────────────────────────────────────
# First-boot customizations — run inside the installed ESXi on first boot
# ─────────────────────────────────────────────────────────────────────
%firstboot --interpreter=busybox

# Enable SSH + ESXi Shell so we can ssh in and use govc against the host
vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh
vim-cmd hostsvc/enable_esx_shell
vim-cmd hostsvc/start_esx_shell

# Suppress the "ESXi Shell is enabled" warning banner
esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1

# Allow nested-traffic security flags on vSwitch0 (saves us a step in
# Phase 1 of the runbook — but only affects vSwitch0; supervisor-dvs
# gets handled by the network module separately).
esxcli network vswitch standard policy security set --vswitch-name=vSwitch0 \
  --allow-promiscuous=true --allow-forged-transmits=true --allow-mac-change=true
