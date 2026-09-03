# Observaties in ADI's RTL

Bevindingen bij het lezen van `library/axi_hsci` (commit main, 2025/2026). Geen van
deze is een blocker; het zijn dingen om te weten bij integratie.

## 1. Reset-deassert is niet gesynchroniseerd

In `hsci_master_top.sv`:

```systemverilog
assign hsci_rstn_async = O.hsci_master_rstn.data & hsci_pll_locked;
```

gaat rechtstreeks naar `hsci_mcore.hsci_rstn` — async assert **en** async deassert t.o.v.
`hsci_pclk`. De `ad_rst` instance eromheen produceert `hsci_rst_sync`, maar die wordt
alleen gebruikt voor BRAM port B en de `pulse_sync`. Recovery/removal op de mcore-flops is
dus niet afgedekt.

Werkt in de praktijk waarschijnlijk omdat de link daarna toch opnieuw op moet komen, maar
het is een echt CDC-gat. Relevanter met een PLL die laat lockt. Twee flops erbij is
triviaal.

## 2. `cmd_sel == 2'b11` is een alias van RMW

`LINKUP_OP = 4'b1001 == MRMW_OP`, en `SEND_ADDR` test alleen op `MWRITE_OP` / `MRMW_OP`.
De comment in `hsci_mcore.v` (`// 00=write, 01=read, 10=write`) klopt niet — `10` is RMW.

## 3. `signal_acquired` is een impliciete net

`hsci_mcore.v:131` declareert `wire signal_acquire;` (typo, ongebruikt), terwijl
`signal_acquired` op regels 164 en 281 wordt gebruikt zonder declaratie. Verilog maakt er
stilzwijgend een 1-bit wire van, dus het werkt — maar bij een strikte lint, of als je het
bestand naar `.sv` omzet, knalt het.

## 4. `wstrb` wordt genegeerd richting BRAM

`BYTE_WRITE_WIDTH_A = 32`. Sub-word writes schrijven stil het hele woord.

## 5. De TTCL-constraint is breed

```tcl
set_false_path -from [get_cells -filter IS_SEQUENTIAL -hierarchical -regexp ".*O_reg.*"] \
               -to [get_clocks -of_objects [get_ports {hsci_pclk}]]
```

Dat `.*O_reg.*` matcht hierarchisch alles wat zo heet. In een groter design met andere IP
die toevallig `O_reg` bevat kun je onbedoeld paden weggooien. Scope het naar de
axi_hsci-instance.

## 6. Bit-reversal in de PHY-koppeling

`system_top.v:334-335` van het vck190-project:

```verilog
assign data_from_fabric = {hsci_data_out[0], ..., hsci_data_out[7]};
```

Dezelfde omkering zit in `hsci_phy_top.sv` voor UltraScale+. Als je je eigen PHY bouwt is
dit precies waar je een dag op verliest. De gegenereerde `hsci_phy_2bank.sv` doet het.

## 7. Timescale-mix

`axi_hsci.sv`, `hsci_master_top.sv` en `hsci_mcore.v` gebruiken `1ps/1ps`, terwijl
`hsci_menc.sv`, `hsci_mdec.sv` en `hsci_mfrm_det.v` `1ns/1ps` gebruiken. Functioneel geen
probleem (timescale is per module), maar rommelig.

## 8. `hsci_phy_top.sv` staat niet in de vcu118 Makefile

Alleen in `adi_project_files` in `system_project.tcl`. Het project bouwt, maar `make` ziet
wijzigingen aan de PHY niet. De Makefile verwijst wel naar `../common/versal_hsci_phy.tcl`,
wat een copy-paste artefact is — dat bestand is Versal-only.
