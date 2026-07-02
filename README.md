# PtahCore 𓁰

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Release](https://img.shields.io/github/v/release/Lord1Egypt/PtahCore)](https://github.com/Lord1Egypt/PtahCore/releases)
[![Stars](https://img.shields.io/github/stars/Lord1Egypt/PtahCore)](https://github.com/Lord1Egypt/PtahCore/stargazers)
[![CI](https://github.com/Lord1Egypt/PtahCore/actions/workflows/ci.yml/badge.svg)](https://github.com/Lord1Egypt/PtahCore/actions)
[![GDSII](https://img.shields.io/badge/GDSII-Phase%206%20Complete-brightgreen)](docs/HARDENING.md)
[![FP8](https://img.shields.io/badge/FP8-e4m3%20%2B%20e5m2-ff6d00)](docs/ISA.md)

> An open-source **FP8 tensor accelerator** — SystemVerilog RTL → synthesis → place-and-route → **7nm GDSII**, on a 100% open-source toolchain. Named after Ptah, the Egyptian creator god and patron of craftsmen & architects.

🟢 **First GDS is out** — a full multi-tile FP8 matmul runs end-to-end through real SystemVerilog (`chip_top`), bit-exact against a golden numpy model, and the `mac_cell` tile has a **complete, signoff-clean 7nm GDSII on ASAP7**: 250 MHz with +1928 ps setup / +13 ps hold slack (zero violations, zero masked), DRC clean, 750 µm². Phase 6 of 10 done. Watch this repo: the fight with real silicon physics lands here as it happens.

<p align="center"><img src="docs/img/mac_cell_gds.webp" width="420" alt="mac_cell routed 7nm layout"><br><em>The routed mac_cell macro — RTL→GDSII on a laptop, 100% open tools (full story in <a href="docs/HARDENING.md">docs/HARDENING.md</a>)</em></p>

## Docs

| | |
|---|---|
| 📐 [PLAN.md](PLAN.md) | Roadmap contract — architecture decisions, 10 phases, risks |
| ✅ [STEPS.md](STEPS.md) | Live execution checklist, ticked per PR |
| 🏛️ [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Block diagram, memory spaces, engines, module map |
| 📜 [docs/ISA.md](docs/ISA.md) | The six instructions, barriers, canonical kernels |
| 🛠️ [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | **Read before contributing** — workflow & numeric contracts |
| 📊 [docs/ENGINEERING.md](docs/ENGINEERING.md) | Honest status + differentiators vs prior art |

## What's here so far

- `config.py` — single source of truth for every design parameter
- `golden/` — bit-exact fp8 (e4m3 **and** e5m2) encode/decode + matmul reference
- `pymodel/` — full cycle-level machine; e2e matmuls **bit-exact**, REPEAT K-loops, async-STORE overlap proven
- `rtl/` — **13 SystemVerilog modules**, from the fp8/fp32 arithmetic leaves up to `chip_top` — every one verified bit-exact under Verilator + cocotb
- **`chip_top.sv`** — the whole accelerator: push an instruction stream, it runs a multi-tile matmul and writes results to DRAM, bit-exact vs golden

```bash
# Python side (no HW tools needed)
pip install numpy pytest && pytest          # 37 tests, < 1 s

# RTL side — 13 units incl. the full chip
sudo apt-get install verilator && pip install 'cocotb<2'
cd rtl/tb && make all_leaves                # 52 RTL tests
```

**89 tests green** (52 RTL + 37 Python).

---

## License

PtahCore is released under the [Apache License 2.0](LICENSE).

---

Made with ❤️ by [Lord1Egypt](https://github.com/Lord1Egypt)
