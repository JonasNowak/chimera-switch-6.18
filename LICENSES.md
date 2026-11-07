# Licensing Policy

This repository uses a split license structure to respect upstream kernel licensing while keeping automation scripts permissively reusable:

| Path / Component | License | File |
|---|---|---|
| `patches/`, `configs/` (Kernel patches, Device Tree diffs, `.config`) | **GPL-2.0-only** | [LICENSE-GPL-2.0](LICENSE-GPL-2.0) |
| `scripts/`, `.github/workflows/`, `docs/`, `README.md`, `VERSIONS` | **MIT** | [LICENSE-MIT](LICENSE-MIT) |

## Proprietary / Third-Party Notice

- **Zero Nintendo proprietary artifacts** (keys, `prodinfo`, `BOOT0`/`BOOT1`, `package1`/`package2`, `switch.cal`, or copyrighted firmware) are included in or accepted into this repository.
- Upstream Linux kernel sources (`linux-nx`) are fetched at build time from [l4t-community/kernel/linux-nx](https://gitlab.com/l4t-community/kernel/linux-nx) under `GPL-2.0-only`.
- Upstream Enigma kernel patches originate from [Garyu-tt/x1SteamOS](https://github.com/Garyu-tt/x1SteamOS) under `GPL-2.0-only`.
- Switchroot / L4T boot chain binaries (`bl31.bin` ARM Trusted Firmware, `bl33.bin` U-Boot) are fetched at packaging time from [l4t-community](https://gitlab.com/l4t-community) under their respective open-source licenses (BSD-3-Clause / GPL-2.0+) and are excluded from git tracking via `.gitignore`.
