#!/bin/bash

set -ouex pipefail

source /ctx/build_files/shared/copr-helpers.sh

echo "::group:: Copy Files"

### Copy files to image
rsync -rvK /ctx/system_files/ /

mkdir -p /tmp/scripts/helpers
install -Dm0755 /ctx/build_files/shared/utils/ghcurl /tmp/scripts/helpers/ghcurl
export PATH="/tmp/scripts/helpers:$PATH"

echo "::endgroup::"


echo "::group:: Installation preparation"

# Apply IP Forwarding before installing Docker to prevent messing with LXC networking
sysctl -p

# Load iptable_nat module for docker-in-docker.
# See:
#   - https://github.com/ublue-os/bluefin/issues/2365
#   - https://github.com/devcontainers/features/issues/1235
mkdir -p /etc/modules-load.d
tee /etc/modules-load.d/ip_tables.conf <<EOF
iptable_nat
EOF

echo "::endgroup::"


echo "::group:: Install"
### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/43/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs a package from fedora repos
dnf5 install -y \
  btop \
  tmux vim-enhanced git \
  fish zsh \
  podman-compose

# Docker
dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
sed -i "s/enabled=.*/enabled=0/g" /etc/yum.repos.d/docker-ce.repo
dnf -y install --enablerepo=docker-ce-stable \
    containerd.io \
    docker-buildx-plugin \
    docker-ce \
    docker-ce-cli \
    docker-compose-plugin \
    docker-model-plugin \
    docker-ce-rootless-extras

# Enable services
systemctl enable docker.socket
systemctl enable podman.socket
systemctl enable bluefin-dx-groups.service

# Tailscale
dnf config-manager addrepo --from-repofile=https://pkgs.tailscale.com/stable/fedora/tailscale.repo
dnf config-manager setopt tailscale-stable.enabled=0
dnf -y install --enablerepo='tailscale-stable' tailscale

# Sublime Text
dnf config-manager addrepo --from-repofile=https://download.sublimetext.com/rpm/stable/x86_64/sublime-text.repo
dnf config-manager setopt sublime-text.enabled=0
dnf -y install --enablerepo='sublime-text' sublime-text

tee /etc/yum.repos.d/netbird.repo <<EOF
[netbird]
name=netbird
baseurl=https://pkgs.netbird.io/yum/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.netbird.io/yum/repodata/repomd.xml.key
repo_gpgcheck=1
EOF
dnf config-manager addrepo --overwrite --from-repofile=/etc/yum.repos.d/netbird.repo
dnf config-manager setopt netbird.enabled=0
# netbird's %post runs `netbird service start`; the
# start/daemon-reload steps need a live systemd and make dnf exit 1 in a
# container build. Skip the scriptlet and drive the installer ourselves.
dnf -y install --enablerepo='netbird' --setopt=tsflags=noscripts netbird
dnf -y install --enablerepo='netbird' netbird-ui gtk4 webkitgtk6.0 xdg-utils

netbird service uninstall || true
netbird service install --log-file console || true

systemctl enable netbird.service

# Install nerdfonts (all of them them for simpler management)
copr_install_isolated "che/nerd-fonts" "nerd-fonts"

# Starship Shell Prompt
ghcurl "https://github.com/starship/starship/releases/latest/download/starship-x86_64-unknown-linux-gnu.tar.gz" --retry 3 -o /tmp/starship.tar.gz
tar -xzf /tmp/starship.tar.gz -C /tmp
install -c -m 0755 /tmp/starship /usr/bin
# shellcheck disable=SC2016
echo 'eval "$(starship init bash)"' >>/etc/bashrc

# Qemu
dnf -y install qemu \
    qemu-char-spice \
    qemu-device-display-virtio-gpu \
    qemu-device-display-virtio-vga \
    qemu-device-usb-redirect \
    qemu-img \
    qemu-system-x86-core \
    qemu-user-binfmt \
    qemu-user-static

# Gnome Shell Extensions
sudo dnf install -y gnome-shell-extension-appindicator

echo "::endgroup::"


echo "::group:: Cleanup"
# Cleanup
dnf5 remove -y gnome-shell-extension-apps-menu \
  gnome-shell-extension-launch-new-instance \
  gnome-shell-extension-places-menu \
  gnome-shell-extension-window-list \
  gnome-shell-extension-background-logo

dnf clean all

# Mitigation until upstream version is rolled out https://github.com/podman-container-tools/podman/pull/30243
v=$(rpm -q --qf '%{VERSION}' podman) && if [ "$(printf '%s\n' "$v" 6.2.1 | sort -V | head -n1)" = "$v" ] && [ "$v" != 6.2.1 ]; then install -d /usr/lib/systemd/system/user@.service.d /usr/lib/systemd/user/podman.service.d && printf '[Service]\nOOMScoreAdjust=0\n' > /usr/lib/systemd/system/user@.service.d/10-oom-adj-floor.conf && printf '[Service]\nOOMScoreAdjust=200\n' > /usr/lib/systemd/user/podman.service.d/10-oom-adj-floor.conf; else rm -f /usr/lib/systemd/system/user@.service.d/10-oom-adj-floor.conf /usr/lib/systemd/user/podman.service.d/10-oom-adj-floor.conf; fi

rm -rf /.gitkeep
find /var/* -maxdepth 0 -type d \! -name cache -exec rm -fr {} \;
find /var/cache/* -maxdepth 0 -type d \! -name libdnf5 \! -name rpm-ostree -exec rm -fr {} \;
rm -rf /tmp && mkdir -p /tmp
rm -rf /boot && mkdir -p /boot

echo "::endgroup::"
