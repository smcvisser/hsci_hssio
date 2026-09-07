# HSCI protocol and registers

Reverse-engineered from ADI's RTL in `library/axi_hsci` — not from a datasheet. If you
have the AD9084 UG under NDA, use it to verify this.

## Architecture of `axi_hsci`

```
AXI4-Lite (18-bit address, 256K aperture)
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

The PHY is **not** part of the IP. It ends at `[7:0] menc_clk / mosi_data / miso_data`
on `hsci_pclk`.

## Address map

From `hsci_master_axi_slave.sv`: `regaddr = axi_addr[17:2]`, then

| regaddr | target |
|---|---|
| `0x0000` | regmap: REVISION_ID |
| `0x0001` .. `0x8000` | BRAM, with `bram_addr = regaddr - 1` |
| `> 0x8000` | regmap: `0x8001` MODE .. `0x801F` SCRATCH |

So BRAM sits at byte offset `0x4` .. `0x20000`, registers at `0x20004` .. `0x2007C`.
That same `-1` offset shows up again in `hsci_master_top`:
`bram_strt_addr = hsci_bram_start_address - 1`.

Relevant registers:

| address | register |
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

## Data path

No streaming AXI. A write works like this: the CPU fills BRAM with a sequence, sets
`cmd_sel`/`xfer_num`/`byte_num`/`addr_size`/`tsize`, and pulses `hsci_run`. Reads land
back in the same BRAM via `hsci_mdec`. The 8-deep prefetch FIFO in `menc` hides the
2-cycle BRAM read latency against a word stream that runs at 4-in-5 clocks.

`cmd_sel`: `00` = write, `01` = read, `10` = RMW. `11` is an alias for RMW
(`LINKUP_OP == MRMW_OP == 4'b1001`); the comment in `hsci_mcore.v` that labels `10` as
write is wrong.

## Wire protocol

Words are **10 bits**:

```
[9]     start bit (1)
[8:5]   instruction
[4:2]   tsize {1'b0, m_tsize}
[1]     parity
[0]     continuation
```

Data words: `[9:2]` = data byte, `[1]` = parity, `[0]` = 1 if more follows.

Instructions: `0110` write, `1000` read, `1001` RMW.

Parity (`hsci_menc.sv` line 556): even parity over `{[9:2], [0]}` — the `+` in 1-bit
context is XOR. For linkup words, `menc_word[1]` is passed through rather than
computed.

### Gearbox

10-bit words over an 8-bit bus: 4 words per 5 clocks (40 bits). Hence
`menc_word_cntr` 0..4 and `menc_pause` on cntr==3 — the FSM stalls one clock in five.

On the RX side, same thing in `hsci_mfrm_det`: an 18-bit sliding buffer, and the
frame search only looks at alignments **7, 5, 3 and 1**. That's not arbitrary — 10
mod 8 = 2, so consecutive word boundaries shift by exactly 2 bit positions every
clock. Even alignments can't exist. `frm_align` cycles 7 → 5 → 3 → 1 → 7.

## Auto-linkup

`hsci_mlink_ctrl` does a phase sweep:

```
M_IDLE -> M_RX_LINK (waits for signal_det, timeout 2^20 pclk)
        -> M_TX_DETECT
        -> [ M_TX_CLK_ADJ -> M_TX_ACQ -> M_TX_ENDLP -> M_TX_STALL ] x 16
               builds alink_table[15:0]: which of the 16 clock phases lock
        -> M_TX_DECIDE   (sum3/sum5/sum7 windowing -> widest eye)
        -> M_TX_CLK_INV  (try clock inversion if no phase works)
        -> M_SET_TXCLK -> M_TX_REACQ -> M_TX_LINKUP -> M_LINKUP
        (or M_LINK_ERR)
```

The phase adjustment is **sent to the slave in the linkup word**, not applied via an
FPGA IDELAY. The MxFE adjusts its own sampling. Hence `tx_clk_adj_rcvd` /
`tx_clk_inv_rcvd`, which come back via `mdec`, plus `txclk_adj_mismatch` /
`txclk_inv_mismatch` as a loopback check.

BIST: `lfsr15_8.v` (x^15 + x^14 + 1, 8 bits/clock) for MOSI test mode; MISO test mode
does LFSR acquisition and BER counting in `mfrm_det`.

## Bring-up sequence

Derived from the RTL:

```
1. hsci_pll_reset = 1 -> 0        (0x8012, active high toward the wizard)
2. poll hsci_pll_locked           (0x8013)
3. poll hsci_rst_seq_done         (0x8013)   <- wizard done, miso_data ungated
4. hsci_master_rstn = 1           (0x8012)
5. hsci_auto_linkup = 1           (0x800A)
6. poll alink_fsm == 0xD (M_LINKUP) / link_active   (0x800C)
```

## Debugging

`alink_table` (0x800C) is the best diagnostic signal: 16 bits, one per clock phase.

| value | meaning |
|---|---|
| `0x0000` | no phase locks at all — wiring, termination, or VCCO |
| `0xFFFF` | every phase "works" — you're looking at noise or a stuck line |
| e.g. `0x03F0` | healthy, pick the middle |

There's also `miso_test_mode` plus the BER counter at `0x800F` for a pure PHY test
without the protocol layer.
