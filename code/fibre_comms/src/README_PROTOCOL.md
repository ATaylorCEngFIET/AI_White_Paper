# Clock-Forwarded LVDS Fibre Protocol

This document describes the protocol implemented by:

- `lvds_tx_entity.vhd`
- `lvds_rx_entity.vhd`
- `lvds_8b10b_pkg.vhd`

It is the implementation reference for the two-fibre link. The current wire
format carries one 16-bit word per data frame.

## 1. Link overview

The link uses two LVDS differential paths:

1. A serial-data path.
2. A continuously forwarded clock path.

At the default settings, the transmitter runs from 200 MHz and sends one data
bit per clock cycle, giving a 200 Mbit/s serial line rate. The forwarded clock
is generated from the same TX clock and accompanies the serial data.

The data output changes on the falling edge of the forwarded clock. The
receiver samples on the rising or falling edge selected during link training.
An IDELAYE2 sweep then centres the chosen sample point within the received
data eye.

The electrical interface is `LVDS_25`. The clock and data paths may use
separate fibres or optical channels, provided their relative skew remains
within the receiver's supported training range.

## 2. Bit and byte ordering

All 10-bit 8b/10b symbols are serialized bit 0 first.

A 16-bit payload is transmitted low byte first:

1. `data(7 downto 0)`
2. `data(15 downto 8)`

The first serial bit of a frame is therefore bit 0 of the encoded K28.5
header. The first payload bit is bit 0 of the encoded low-byte symbol.

## 3. 8b/10b encoding

Normal traffic uses 8b/10b encoding with continuous running-disparity
tracking. The implemented control symbols are:

| Symbol | 8-bit value | Purpose |
| --- | ---: | --- |
| K28.5 | `0xBC` | Comma, idle symbol and data-frame header |
| K28.1 | `0x3C` | In-band `TRAIN_START` marker |

Payload bytes are always encoded as data symbols, even when their values are
`0xBC` or `0x3C`. Consequently, payload values cannot be confused with K28.5
or K28.1 control symbols and do not require escaping.

Running disparity is carried continuously through idle symbols and data
frames. After a raw training preamble, the transmitter restarts normal
traffic with negative running disparity.

The alternating raw training pattern is not 8b/10b encoded.

## 4. Normal traffic

### 4.1 Idle

When no payload is waiting, the transmitter repeatedly sends K28.5 control
symbols. Each idle symbol occupies 10 serial bit times.

### 4.2 Data frame

Each 16-bit data frame contains three 10-bit symbols:

| Serial-bit positions | Symbol | Encoding |
| ---: | --- | --- |
| 0 to 9 | Header | K28.5 control symbol |
| 10 to 19 | Low payload byte | 8b/10b data symbol |
| 20 to 29 | High payload byte | 8b/10b data symbol |

The on-wire sequence is:

```text
K28.5  D(data[7:0])  D(data[15:8])
```

At 200 Mbit/s, a frame occupies 150 ns. Consecutive data frames may be sent
without an intervening idle symbol because every frame begins with K28.5.
The maximum theoretical payload rate is approximately 6.67 million 16-bit
words per second.

The TX accepts a word on a rising `i_clk_200` edge when both
`i_data_valid = '1'` and `o_data_ready = '1'`. `o_data_ready` is deasserted
during training and while the internal frame buffer is occupied.

There is no link-level acknowledgement, retry or receiver-to-transmitter flow
control.

## 5. Startup and link training

After reset, and at the start of each periodic retraining operation, the
transmitter sends:

1. Four K28.1 `TRAIN_START` symbols.
2. `g_train_bits` alternating raw bits: `0, 1, 0, 1, ...`.
3. Normal 8b/10b traffic, beginning with negative running disparity.

The default `g_train_bits` value is 131072 bits. At 200 Mbit/s, the raw
training preamble lasts 655.36 us.

At startup the receiver begins its training sweep after IDELAYCTRL reports
ready. During the raw alternating preamble it:

1. Sweeps all 32 IDELAYE2 taps using rising-edge sampling.
2. Sweeps all 32 taps using falling-edge sampling.
3. Tests each candidate against repeating `0x55` or `0xAA` bit windows for
   `g_sample_window` recovered-clock cycles.
4. Finds the widest contiguous passing window.
5. Selects its centre tap and sampling edge.
6. Asserts `o_eye_locked`.
7. Hunts the serial stream for K28.5 and then asserts `o_sync_locked`.

`i_ref_clk_200` must be a stable, free-running 200 MHz reference for
IDELAYCTRL. It must remain active if the received clock disappears.

## 6. Periodic retraining

The transmitter starts periodic retraining after `g_retrain_ms`. The default
interval is 10000 ms.

Retraining begins only after the current serialized symbol or frame has
finished. The four K28.1 markers are therefore sent at a symbol boundary.
An aligned receiver recognizes K28.1 in every frame state, drops frame and eye
lock, and restarts the complete sampling-edge and IDELAY tap sweep.

The RX generics `g_clk_freq_hz` and `g_retrain_ms` are retained for block
design compatibility but are not used to time retraining. The in-band K28.1
marker is the authoritative trigger.

Payload transmission is paused while `o_training = '1'`. Any upstream word
held with `i_data_valid = '1'` remains subject to the normal ready/valid rule
and is accepted after training when `o_data_ready` returns high.

## 7. Receiver framing and error recovery

After eye training, the receiver uses a sliding 10-bit window to find K28.5.
Once aligned, it expects:

1. A data symbol for the low byte.
2. A data symbol for the high byte.
3. K28.5 at the next frame or idle boundary.

The receiver checks symbol validity, control/data type and running disparity.
An invalid symbol, illegal disparity, unexpected control symbol or missing
K28.5 causes `o_sync_locked` to drop and the receiver to return to comma
hunting.

A normal framing error triggers re-alignment, not a complete IDELAY sweep.
Only reset, loss of eye lock or an in-band K28.1 marker starts full eye
retraining.

The protocol has no CRC, sequence number or retransmission mechanism. 8b/10b
detects many line errors, but a corruption that produces another legal symbol
with legal disparity may not be detected by this protocol.

## 8. Receiver output and clock-domain crossing

Completed words cross from the recovered forwarded-clock domain to
`i_clk_200` through a toggle-based clock-domain crossing.

- `o_data` contains the reconstructed 16-bit word.
- `o_data_valid` pulses for one `i_clk_200` cycle for each received word.
- `o_eye_locked` and `o_sync_locked` are synchronized into the `i_clk_200`
  domain.

The receiver has no output-ready input and does not provide backpressure over
the fibre. Downstream logic must be able to accept every `o_data_valid` pulse
or must add a FIFO.

## 9. Configuration parameters

| Block | Generic | Default | Meaning |
| --- | --- | ---: | --- |
| TX | `g_data_width` | 16 | Parallel interface width; current frame format requires 16 |
| TX | `g_train_bits` | 131072 | Number of alternating raw training bits |
| TX | `g_clk_freq_hz` | 200000000 | TX and serial clock frequency |
| TX | `g_retrain_ms` | 10000 | Periodic retraining interval |
| RX | `g_data_width` | 16 | Parallel output width; current frame format requires 16 |
| RX | `g_sample_window` | 256 | Samples evaluated at each tap and edge |
| RX | `g_clk_freq_hz` | 200000000 | Compatibility generic; unused by RX datapath |
| RX | `g_retrain_ms` | 10000 | Compatibility generic; retraining uses K28.1 |

Although `g_data_width` is exposed as a generic, the implemented serializer
and frame receiver explicitly encode two bytes. Both ends must therefore use
`g_data_width = 16` unless the frame logic is extended.

## 10. Reset and lock sequence

The expected receiver status progression is:

```text
reset
  -> IDELAYCTRL ready
  -> raw-preamble eye sweep
  -> o_eye_locked = 1
  -> K28.5 comma acquisition
  -> o_sync_locked = 1
  -> payload delivery
```

During periodic retraining, both lock indications drop and then reacquire in
the same order.

## 11. Verified behavior

The Questa testbenches in `../test` cover:

- Startup training with deliberately skewed data and clock paths.
- K28.5 acquisition and continuous idle traffic.
- Payload values that equal control-code byte values.
- All 256 possible data-byte values.
- Periodic K28.1 retraining and post-training recovery.
- Accepted-to-received link latency below 1 us.
- Source-to-DAC end-to-end latency below 1 us.

With Questa 2025.3 and the Vivado 2025.2 UNISIM models, the measured fibre-link
latency was 161 to 193 ns. The complete source-to-DAC path measured 663 to
699 ns across 158 verified writes.

