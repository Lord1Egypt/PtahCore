# PtahCore 𓁰

> An open-source **FP8 tensor accelerator** — SystemVerilog RTL → synthesis → place-and-route → **7nm GDSII**, on a 100% open-source toolchain. Named after Ptah, the Egyptian creator god and patron of craftsmen & architects.

🚧 **Under active construction** — Phase 0 of 10. Watch this repo: the full story (architecture, layouts, the fight with 7nm physics) lands here as it happens.

- 📐 [PLAN.md](PLAN.md) — full architecture & roadmap
- ✅ [STEPS.md](STEPS.md) — live execution checklist

## What's here so far

- `config.py` — single source of truth for every design parameter
- `golden/` — bit-exact fp8 (e4m3 **and** e5m2) encode/decode + matmul reference, fully tested

```bash
pip install numpy pytest
pytest
```

---

Made with ❤️ by [Lord1Egypt](https://github.com/Lord1Egypt)
