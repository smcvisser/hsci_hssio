# Empirische bevindingen — Vivado 2025.1 en 2026.1

Alles hieronder is gemeten, niet aangenomen. Twee testplatforms:

| | |
|---|---|
| eerste ronde | Vivado 2026.1 (SW build 6511674), `xczu7ev-ffvf1517-2-e` |
| tweede ronde | Vivado 2025.1 (SW build 6140274), `xczu7ev-ffvf1517-2-e` **en** het echte doeldevice `xczu17eg-ffvd1760-1-e` |

Waar de twee versies verschillen staat dat erbij; tot nu toe verschilden ze nergens.

## Wizard-versie

`high_speed_selectio_wiz` is in zowel 2025.1 als 2026.1 **3.6** — dezelfde versie die ADI
in hun vcu118-project gebruikt. Er is dus geen property-drift ten opzichte van ADI's
`create_ip` regel.

IP-objecten hebben **geen** `VERSION` property; de versie zit in `IPDEF`
(`xilinx.com:ip:high_speed_selectio_wiz:3.6`).

Aantal `CONFIG.*` properties op een verse instantie: **547**.

## `get_package_pins` werkt niet zonder `link_design`

In een kaal (in-memory) project geeft zowel `get_package_pins` als `get_iobanks`
**nul** resultaten. De device database wordt pas geladen door `link_design`:

```tcl
create_project -in_memory -part $part
puts [llength [get_package_pins -quiet]]     ;# 0
link_design -part $part -name q
puts [llength [get_package_pins -quiet]]     ;# 1517
puts [llength [get_iobanks -quiet]]          ;# 23
```

`get_iobanks` geeft de banknummers zelf terug (`0 27 28 63 64 65 66 67 ...`), geen
objecten met een aparte NAME.

`BANK_TYPE` waarden op dit device: `BT_HIGH_PERFORMANCE` (8), `BT_HIGH_DENSITY` (2),
`BT_MGT` (7), `BT_PSS` (5), `BT_NO_USER_IO` (1).

### Gevolg: DESIGN_MODE moet hersteld worden

`link_design` zet `DESIGN_MODE` op `GateLvl`, en `close_design` zet dat **niet** terug.
`create_ip` weigert dan met:

```
ERROR: [Ipptcl 7-1624] IP commands are only valid for RTL projects.
```

`DESIGN_MODE` zit op de fileset, niet op het project:

```tcl
close_design
set_property DESIGN_MODE RTL [get_filesets sources_1]
```

## Properties zijn vrije strings, geen enums

`list_property_value` geeft een **lege lijst** voor `CONFIG.BUS_DIR`,
`CONFIG.BYTE0_PIN0_DATA_STROBE`, `CONFIG.BYTE0_PIN0_SIG_TYPE`,
`CONFIG.BYTE0_PIN0_BUS_DIR`, `CONFIG.DIFFERENTIAL_IO_STD`, `CONFIG.PLL0_CLK_SOURCE` en
`CONFIG.FIFO_RD_EN_CONTROL`. Je kunt waarden dus niet vooraf valideren — alleen echt
zetten en kijken wat de wizard zegt.

Defaults op een verse instantie:

| property | default |
|---|---|
| `BUS_DIR` | `1` |
| `BYTE0_PIN0_DATA_STROBE` | `Data` |
| `BYTE0_PIN0_SIG_TYPE` | `SINGLE` |
| `BYTE0_PIN0_BUS_DIR` | `RX` |
| `DIFFERENTIAL_IO_STD` | `NONE` |
| `PLL0_CLK_SOURCE` | `IBUF_TO_PLL` |
| `FIFO_RD_EN_CONTROL` | `0` |

## LOC en NAME worden auto-afgeleid

Zonder `CONFIG.BANK` te zetten stond `BYTE0_PIN0_LOC` al op `H38` en `BYTE0_PIN0_NAME`
op `IO_L1P_T0L_N0_DBC_27`. De wizard vult de pin-tabel dus zelf uit de bank. Het script
zet ze alsnog expliciet als extra zekerheid, en leest ze daarna terug ter controle.

## Twee pinnen staan STANDAARD aan

Dit is de belangrijkste valkuil:

```
CONFIG.ENABLE_BYTE2_PIN0  = true   signal='clk'        strobe='Input Clock'
CONFIG.ENABLE_BYTE3_PIN12 = true   signal='bg3_pin12'  strobe='Data'
```

Laat je die staan, dan krijg je validatiefouten over byte groups die je nooit hebt
aangeraakt:

```
Byte-Group 2 Lower Nibble bits cannot be Enabled with current strobe/clock positions
Port with name clk already exists, have a different name to 26 pin to proceed
```

(pin 26 = byte2 · 13 + 0). Precies daarom staat er in ADI's config
`CONFIG.ENABLE_BYTE2_PIN0 {false}` en `CONFIG.ENABLE_BYTE3_PIN12 {false}`.

**Fix:** zet elke `ENABLE_BYTE?_PIN*` die je niet gebruikt expliciet op `false`.

## Properties moeten atomisch gezet worden

Property-voor-property zetten werkt niet. De wizard valideert na elke losse
`set_property` en struikelt over een inconsistente tussentoestand — bijvoorbeeld een pin
die enabled wordt terwijl zijn `BUS_DIR` nog op de default `RX` staat:

```
RX and TX cannot be combined in same nibble when IP is operating in ASYNC/NONE mode,
Byte-Group 0 Lower Nibble is violating this rule
```

Alles in één `set_property -dict` lost dit op. Dat is ook wat ADI doet.

Nadeel: je verliest de mogelijkheid om te zeggen welke property precies faalt. De
wizard-melding noemt gelukkig meestal de echte regel.

## BUS_DIR — opgelost, het is een enum

`BUS_DIR` is geen bitmasker en geen aantal buses. Het is een enum, en de labels staan
gewoon in `component.xml` van het IP
(`<Vivado>/data/ip/xilinx/high_speed_selectio_wiz_v3_6/component.xml`, choice
`choice_pairs_1bcffd76`):

| waarde | label |
|---|---|
| **0** | **TX_ONLY** |
| **1** | **RX_ONLY** |
| 3 | TX + RX |
| 2 | BIDIR of TX+RX of TX+RX+BIDIR |

Voor de split-bank opzet is het dus 0 voor de TX-instantie en 1 voor de RX-instantie.

Wat er gebeurde met de eerder gebruikte `BUS_DIR 3` op een TX-only instantie: de wizard
accepteert hem, maar zet dan zelf de klokstructuur om. Gemeten op de gegenereerde
`.xci`/`.veo`, 1600 Mb/s:

| property | BUS_DIR 3 (fout) | BUS_DIR 0 (goed) |
|---|---|---|
| `PLL0_CLK_SOURCE` | `IBUF_TO_PLL`, **disabled** | `BUFG_TO_PLL` |
| `PLL0_INPUT_CLK_FREQ` | `800.000`, **disabled** | `200.000` |
| `C_INCLK_LOC` | `G28` (pin in de bank!) | `NONE` (fabric) |
| `ooc.xdc` | `create_clock -period 1.250` | `create_clock -period 5.000` |

Met `BUS_DIR 3` krijg je dus stilzwijgend een instantie die een externe 800 MHz klok op
een bankpin verwacht in plaats van je 200 MHz fabric-referentie — terwijl de wrapper
diezelfde `pll_inclk` aan beide instanties hangt. Met `BUS_DIR 0` zijn TX en RX identiek
geklokt: `MULT 8 / DIV 2` → VCO 800 MHz, `CLKOUTPHY` in `VCO_2X` → 1600 Mb/s.

`BUS_DIR 2` klemt bovendien `PLL0_DATA_SPEED` op het bereik (800.0, 1300.0).

ADI's Versal-config gebruikt `BUS_DIR {3}` — dat is daar terecht: één instantie met TX
*en* RX.

## Genegeerde properties zijn stil

Dit is de reden dat bovenstaande zo lang onopgemerkt bleef. Zet je een property die in de
huidige modus disabled is, dan **slaagt `set_property`**. Je krijgt alleen:

```
WARNING: [IP_Flow 19-3374] An attempt to modify the value of disabled parameter
'PLL0_INPUT_CLK_FREQ' from '800.000' to '200.000' has been ignored for IP 'hsci_hssio_tx'
```

Geen fout, geen exit code, en in een batchlog van duizend regels zie je het niet. Daarom
leest `hsci_verify_props` na afloop elke gezette property terug en faalt hard bij een
afwijking. Alleen `PLL0_PLLOUT0` (altijd afgeleid uit `data_speed`), `ENABLE_N_PINS`
(bestaat niet in TX_ONLY) en `TX_PRE_EMPHASIS_D` mogen afwijken.

## De referentieklok mag niet zomaar iets zijn

`PLL0_INPUT_CLK_FREQ` heeft per `data_speed` een vaste lijst toegestane waarden. Bij
1250 Mb/s staat 200 MHz er **niet** in; de wizard antwoordt met de volledige lijst:

```
73.529, 78.125, 83.333, 89.286, 96.154, 104.167, 113.636, 125.000, 138.889, 147.059,
156.250, 166.667, 178.571, 192.308, 208.333, ... 714.286
```

Bij 1600 Mb/s is 200.000 wel geldig. Ga je naar 1250 (zie speed grade), dan is 156.250
(= 1250/8) de natuurlijke keuze.

## Port map bevestigd

RX-instantie, bank 27, strobe op byte2 N6/N7, data op byte2 N8/N9. Werkelijke poorten uit
de `.veo`:

```
clk, rst, pll0_locked, pll0_clkout0, pll0_clkout1, rst_seq_done,
shared_pll0_clkoutphy_out,
dly_rdy_bsc5, vtc_rdy_bsc5, en_vtc_bsc5,
clk_in_p, clk_in_n, data_to_fabric_clk_in_p,
data_in_p, data_in_n, data_to_fabric_data_in_p,
fifo_rd_clk_32, fifo_rd_en_32, fifo_empty_32,
fifo_rd_clk_34, fifo_rd_en_34, fifo_empty_34
```

Dit bevestigt de afleidingsregel exact:

- `bsc` = byte · 2 + nibble → 2 · 2 + 1 = **5**
- fifo-index = byte · 13 + pinindex → 2 · 13 + 6 = **32**, en + 8 = **34**

`pll0_clkout1` en `shared_pll0_clkoutphy_out` waren niet voorspeld; die zijn optioneel en
blijven onaangesloten.

## De fysieke nibble is opvraagbaar uit de device database

Gemeten op `xczu17eg-ffvd1760-1-e` (Vivado 2025.1). Tot nu toe leidde alles byte group en
nibble af uit een regex op `PIN_FUNC` (`IO_L16P_T2U_N6_QBC_AD3P_65` → byte 2, nibble U,
N6). Dat werkt, maar het is een naamconventie, geen device data. Het echte silicium staat
er ook in, en `scripts/hsci_nibble.tcl` haalt het daar vandaan.

### Twee properties die niemand noemt

Een package pin heeft `PKGPIN_BYTEGROUP_INDEX` (0..12, positie in de byte group) en
`PKGPIN_NIBBLE_INDEX` (0..6, positie in de nibble). Voor `IO_L24N_T3U_N11_65`: 11 en 5.
Het byte group*nummer* zelf zit er niet in — dat komt uit de sitegeometrie hieronder.

### De sitestructuur

```
HP bank            52 IOB-sites = 4 byte groups x 13
  get_sites -of_objects [get_iobanks 65]   ->  IOB_X0Y52 .. IOB_X0Y103

XIPHY_BYTE_*-tile  een per byte group, in dezelfde clock region als de HPIO-tile
  13x BITSLICE_RX_TX     de bitslices
   2x BITSLICE_CONTROL   een per nibble          <- DE fysieke nibble
   2x PLL_SELECT_SITE
   1x RIU_OR             een per byte group
```

De sleutel: **de Y-nummering van `BITSLICE_RX_TX` is identiek aan die van de IOB-sites.**
Gecontroleerd op alle vijf HP banks van dit package:

| bank | clock region | IOB Y | BITSLICE_RX_TX Y |
|---|---|---|---|
| 65 | X2Y1 | 52..103 | 52..103 |
| 66 | X2Y2 | 104..155 | 104..155 |
| 69 | X2Y5 | 260..311 | 260..311 |
| 70 | X2Y6 | 312..363 | 312..363 |
| 71 | X2Y7 | 364..415 | 364..415 |

Daarmee is de bitslice van een pin te vinden zonder enige aanname over tilevolgorde:
zoek in de XIPHY-tiles van dezelfde clock region naar de bitslice met dezelfde Y.

`BITSLICE_CONTROL` telt gewoon door over het device — bank 65 byte0 krijgt Y8/Y9, byte1
Y10/Y11, byte2 Y12/Y13, byte3 Y14/Y15, bank 66 byte0 Y16/Y17, enzovoort. Die Y is het
device-globale nibblenummer. De wizard nummert per instantie vanaf 0 (`bsc0`..`bsc7`
binnen de bank), dus `bsc = byte*2 + nibble` blijft de naam in de poortmap; het
`BITSLICE_CONTROL`-site is waar hij fysiek landt.

Voorbeeld, `AP18` = `IO_L16P_T2U_N6_QBC_AD3P_65`:

```
IOB_X0Y84  ->  BITSLICE_RX_TX_X0Y84  in  XIPHY_BYTE_L_X28Y90
byte 2, nibble U, N6      bsc5      BITSLICE_CONTROL_X0Y13   RIU_OR_X0Y6
```

Alle 52 pinnen van bank 65 en bank 66 zijn zo doorgerekend en komen exact overeen met
`PIN_FUNC` en met beide `PKGPIN_*`-properties. `hsci_nibble_of_pin` doet die kruiscontrole
elke aanroep en zet afwijkingen in `warnings`.

### Waarom dit nuttig is

- De nibble-regel voor HSCI ("strobe en data in dezelfde nibble") wordt controleerbaar
  tegen het silicium in plaats van tegen een pinnaam.
- Je kunt een `set_property LOC` op bitslice- of `BITSLICE_CONTROL`-niveau plannen.
- Het `PLL_SELECT_SITE` per nibble laat zien welke XPLL een nibble kan klokken.
- Bij een device waar de naamconventie afwijkt, valt dat op in `warnings` in plaats van
  stil een verkeerde `bscN` op te leveren.

## Het doeldevice bestaat, en snellere grades ook

`xczu17eg-ffvd1760-1-e` is een geldig part (device `xczu17eg`, package `ffvd1760`,
architectuur `zynquplus`, speed grade `-1`). In dezelfde footprint bestaan ook `-2-e`,
`-2-i`, `-2L-e`, `-2LV-e` en `-3-e`, dus een part dat 1600 Mb/s haalt is bestelbaar
zonder de PCB-footprint te wijzigen.

HP banks op dit package: **65, 66, 69, 70, 71**. De pinnen die eerder in de config stonden
(`P37`, `V33`, …) horen op dit package bij MGT-banks — die kwamen uit een ander pinout.

## DBC en QBC reiken verder dan hun eigen nibble

De demo-config in `docs/hssio_for_demo.txt` zet de RX-strobe op `BYTE3_PIN6/7`
(byte3**U**) en de data op `BYTE3_PIN2/3` (byte3**L**) — verschillende nibbles. Dat
leek in strijd met de regel "strobe en data in dezelfde nibble" die hier eerder stond.
Die regel was te streng. Het verschil tussen de twee soorten clock-capable pinnen zit
precies hierin (UG571):

| | reikt tot |
|---|---|
| **DBC** — dual byte clock | de **twee** nibbles van zijn eigen byte group |
| **QBC** — quad byte clock | **vier** nibbles, dus ook de aangrenzende byte group |

`C20` = `IO_L22P_T3U_N6_DBC_AD0P_70` klokt dus zowel bsc7 (zijn eigen nibble) als bsc6
(waar de data zit). De juiste regel is: **zelfde byte group, strobe op een DBC- of
QBC-pin**.

Gevolg voor de port map: zodra strobe en data in verschillende nibbles zitten, levert
de wizard **twee** `BITSLICE_CONTROL`s op en dus twee sets `dly_rdy`/`vtc_rdy`/`en_vtc`.
Bevestigd op de demo-pinout — de RX-instantie gaf `bsc6` én `bsc7`, met fifo-poorten op
slice 41 (data, 3·13+2) en 45 (strobe, 3·13+6). `axi_hsci` heeft maar één statuslijn per
richting, dus de gegenereerde PHY AND't ze.

## Alle IP-HDL in één synthese laat Vivado 2025.1 crashen

Om een gegenereerde wrapper te controleren wil je het IP niet apart naar een DCP
synthetiseren maar alles in één keer meenemen:

```tcl
set_property GENERATE_SYNTH_CHECKPOINT false [get_files *.xci]
generate_task {synthesis} [get_files *.xci]
synth_design -top hsci_demo_top -mode out_of_context
```

RTL-elaboratie loopt dan helemaal door, en vervolgens crasht Vivado:

```
Parsing XDC File [.../hssio_wiz_hsci_tx.xdc] for cell 'i_hsci_phy/i_hssio_tx/inst'
INFO: [Project 1-236] Implementation specific constraints were found ...
Abnormal program termination (EXCEPTION_ACCESS_VIOLATION)
```

Exit code 0xC0000005, `hs_err_pid*.log` zonder stack trace. Gebeurt zowel met als zonder
`-mode out_of_context`, en zowel op `xczu17eg` als bij een kaler ontwerp — het hangt aan
de XDC van `high_speed_selectio_wiz` 3.6.

**Werkt wel:** de normale flow, elk IP eerst zijn eigen checkpoint geven.

```tcl
set_property GENERATE_SYNTH_CHECKPOINT true [get_files *.xci]
foreach ip [get_ips] { synth_ip [get_ips $ip] }
synth_design -top hsci_demo_top -mode out_of_context
```

Daarmee synthetiseert het complete demo-toplevel (7060 cellen: 2 `TX_BITSLICE`,
2 `RX_BITSLICE`, 4 `BITSLICE_CONTROL`, 2 XPLL, 1 MMCM, `BSCANE2` voor de JTAG-AXI).

Eén verwachte CRITICAL WARNING blijft over:

```
Clock 'sys_clk' completely overrides clock 'H20'.
  New:      create_clock -period 5.000 -name sys_clk [get_ports H20]   (onze XDC)
  Previous: create_clock -period 5.000 [get_ports H20]                 (hsci_demo_clk_in_context.xdc)
```

De `*_in_context.xdc` die Vivado voor de OOC-synthese van het clocking wizard IP maakt,
definieert de inkomende klok met dezelfde periode maar zonder naam. In een echte
projectflow leest de top-run dat bestand niet en is de melding weg; in een
in-memory-controle als deze zie je hem wel.
