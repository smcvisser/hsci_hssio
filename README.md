# hsci_hssio

ADI's **HSCI** (High Speed Control Interface, `axi_hsci`) on a **Zynq UltraScale+**
using the **High Speed SelectIO Wizard** (PG188), with TX and RX in different HP banks.

ADI ships `library/axi_hsci` and a reference PHY for the VCU118 (Virtex US+), but no
ready-made solution for a split-bank UltraScale+ integration. This repo generates
that: from a part number and 8 package pins it derives two wizard instances, an RTL
wrapper with the correct bitslice indices, and the matching constraints.

> **Status: work in progress.** See [What works / what doesn't](#what-works--what-doesnt)
> below. The target device `xczu17eg-ffvd1760-1-e` has since been verified in Vivado
> 2025.1. The full generation run was done on an `xczu7ev`, because a matching pinout
> existed for that part; the pinout for `ffvd1760` still needs to be chosen.

---

## Language convention

The chat runs in **Dutch**, switching to English whenever that is clearer.
Everything written into the repo — code, comments, docs, commit messages — is
in **English**.

---

## Target configuration

| | |
|---|---|
| Target FPGA | `xczu17eg-ffvd1760-1-e` — exists, HP banks 65, 66, 69, 70, 71 |
| Slave | AD9084 / AD9088 (Apollo MxFE) |
| Vivado | 2025.1 and 2026.1 (wizard is 3.6 in both) |
| Wizard | `high_speed_selectio_wiz` **3.6** |
| Link rate | 1600 Mb/s desired — **not achievable on -1**, see [Speed grade](#speed-grade) |

---

## What HSCI is

A source-synchronous LVDS link at 1.6 Gbps per direction that replaces SPI as the
control interface to the MxFE. Four differential pairs:

| signal | direction | function |
|---|---|---|
| `hsci_ckin_p/n` | FPGA → MxFE | forwarded clock, 800 MHz @ 1600 Mb/s |
| `hsci_din_p/n` | FPGA → MxFE | MOSI |
| `hsci_cko_p/n` | MxFE → FPGA | strobe |
| `hsci_do_p/n` | MxFE → FPGA | MISO |

`hsci_pclk` = data rate / 8 (8:1 serdes). The forwarded clock is data rate / 2:
`menc_clk` is hardcoded in the RTL as `8'h55` (or `8'hAA` with `mosi_clk_inv`) — a
toggle-per-bit pattern through the same serializer.

See [docs/protocol.md](docs/protocol.md) for the wire protocol, the auto-linkup FSM
and the register/memory layout, and [docs/observations.md](docs/observations.md) for
notes on ADI's RTL.

---

## Contents

```
demo/
  build_demo.py          one command: pins -> IP -> RTL -> synthesis  (uv run)
  demo_config.json       part, eight pins, clocks, rate
  templates/             Jinja: hsci_phy_top.sv, top level, XDC, file list
  vivado/                the Vivado half: analysis + IP + synthesis check
scripts/
  hsci_hssio_gen.tcl     main script: analysis -> 2 wizard IPs + wrapper + XDC
  hsci_hssio_lib.tcl     the shared engine: pin analysis, rule checks, IP helpers
  hsci_find_pins.tcl     finds valid pin combinations on a given part
  hsci_list_parts.tcl    validates the part, shows speed grades in the same footprint
  hsci_pin_index.tcl     part + pin -> PKGPIN_BYTEGROUP_INDEX / PKGPIN_NIBBLE_INDEX
  hsci_nibble.tcl        pin -> physical nibble (BITSLICE_CONTROL site) from the device DB
  hsci_check_wrapper.tcl synthesizes the generated wrapper against the generated IP
  hsci_probe_wizard.tcl  dumps wizard version and CONFIG properties
rtl/
  hsci_top.sv            connects axi_hsci to the generated PHY (AXI4-Lite in, pads out)
reference/
  hsci_phy_top.sv        ADI's VCU118 PHY wrapper (source of the port-map derivation)
  versal_hsci_phy.tcl    ADI's Versal variant, for comparison
docs/
  protocol.md            HSCI wire protocol, linkup, registers
  observations.md        findings in ADI's RTL
  vivado-findings.md     what came out empirically from Vivado 2025.1 and 2026.1
  hssio_for_demo.txt     the wizard config the demo is based on
```

Generated (in `.gitignore`): `hsci_phy_2bank.sv`, `hsci_phy_pins.xdc`,
`demo/generated/`, and `src/adi-hdl/` (sparse clone of ADI's HDL).

---

## Demo

A complete design from one command:

```bash
uv run demo/build_demo.py --check
```

Eight package pins in, and out comes: two wizard instances, a PHY with exactly the
ports `axi_hsci` wants, a top level with MMCM clocks, a JTAG-AXI debug master on its
own clock domain, an AXI-Lite clock converter to `hsci_pclk`, and the XDC. With
`--check` it also synthesizes the whole thing (7060 cells on an `xczu17eg`).

See [demo/README.md](demo/README.md).

---

## Usage

**1 — check the part and see speed grades**

```bash
vivado -mode batch -source scripts/hsci_list_parts.tcl
```

**2 — find valid pins** (or skip this if your pinout is already fixed)

```bash
vivado -mode batch -source scripts/hsci_find_pins.tcl -tclargs xczu17eg-ffvd1760-1-e 4
```

Prints ready-to-paste `set cfg(...)` lines.

**3 — generate**

Fill in the config block at the top of `scripts/hsci_hssio_gen.tcl` and run:

```bash
vivado -mode batch -source scripts/hsci_hssio_gen.tcl
```

Set `cfg(probe_only) 1` to only analyze and see the predicted port map.

**4 — synthesize the wrapper**

```bash
vivado -mode batch -source scripts/hsci_check_wrapper.tcl -tclargs xczu17eg-ffvd1760-1-e
```

Runs `synth_design` out-of-context on `hsci_phy_2bank` together with the two
generated IPs. The port check in the generator only compares names against the
`.veo`; this is the real test.

---

## Pin → physical nibble

`scripts/hsci_nibble.tcl` translates a package pin to the piece of silicon underneath
it, from the device database instead of a regex on `PIN_FUNC`:

```bash
vivado -mode batch -source scripts/hsci_nibble.tcl \
       -tclargs xczu17eg-ffvd1760-1-e AP18
```

```
=== AP18 : IO_L16P_T2U_N6_QBC_AD3P_65 ===
  bank 65   byte 2   nibble U   N6   bsc5
  iob            IOB_X0Y84
  bitslice       BITSLICE_RX_TX_X0Y84
  bsc_site       BITSLICE_CONTROL_X0Y13     <- the physical nibble
  nibble_global  13
  riu_or         RIU_OR_X0Y6
  pll_select     PLL_SELECT_SITE_X0Y13
  xiphy_tile     XIPHY_BYTE_L_X28Y90
  clk_cap        QBC
```

Without pin names it dumps the complete nibble layout of every HP bank. As a library:

```tcl
set hsci_nibble_library 1
source scripts/hsci_nibble.tcl
hsci_nib_load_device xczu17eg-ffvd1760-1-e
dict get [hsci_nibble_of_pin AP18] bsc_site
```

The proc cross-checks its result on every call against `PIN_FUNC`,
`PKGPIN_BYTEGROUP_INDEX` and `PKGPIN_NIBBLE_INDEX`; discrepancies end up in
`warnings` instead of silently producing a wrong `bscN`. See
[docs/vivado-findings.md](docs/vivado-findings.md) for the measured site
structure this rests on.

### Just the two indices

If what Vivado already knows is enough for you, `scripts/hsci_pin_index.tcl` is the
whole story — one proc, no derivation:

```tcl
source scripts/hsci_pin_index.tcl
hsci_pin_index xczu17eg-ffvd1760-1-e AP18    ;# bytegroup 6 nibble 0
```

| property | meaning |
|---|---|
| `PKGPIN_BYTEGROUP_INDEX` | 0..12, position in the byte group — the `N` from `PIN_FUNC` |
| `PKGPIN_NIBBLE_INDEX` | 0..6, position in the nibble |

Cost: `get_package_pins` returns **nothing** until `link_design` has loaded the device
database, which costs about 14 s once on an `xczu17eg`. After that, a call takes
0.9 ms, and reading out all 1760 pins of the package takes 113 ms. The proc therefore
remembers which part is loaded and runs `link_design` at most once per Vivado session.

---

## Pin rules

The script checks these and fails with the reason attached:

1. All four pairs in an **HP bank** (`BT_HIGH_PERFORMANCE`). HD banks have no BITSLICE.
2. **RX strobe and RX data in the same byte group**, with the strobe on a **DBC or
   QBC pin** (N0/N1 or N6/N7). The same *nibble* is not required: DBC = dual byte
   clock and clocks both nibbles of its byte group, QBC = quad byte clock and reaches
   four. If strobe and data are in different nibbles, the RX instance gets two
   `BITSLICE_CONTROL`s and thus two sets of bsc ports.
3. **TX clkfwd and TX data in the same byte group.**
4. `VCCO = 1.8V` on both banks (LVDS in HP banks). Not checkable from Vivado —
   noted as a comment in the generated XDC.

---

## Port map

The wizard's port names can be derived mechanically. Rule, derived from ADI's
VCU118 combination and **empirically confirmed on Vivado 2025.1 and 2026.1, wizard
3.6**:

```
pad port          = SIGNAL_NAME                          (with APPEND_PIN_NO = 0)
fabric TX         = data_from_fabric_<SIGNAL_NAME>
fabric RX         = data_to_fabric_<SIGNAL_NAME>
bitslice control  = {dly_rdy,vtc_rdy,en_vtc}_bsc<byte*2 + nibble>
per-slice FIFO    = {fifo_rd_clk,fifo_rd_en,fifo_empty}_<byte*13 + pin index>
PLL / reset       = clk, rst, pll0_locked, pll0_clkout0, rst_seq_done
```

Verification: RX strobe on byte2 N6, data on N8 gave `dly_rdy_bsc5` (2·2+1) and
`fifo_rd_en_32` / `fifo_rd_en_34` (2·13+6 and +8). Exactly as predicted.

The wizard also delivers `pll0_clkout1` and `shared_pll0_clkoutphy_out`; the wrapper
leaves those unconnected.

The script checks its own prediction after generation against the `.veo` template
and reports any discrepancies.

---

## Two banks, one clock

TX and RX in different banks means two XPLLs. `hsci_pclk` comes from the **TX** PLL,
and that clock also goes to `fifo_rd_clk` of the RX instance.

That's correct by construction: the MxFE derives `hsci_cko` from our `hsci_ckin`, so
the write side of the RX bitslice FIFO runs on (a delayed version of) the TX PLL
clock. Write and read sides are therefore mesochronous — same frequency, fixed but
unknown phase. The 8-deep FIFO only absorbs that phase. No real CDC needed.

The RX PLL is still needed for the RIU/VTC calibration of its own `BITSLICE_CONTROL`.

---

## Speed grade

The maximum rate is in the **"LVDS Native Mode Performance"** table of the datasheet
(DS925 for Zynq US+), row **RX DDR, RX_BITSLICE 1:8**. The RX side is the binding
constraint.

| speed grade | max native |
|---|---|
| -3 | 1600 Mb/s |
| -2 | 1600 Mb/s |
| **-1** | **1250 Mb/s** |

Native mode is the right table: the wizard uses `RX_BITSLICE`/`TX_BITSLICE` with
`BITSLICE_CONTROL` and the XPLL. Component mode (instantiating an `ISERDESE3`
yourself) is a different, lower path.

> **Pitfall.** 1250 Mb/s appears in two independent places in the datasheet: as the
> component-mode ceiling on -2/-3, and as the native-mode ceiling on -1. Same
> number, different cause. Summaries that say "native = 1600, component = 1250"
> only mention the first and wrongly imply that native always hits 1600.

**Consequence for this project:** on a `-1`, 1600 Mb/s is ruled out. Options:

1. `cfg(data_speed) 1250` → `hsci_pclk` 156.25 MHz, forwarded clock 625 MHz.
   Open question: does the AD9084 accept that rate? (`RG_HSCI_RATE_CTRL`, 0x8011)
2. A `-2` part.

`cfg(force_rate)` exists for when the table turns out to be too conservative — not
to bypass a real limit.

---

## What works / what doesn't

Tested on Vivado 2025.1 with `xczu7ev-ffvf1517-2-e` (full run) and on the actual
target device `xczu17eg-ffvd1760-1-e` (part, pin and nibble analysis):

| component | status |
|---|---|
| part and speed grade analysis | works, also on `xczu17eg-ffvd1760-1-e` |
| pin analysis (bank/byte/nibble/bsc/slice) | works, verified against `PIN_FUNC` and against the sites |
| pin → physical nibble (`hsci_nibble.tcl`) | works, all 52 pins of two banks check out |
| all rule checks + error messages | works |
| pin finder | works, also on the target device |
| port-map prediction | **confirmed** against the real `.veo` |
| generating the RX wizard instance | works |
| generating the TX wizard instance | works (with `BUS_DIR 0`, see below) |
| readback verification of properties | works, catches silently ignored properties |
| full end-to-end run | **green** on `xczu7ev`, 1600 Mb/s |
| synthesizing the wrapper (`hsci_check_wrapper.tcl`) | **not yet run** |

Two bugs surfaced and were fixed this round:

- **`cfg(busdir_tx)` had to be 0 (`TX_ONLY`), not 3.** With 3, the wizard silently
  sets `PLL0_CLK_SOURCE` to `IBUF_TO_PLL` and `PLL0_INPUT_CLK_FREQ` to 800 MHz — an
  instance that expects an external 800 MHz clock on a bank pin instead of your
  fabric reference. The generator now reads every property back and fails hard if
  the wizard ignores one.
- **Net name collision in the wrapper** when TX and RX happen to have the same
  `bsc` number (both numbered bank-locally). Nets are now prefixed `tx_`/`rx_`.

### Open items

1. **The pinout needs redoing.** The pins that were in the config block belong to
   MGT banks on `ffvd1760`; they came from a different pinout. HP banks on this
   package are **65, 66, 69, 70, 71**. `hsci_find_pins.tcl` now runs on the actual
   device and returns valid combinations — but the final choice depends on the PCB.
2. **The AD9084 side**: does it accept 1250 Mb/s, and what exactly does
   `RG_HSCI_RATE_CTRL` (0x8011) do? A question for the ADI FAE. At 1250 Mb/s
   `cfg(ref_freq)` also needs to change: 200 MHz is not a valid reference there,
   156.250 is.
3. **`PLL0_RX_EXTERNAL_CLK_TO_DATA = 3`** was copied from ADI. It's a property of
   how the MxFE outputs its data relative to `hsci_cko`, not of the FPGA.
4. **Trace matching**: the auto-linkup FSM only sweeps the TX phase. `hsci_cko` ↔
   `hsci_do` must be tightly matched on the PCB; nothing corrects for that.

---

## Sources

- [ADI HDL `library/axi_hsci`](https://github.com/analogdevicesinc/hdl/tree/main/library/axi_hsci)
- [ADI `ad9084_ebz` VCU118 project](https://github.com/analogdevicesinc/hdl/tree/main/projects/ad9084_ebz/vcu118) — the UltraScale+ reference
- [AXI HSCI Linux driver](https://developer.analog.com/docs/linux/drivers/misc/axi-hsci.html)
- PG188 — High Speed SelectIO Wizard
- UG571 — UltraScale Architecture SelectIO Resources
- DS925 — Zynq UltraScale+ MPSoC datasheet (DC/AC switching)
