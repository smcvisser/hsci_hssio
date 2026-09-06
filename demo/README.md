# Demo: HSCI van pinnen tot bitstream-klaar toplevel

Eén commando:

```bash
uv run demo/build_demo.py --check
```

Daar rolt een compleet, synthetiseerbaar ontwerp uit: twee High Speed SelectIO
Wizard instanties afgeleid uit acht package pins, ADI's `axi_hsci` erop
aangesloten, een JTAG-AXI debugmaster op een eigen klokdomein, en een AXI-Lite
klokconverter daartussen.

`uv` regelt Jinja zelf — het scriptheader is PEP 723, er is geen venv om te
activeren.

---

## Wat er gebeurt

```
demo_config.json          jouw keuzes: part, 8 pinnen, klokken, rate
        |
        |  build_demo.py schrijft er een Tcl-configblok van
        v
vivado/hsci_demo_gen.tcl  ---> Vivado batch
        |                        - pin-analyse tegen de echte device database
        |                        - regelchecks (bank, byte group, DBC/QBC)
        |                        - 2x high_speed_selectio_wiz, afgeleid
        |                        - clk_wiz, jtag_axi, axi_clock_converter
        |                        - port map toetsen aan de .veo
        v
generated/hsci_facts.json  alles wat de analyse heeft opgeleverd
        |
        |  build_demo.py rendert met Jinja
        v
generated/hsci_phy_top.sv     PHY, poorten exact zoals axi_hsci ze wil
generated/hsci_demo_top.sv    toplevel met klokken, JTAG-AXI, CDC, axi_hsci
generated/hsci_demo_pins.xdc  pinnen, klokken, VCCO-eis
generated/hsci_demo_srcs.tcl  bestandslijst voor een Vivado-project
```

De splitsing is niet willekeurig: alles waarvoor je de device database nodig
hebt gebeurt in Tcl binnen Vivado, al het genereren van tekst in Python. De
analyseprocs komen uit [`scripts/hsci_hssio_lib.tcl`](../scripts/hsci_hssio_lib.tcl),
dezelfde motor als de generator in `scripts/`.

## De pinout

Overgenomen uit [`docs/hssio_for_demo.txt`](../docs/hssio_for_demo.txt), maar
niet overgetypt: `build_demo.py` krijgt alleen de acht package pins en leidt
bank, byte group, nibble, bitslice-index en de complete port map zelf af.

| | wizard-pin | package | PIN_FUNC | nibble | bsc |
|---|---|---|---|---|---|
| TX clk fwd | `BYTE0_PIN4/5` | R26/P26 | `IO_L3P_T0L_N4_AD15P_69` | byte0**L** | 0 |
| TX data | `BYTE0_PIN10/11` | M27/M28 | `IO_L6P_T0U_N10_AD6P_69` | byte0**U** | 1 |
| RX data | `BYTE3_PIN2/3` | D20/C21 | `IO_L20P_T3L_N2_AD1P_70` | byte3**L** | 6 |
| RX strobe | `BYTE3_PIN6/7` | C20/B21 | `IO_L22P_T3U_N6_DBC_AD0P_70` | byte3**U** | 7 |

Let op de RX-kant: strobe en data zitten in **verschillende nibbles**. Dat mag,
want C20 is een DBC-pin en *dual byte clock* betekent dat hij beide nibbles van
zijn byte group klokt (QBC haalt er vier, over twee byte groups). Gevolg is wel
dat zowel de TX- als de RX-instantie twee `BITSLICE_CONTROL`s krijgt; de
gegenereerde PHY AND't hun `dly_rdy`/`vtc_rdy` naar de twee statuslijnen die
`axi_hsci` verwacht.

## De klokken

Eén differentiële systeemklok van 200 MHz komt binnen op H20/H21 (GC-pin in
bank 70). De MMCM maakt daar twee klokken van:

| klok | frequentie | waarvoor |
|---|---|---|
| `clk_out1` | 200 MHz | referentie voor de XPLL van **beide** wizards |
| `clk_out2` | 100 MHz | het JTAG-AXI domein |
| `hsci_pclk` | 200 MHz | uit de XPLL van de TX-wizard, = datarate/8 |

De JTAG-AXI draait expres op `clk_out2` en niet op `hsci_pclk`. Dat is het punt
van de demo: je debugmaster hangt aan een vrijlopende klok, en
`axi_clock_converter` doet de overgang naar `hsci_pclk` voordat het bij
`axi_hsci` aankomt. Hing je hem rechtstreeks aan `hsci_pclk`, dan verlies je je
debugpad precies op het moment dat je het nodig hebt — als de XPLL uit lock
gaat.

Resets komen van ADI's `ad_rst`, één per klokdomein: het AXI-domein komt los
zodra de MMCM lockt, het `hsci_pclk`-domein zodra ook beide XPLLs locken.

### Eén consequentie om te weten

`axi_hsci` op `hsci_pclk` zetten betekent dat het register `HSCI_RATE_CTRL[8]`
(`hsci_pll_reset`) de klok wegneemt waarop `axi_hsci` zelf loopt. Schrijf je die
bit op 1, dan krijg je hem niet meer op 0 — alleen een nieuwe bitstream helpt.
Uit reset staat de bit op 0 (`hsci_master_regs_regs.sv:366`), dus opstarten gaat
goed. Wil je die bit echt kunnen bedienen, geef `axi_hsci` dan een eigen
`s_axi_aclk` en laat de CDC die er al in zit het werk doen — dan is de externe
`axi_clock_converter` overbodig.

## Wat je zelf kunt veranderen

Alles in `demo_config.json`. De acht pinnen, de systeemklok, de twee
MMCM-frequenties, de rate, `PLL0_RX_EXTERNAL_CLK_TO_DATA`, de IP-namen. Het
script leidt de rest af en klaagt met een reden als een combinatie niet kan:

```
**** HSCI CONFIGURATIE ONMOGELIJK ****

  reden   : RX strobe C21 is geen QBC/DBC pin (IO_L20N_T3L_N3_AD1N_70)
  remedie : de strobe moet op het N0/N1- of N6/N7-paar van een nibble; die
            zijn als DBC of QBC gemarkeerd in de pinnaam
```

## Twee dingen die niet kloppen met de werkelijkheid

**1600 Mb/s op een -1.** `demo_config.json` staat op `"force_rate": true`. De
`xczu17eg-ffvd1760-**1**` haalt in native mode 1250 Mb/s volgens DS925, niet
1600. Voor genereren en synthetiseren maakt dat niets uit, voor silicon wel.
Zet je de rate op 1250, zet dan ook `ref_freq` op 156.250 — 200 MHz staat niet
in de lijst die de wizard bij 1250 accepteert.

**`PLL0_RX_EXTERNAL_CLK_TO_DATA` staat op 4**, zoals in `hssio_for_demo.txt`
(edge-aligned strobe). ADI's eigen vcu118-referentie gebruikt 3 (center-aligned).
Dat is een eigenschap van hoe de MxFE zijn data t.o.v. `hsci_cko` uitstuurt, niet
van de FPGA — controleer het tegen de AD9084-datasheet voor je hier een PCB op
baseert.

## ADI's sources

`axi_hsci` komt uit een sparse clone onder `src/adi-hdl` (staat in
`.gitignore`). Opnieuw ophalen:

```bash
git clone --filter=blob:none --sparse --depth 1 https://github.com/analogdevicesinc/hdl.git src/adi-hdl
cd src/adi-hdl && git sparse-checkout set library/axi_hsci library/common library/util_cdc library/scripts library/xilinx
```

Ongeveer 3 MB in plaats van de volledige repo.

## In de Vivado GUI openen

De hele flow draait op `create_project -in_memory`, en dat schrijft nooit een
`.xpr`. Wil je het ontwerp in de GUI zien, vraag er dan expliciet om:

```bash
uv run demo/build_demo.py --project
vivado demo/generated/vivado_project/hsci_demo.xpr
```

Wat je dan opent: part `xczu17eg-ffvd1760-1-e`, top `hsci_demo_top`, 79
bronbestanden, de vijf IP's (`high_speed_selectio_wiz` 3.6 ×2, `clk_wiz` 6.0,
`jtag_axi` 1.2, `axi_clock_converter` 2.1), de XDC, en runs `synth_1`/`impl_1`
klaar om te starten.

De IP's blijven staan waar `build_demo.py` ze heeft gezet (`generated/.srcs/`);
het project verwijst ernaar in plaats van ze te kopiëren. Eén waarheid dus — pas
je `demo_config.json` aan en draai je opnieuw, dan ziet het project dat. De
keerzijde: wijzig je iets in de GUI, dan overschrijft de volgende run het weer.
De bron is `demo_config.json` en `templates/`, niet het project.

`--project` combineert met de rest, dus dit is de complete gang van nul af:

```bash
uv run demo/build_demo.py --clean --project --check
```

## Losse onderdelen draaien

```bash
uv run demo/build_demo.py --skip-vivado    # alleen opnieuw renderen uit hsci_facts.json
uv run demo/build_demo.py --check          # genereren en daarna synthetiseren
uv run demo/build_demo.py --clean --check  # schone build van nul af
uv run demo/build_demo.py --project        # .xpr voor de GUI
uv run demo/build_demo.py --clean-only     # alleen generated/ weggooien
uv run demo/build_demo.py --vivado <pad>   # als vivado niet in PATH staat
```

`--clean` gooit `generated/` in zijn geheel weg: de RTL, de XDC,
`hsci_facts.json`, `demo_cfg.tcl`, de logs, en de Vivado-mappen `.srcs/`,
`.gen/` en `.Xil/` met de vijf IP's erin — bij elkaar zo'n 58 MB. Wat blijft
staan is bron en geen resultaat: `demo_config.json`, `templates/`, `vivado/`,
en `src/adi-hdl` (dat is een clone, niet iets wat dit script maakt).

`--clean` samen met `--skip-vivado` wordt geweigerd voordat er iets verdwijnt —
die combinatie gooit juist de `hsci_facts.json` weg waar `--skip-vivado` uit
zou renderen.

Het volledige Vivado-log staat altijd in `generated/gen.log` en
`generated/check.log`; op de terminal komen alleen de kopregels.
