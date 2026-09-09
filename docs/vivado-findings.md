# Empirical findings — Vivado 2025.1 and 2026.1

Everything below is measured, not assumed. Two test platforms:

| | |
|---|---|
| first round | Vivado 2026.1 (SW build 6511674), `xczu7ev-ffvf1517-2-e` |
| second round | Vivado 2025.1 (SW build 6140274), `xczu7ev-ffvf1517-2-e` **and** the actual target device `xczu17eg-ffvd1760-1-e` |

Where the two versions differ, it's noted; so far they haven't differed anywhere.

## Wizard version

`high_speed_selectio_wiz` is **3.6** in both 2025.1 and 2026.1 — the same version ADI
uses in their vcu118 project. So there's no property drift relative to ADI's
`create_ip` line.

IP objects have **no** `VERSION` property; the version is in `IPDEF`
(`xilinx.com:ip:high_speed_selectio_wiz:3.6`).

Number of `CONFIG.*` properties on a fresh instance: **547**.

## `get_package_pins` doesn't work without `link_design`

In a bare (in-memory) project, both `get_package_pins` and `get_iobanks` return
**zero** results. The device database is only loaded by `link_design`:

```tcl
create_project -in_memory -part $part
puts [llength [get_package_pins -quiet]]     ;# 0
link_design -part $part -name q
puts [llength [get_package_pins -quiet]]     ;# 1517
puts [llength [get_iobanks -quiet]]          ;# 23
```

`get_iobanks` returns the bank numbers themselves (`0 27 28 63 64 65 66 67 ...`), not
objects with a separate NAME.

`BANK_TYPE` values on this device: `BT_HIGH_PERFORMANCE` (8), `BT_HIGH_DENSITY` (2),
`BT_MGT` (7), `BT_PSS` (5), `BT_NO_USER_IO` (1).

### Consequence: DESIGN_MODE has to be restored

`link_design` sets `DESIGN_MODE` to `GateLvl`, and `close_design` does **not** set it
back. `create_ip` then refuses with:

```
ERROR: [Ipptcl 7-1624] IP commands are only valid for RTL projects.
```

`DESIGN_MODE` lives on the fileset, not on the project:

```tcl
close_design
set_property DESIGN_MODE RTL [get_filesets sources_1]
```

## Properties are free-form strings, not enums

`list_property_value` returns an **empty list** for `CONFIG.BUS_DIR`,
`CONFIG.BYTE0_PIN0_DATA_STROBE`, `CONFIG.BYTE0_PIN0_SIG_TYPE`,
`CONFIG.BYTE0_PIN0_BUS_DIR`, `CONFIG.DIFFERENTIAL_IO_STD`, `CONFIG.PLL0_CLK_SOURCE` and
`CONFIG.FIFO_RD_EN_CONTROL`. You can't validate values up front — only actually set
them and see what the wizard says.

Defaults on a fresh instance:

| property | default |
|---|---|
| `BUS_DIR` | `1` |
| `BYTE0_PIN0_DATA_STROBE` | `Data` |
| `BYTE0_PIN0_SIG_TYPE` | `SINGLE` |
| `BYTE0_PIN0_BUS_DIR` | `RX` |
| `DIFFERENTIAL_IO_STD` | `NONE` |
| `PLL0_CLK_SOURCE` | `IBUF_TO_PLL` |
| `FIFO_RD_EN_CONTROL` | `0` |

## LOC and NAME are auto-derived

Without setting `CONFIG.BANK`, `BYTE0_PIN0_LOC` was already `H38` and
`BYTE0_PIN0_NAME` was `IO_L1P_T0L_N0_DBC_27`. So the wizard fills the pin table
itself from the bank. The script still sets them explicitly as extra insurance, and
reads them back afterward as a check.

## Two pins are enabled by DEFAULT

This is the most important pitfall:

```
CONFIG.ENABLE_BYTE2_PIN0  = true   signal='clk'        strobe='Input Clock'
CONFIG.ENABLE_BYTE3_PIN12 = true   signal='bg3_pin12'  strobe='Data'
```

Leave those as-is and you get validation errors about byte groups you never touched:

```
Byte-Group 2 Lower Nibble bits cannot be Enabled with current strobe/clock positions
Port with name clk already exists, have a different name to 26 pin to proceed
```

(pin 26 = byte2 · 13 + 0). This is exactly why ADI's config has
`CONFIG.ENABLE_BYTE2_PIN0 {false}` and `CONFIG.ENABLE_BYTE3_PIN12 {false}`.

**Fix:** explicitly set every `ENABLE_BYTE?_PIN*` you don't use to `false`.

## Properties must be set atomically

Setting properties one by one doesn't work. The wizard validates after every
individual `set_property` and trips over an inconsistent intermediate state — for
example a pin being enabled while its `BUS_DIR` is still at the default `RX`:

```
RX and TX cannot be combined in same nibble when IP is operating in ASYNC/NONE mode,
Byte-Group 0 Lower Nibble is violating this rule
```

Doing everything in one `set_property -dict` fixes this. That's also what ADI does.

Downside: you lose the ability to see exactly which property fails. Fortunately the
wizard's message usually names the actual rule.

## BUS_DIR — solved, it's an enum

`BUS_DIR` is not a bitmask and not a bus count. It's an enum, and the labels are
right there in the IP's `component.xml`
(`<Vivado>/data/ip/xilinx/high_speed_selectio_wiz_v3_6/component.xml`, choice
`choice_pairs_1bcffd76`):

| value | label |
|---|---|
| **0** | **TX_ONLY** |
| **1** | **RX_ONLY** |
| 3 | TX + RX |
| 2 | BIDIR or TX+RX or TX+RX+BIDIR |

For the split-bank setup that's 0 for the TX instance and 1 for the RX instance.

What happened with the previously used `BUS_DIR 3` on a TX-only instance: the wizard
accepts it, but then silently changes the clock structure. Measured on the generated
`.xci`/`.veo`, 1600 Mb/s:

| property | BUS_DIR 3 (wrong) | BUS_DIR 0 (correct) |
|---|---|---|
| `PLL0_CLK_SOURCE` | `IBUF_TO_PLL`, **disabled** | `BUFG_TO_PLL` |
| `PLL0_INPUT_CLK_FREQ` | `800.000`, **disabled** | `200.000` |
| `C_INCLK_LOC` | `G28` (a pin in the bank!) | `NONE` (fabric) |
| `ooc.xdc` | `create_clock -period 1.250` | `create_clock -period 5.000` |

So with `BUS_DIR 3` you silently get an instance that expects an external 800 MHz
clock on a bank pin instead of your 200 MHz fabric reference — while the wrapper
connects that same `pll_inclk` to both instances. With `BUS_DIR 0`, TX and RX are
clocked identically: `MULT 8 / DIV 2` → VCO 800 MHz, `CLKOUTPHY` in `VCO_2X` →
1600 Mb/s.

`BUS_DIR 2` additionally clamps `PLL0_DATA_SPEED` to the range (800.0, 1300.0).

ADI's Versal config uses `BUS_DIR {3}` — that's correct there: one instance with both
TX *and* RX.

## Ignored properties are silent

This is why the above went unnoticed for so long. Set a property that's disabled in
the current mode, and **`set_property` succeeds**. All you get is:

```
WARNING: [IP_Flow 19-3374] An attempt to modify the value of disabled parameter
'PLL0_INPUT_CLK_FREQ' from '800.000' to '200.000' has been ignored for IP 'hsci_hssio_tx'
```

No error, no exit code, and in a thousand-line batch log you won't spot it. That's why
`hsci_verify_props` reads every set property back afterward and fails hard on a
mismatch. Only `PLL0_PLLOUT0` (always derived from `data_speed`), `ENABLE_N_PINS`
(doesn't exist in TX_ONLY) and `TX_PRE_EMPHASIS_D` are allowed to differ.

## The reference clock can't just be anything

`PLL0_INPUT_CLK_FREQ` has a fixed list of allowed values per `data_speed`. At
1250 Mb/s, 200 MHz is **not** in it; the wizard responds with the full list:

```
73.529, 78.125, 83.333, 89.286, 96.154, 104.167, 113.636, 125.000, 138.889, 147.059,
156.250, 166.667, 178.571, 192.308, 208.333, ... 714.286
```

At 1600 Mb/s, 200.000 is valid. Move to 1250 (see speed grade) and 156.250
(= 1250/8) is the natural choice.

## Port map confirmed

RX instance, bank 27, strobe on byte2 N6/N7, data on byte2 N8/N9. Actual ports from
the `.veo`:

```
clk, rst, pll0_locked, pll0_clkout0, pll0_clkout1, rst_seq_done,
shared_pll0_clkoutphy_out,
dly_rdy_bsc5, vtc_rdy_bsc5, en_vtc_bsc5,
clk_in_p, clk_in_n, data_to_fabric_clk_in_p,
data_in_p, data_in_n, data_to_fabric_data_in_p,
fifo_rd_clk_32, fifo_rd_en_32, fifo_empty_32,
fifo_rd_clk_34, fifo_rd_en_34, fifo_empty_34
```

This confirms the derivation rule exactly:

- `bsc` = byte · 2 + nibble → 2 · 2 + 1 = **5**
- fifo index = byte · 13 + pin index → 2 · 13 + 6 = **32**, and + 8 = **34**

`pll0_clkout1` and `shared_pll0_clkoutphy_out` weren't predicted; those are optional
and stay unconnected.

## The physical nibble can be queried from the device database

Measured on `xczu17eg-ffvd1760-1-e` (Vivado 2025.1). Up to now, everything derived
byte group and nibble from a regex on `PIN_FUNC` (`IO_L16P_T2U_N6_QBC_AD3P_65` → byte
2, nibble U, N6). That works, but it's a naming convention, not device data. The
actual silicon is in there too, and `scripts/hsci_nibble.tcl` pulls it from there.

### Two properties nobody mentions

A package pin has `PKGPIN_BYTEGROUP_INDEX` (0..12, position in the byte group) and
`PKGPIN_NIBBLE_INDEX` (0..6, position in the nibble). For `IO_L24N_T3U_N11_65`: 11
and 5. The byte group *number* itself isn't in there — that comes from the site
geometry below.

### The site structure

```
HP bank            52 IOB sites = 4 byte groups x 13
  get_sites -of_objects [get_iobanks 65]   ->  IOB_X0Y52 .. IOB_X0Y103

XIPHY_BYTE_*-tile  one per byte group, in the same clock region as the HPIO tile
  13x BITSLICE_RX_TX     the bitslices
   2x BITSLICE_CONTROL   one per nibble          <- THE physical nibble
   2x PLL_SELECT_SITE
   1x RIU_OR             one per byte group
```

The key: **the Y numbering of `BITSLICE_RX_TX` is identical to that of the IOB
sites.** Checked across all five HP banks of this package:

| bank | clock region | IOB Y | BITSLICE_RX_TX Y |
|---|---|---|---|
| 65 | X2Y1 | 52..103 | 52..103 |
| 66 | X2Y2 | 104..155 | 104..155 |
| 69 | X2Y5 | 260..311 | 260..311 |
| 70 | X2Y6 | 312..363 | 312..363 |
| 71 | X2Y7 | 364..415 | 364..415 |

So the bitslice of a pin can be found without any assumption about tile ordering:
look in the XIPHY tiles of the same clock region for the bitslice with the same Y.

`BITSLICE_CONTROL` just counts up across the device — bank 65 byte0 gets Y8/Y9, byte1
Y10/Y11, byte2 Y12/Y13, byte3 Y14/Y15, bank 66 byte0 Y16/Y17, and so on. That Y is the
device-global nibble number. The wizard numbers from 0 per instance (`bsc0`..`bsc7`
within the bank), so `bsc = byte*2 + nibble` remains the name in the port map; the
`BITSLICE_CONTROL` site is where it physically lands.

Example, `AP18` = `IO_L16P_T2U_N6_QBC_AD3P_65`:

```
IOB_X0Y84  ->  BITSLICE_RX_TX_X0Y84  in  XIPHY_BYTE_L_X28Y90
byte 2, nibble U, N6      bsc5      BITSLICE_CONTROL_X0Y13   RIU_OR_X0Y6
```

All 52 pins of bank 65 and bank 66 have been computed this way and match exactly
against `PIN_FUNC` and both `PKGPIN_*` properties. `hsci_nibble_of_pin` runs that
cross-check on every call and records discrepancies in `warnings`.

### Why this is useful

- The nibble rule for HSCI ("strobe and data in the same nibble") becomes checkable
  against the silicon instead of against a pin name.
- You can plan a `set_property LOC` at the bitslice or `BITSLICE_CONTROL` level.
- The `PLL_SELECT_SITE` per nibble shows which XPLL can clock a nibble.
- On a device where the naming convention differs, that shows up in `warnings`
  instead of silently producing a wrong `bscN`.

## The target device exists, and faster grades too

`xczu17eg-ffvd1760-1-e` is a valid part (device `xczu17eg`, package `ffvd1760`,
architecture `zynquplus`, speed grade `-1`). In the same footprint, `-2-e`, `-2-i`,
`-2L-e`, `-2LV-e` and `-3-e` also exist, so a part that hits 1600 Mb/s can be ordered
without changing the PCB footprint.

HP banks on this package: **65, 66, 69, 70, 71**. The pins that were previously in the
config (`P37`, `V33`, …) belong to MGT banks on this package — they came from a
different pinout.

## DBC and QBC reach further than their own nibble

The demo config in `docs/hssio_for_demo.txt` puts the RX strobe on `BYTE3_PIN6/7`
(byte3**U**) and the data on `BYTE3_PIN2/3` (byte3**L**) — different nibbles. That
seemed to contradict the "strobe and data in the same nibble" rule that used to be
here. That rule was too strict. The difference between the two kinds of clock-capable
pins is exactly this (UG571):

| | reaches |
|---|---|
| **DBC** — dual byte clock | the **two** nibbles of its own byte group |
| **QBC** — quad byte clock | **four** nibbles, so the adjacent byte group too |

So `C20` = `IO_L22P_T3U_N6_DBC_AD0P_70` clocks both bsc7 (its own nibble) and bsc6
(where the data sits). The correct rule is: **same byte group, strobe on a DBC or
QBC pin**.

Consequence for the port map: as soon as strobe and data are in different nibbles,
the wizard produces **two** `BITSLICE_CONTROL`s and thus two sets of
`dly_rdy`/`vtc_rdy`/`en_vtc`. Confirmed on the demo pinout — the RX instance gave
both `bsc6` and `bsc7`, with fifo ports on slice 41 (data, 3·13+2) and 45 (strobe,
3·13+6). `axi_hsci` has only one status line per direction, so the generated PHY
ANDs them.

## Synthesizing all IP HDL in one pass crashes Vivado 2025.1

To check a generated wrapper you'd want to not synthesize the IP separately to a DCP
but pull everything in at once:

```tcl
set_property GENERATE_SYNTH_CHECKPOINT false [get_files *.xci]
generate_task {synthesis} [get_files *.xci]
synth_design -top hsci_demo_top -mode out_of_context
```

RTL elaboration then runs all the way through, and Vivado crashes:

```
Parsing XDC File [.../hssio_wiz_hsci_tx.xdc] for cell 'i_hsci_phy/i_hssio_tx/inst'
INFO: [Project 1-236] Implementation specific constraints were found ...
Abnormal program termination (EXCEPTION_ACCESS_VIOLATION)
```

Exit code 0xC0000005, `hs_err_pid*.log` with no stack trace. Happens both with and
without `-mode out_of_context`, and on both `xczu17eg` and a barer design — it's tied
to the XDC of `high_speed_selectio_wiz` 3.6.

**What avoids it in synthesis:** the normal flow, giving each IP its own checkpoint
first. That does not solve the crash, it just steps around it — see the next
section: with per-IP checkpoints, synthesis reads only the `*_in_context.xdc` of an
IP and never gets to the file it dies on.

```tcl
set_property GENERATE_SYNTH_CHECKPOINT true [get_files *.xci]
foreach ip [get_ips] { synth_ip [get_ips $ip] }
synth_design -top hsci_demo_top -mode out_of_context
```

That synthesizes the complete demo top level (7060 cells: 2 `TX_BITSLICE`,
2 `RX_BITSLICE`, 4 `BITSLICE_CONTROL`, 2 XPLL, 1 MMCM, `BSCANE2` for the JTAG-AXI).

One expected CRITICAL WARNING remains:

```
Clock 'sys_clk' completely overrides clock 'H20'.
  New:      create_clock -period 5.000 -name sys_clk [get_ports H20]   (our XDC)
  Previous: create_clock -period 5.000 [get_ports H20]                 (hsci_demo_clk_in_context.xdc)
```

The `*_in_context.xdc` that Vivado creates for the OOC synthesis of the clocking
wizard IP defines the incoming clock with the same period but no name. In a real
project flow, the top-level run doesn't read that file and the message goes away; in
an in-memory check like this one you do see it.

## The same crash comes back in link_design, and why

Per-IP checkpoints get synthesis through, but `impl_1` then dies in its very first
step, `init_design` → `link_design`, at the same file:

```
Parsing XDC File [.../hsci_demo_jtag_axi/constraints/jtag_axi.xdc] for cell 'i_jtag_axi/inst'
Finished Parsing XDC File [...]
Parsing XDC File [.../hssio_wiz_hsci_tx.xdc] for cell 'i_hsci_phy/i_hssio_tx/inst'
Finished Parsing XDC File [...]
Abnormal program termination (EXCEPTION_ACCESS_VIOLATION)
```

The RX wizard's XDC is never reached. `hs_err_pid*.log` again has no stack trace.

**Why synthesis survives and implementation doesn't.** Compare which constraint
files the two runs parse. `synth_1` parses eleven `*_in_context.xdc` files plus our
own `hsci_demo_pins.xdc` — the real `hssio_wiz_hsci_tx.xdc` is not among them.
`impl_1` does parse it. An IP's `*_in_context.xdc` is the small file Vivado writes
for the IP's own out-of-context synthesis; the IP's real XDC only enters the flow
when the netlist is linked. So the crash was never gone, only postponed.

**What is in that file.** Besides `set_false_path`, `PHASESHIFT_MODE` and the
analog I/O settings, the wizard XDC assigns `PACKAGE_PIN`, `IOSTANDARD` and
`DATA_RATE` to the same eight ports as `hsci_demo_pins.xdc`. Same values — the
wizard was configured with these pins — but assigned twice, and only at link time.

**The fix:** switch the wizard's own XDC off and let `hsci_demo_pins.xdc` own all
I/O. `hsci_demo_project.tcl` does that on IPDEF, not on name:

```tcl
foreach ip [get_ips] {
    if {![string match *high_speed_selectio_wiz* [get_property IPDEF $ip]]} { continue }
    set_property is_enabled false [get_files -of_objects [get_ips $ip] "*/$ip.xdc"]
}
```

The `*_ooc.xdc` of the same IP stays enabled — that one drives the IP's own OOC
synthesis and never reaches the top level.

Everything the two files constrained beyond the duplicate pins is repeated in
`hsci_demo_pins.xdc`, scoped by hand because there it is no longer scoped to the
cell: `DATA_RATE DDR` on all eight pins, `LVDS_PRE_EMPHASIS FALSE` on the four TX
pins, `EQUALIZATION EQ_LEVEL0` on the four RX pins, `PHASESHIFT_MODE LATENCY` on
the two wizard XPLLs (a `REF_NAME =~ PLLE*_ADV` filter keeps the MMCM out), and the
`set_false_path` to the wizards' `sync_flop_0` synchronisers (5 pins).

**Result:** `hsci_demo_impl.tcl` runs synthesis and implementation through to
`route_design Complete!` on `xczu17eg-ffvd1760-1-e`, 7624 cells, WNS +1.056 ns and
WHS +0.010 ns. Verified afterwards on the routed checkpoint that all five
taken-over constraints did land on real objects.

Three CRITICAL WARNINGs remain, all expected: the `sys_clk` / `H20` override above,
and twice `[Route 35-4573]` about an Xtalk aggressor on `TX_D1`/`TX_D2` of the TX
bitslice that is not driven directly by a flop — that is how the wizard builds its
serialiser.
