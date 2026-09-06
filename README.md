# hsci_hssio

ADI's **HSCI** (High Speed Control Interface, `axi_hsci`) op een **Zynq UltraScale+**
met de **High Speed SelectIO Wizard** (PG188), met TX en RX in verschillende HP banks.

ADI levert `library/axi_hsci` en een referentie-PHY voor VCU118 (Virtex US+), maar geen
kant-en-klare oplossing voor een split-bank UltraScale+ integratie. Deze repo genereert
die: uit een part-nummer en 8 package pins rollen twee wizard-instanties, een RTL-wrapper
met de juiste bitslice-indices, en de bijbehorende constraints.

> **Status: work in progress.** Zie [Wat werkt / wat niet](#wat-werkt--wat-niet) onderaan.
> Het doeldevice `xczu17eg-ffvd1760-1-e` is inmiddels geverifieerd in Vivado 2025.1. De
> volledige generatie-run is gedraaid op een `xczu7ev`, omdat daar een passende pinout
> voor bestond; de pinout voor `ffvd1760` moet nog gekozen worden.

---

## Doelconfiguratie

| | |
|---|---|
| Doel-FPGA | `xczu17eg-ffvd1760-1-e` — bestaat, HP banks 65, 66, 69, 70, 71 |
| Slave | AD9084 / AD9088 (Apollo MxFE) |
| Vivado | 2025.1 en 2026.1 (wizard is in beide 3.6) |
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
demo/
  build_demo.py          een commando: pinnen -> IP -> RTL -> synthese  (uv run)
  demo_config.json       part, acht pinnen, klokken, rate
  templates/             Jinja: hsci_phy_top.sv, toplevel, XDC, bestandslijst
  vivado/                de Vivado-helft: analyse + IP + synthesecheck
scripts/
  hsci_hssio_gen.tcl     hoofdscript: analyse -> 2 wizard IPs + wrapper + XDC
  hsci_hssio_lib.tcl     de gedeelde motor: pin-analyse, regelchecks, IP-helpers
  hsci_find_pins.tcl     zoekt geldige pin-combinaties op een gegeven part
  hsci_list_parts.tcl    valideert het part, toont speed grades in dezelfde footprint
  hsci_pin_index.tcl     part + pin -> PKGPIN_BYTEGROUP_INDEX / PKGPIN_NIBBLE_INDEX
  hsci_nibble.tcl        pin -> fysieke nibble (BITSLICE_CONTROL-site) uit de device DB
  hsci_check_wrapper.tcl synthetiseert de gegenereerde wrapper tegen de gegenereerde IP
  hsci_probe_wizard.tcl  dumpt wizard-versie en CONFIG-properties
rtl/
  hsci_top.sv            koppelt axi_hsci aan de gegenereerde PHY (AXI4-Lite in, pads uit)
reference/
  hsci_phy_top.sv        ADI's VCU118 PHY-wrapper (bron van de port-map afleiding)
  versal_hsci_phy.tcl    ADI's Versal variant, ter vergelijking
docs/
  protocol.md            HSCI wire protocol, linkup, registers
  observaties.md         bevindingen in ADI's RTL
  vivado-bevindingen.md  wat er empirisch uit Vivado 2025.1 en 2026.1 kwam
  hssio_for_demo.txt     de wizard-config waar de demo op teruggaat
```

Gegenereerd (staat in `.gitignore`): `hsci_phy_2bank.sv`, `hsci_phy_pins.xdc`,
`demo/generated/`, en `src/adi-hdl/` (sparse clone van ADI's HDL).

---

## Demo

Een compleet ontwerp uit een commando:

```bash
uv run demo/build_demo.py --check
```

Acht package pinnen in, en eruit rolt: twee wizard-instanties, een PHY met exact de
poorten die `axi_hsci` wil, een toplevel met MMCM-klokken, een JTAG-AXI debugmaster op
een eigen klokdomein, een AXI-Lite klokconverter naar `hsci_pclk`, en de XDC. Met
`--check` synthetiseert hij het geheel ook nog (7060 cellen op een `xczu17eg`).

Zie [demo/README.md](demo/README.md).

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

**4 — de wrapper laten synthetiseren**

```bash
vivado -mode batch -source scripts/hsci_check_wrapper.tcl -tclargs xczu17eg-ffvd1760-1-e
```

Draait `synth_design` out-of-context op `hsci_phy_2bank` met de twee gegenereerde IPs
erbij. De poortcheck in de generator vergelijkt alleen namen met de `.veo`; dit is de
echte proef.

---

## Pin → fysieke nibble

`scripts/hsci_nibble.tcl` vertaalt een package pin naar het stuk silicium eronder, uit de
device database in plaats van uit een regex op `PIN_FUNC`:

```bash
vivado -mode batch -source scripts/hsci_nibble.tcl \
       -tclargs xczu17eg-ffvd1760-1-e AP18
```

```
=== AP18 : IO_L16P_T2U_N6_QBC_AD3P_65 ===
  bank 65   byte 2   nibble U   N6   bsc5
  iob            IOB_X0Y84
  bitslice       BITSLICE_RX_TX_X0Y84
  bsc_site       BITSLICE_CONTROL_X0Y13     <- de fysieke nibble
  nibble_global  13
  riu_or         RIU_OR_X0Y6
  pll_select     PLL_SELECT_SITE_X0Y13
  xiphy_tile     XIPHY_BYTE_L_X28Y90
  clk_cap        QBC
```

Zonder pinnamen dumpt hij de complete nibble-indeling van elke HP bank. Als library:

```tcl
set hsci_nibble_library 1
source scripts/hsci_nibble.tcl
hsci_nib_load_device xczu17eg-ffvd1760-1-e
dict get [hsci_nibble_of_pin AP18] bsc_site
```

De proc kruist zijn uitkomst elke aanroep tegen `PIN_FUNC`, `PKGPIN_BYTEGROUP_INDEX` en
`PKGPIN_NIBBLE_INDEX`; afwijkingen komen in `warnings` te staan in plaats van stil een
verkeerde `bscN` op te leveren. Zie [docs/vivado-bevindingen.md](docs/vivado-bevindingen.md)
voor de gemeten sitestructuur waar dit op rust.

### Alleen de twee indices

Heb je genoeg aan wat Vivado zelf al weet, dan is `scripts/hsci_pin_index.tcl` het hele
verhaal — één proc, geen afleiding:

```tcl
source scripts/hsci_pin_index.tcl
hsci_pin_index xczu17eg-ffvd1760-1-e AP18    ;# bytegroup 6 nibble 0
```

| property | betekenis |
|---|---|
| `PKGPIN_BYTEGROUP_INDEX` | 0..12, positie in de byte group — de `N` uit `PIN_FUNC` |
| `PKGPIN_NIBBLE_INDEX` | 0..6, positie in de nibble |

Kosten: `get_package_pins` geeft **niets** tot `link_design` de device database heeft
geladen, en dat kost eenmalig ~14 s op een `xczu17eg`. Daarna is een aanroep 0,9 ms en
kost het uitlezen van alle 1760 pinnen van het package 113 ms. De proc onthoudt daarom
welk part geladen is en doet `link_design` hooguit één keer per Vivado-sessie.

---

## Pin-regels

Het script controleert deze en faalt met de reden erbij:

1. Alle vier de paren in een **HP bank** (`BT_HIGH_PERFORMANCE`). HD banks hebben geen BITSLICE.
2. **RX strobe en RX data in dezelfde byte group**, met de strobe op een **DBC- of
   QBC-pin** (N0/N1 of N6/N7). Dezelfde *nibble* hoeft niet: DBC = dual byte clock en
   klokt beide nibbles van zijn byte group, QBC = quad byte clock en haalt er vier.
   Zitten strobe en data in verschillende nibbles, dan krijgt de RX-instantie twee
   `BITSLICE_CONTROL`s en dus twee sets bsc-poorten.
3. **TX clkfwd en TX data in dezelfde byte group.**
4. `VCCO = 1.8V` op beide banks (LVDS in HP banks). Niet controleerbaar vanuit Vivado —
   staat als comment in de gegenereerde XDC.

---

## Port map

De poortnamen van de wizard zijn mechanisch afleidbaar. Regel, afgeleid uit ADI's
VCU118-combinatie en **empirisch bevestigd op Vivado 2025.1 en 2026.1, wizard 3.6**:

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

Getest op Vivado 2025.1 met `xczu7ev-ffvf1517-2-e` (volledige run) en op het echte
doeldevice `xczu17eg-ffvd1760-1-e` (part-, pin- en nibble-analyse):

| onderdeel | status |
|---|---|
| part- en speed grade-analyse | werkt, ook op `xczu17eg-ffvd1760-1-e` |
| pin-analyse (bank/byte/nibble/bsc/slice) | werkt, geverifieerd tegen `PIN_FUNC` én tegen de sites |
| pin → fysieke nibble (`hsci_nibble.tcl`) | werkt, alle 52 pinnen van twee banks kloppen |
| alle regelchecks + foutmeldingen | werkt |
| pin-finder | werkt, ook op het doeldevice |
| port-map voorspelling | **bevestigd** tegen echte `.veo` |
| RX wizard-instantie genereren | werkt |
| TX wizard-instantie genereren | werkt (met `BUS_DIR 0`, zie hieronder) |
| readback-verificatie van properties | werkt, vangt stil genegeerde properties |
| volledige run end-to-end | **groen** op `xczu7ev`, 1600 Mb/s |
| wrapper synthetiseren (`hsci_check_wrapper.tcl`) | **nog niet gedraaid** |

Twee fouten die deze ronde boven water kwamen en verholpen zijn:

- **`cfg(busdir_tx)` moest 0 (`TX_ONLY`) zijn, niet 3.** Met 3 zet de wizard stilzwijgend
  `PLL0_CLK_SOURCE` op `IBUF_TO_PLL` en `PLL0_INPUT_CLK_FREQ` op 800 MHz — een instantie
  die een externe 800 MHz klok op een bankpin verwacht in plaats van je fabric-referentie.
  De generator leest nu elke property terug en faalt hard als de wizard er een negeert.
- **Netnaam-botsing in de wrapper** wanneer TX en RX toevallig hetzelfde `bsc`-nummer
  hebben (allebei bank-lokaal genummerd). De netten heten nu `tx_`/`rx_`-geprefixt.

### Openstaande punten

1. **De pinout moet opnieuw.** De pinnen die in het configblok stonden horen op
   `ffvd1760` bij MGT-banks; ze kwamen uit een ander pinout. HP banks op dit package zijn
   **65, 66, 69, 70, 71**. `hsci_find_pins.tcl` draait nu op het echte device en geeft
   geldige combinaties — maar de uiteindelijke keuze hangt aan de PCB.
2. **De AD9084-kant**: accepteert die 1250 Mb/s, en wat doet `RG_HSCI_RATE_CTRL` (0x8011)
   precies? Vraag voor de ADI FAE. Bij 1250 Mb/s moet `cfg(ref_freq)` ook mee: 200 MHz is
   dan geen geldige referentie, 156.250 wel.
3. **`PLL0_RX_EXTERNAL_CLK_TO_DATA = 3`** is overgenomen van ADI. Het is een eigenschap
   van hoe de MxFE zijn data t.o.v. `hsci_cko` uitstuurt, niet van de FPGA.
4. **Trace matching**: de auto-linkup FSM sweept alleen de TX-fase. `hsci_cko` ↔ `hsci_do`
   moet op de PCB strak gematcht worden; daar corrigeert niets voor.

---

## Bronnen

- [ADI HDL `library/axi_hsci`](https://github.com/analogdevicesinc/hdl/tree/main/library/axi_hsci)
- [ADI `ad9084_ebz` VCU118 project](https://github.com/analogdevicesinc/hdl/tree/main/projects/ad9084_ebz/vcu118) — de UltraScale+ referentie
- [AXI HSCI Linux driver](https://developer.analog.com/docs/linux/drivers/misc/axi-hsci.html)
- PG188 — High Speed SelectIO Wizard
- UG571 — UltraScale Architecture SelectIO Resources
- DS925 — Zynq UltraScale+ MPSoC datasheet (DC/AC switching)
