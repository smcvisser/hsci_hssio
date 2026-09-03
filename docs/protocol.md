# HSCI protocol en registers

Gereverse-engineerd uit ADI's RTL in `library/axi_hsci` — niet uit een datasheet. Als je
onder NDA de AD9084 UG hebt, gebruik die om dit te toetsen.

## Architectuur van `axi_hsci`

```
AXI4-Lite (18-bit adres, 256K aperture)
   |
   +-- hsci_master_axi_slave --+-- Yoda regmap (hsci_master_regs_regs)
   |                           +-- XPM TDPRAM 32K x 32 (128 KB)
   |                                    | port B @ hsci_pclk
   +------------------ hsci_mcore ------+
                          +-- hsci_menc       TX: FSM + gearbox + 8-deep prefetch FIFO
                          +-- hsci_mfrm_det   RX: frame alignment, BER counter
                          +-- hsci_mdec       RX: decode -> BRAM writeback
                          +-- hsci_mlink_ctrl auto-linkup FSM, 15 states
```

De PHY zit **niet** in de IP. Die eindigt bij `[7:0] menc_clk / mosi_data / miso_data`
op `hsci_pclk`.

## Address map

Uit `hsci_master_axi_slave.sv`: `regaddr = axi_addr[17:2]`, daarna

| regaddr | doel |
|---|---|
| `0x0000` | regmap: REVISION_ID |
| `0x0001` .. `0x8000` | BRAM, met `bram_addr = regaddr - 1` |
| `> 0x8000` | regmap: `0x8001` MODE .. `0x801F` SCRATCH |

BRAM staat dus op byte-offset `0x4` .. `0x20000`, registers op `0x20004` .. `0x2007C`.
Diezelfde `-1` offset komt terug in `hsci_master_top`:
`bram_strt_addr = hsci_bram_start_address - 1`.

Relevante registers:

| adres | register |
|---|---|
| `0x8001` | MASTER_MODE |
| `0x8002` | XFER_NUM |
| `0x8003` | ADDR_SIZE |
| `0x8004` | BYTE_NUM |
| `0x8006` | CTRL |
| `0x8007` | BRAM start address |
| `0x8008` | RUN (self-clearing) |
| `0x8009` | STATUS |
| `0x800A` | LINKUP_CTRL |
| `0x800B` | TEST_CTRL |
| `0x800C` | LINKUP_STATUS (`alink_fsm`, `alink_table`) |
| `0x800D` | LINKUP_STATUS2 |
| `0x800E` | DEBUG_STATUS (FSM states) |
| `0x800F` | MISO_TEST_BER |
| `0x8010` | LINK_ERR_INFO |
| `0x8011` | RATE_CTRL |
| `0x8012` | MASTER_RST |
| `0x8013` | PHY_STATUS |
| `0x801F` | SCRATCH |

## Datapad

Geen streaming AXI. Een write is: CPU vult BRAM met een sequence, zet
`cmd_sel`/`xfer_num`/`byte_num`/`addr_size`/`tsize`, en pulst `hsci_run`. Reads komen via
`hsci_mdec` weer in dezelfde BRAM terecht. De 8-deep prefetch-FIFO in `menc` verbergt de
2-cycle BRAM read latency tegen een woordstroom die 4-op-5 klokken doorloopt.

`cmd_sel`: `00` = write, `01` = read, `10` = RMW. `11` is een alias van RMW
(`LINKUP_OP == MRMW_OP == 4'b1001`); de comment in `hsci_mcore.v` die `10` als write
aanduidt klopt niet.

## Wire protocol

Woorden zijn **10 bits**:

```
[9]     start bit (1)
[8:5]   instructie
[4:2]   tsize {1'b0, m_tsize}
[1]     parity
[0]     continuation
```

Data-woorden: `[9:2]` = databyte, `[1]` = parity, `[0]` = 1 als er meer volgt.

Instructies: `0110` write, `1000` read, `1001` RMW.

Parity (`hsci_menc.sv` regel 556): even parity over `{[9:2], [0]}` — de `+` in 1-bit
context is XOR. Bij linkup-woorden wordt `menc_word[1]` doorgegeven in plaats van
berekend.

### Gearbox

10-bit woorden over een 8-bit bus: 4 woorden per 5 klokken (40 bits). Vandaar
`menc_word_cntr` 0..4 en `menc_pause` op cntr==3 — de FSM staat een op de vijf klokken
stil.

Aan de RX-kant hetzelfde in `hsci_mfrm_det`: een 18-bit sliding buffer, en de frame-search
kijkt alleen naar alignments **7, 5, 3 en 1**. Dat is geen willekeur — 10 mod 8 = 2, dus
opeenvolgende woordgrenzen schuiven elke klok exact 2 bitposities op. Even alignments
kunnen niet bestaan. `frm_align` loopt 7 → 5 → 3 → 1 → 7.

## Auto-linkup

`hsci_mlink_ctrl` doet een phase sweep:

```
M_IDLE -> M_RX_LINK (wacht op signal_det, timeout 2^20 pclk)
        -> M_TX_DETECT
        -> [ M_TX_CLK_ADJ -> M_TX_ACQ -> M_TX_ENDLP -> M_TX_STALL ] x 16
               bouwt alink_table[15:0]: welke van de 16 klokfases locken
        -> M_TX_DECIDE   (sum3/sum5/sum7 windowing -> breedste eye)
        -> M_TX_CLK_INV  (probeer klokinversie als geen fase werkt)
        -> M_SET_TXCLK -> M_TX_REACQ -> M_TX_LINKUP -> M_LINKUP
        (of M_LINK_ERR)
```

De fase-adjust wordt **in het linkup-woord naar de slave gestuurd**, niet in een FPGA
IDELAY gezet. De MxFE past zijn eigen sampling aan. Vandaar `tx_clk_adj_rcvd` /
`tx_clk_inv_rcvd` die terugkomen via `mdec`, plus `txclk_adj_mismatch` /
`txclk_inv_mismatch` als loopback-check.

BIST: `lfsr15_8.v` (x^15 + x^14 + 1, 8 bits/klok) voor MOSI test mode; MISO test mode doet
LFSR-acquisitie en BER-telling in `mfrm_det`.

## Bring-up volgorde

Afgeleid uit de RTL:

```
1. hsci_pll_reset = 1 -> 0        (0x8012, actief hoog richting de wizard)
2. poll hsci_pll_locked           (0x8013)
3. poll hsci_rst_seq_done         (0x8013)   <- wizard klaar, miso_data ungated
4. hsci_master_rstn = 1           (0x8012)
5. hsci_auto_linkup = 1           (0x800A)
6. poll alink_fsm == 0xD (M_LINKUP) / link_active   (0x800C)
```

## Debuggen

`alink_table` (0x800C) is het beste diagnosesignaal: 16 bits, een per klokfase.

| waarde | betekenis |
|---|---|
| `0x0000` | geen enkele fase lockt — bedrading, termination of VCCO |
| `0xFFFF` | alle fases "werken" — je kijkt naar ruis of een vastzittende lijn |
| bv. `0x03F0` | gezond, kies het midden |

Daarnaast `miso_test_mode` + BER-teller op `0x800F` voor een pure PHY-test zonder
protocol.
