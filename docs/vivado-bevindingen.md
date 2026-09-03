# Empirische bevindingen — Vivado 2026.1

Alles hieronder is gemeten, niet aangenomen. Testplatform: Vivado 2026.1
(SW build 6511674), part `xczu7ev-ffvf1517-2-e`. Het doeldevice `xczu17eg` zat niet in
deze installatie.

## Wizard-versie

`high_speed_selectio_wiz` is in 2026.1 nog steeds **3.6** — dezelfde versie die ADI in
hun vcu118-project gebruikt. Er is dus geen property-drift ten opzichte van ADI's
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

## BUS_DIR

| instantie | waarde | resultaat |
|---|---|---|
| TX-only | 1 | faalt |
| TX-only | 2 | faalt |
| TX-only | **3** | **OK** |
| RX-only | **1** | **OK** (met de disable-fix) |

Kanttekening: de TX-tests liepen *zonder* de "disable unused pins"-fix. Mogelijk werkt 2
inmiddels ook. Nog opnieuw te testen.

Merk op dat ADI's Versal-config `BUS_DIR {3}` gebruikt met `BUS0`/`BUS1`/`BUS2`
signal-definities — daar lijkt het het *aantal buses* te zijn (data_in, data_out,
clk_out). Op de US+ wizard 3.6 worden pinnen via `BYTE?_PIN*` gedefinieerd en is de
betekenis van `BUS_DIR` onduidelijk; bovenstaande waarden zijn empirisch.

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
