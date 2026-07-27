# ip_syzygy_dac_ad911x_ultrascale

Vivado 2025.2 VHDL IP for the Opal Kelly SZG-DAC-AD911X module on Xilinx
UltraScale and UltraScale+ devices. The core accepts a dual-channel AD9116
sample over AXI Stream, configures and verifies the DAC through three-wire SPI,
and enables the module output amplifiers only after successful initialization.

This repository is the UltraScale+ counterpart of
`adiuvo-engineering/ip_syzygy_dac_ad911x`. The control path and external
interface remain compatible; the device-specific PHY is rewritten around the
UltraScale `ODDRE1` primitive. Keeping a distinct IP VLNV prevents Vivado from
using the 7-series `ODDR` implementation on an UltraScale+ target.

## Interfaces

- `i_axis_aclk`: AXI Stream and DAC data clock, normally 125 MHz.
- `i_dac_clk_90`: same frequency, shifted by +90 degrees.
- `i_s_axis_tdata(11 DOWNTO 0)`: DAC I sample.
- `i_s_axis_tdata(27 DOWNTO 16)`: DAC Q sample.
- `i_s_axis_tvalid` / `o_s_axis_tready`: sample handshake.
- `o_config_ok`: initialization and readback succeeded.
- `o_config_error`: sticky readback mismatch, cleared by reset.

The PHY emits I on the rising data-clock edge and Q on the falling edge. The
forwarded clock uses the +90-degree input so its edges are centered in the
AD9116 DDR data eye. The most recently accepted sample is held when AXI Stream
is idle.

## Packaging and verification

The checked target is the XEM8320 AU25P (`xcau25p-ffvb676-2-e`). Generated
projects and logs are excluded from source control.

```powershell
vivado -mode batch -source scripts/check_vivado.tcl -tclargs $PWD
vivado -mode batch -source scripts/package_ip.tcl -tclargs $PWD
vivado -mode batch -source scripts/check_ip_catalog.tcl -tclargs $PWD
```

The packaged VLNV is:

```text
adiuvoengineering.com:user:ip_syzygy_dac_ad911x_ultrascale:1.0
```

Run the vendor-independent functional test with Questa:

```powershell
.\scripts\run_sim.ps1
```

The test covers DAC startup writes and readback, AXI I/Q mapping, hold-last
behavior, op-amp enable, and error response to corrupt readback.

### Blue Pearl / Adiuvo verification

Blue Pearl VVS 2026.4 with Adiuvo VHDL rules 1.6 reports 0 errors, 100 warnings,
and 94 informationals. The pre-correction baseline was 2 errors, 158 warnings,
and 90 informationals. The remaining warnings are reviewed interface,
reset-style, formatting, and vendor-library heuristics; correcting them would
either change the SPI/AXI timing contract or alter vendor primitive declarations.

The corrected RTL also passes the self-checking Questa test and Vivado 2025.2
IP-catalog out-of-context synthesis for `xcau25p-ffvb676-2-e`.

## Integration notes

Carrier-level constraints must assign the SYZYGY package pins and I/O voltage.
For the XEM8320 Port A design, use 1.8 V SmartVIO and `LVCMOS18`. Both clocks
must be running and stable before releasing `i_axis_aresetn`.

`o_dac_clkin` is a forwarded clock and intentionally remains a scalar port; its
timing relationship to the parent clock and physical output delays belong in
the carrier XDC.

The module SMA outputs are transformer-coupled in their default assembly and
therefore do not pass DC.
