#cloud-config
# NFS storage VM cloud-init.

hostname: ${hostname}
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: Srosario1!
    shell: /bin/bash
ssh_pwauth: true
chpasswd:
  expire: false

write_files:
  - path: /etc/netplan/60-static.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          primary:
            match:
              name: en*
            dhcp4: false
            addresses: [${ip_addr}/24]
            routes:
              - to: default
                via: ${gateway}
            nameservers:
              addresses: [${dns_servers}]

  - path: /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    content: |
      network: {config: disabled}

  - path: /etc/exports
    permissions: '0644'
    content: |
      ${share_path} *(rw,sync,no_subtree_check,no_root_squash,insecure)

package_update: true
packages:
  - nfs-kernel-server
  - open-vm-tools
  - parted
  - xfsprogs

runcmd:
  - rm -f /etc/netplan/50-cloud-init.yaml
  - chmod 600 /etc/netplan/60-static.yaml
  - netplan apply

  # Format and mount the second disk as the share
  - parted -s /dev/sdb mklabel gpt mkpart primary xfs 0% 100%
  - mkfs.xfs -f /dev/sdb1
  - mkdir -p ${share_path}
  - bash -c "echo '/dev/sdb1  ${share_path}  xfs  defaults  0  0' >> /etc/fstab"
  - mount ${share_path}
  - chmod 0777 ${share_path}

  - systemctl enable --now nfs-kernel-server
  - exportfs -ra

  - systemctl enable open-vm-tools

final_message: "NFS server up — export ${ip_addr}:${share_path}"
