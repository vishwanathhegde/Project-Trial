#!/usr/bin/env bash
# =============================================================================
# setup-build-host.sh - prepares a Debian 13 x86-64 host to run build-base-vm.sh
#
# Installs: qemu-system-x86, qemu-utils, openssh-client, packer (HashiCorp apt
# repo, signed-by keyring), and adds the current user to the kvm group.
#
# Safe to re-run. Must be run by a user with sudo rights; you will be prompted
# for your sudo password interactively.
#
# Usage: ./setup-build-host.sh
# =============================================================================
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

. /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 13 && "$(uname -m)" == x86_64 ]] || die "Needs Debian 13 on x86-64."

echo "--- 1. kvm group ---"
if [[ -e /dev/kvm ]]; then
    if id -nG "$USER" | grep -qw kvm; then
        echo "$USER is already in the kvm group."
    else
        sudo usermod -aG kvm "$USER"
        echo "Added $USER to the kvm group. Log out/in (or restart this WSL distro: 'wsl --shutdown' from Windows) for it to take effect."
    fi
else
    echo "WARNING: /dev/kvm does not exist. Enable virtualization (BIOS/VM settings), then re-run this script."
fi

echo "--- 2. gnupg/curl (needed to add the HashiCorp apt repo) ---"
sudo apt-get update -qq
sudo apt-get install -y gnupg curl

echo "--- 3. HashiCorp apt repo ---"
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --yes --dearmor -o /etc/apt/keyrings/hashicorp.gpg
sudo chmod 0644 /etc/apt/keyrings/hashicorp.gpg

SUITE="$VERSION_CODENAME"
if ! curl -fsS https://apt.releases.hashicorp.com/dists/ | grep -q "href=\"$SUITE/\""; then
    echo "HashiCorp repo has no '$SUITE' suite yet; falling back to bookworm."
    SUITE="bookworm"
fi

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $SUITE main" \
    | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null

echo "--- 4. apt-get update ---"
sudo apt-get update -qq

echo "--- 5. install build tools ---"
sudo apt-get install -y qemu-system-x86 qemu-utils openssh-client packer

echo
echo "Done. Installed versions:"
packer version
qemu-system-x86_64 --version | head -1
qemu-img --version | head -1
ssh-keygen -V 2>&1 || true
echo
echo "If this was the first time $USER was added to the kvm group, open a new shell"
echo "(or 'wsl --shutdown' + reopen on Windows) before running build-base-vm.sh."
