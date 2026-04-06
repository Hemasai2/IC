# SSCC - Self-Healing Security Controller Chip (Version 4)

**A fully synthesizable, temperature-compensated Physically Unclonable Function (PUF) based hardware security controller with dynamic trust management and automatic self-healing.**

Designed for IoT, edge devices, and embedded systems requiring robust hardware-level authentication and fault tolerance.

---

## Version 4 (Latest)

**Release Date:** April 2026  
**File:** `sscc_version4.v`

### Major Fixes & Improvements in v4
- `reauth_req` is now a clean **one-cycle pulse** (no stuck-high)
- `low_trust` uses proper **hysteresis** (6/3 threshold)
- `REAUTH` state now has a **timeout escape path** (prevents lock-up)
- Trust score recovers **faster** (+2) than it decays (-1)
- Cleaner internal signal naming and better FSM recovery logic
- Improved testbench with better monitoring

---

## Features

- **Temperature-compensated PUF** core with real-time stabilization
- **Dynamic 8-bit Trust Score** with fast recovery
- **Self-Healing FSM** with 5 states:
  - NORMAL → RETRY → REROUTE → REAUTH → ISOLATE
- **Redundant data path** (primary + backup data)
- **Link error monitoring** with hysteresis
- **Fully synchronous digital design** (no analog components)
- **Ready for ASIC/FPGA** synthesis (tested with OpenLane Sky130 PDK)

---

## Architecture (7 Core Modules)

| Module               | Function |
|----------------------|----------|
| `puf_core`           | Generates raw PUF response with temperature effect |
| `puf_stabilizer`     | Corrects response and generates `stable_ok` |
| `auth_controller`    | Challenge-response authentication |
| `link_monitor`       | Detects persistent link errors |
| `trust_manager`      | Dynamic trust scoring + drift calculation + reauth pulse |
| `healing_fsm`        | Self-healing state machine |
| `backup_path_mux`    | Selects primary/backup/zero data based on state |

**Top Module:** `sscc_top` (with debug outputs for trust_score, heal_state, etc.)

---

## Quick Start - Simulation

```bash
# Run simulation with iverilog
iverilog -o sscc_tb sscc_version4.v
vvp sscc_tb

# View waveform
gtkwave wave.vcd
