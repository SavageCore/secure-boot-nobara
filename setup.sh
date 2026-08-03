#!/usr/bin/env bash
# Enrolls Secure Boot keys on Nobara using sbctl, signs the boot chain and
# kernel, and (if an Nvidia GPU is detected) enrolls the DKMS/akmods MOK key
# so out-of-tree modules keep loading once Secure Boot is enabled.
set -euo pipefail
shopt -s nullglob

VERSION="0.0.0"

# --- Output helpers --------------------------------------------------------

if [[ -t 1 ]]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
    GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; CYAN=$'\e[36m'
else
    BOLD=""; DIM=""; RESET=""; GREEN=""; YELLOW=""; RED=""; CYAN=""
fi

step() { echo -e "\n${BOLD}${CYAN}==> $*${RESET}"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
warn() { echo "${YELLOW}⚠${RESET} $*"; }
err()  { echo "${RED}✗${RESET} $*" >&2; }
info() { echo "${DIM}$*${RESET}"; }

# --- Preflight ---------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    err "This script must be run as root."
    info "Try: sudo $0"
    exit 1
fi

echo "${BOLD}Secure Boot setup for Nobara${RESET} ${DIM}v${VERSION}${RESET}"
info "Enrolls Secure Boot keys with sbctl (https://github.com/Foxboron/sbctl)"
info "and signs your boot chain, kernel, and Nvidia/DKMS modules."

# --- Install sbctl ------------------------------------------------------------

if command -v sbctl >/dev/null; then
    ok "sbctl is already installed"
else
    step "Installing sbctl"
    dnf -y copr enable chenxiaolong/sbctl
    dnf -y install sbctl
    ok "sbctl installed"
fi

# --- Unlock immutable EFI variables --------------------------------------------

if lsattr /sys/firmware/efi/efivars/PK-* 2>/dev/null | grep -q 'i'; then
    step "Unlocking immutable EFI variables"
    chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}-* 2>/dev/null || true
    ok "EFI variables unlocked"
fi

step "Current sbctl status"
sbctl status
status_json=$(sbctl status --json)
setup_mode=$(grep -q '"setup_mode": *true' <<< "$status_json" && echo y || echo n)
has_microsoft=$(grep -q '"microsoft"' <<< "$status_json" && echo y || echo n)
secure_boot=$(grep -q '"secure_boot": *true' <<< "$status_json" && echo y || echo n)

# --- Detect GPU ---------------------------------------------------------------

step "Detecting GPU"
gpu_lines=$(lspci -nnk 2>/dev/null | grep -E "VGA compatible controller|3D controller" || true)

if [[ -z "$gpu_lines" ]]; then
    warn "Could not detect a GPU via lspci"
    gpu_summary="unknown"
    is_nvidia=n
elif grep -qi nvidia <<< "$gpu_lines"; then
    gpu_summary=$(grep -i nvidia <<< "$gpu_lines" | head -1 | sed -E 's/^[0-9a-f:.]+ [^:]+: //')
    is_nvidia=y
else
    gpu_summary=$(head -1 <<< "$gpu_lines" | sed -E 's/^[0-9a-f:.]+ [^:]+: //')
    is_nvidia=n
fi
ok "Detected: $gpu_summary"

if [[ "$setup_mode" == n ]]; then
    # Keys are already enrolled - nothing to ask, nothing to confirm.
    ok "Secure Boot keys are already enrolled - skipping key enrollment"
    [[ "$has_microsoft" == y ]] && info "Microsoft vendor keys are already enrolled"
    info "Continuing with module-signing key check and binary signing."
    dualboot=n
else
    # --- Question -------------------------------------------------------------

    echo
    read -rp "Do you need Microsoft's certificates for dual-booting Windows or anti-cheat games (Valorant, Battlefield 6, etc.)? (Y/n): " dualboot
    [[ "$dualboot" =~ ^[Nn]$ ]] || dualboot=y

    # --- Summary & confirmation ------------------------------------------------

    step "Summary"
    echo "  GPU:              $gpu_summary"
    if [[ "$is_nvidia" =~ ^[Yy]$ ]]; then
        echo "  Nvidia detected:  will enroll DKMS/akmods MOK key to keep modules trusted"
    fi
    if [[ "$dualboot" == y ]]; then
        echo "  Microsoft certs:  will enroll"
    else
        echo "  Microsoft certs:  skipped"
    fi
    echo "  Keys:             creating new sbctl keys"
    echo "  Then:             sign every unsigned EFI binary and kernel image"
    echo
    read -rp "Proceed? (Y/n): " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        warn "Aborted, nothing was changed."
        exit 0
    fi
fi

# --- Enroll keys --------------------------------------------------------------

mok_pending=0

enroll_keys() {
    step "Enrolling Secure Boot keys"
    if [[ "$dualboot" == y ]]; then
        sbctl enroll-keys --microsoft
    else
        sbctl enroll-keys
    fi
    ok "Keys enrolled"
}

# Nvidia/DKMS kernel modules are checked against the MOK/machine keyring, not
# the UEFI db, so the module-signing cert is enrolled via mokutil. This is
# independent of Setup Mode and safe to re-run.
enroll_mok() {
    step "Enrolling DKMS module-signing key (Nvidia)"
    mok_certs=(/var/lib/dkms/mok.pub /etc/pki/akmods/certs/*.der)
    if [[ ${#mok_certs[@]} -eq 0 ]]; then
        warn "No DKMS/akmods signing cert found; Nvidia may fail to load."
    fi
    for cert in "${mok_certs[@]}"; do
        [[ -f "$cert" ]] || continue
        echo
        info "Enrolling: $cert"
        info "You'll be asked to set a one-time password - remember it, you'll need it after reboot."
        import_output=$(mokutil --import "$cert" 2>&1) || warn "Failed to enroll $cert"
        echo "$import_output"
        if grep -q "SKIP:.*already enrolled" <<< "$import_output"; then
            ok "Already enrolled: $cert"
        else
            mok_pending=1
        fi
    done
}

if [[ "$setup_mode" == y ]]; then
    step "Setup Mode is enabled - creating and enrolling keys"
    sbctl create-keys
    ok "Keys created"
    enroll_keys
    step "Status after enrollment"
    sbctl status
fi
[[ "$is_nvidia" =~ ^[Yy]$ ]] && enroll_mok

# --- Sign EFI binaries ------------------------------------------------------

step "Signing EFI binaries"

attempts=0
while true; do
    # Strip bogus "invalid pe header" noise sbctl emits for non-PE files.
    verify_output=$(sbctl verify 2>&1 | grep -v "failed to verify file" || true)
    echo "$verify_output"

    # .zst files are excluded: signing compressed archives corrupts them.
    unsigned_efi=$(echo "$verify_output" | grep "✗" | awk '{print $2}' | grep -E "\.efi$|\.EFI$" | grep -v "\.zst$" || true)

    if [[ -z "$unsigned_efi" ]]; then
        ok "All EFI binaries are signed"
        break
    fi

    if (( ++attempts > 2 )); then
        warn "Still unsigned after $attempts passes, giving up on:"
        echo "$unsigned_efi"
        break
    fi

    echo
    info "Found unsigned EFI binaries:"
    echo "$unsigned_efi"

    while read -r file; do
        [[ -z "$file" ]] && continue
        echo "Signing: $file"
        sbctl sign -s "$file" || warn "Failed to sign $file"
    done <<< "$unsigned_efi"
done

# --- Sign kernels ------------------------------------------------------------

step "Signing kernel images"
kernels=(/boot/vmlinuz-*)

if [[ ${#kernels[@]} -gt 0 ]]; then
    for kernel in "${kernels[@]}"; do
        echo "Signing kernel: $kernel"
        sbctl sign -s "$kernel" || warn "Failed to sign $kernel"
    done
else
    warn "No kernel images found in /boot/"
fi

step "Final verification"
sbctl verify | grep -v "failed to verify file"
ok "All EFI binaries and kernels have been signed"

# --- Next steps ----------------------------------------------------------------

step "Next steps"
if [[ "$mok_pending" -eq 0 && "$secure_boot" == y ]]; then
    ok "Secure Boot is already enabled and everything is signed - nothing left to do."
else
    n=1
    if [[ "$mok_pending" -eq 1 ]]; then
        echo "${BOLD}${n}. Reboot.${RESET} A blue MOK Management screen will appear first:"
        echo "     Enroll MOK → Continue → Yes → enter the password you just set → Reboot"
        ((n++))
    fi
    if [[ "$secure_boot" != y ]]; then
        echo "${BOLD}${n}. Enter your BIOS/UEFI firmware setup and enable Secure Boot.${RESET}"
        info "   Keep Secure Boot Mode set to \"Custom\" if your board has that option -"
        info "   switching to \"Standard\" can wipe your enrolled keys."
        ((n++))
    fi
    echo "${BOLD}${n}. Once back in Nobara, confirm everything took effect:${RESET}"
    info "     mokutil --sb-state   # SecureBoot enabled"
    info "     sbctl status         # Secure Boot: ✓ Enabled"
    if [[ "$is_nvidia" =~ ^[Yy]$ ]]; then
        info "     nvidia-smi           # driver loads"
    fi
fi
