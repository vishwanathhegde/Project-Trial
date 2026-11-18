#!/usr/bin/env bash
# =============================================================================
# build-base-vm.sh - builds the base VM for the SUASecLab RAG security lab
#
# Creates a minimal Debian 13 VM image with Packer + QEMU/KVM:
#   - unattended install from the Debian 13 DVD-1 ISO (no internet packages)
#   - admin account "labadmin": SSH key login only, passwordless sudo
#   - no root login, no password login
#
# Requirements (build host): Debian 13 x86-64 with KVM, packer, qemu-system-x86,
#                            qemu-utils, openssl, openssh-client
# Usage:   ./build-base-vm.sh <debian-13.x.x-amd64-DVD-1.iso> <admin-public-key.pub>
# Output:  output/rag-base/rag-base.qcow2  (+ .sha256, build-info.txt, packages.tsv)
# =============================================================================
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $# == 2 ]] || die "Usage: $0 <debian-13 DVD-1 ISO> <admin-public-key.pub>"
ISO="$(realpath -e -- "$1")"
KEY="$(realpath -e -- "$2")"
cd "$(dirname "$(realpath "$0")")"

WORK="$PWD/build-work"
OUT="$PWD/output/rag-base"

# --- 1. Check the build host ---------------------------------------------------
. /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 13 && "$(uname -m)" == x86_64 ]] || die "Needs Debian 13 on x86-64."
[[ -r /dev/kvm && -w /dev/kvm ]] || die "KVM not usable. Enable virtualization and run: sudo usermod -aG kvm \$USER"
for tool in packer qemu-system-x86_64 qemu-img openssl ssh-keygen sha256sum; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
[[ ! -e "$OUT" ]] || die "$OUT already exists. Move or delete it first."

# --- 2. Check the inputs -------------------------------------------------------
grep -q "PRIVATE KEY" "$KEY" && die "That is a PRIVATE key. Give the .pub file."
ssh-keygen -lf "$KEY" >/dev/null 2>&1 || die "Not a valid SSH public key: $KEY"

echo "Checking ISO checksum..."
ISO_SHA256="$(sha256sum "$ISO" | cut -d' ' -f1)"
SUMS="$(dirname "$ISO")/SHA256SUMS"
if [[ -f "$SUMS" ]]; then
    grep -q "^$ISO_SHA256  $(basename "$ISO")\$" "$SUMS" || die "ISO does not match $SUMS"
    echo "ISO verified against SHA256SUMS."
else
    echo "WARNING: no SHA256SUMS next to the ISO; compare manually: $ISO_SHA256"
fi

# --- 3. Prepare the work folder (deleted again at the end) ---------------------
rm -rf "$WORK"
mkdir -p "$WORK/http"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
cp "$KEY" "$WORK/admin.pub"

# One-time password, only used while Packer installs the VM
export PKR_VAR_build_password
PKR_VAR_build_password="$(openssl rand -hex 24)"
PASSWORD_HASH="$(printf '%s' "$PKR_VAR_build_password" | openssl passwd -6 -stdin)"

# --- 4. Debian installer answers (preseed) -------------------------------------
cat > "$WORK/http/preseed.cfg" <<EOF
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string rag-base
d-i netcfg/get_domain string lab.local
d-i netcfg/hostname string rag-base
d-i hw-detect/load_firmware boolean false

# Install from the DVD only, so the ISO fixes which packages are installed
d-i apt-setup/cdrom/set-first boolean false
d-i apt-setup/cdrom/set-next boolean false
d-i apt-setup/cdrom/set-failed boolean false
d-i apt-setup/use_mirror boolean false
d-i apt-setup/services-select multiselect

d-i passwd/root-login boolean false
d-i passwd/user-fullname string Lab Admin
d-i passwd/username string labadmin
d-i passwd/user-password-crypted password $PASSWORD_HASH

d-i clock-setup/utc boolean true
d-i time/zone string Europe/Berlin
d-i clock-setup/ntp boolean false

d-i partman-auto/disk string /dev/vda
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true

tasksel tasksel/first multiselect standard, ssh-server
d-i pkgsel/include string sudo
d-i pkgsel/upgrade select none
popularity-contest popularity-contest/participate boolean false

d-i grub-installer/only_debian boolean true
d-i grub-installer/bootdev string /dev/vda

d-i preseed/late_command string in-target sh -c 'echo "labadmin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/labadmin && chmod 0440 /etc/sudoers.d/labadmin'
d-i finish-install/reboot_in_progress note
EOF

# --- 5. Setup steps that run inside the VM as root -----------------------------
cat > "$WORK/provision.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Admin key: labadmin logs in with the instructor's SSH key
install -d -m 700 -o labadmin -g labadmin /home/labadmin/.ssh
install -m 600 -o labadmin -g labadmin /tmp/admin.pub /home/labadmin/.ssh/authorized_keys
rm -f /tmp/admin.pub

# SSH: keys only, no root login (active from the next boot)
cat > /etc/ssh/sshd_config.d/10-lab.conf <<'CONF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
sshd -t

# Normal Debian mirrors for the next stages (no update now: base = DVD content)
[[ -f /etc/apt/sources.list ]] && sed -i 's/^deb cdrom:/# deb cdrom:/' /etc/apt/sources.list
cat > /etc/apt/sources.list.d/debian.sources <<'CONF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
CONF

# List of installed packages (downloaded by Packer)
dpkg-query -W -f='${Package}\t${Version}\n' | sort > /tmp/packages.tsv
chmod 644 /tmp/packages.tsv

# Every copy of the image gets its own machine-id and SSH host keys at first boot
truncate -s 0 /etc/machine-id
rm -f /etc/ssh/ssh_host_*
mkdir -p /etc/systemd/system/ssh.service.d
cat > /etc/systemd/system/ssh.service.d/10-host-keys.conf <<'CONF'
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
CONF

apt-get clean
EOF

# --- 6. Packer recipe ------------------------------------------------------------
cat > "$WORK/base.pkr.hcl" <<'EOF'
packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0, < 2.0.0"
    }
  }
}

variable "iso_path"       { type = string }
variable "iso_checksum"   { type = string }
variable "output_dir"     { type = string }
variable "build_password" {
  type      = string
  sensitive = true
}

source "qemu" "base" {
  iso_url          = var.iso_path
  iso_checksum     = var.iso_checksum
  output_directory = var.output_dir
  vm_name          = "rag-base.qcow2"
  format           = "qcow2"
  disk_size        = "30G"
  disk_interface   = "virtio"
  disk_compression = true
  net_device       = "virtio-net"
  accelerator      = "kvm"
  headless         = true
  cpus             = 2
  memory           = 2048

  # The VM fetches preseed.cfg from the host; 10.0.2.2 = host loopback in QEMU user networking
  http_directory    = "${path.root}/http"
  http_bind_address = "127.0.0.1"
  boot_wait         = "5s"
  boot_command = [
    "<esc><wait>",
    "auto url=http://10.0.2.2:{{ .HTTPPort }}/preseed.cfg priority=critical ",
    "debian-installer/locale=en_US.UTF-8 keyboard-configuration/xkb-keymap=us ",
    "netcfg/get_hostname=rag-base netcfg/get_domain=lab.local <enter>"
  ]

  communicator     = "ssh"
  ssh_username     = "labadmin"
  ssh_password     = var.build_password
  ssh_timeout      = "60m"
  shutdown_command = "sudo shutdown -P now"
}

build {
  sources = ["source.qemu.base"]

  provisioner "file" {
    source      = "${path.root}/admin.pub"
    destination = "/tmp/admin.pub"
  }

  provisioner "shell" {
    script          = "${path.root}/provision.sh"
    execute_command = "sudo env {{ .Vars }} bash '{{ .Path }}'"
  }

  provisioner "file" {
    direction   = "download"
    source      = "/tmp/packages.tsv"
    destination = "${path.root}/packages.tsv"
  }

  # Remove the one-time password: from now on only the admin SSH key works
  provisioner "shell" {
    inline          = ["usermod -p '*' labadmin", "rm -f /tmp/packages.tsv"]
    execute_command = "sudo env {{ .Vars }} bash '{{ .Path }}'"
  }
}
EOF

# --- 7. Build ----------------------------------------------------------------------
export CHECKPOINT_DISABLE=1
packer init "$WORK/base.pkr.hcl"
packer build \
    -var "iso_path=$ISO" \
    -var "iso_checksum=sha256:$ISO_SHA256" \
    -var "output_dir=$OUT" \
    "$WORK/base.pkr.hcl" 2>&1 | tee "$PWD/build-base-vm.log"

# --- 8. Check and record the result -------------------------------------------------
qemu-img check "$OUT/rag-base.qcow2"
mv "$WORK/packages.tsv" "$OUT/"
cp "$PWD/build-base-vm.log" "$OUT/build.log"
(cd "$OUT" && sha256sum rag-base.qcow2 > rag-base.qcow2.sha256)
cat > "$OUT/build-info.txt" <<EOF
built:           $(date -u +%Y-%m-%dT%H:%M:%SZ)
iso:             $(basename "$ISO")
iso_sha256:      $ISO_SHA256
script_sha256:   $(sha256sum "$(realpath "$0")" | cut -d' ' -f1)
packer:          $(packer version | head -1)
packer_plugins:  $(packer plugins installed | tr '\n' ' ')
qemu:            $(qemu-system-x86_64 --version | head -1)
EOF
chmod 755 output "$OUT"
chmod 644 "$OUT"/*

echo
echo "Done: $OUT/rag-base.qcow2"
echo "Admin login: ssh labadmin@<vm-ip> with the key matching $(basename "$KEY")"
