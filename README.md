# secure-boot-nobara

A script that enrolls Secure Boot keys on Nobara using
[sbctl](https://github.com/Foxboron/sbctl), signs your boot chain and kernel,
and (optionally) enrolls the DKMS/akmods MOK key so Nvidia and other
out-of-tree kernel modules keep loading once Secure Boot is enabled.

## Before you start

1. Enter your BIOS/UEFI firmware setup and reset Secure Boot to **Setup Mode**
   (this usually means clearing/deleting existing PK/KEK/db keys).
2. Boot straight into Nobara - don't boot any other OS first.

## Usage

```bash
curl -fsSL -o setup.sh https://github.com/SavageCore/secure-boot-nobara/releases/latest/download/setup.sh && sudo bash setup.sh
```

The script asks questions and prompts for a MOK password, so it's fetched then
run rather than piped straight into `bash` - worth a skim before running
anything as root that touches Secure Boot anyway.

Or clone the repo instead:

```bash
git clone https://github.com/SavageCore/secure-boot-nobara.git
cd secure-boot-nobara
sudo ./setup.sh
```

The script will:

- Install `sbctl` from [Copr repo](https://copr.fedorainfracloud.org/coprs/chenxiaolong/sbctl/)
- Detect your GPU automatically
- Create and enroll Secure Boot keys (optionally including Microsoft's
  certificates, needed for dual-booting Windows or for anti-cheat games like
  Battlefield 6/Valorant)
- Enroll your DKMS/akmods MOK key if an Nvidia GPU was detected
- Sign every unsigned EFI binary and kernel image

## After updates

- **Nvidia driver updates** - nothing to do. DKMS rebuilds and re-signs with
  the same key you enrolled.
- **Kernel updates** - nothing to do. sbctl's `91-sbctl.install` kernel hook
  signs new kernels automatically.
- **GRUB/shim updates** (`grub2-efi`, `shim-x64`) - **re-run the script**, or
  just `sudo sbctl verify && sudo sbctl sign-all`. There's no dnf hook for
  this, so a bootloader update can leave an unsigned binary behind and the
  machine won't boot with Secure Boot on until it's re-signed.

## Notes

- Works on other distributions too - swap the `dnf copr`/`dnf install` lines
  for your distro's sbctl install command (see the "Install" section of
  [sbctl](https://github.com/Foxboron/sbctl)).
- Safe to re-run: already-enrolled keys and already-signed files are skipped.
- `sudo sbctl verify` is the quick health check any time you're unsure
  everything is still signed.

## Issues & contributions

Issues and pull requests welcome.

## License

[MIT](LICENSE)
