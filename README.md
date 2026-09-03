# hsci_hssio

ADI's **HSCI** (High Speed Control Interface, `axi_hsci`) op een **Zynq UltraScale+**
met de **High Speed SelectIO Wizard** (PG188), met TX en RX in verschillende HP banks.

ADI levert `library/axi_hsci` en een referentie-PHY voor VCU118 (Virtex US+), maar geen
kant-en-klare oplossing voor een split-bank UltraScale+ integratie. Deze repo genereert
die: uit een part-nummer en 8 package pins rollen twee wizard-instanties, een RTL-wrapper
met de juiste bitslice-indices, en de bijbehorende constraints.

> **Status: work in progress.** Zie [Wat werkt / wat niet](#wat-werkt--wat-niet) onderaan.
> Doelplatform is een `xczu17eg`, maar dat device zat niet in de Vivado-installatie waarop
> is getest — verificatie is gedaan op een `xczu7ev`.

---

## Doelconfiguratie

| | |
|---|---|
| Doel-FPGA | `xczu17eg-ffvd1760-1-e` (te verifiëren, zie open punten) |
| Slave | AD9084 / AD9088 (Apollo MxFE) |
| Vivado | 2026.1 |
| Wizard | `high_speed_selectio_wiz` **3.6** |
| Link rate | 1600 Mb/s gewenst — **niet haalbaar op -1**, zie [Speed grade](#speed-grade) |

---

## Wat HSCI is

Een source-synchrone LVDS-link van 1,6 Gbps per richting die SPI vervangt als
control-interface naar de MxFE. Vier differentiële paren:

| signaal | richting | functie |
|---|---|---|
| `hsci_ckin_p/n` | FPGA → MxFE | forwarded clock, 800 MHz @ 1600 Mb/s |
| `hsci_din_p/n` | FPGA → MxFE | MOSI |
| `hsci_cko_p/n` | MxFE → FPGA | strobe |
| `hsci_do_p/n` | MxFE → FPGA | MISO |

`hsci_pclk` = datarate / 8 (8:1 serdes). De forwarded clock is datarate / 2: `menc_clk`
is in de RTL hardcoded als `8'h55` (of `8'hAA` bij `mosi_clk_inv`) — een toggle-per-bit
patroon door dezelfde serializer.

Zie [docs/protocol.md](docs/protocol.md) voor het wire protocol, de auto-linkup FSM en
de register/geheugen-indeling, en [docs/observaties.md](docs/observaties.md) voor
opmerkingen bij ADI's RTL.

---

## Inhoud

```
scripts/
  hsci_hssio_gen.tcl     hoofdscript: analyse -> 2 wizard IPs + wrapper + XDC
  hsci_find_pins.tcl     zoekt geldige pin-combinaties op een gegeven part
  hsci_list_parts.tcl    valideert het part, toont speed grades in dezelfde footprint
  hsci_probe_wizard.tcl  dumpt wizard-versie en CONFIG-properties
rtl/
  hsci_top.sv            koppelt axi_hsci aan de gegenereerde PHY (AXI4-Lite in, pads uit)
reference/
  hsci_phy_top.sv        ADI's VCU118 PHY-wrapper (bron van de port-map afleiding)
  versal_hsci_phy.tcl    ADI's Versal variant, ter vergelijking
docs/
  protocol.md            HSCI wire protocol, linkup, registers
  observaties.md         bevindingen in ADI's RTL
  vivado-bevindingen.md  wat er empirisch uit Vivado 2026.1 kwam
```

Gegenereerd (staat in `.gitignore`): `hsci_phy_2bank.sv`, `hsci_phy_pins.xdc`.

---

## Gebruik

**1 — part controleren en speed grades zien**

```bash
vivado -mode batch -source scripts/hsci_list_parts.tcl
```

**2 — geldige pinnen zoeken** (of sla over als je pinout al vastligt)

```bash
vivado -mode batch -source scripts/hsci_find_pins.tcl -tclargs xczu17eg-ffvd1760-1-e 4
```

Print kant-en-klare `set cfg(...)` regels.

**3 — genereren**

Vul het configblok bovenin `scripts/hsci_hssio_gen.tcl` en draai:

```bash
vivado -mode batch -source scripts/hsci_hssio_gen.tcl
```

Zet `cfg(probe_only) 1` om alleen te analyseren en de voorspelde port map te zien.

---

## Pin-regels

Het script controleert deze en faalt met de reden erbij:

1. Alle vier de paren in een **HP bank** (`BT_HIGH_PERFORMANCE`). HD banks hebben geen BITSLICE.
2. **RX strobe en RX data in dezelfde nibble.** De `RX_BITSLICE` wordt geklokt door de
   `BITSLICE_CONTROL` van zijn eigen nibble.
3. **RX strobe op een QBC- of DBC-pin**, dus N0/N1 of N6/N7 van die nibble.
4. **TX clkfwd en TX data in dezelfde byte group.**
5. `VCCO = 1.8V` op beide banks (LVDS in HP banks). Niet controleerbaar vanuit Vivado —
   staat als comment in de gegenereerde XDC.

---

## Port map

De poortnamen van de wizard zijn mechanisch afleidbaar. Regel, afgeleid uit ADI's
VCU118-combinatie en **empirisch bevestigd op Vivado 2026.1 / wizard 3.6**:

```
pad-poort         = SIGNAL_NAME                          (met APPEND_PIN_NO = 0)
fabric TX         = data_from_fabric_<SIGNAL_NAME>
fabric RX         = data_to_fabric_<SIGNAL_NAME>
bitslice control  = {dly_rdy,vtc_rdy,en_vtc}_bsc<byte*2 + nibble>
per-slice FIFO    = {fifo_rd_clk,fifo_rd_en,fifo_empty}_<byte*13 + pinindex>
PLL / reset       = clk, rst, pll0_locked, pll0_clkout0, rst_seq_done
```

Verificatie: RX strobe op byte2 N6, data op N8 gaf `dly_rdy_bsc5` (2·2+1) en
`fifo_rd_en_32` / `fifo_rd_en_34` (2·13+6 en +8). Exact zoals voorspeld.

De wizard levert daarnaast `pll0_clkout1` en `shared_pll0_clkoutphy_out`; die laat de
wrapper onaangesloten.

Het script toetst zijn eigen voorspelling na generatie tegen de `.veo` template en
meldt afwijkingen.

---

## Twee banks, één klok

TX en RX in verschillende banks betekent twee XPLLs. `hsci_pclk` komt van de **TX** PLL,
en die klok gaat ook naar `fifo_rd_clk` van de RX-instantie.

Dat is correct by construction: de MxFE leidt `hsci_cko` af van onze `hsci_ckin`, dus de
schrijfzijde van de RX bitslice-FIFO loopt op (een vertraagde versie van) de TX-PLL-klok.
Schrijf- en leeszijde zijn daarmee mesochroon — zelfde frequentie, vaste onbekende fase.
De 8-diepe FIFO vangt alleen die fase op. Geen echte CDC nodig.

De RX PLL blijft nodig voor de RIU/VTC-kalibratie van zijn eigen `BITSLICE_CONTROL`.

---

## Speed grade

De maximale rate staat in de tabel **"LVDS Native Mode Performance"** van de datasheet
(DS925 voor Zynq US+), rij **RX DDR, RX_BITSLICE 1:8**. De RX-kant is bindend.

| speed grade | max native |
|---|---|
| -3 | 1600 Mb/s |
| -2 | 1600 Mb/s |
| **-1** | **1250 Mb/s** |

Native mode is de juiste tabel: de wizard gebruikt `RX_BITSLICE`/`TX_BITSLICE` met
`BITSLICE_CONTROL` en de XPLL. Component mode (zelf een `ISERDESE3` instantiëren) is een
ander, lager pad.

> **Valkuil.** 1250 Mb/s staat op twee onafhankelijke plekken in de datasheet: als
> component-mode plafond bij -2/-3, en als native-mode plafond bij -1. Zelfde getal,
> andere oorzaak. Samenvattingen die "native = 1600, component = 1250" zeggen noemen
> alleen de eerste en wekken ten onrechte de indruk dat native altijd 1600 haalt.

**Gevolg voor dit project:** op een `-1` is 1600 Mb/s uitgesloten. Opties:

1. `cfg(data_speed) 1250` → `hsci_pclk` 156,25 MHz, forwarded clock 625 MHz.
   Open vraag: accepteert de AD9084 die rate? (`RG_HSCI_RATE_CTRL`, 0x8011)
2. Een `-2` part.

`cfg(force_rate)` bestaat voor als de tabel te conservatief blijkt — niet om een echte
limiet te omzeilen.

---

## Wat werkt / wat niet

Getest op Vivado 2026.1 met `xczu7ev-ffvf1517-2-e` (echte device-data, geen model):

| onderdeel | status |
|---|---|
| part- en speed grade-analyse | werkt |
| pin-analyse (bank/byte/nibble/bsc/slice) | werkt, geverifieerd tegen echte `PIN_FUNC` |
| alle regelchecks + foutmeldingen | werkt |
| pin-finder | werkt |
| port-map voorspelling | **bevestigd** tegen echte `.veo` |
| RX wizard-instantie genereren | werkt |
| TX wizard-instantie genereren | werkte in een losse test; **nog niet opnieuw getest** na de laatste fixes |
| volledige run end-to-end | **nog niet groen** |

### Openstaande punten

1. **`xczu17eg` device support ontbrak** in de geteste Vivado-installatie (alleen de
   kleine Zynq US+ devices tot `xczu7ev` waren geïnstalleerd). Of `ffvd1760` een geldig
   package is, is dus nog niet bevestigd — draai `hsci_list_parts.tcl` op een machine met
   de juiste device support.
2. **`cfg(busdir_tx)` = 3** is de waarde die valideerde, maar in een test *zonder* de
   "disable unused pins"-fix. Mogelijk werkt 2 nu ook. Opnieuw testen.
3. **De AD9084-kant**: accepteert die 1250 Mb/s, en wat doet `RG_HSCI_RATE_CTRL` (0x8011)
   precies? Vraag voor de ADI FAE.
4. **`PLL0_RX_EXTERNAL_CLK_TO_DATA = 3`** is overgenomen van ADI. Het is een eigenschap
   van hoe de MxFE zijn data t.o.v. `hsci_cko` uitstuurt, niet van de FPGA.
5. **Trace matching**: de auto-linkup FSM sweept alleen de TX-fase. `hsci_cko` ↔ `hsci_do`
   moet op de PCB strak gematcht worden; daar corrigeert niets voor.

---

## Bronnen

- [ADI HDL `library/axi_hsci`](https://github.com/analogdevicesinc/hdl/tree/main/library/axi_hsci)
- [ADI `ad9084_ebz` VCU118 project](https://github.com/analogdevicesinc/hdl/tree/main/projects/ad9084_ebz/vcu118) — de UltraScale+ referentie
- [AXI HSCI Linux driver](https://developer.analog.com/docs/linux/drivers/misc/axi-hsci.html)
- PG188 — High Speed SelectIO Wizard
- UG571 — UltraScale Architecture SelectIO Resources
- DS925 — Zynq UltraScale+ MPSoC datasheet (DC/AC switching)
