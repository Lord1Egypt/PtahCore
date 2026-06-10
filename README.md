# PtahCore 𓁰

> An open-source **FP8 tensor accelerator** — SystemVerilog RTL → synthesis → place-and-route → **7nm GDSII**, on a 100% open-source toolchain. Named after Ptah, the Egyptian creator god and patron of craftsmen & architects.

🚧 **Under active construction** — Phase 0 of 10. Watch this repo: the full story (architecture, layouts, the fight with 7nm physics) lands here as it happens.

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
- `rtl/` — SystemVerilog leaves (fp8 decode, IEEE-754 RNE mul/add, MAC cell) + exhaustive cocotb suites

```bash
# Python side (no HW tools needed)
pip install numpy pytest && pytest          # 37 tests, < 1 s

# RTL side
sudo apt-get install verilator && pip install cocotb
cd rtl/tb && make all_leaves
```

---

Made with ❤️ by [Lord1Egypt](https://github.com/Lord1Egypt)
