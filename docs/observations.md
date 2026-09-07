# Observations in ADI's RTL

Findings from reading `library/axi_hsci` (commit main, 2025/2026). None of these
is a blocker; they're things worth knowing during integration.

## 1. Reset deassert is not synchronized

In `hsci_master_top.sv`:

```systemverilog
assign hsci_rstn_async = O.hsci_master_rstn.data & hsci_pll_locked;
```

goes straight to `hsci_mcore.hsci_rstn` — async assert **and** async deassert
relative to `hsci_pclk`. The `ad_rst` instance around it produces
`hsci_rst_sync`, but that's only used for BRAM port B and the `pulse_sync`.
Recovery/removal on the mcore flops is therefore not covered.

Probably works in practice because the link has to come back up again anyway
afterward, but it's a real CDC gap. More relevant with a PLL that locks late.
Adding two flops is trivial.

## 2. `cmd_sel == 2'b11` is an alias for RMW

`LINKUP_OP = 4'b1001 == MRMW_OP`, and `SEND_ADDR` only tests for
`MWRITE_OP` / `MRMW_OP`. The comment in `hsci_mcore.v`
(`// 00=write, 01=read, 10=write`) is wrong — `10` is RMW.

## 3. `signal_acquired` is an implicit net

`hsci_mcore.v:131` declares `wire signal_acquire;` (typo, unused), while
`signal_acquired` is used on lines 164 and 281 without a declaration. Verilog
silently turns it into a 1-bit wire, so it works — but a strict lint, or
converting the file to `.sv`, will blow up on it.

## 4. `wstrb` is ignored toward the BRAM

`BYTE_WRITE_WIDTH_A = 32`. Sub-word writes silently write the whole word.

## 5. The TTCL constraint is too broad

```tcl
set_false_path -from [get_cells -filter IS_SEQUENTIAL -hierarchical -regexp ".*O_reg.*"] \
               -to [get_clocks -of_objects [get_ports {hsci_pclk}]]
```

That `.*O_reg.*` matches hierarchically anything named that way. In a larger
design with other IP that happens to contain `O_reg`, you can unintentionally
drop paths. Scope it to the axi_hsci instance.

## 6. Bit reversal in the PHY coupling

`system_top.v:334-335` of the vck190 project:

```verilog
assign data_from_fabric = {hsci_data_out[0], ..., hsci_data_out[7]};
```

The same reversal is in `hsci_phy_top.sv` for UltraScale+. If you build your
own PHY, this is exactly where you'll lose a day. The generated
`hsci_phy_2bank.sv` does it.

## 7. Timescale mix

`axi_hsci.sv`, `hsci_master_top.sv` and `hsci_mcore.v` use `1ps/1ps`, while
`hsci_menc.sv`, `hsci_mdec.sv` and `hsci_mfrm_det.v` use `1ns/1ps`.
Functionally not a problem (timescale is per module), but messy.

## 8. `hsci_phy_top.sv` is not in the vcu118 Makefile

Only in `adi_project_files` in `system_project.tcl`. The project builds, but
`make` doesn't see changes to the PHY. The Makefile does reference
`../common/versal_hsci_phy.tcl`, which is a copy-paste artifact — that file is
Versal-only.
