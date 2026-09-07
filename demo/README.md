# Demo: HSCI from pins to a bitstream-ready top level

One command:

```bash
uv run demo/build_demo.py --check
```

Out of that rolls a complete, synthesizable design: two High Speed SelectIO
Wizard instances derived from eight package pins, ADI's `axi_hsci` connected to
them, a JTAG-AXI debug master on its own clock domain, and an AXI-Lite clock
converter in between.

`uv` handles Jinja itself — the script header is PEP 723, there's no venv to
activate.

---

## What happens

```
demo_config.json          your choices: part, 8 pins, clocks, rate
        |
        |  build_demo.py writes a Tcl config block from it
        v
vivado/hsci_demo_gen.tcl  ---> Vivado batch
        |                        - pin analysis against the real device database
        |                        - rule checks (bank, byte group, DBC/QBC)
        |                        - 2x high_speed_selectio_wiz, derived
        |                        - clk_wiz, jtag_axi, axi_clock_converter
        |                        - port map checked against the .veo
        v
generated/hsci_facts.json  everything the analysis produced
        |
        |  build_demo.py renders with Jinja
        v
generated/hsci_phy_top.sv     PHY, ports exactly as axi_hsci wants them
generated/hsci_demo_top.sv    top level with clocks, JTAG-AXI, CDC, axi_hsci
generated/hsci_demo_pins.xdc  pins, clocks, VCCO requirement
generated/hsci_demo_srcs.tcl  file list for a Vivado project
```

The split isn't arbitrary: everything that needs the device database happens
in Tcl inside Vivado, all the text generation in Python. The analysis procs
come from [`scripts/hsci_hssio_lib.tcl`](../scripts/hsci_hssio_lib.tcl), the
same engine as the generator in `scripts/`.

## The pinout

Taken from [`docs/hssio_for_demo.txt`](../docs/hssio_for_demo.txt), but not
retyped: `build_demo.py` is given only the eight package pins and derives
bank, byte group, nibble, bitslice index and the complete port map itself.

| | wizard pin | package | PIN_FUNC | nibble | bsc |
|---|---|---|---|---|---|
| TX clk fwd | `BYTE0_PIN4/5` | R26/P26 | `IO_L3P_T0L_N4_AD15P_69` | byte0**L** | 0 |
| TX data | `BYTE0_PIN10/11` | M27/M28 | `IO_L6P_T0U_N10_AD6P_69` | byte0**U** | 1 |
| RX data | `BYTE3_PIN2/3` | D20/C21 | `IO_L20P_T3L_N2_AD1P_70` | byte3**L** | 6 |
| RX strobe | `BYTE3_PIN6/7` | C20/B21 | `IO_L22P_T3U_N6_DBC_AD0P_70` | byte3**U** | 7 |

Note the RX side: strobe and data are in **different nibbles**. That's
allowed, because C20 is a DBC pin and *dual byte clock* means it clocks both
nibbles of its byte group (QBC reaches four, across two byte groups). The
consequence is that both the TX and the RX instance get two
`BITSLICE_CONTROL`s; the generated PHY ANDs their `dly_rdy`/`vtc_rdy` into the
two status lines that `axi_hsci` expects.

## The clocks

One differential 200 MHz system clock comes in on H20/H21 (a GC pin in
bank 70). The MMCM makes two clocks from it:

| clock | frequency | for |
|---|---|---|
| `clk_out1` | 200 MHz | reference for the XPLL of **both** wizards |
| `clk_out2` | 100 MHz | the JTAG-AXI domain |
| `hsci_pclk` | 200 MHz | from the TX wizard's XPLL, = data rate/8 |

The JTAG-AXI deliberately runs on `clk_out2` and not on `hsci_pclk`. That's
the point of the demo: your debug master hangs off a free-running clock, and
`axi_clock_converter` does the crossing to `hsci_pclk` before it reaches
`axi_hsci`. If you hung it directly off `hsci_pclk`, you'd lose your debug
path at exactly the moment you need it — when the XPLL drops out of lock.

Resets come from ADI's `ad_rst`, one per clock domain: the AXI domain
deasserts as soon as the MMCM locks, the `hsci_pclk` domain once both XPLLs
have also locked.

### One consequence worth knowing

Putting `axi_hsci` on `hsci_pclk` means the register `HSCI_RATE_CTRL[8]`
(`hsci_pll_reset`) removes the very clock `axi_hsci` runs on. Write that bit
to 1 and you can no longer write it back to 0 — only a new bitstream helps.
Out of reset the bit is 0 (`hsci_master_regs_regs.sv:366`), so start-up works
fine. If you actually want to use that bit, give `axi_hsci` its own
`s_axi_aclk` and let the CDC it already has do the work — then the external
`axi_clock_converter` becomes unnecessary.

## What you can change yourself

Everything in `demo_config.json`. The eight pins, the system clock, the two
MMCM frequencies, the rate, `PLL0_RX_EXTERNAL_CLK_TO_DATA`, the IP names. The
script derives the rest and complains with a reason when a combination can't
work:

```
**** HSCI CONFIGURATION IMPOSSIBLE ****

  reason : RX strobe C21 is not a QBC/DBC pin (IO_L20N_T3L_N3_AD1N_70)
  fix    : the strobe must be on the N0/N1 or N6/N7 pair of a nibble; those
           are marked DBC or QBC in the pin name
```

## Two things that don't match reality

**1600 Mb/s on a -1.** `demo_config.json` has `"force_rate": true`. The
`xczu17eg-ffvd1760-**1**` reaches 1250 Mb/s in native mode per DS925, not
1600. For generating and synthesizing that makes no difference, for silicon
it does. If you set the rate to 1250, also set `ref_freq` to 156.250 — 200 MHz
is not in the list the wizard accepts at 1250.

**`PLL0_RX_EXTERNAL_CLK_TO_DATA` is set to 4**, as in `hssio_for_demo.txt`
(edge-aligned strobe). ADI's own vcu118 reference uses 3 (center-aligned).
That's a property of how the MxFE outputs its data relative to `hsci_cko`,
not of the FPGA — check it against the AD9084 datasheet before basing a PCB
on it.

## ADI's sources

`axi_hsci` comes from a sparse clone under `src/adi-hdl` (in `.gitignore`).
Fetch it again with:

```bash
git clone --filter=blob:none --sparse --depth 1 https://github.com/analogdevicesinc/hdl.git src/adi-hdl
cd src/adi-hdl && git sparse-checkout set library/axi_hsci library/common library/util_cdc library/scripts library/xilinx
```

About 3 MB instead of the full repo.

## Opening it in the Vivado GUI

The whole flow runs on `create_project -in_memory`, which never writes a
`.xpr`. If you want to see the design in the GUI, ask for it explicitly:

```bash
uv run demo/build_demo.py --project
vivado demo/generated/vivado_project/hsci_demo.xpr
```

What you get: part `xczu17eg-ffvd1760-1-e`, top `hsci_demo_top`, 79 source
files, the five IPs (`high_speed_selectio_wiz` 3.6 x2, `clk_wiz` 6.0,
`jtag_axi` 1.2, `axi_clock_converter` 2.1), the XDC, and runs `synth_1`/
`impl_1` ready to launch.

The IPs stay where `build_demo.py` put them (`generated/.srcs/`); the project
references them instead of copying them. One source of truth, then — adjust
`demo_config.json` and rerun, and the project sees it. The flip side: change
something in the GUI and the next run overwrites it. The source is
`demo_config.json` and `templates/`, not the project.

`--project` combines with the rest, so this is the complete run from scratch:

```bash
uv run demo/build_demo.py --clean --project --check
```

## Running implementation

`--check` synthesizes, but says nothing about placement, routing or timing. For
that there is a fourth Vivado script, which runs `synth_1` and `impl_1` in batch
so you don't need the GUI:

```bash
vivado -mode batch -source demo/vivado/hsci_demo_impl.tcl -tclargs demo/generated/vivado_project/hsci_demo.xpr 4
```

The last argument is the number of parallel jobs. It stops at `route_design`; no
bitstream. First it prints which constraint files `link_design` is going to read
and whether they are enabled — that matters, because the XDC of
`high_speed_selectio_wiz` is deliberately switched off there. It duplicates the
pin assignments from `hsci_demo_pins.xdc` and made Vivado 2025.1 crash with an
access violation in `link_design`; everything else those files constrained has
been moved into `hsci_demo_pins.xdc`. See
[`docs/vivado-findings.md`](../docs/vivado-findings.md).

On `xczu17eg-ffvd1760-1-e` the demo routes with WNS +1.056 ns and WHS +0.010 ns,
7624 cells, in about thirteen minutes on four jobs.

## Running individual parts

```bash
uv run demo/build_demo.py --skip-vivado    # only re-render from hsci_facts.json
uv run demo/build_demo.py --check          # generate and then synthesize
uv run demo/build_demo.py --clean --check  # clean build from scratch
uv run demo/build_demo.py --project        # .xpr for the GUI
uv run demo/build_demo.py --clean-only     # only delete generated/ and __pycache__
uv run demo/build_demo.py --vivado <path>  # if vivado isn't on PATH
```

`--clean` deletes `generated/` entirely: the RTL, the XDC, `hsci_facts.json`,
`demo_cfg.tcl`, the logs, and the Vivado directories `.srcs/`, `.gen/` and
`.Xil/` with the five IPs in them — about 58 MB altogether. It also removes
`demo/__pycache__`, the bytecode cache Python leaves behind. What stays is
source, not output: `demo_config.json`, `templates/`, `vivado/`, and
`src/adi-hdl` (that's a clone, not something this script produces).

`--clean` together with `--skip-vivado` is refused before anything
disappears — that combination would delete the very `hsci_facts.json` that
`--skip-vivado` renders from.

The full Vivado log always lands in `generated/gen.log` and
`generated/check.log`; the terminal only shows the headline lines.
