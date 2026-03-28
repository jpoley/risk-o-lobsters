# -*- mode: ruby -*-
# Vagrantfile — Arch Linux test VM for risk-o-lobsters
#
# Tests the setup scripts on Arch Linux.
# Libvirt provider (galway/Linux).

VM_CPUS   = Integer(ENV["VM_CPUS"]   || 2)
VM_MEMORY = Integer(ENV["VM_MEMORY"] || 2048)

Vagrant.configure("2") do |config|
  config.vm.box = "jumperfly/archlinux"
  config.vm.box_check_update = false
  config.vm.hostname = "arch-claw"
  config.vm.boot_timeout = 300
  config.ssh.forward_agent = true

  # Sync project into VM at /project
  config.vm.synced_folder ".", "/project", type: "rsync",
    rsync__exclude: [".git/", ".vagrant/"]

  # libvirt (galway)
  config.vm.provider "libvirt" do |lv|
    lv.cpus   = VM_CPUS
    lv.memory = VM_MEMORY
    lv.cpu_mode = "host-passthrough"
    lv.nested = true
  end

  # Parallels (Mac fallback)
  config.vm.provider "parallels" do |prl|
    prl.cpus   = VM_CPUS
    prl.memory = VM_MEMORY
  end

  # VirtualBox (fallback)
  config.vm.provider "virtualbox" do |vb|
    vb.cpus   = VM_CPUS
    vb.memory = VM_MEMORY
  end

  # Provision: refresh keyring, full sysupgrade, install base tools.
  # Stale Arch boxes have untrusted package sigs. Fix: temporarily disable
  # SigLevel to pull a fresh archlinux-keyring, then re-enable and upgrade.
  config.vm.provision "shell", privileged: true, inline: <<-SHELL
    set -euo pipefail

    echo "[provision] Fixing stale Arch keyring..."
    # Use a temporary pacman config with SigLevel=Never so the system config
    # is never touched — limits scope of the trust bypass to this one command.
    PACMAN_CONF_TMP="$(mktemp /tmp/pacman.conf.XXXXXX)"
    cp /etc/pacman.conf "$PACMAN_CONF_TMP"
    sed -i 's/^SigLevel.*/SigLevel = Never/' "$PACMAN_CONF_TMP"
    pacman --config "$PACMAN_CONF_TMP" -Sy --noconfirm archlinux-keyring 2>&1 | tail -5
    rm -f "$PACMAN_CONF_TMP"
    # Re-populate keyring from the freshly installed package (no network call)
    rm -rf /etc/pacman.d/gnupg
    pacman-key --init 2>&1 | tail -2
    pacman-key --populate archlinux 2>&1 | tail -3

    echo "[provision] Full system upgrade..."
    pacman -Syu --noconfirm 2>&1 | tail -15

    echo "[provision] Installing base tools..."
    # Avoid grep here — with set -euo pipefail, grep exits 1 if no lines match,
    # which would abort provisioning even on a successful pacman install.
    pacman -S --noconfirm --needed sudo curl git bash 2>&1 | tail -10

    systemctl enable dbus.service 2>/dev/null || true
    echo "[provision] Arch VM ready."
  SHELL
end
