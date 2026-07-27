# ip_syzygy_dac_ad911x

VHDL-2002 IP for the Opal Kelly SZG-DAC-AD911X module. The core accepts one
dual-channel AD9116 sample per AXI Stream transfer, configures the DAC over its
three-wire SPI port, verifies configuration by readback, and enables the module
output amplifiers only after successful initialization.

Author: Adam Taylor, Adiuvo Engineering.

Repository: [adiuvo-engineering/ip_syzygy_dac_ad911x](https://bitbucket.org/adiuvo-engineering/ip_syzygy_dac_ad911x)

## Interfaces

- `i_axis_aclk`: AXI Stream and DAC sample clock, up to 125 MHz.
- `i_dac_clk_90`: the same frequency as `i_axis_aclk`, shifted by +90 degrees.
- `i_s_axis_tdata(11 DOWNTO 0)`: DAC I sample.
- `i_s_axis_tdata(27 DOWNTO 16)`: DAC Q sample.
- `i_s_axis_tvalid` / `o_s_axis_tready`: AXI Stream handshake.
- `o_config_ok`: configuration and readback completed successfully.
- `o_config_error`: sticky SPI readback mismatch; cleared by reset.

The core accepts samples only while `o_config_ok` is high. When no transfer is
accepted, the most recently accepted I/Q pair remains at the DAC output.

## Clocking

Generate `i_axis_aclk` and `i_dac_clk_90` with the same MMCM or PLL. The +90°
phase moves the forwarded AD9116 sampling clock into the center of the DDR data
eye. Clock generation is intentionally outside this IP because legal MMCM
settings depend on the carrier input clock and selected sample rate.

Both clocks must be running and stable before `i_axis_aresetn` is released.
The default 125 MHz configuration therefore uses 0° and +90° 125 MHz outputs.

## Configuration generics

`g_register_data` is a flattened image of all 32 AD911x registers. Register N
occupies bits `(N * 8) + 7 DOWNTO (N * 8)`. `g_write_mask(N)` selects registers
written after hardware reset, and `g_verify_mask(N)` selects registers read and
compared with the image. This permits any writable configuration without an
AXI-Lite interface. Action or read-only bits should be omitted from the verify
mask when their read value is not equal to their written value.

The default sequence configures unsigned-binary data with I on the rising edge,
uses the internal I/Q RSET and 60-ohm RCML resistors, and verifies those values
plus the version register at address `0x1F`.

Other important generics are:

- `g_spi_clk_divisor`: SCLK half-period in `i_axis_aclk` cycles. The default of
  four gives 15.625 MHz SCLK with a 125 MHz sample clock.
- `g_clock_frequency_hz`: AXIS/sample-clock frequency used to validate that
  the selected SPI divisor does not exceed the AD9116 25 MHz SCLK limit.
- `g_reset_cycles`: duration of the active-high AD911x reset pulse.
- `g_post_reset_cycles`: clock cycles allowed for the AD911x retimer to settle.
- `g_initial_sample`: sample driven before configuration succeeds.
- `g_simulation`: selects the vendor-independent behavioral DDR model for the
  supplied test bench; leave false for synthesis.

## Physical integration

The PHY targets Xilinx 7-series devices and confines `ODDR` primitives to
`ad911x_phy_7series`. Apply carrier-specific package pins and a matching
`IOSTANDARD` to the SYZYGY signals. The Opal Kelly module supports VIO from
1.8 V to 3.3 V; the supplied timing XDC contains the 1.8 V AD9116 limits and
must be adjusted if a different VIO is selected.

The bidirectional SDIO pin is exposed as `i_dac_sdio`, `o_dac_sdio`, and
active-high tristate control `o_dac_sdio_t`. Connect these through a 7-series
`IOBUF` at the carrier top level. Keeping the buffer at the FPGA boundary
preserves correct bidirectional behavior when this IP is used in a block design.

## Verification and packaging

Run the self-checking Questa test from PowerShell:

```powershell
.\scripts\run_sim.ps1
```

The test covers startup writes, successful readback, the AXI I/Q mapping,
hold-last behavior, op-amp control, and the error response to corrupt readback.

Run the controlled Adiuvo Blue Pearl VHDL-2000 review:

```powershell
.\scripts\run_bluepearl.ps1
```

The batch flow applies the ruleset in
`C:\hdl_projects\00_AI_Instructions\bluepearl\bps_setup.tcl`, writes a
SARIF report under `build/bluepearl`, and fails if Blue Pearl reports an RTL
error. The flow loads AMD's `xpm_VCOMP.vhd` and `xpm_cdc.sv` into Blue Pearl's
`xpm` library so the production `xpm_cdc_async_rst` reset synchronizer is
analyzed. The `test/oddr_entity.vhd` model is used only to bind the Xilinx
ODDR primitive during static analysis.

Run the 7-series out-of-context synthesis check and regenerate IP-XACT metadata:

```powershell
vivado -mode batch -nojournal -nolog -source scripts/check_vivado.tcl -tclargs $PWD
vivado -mode batch -nojournal -nolog -source scripts/package_ip.tcl -tclargs $PWD
vivado -mode batch -nojournal -nolog -source scripts/check_ip_catalog.tcl -tclargs $PWD
```

## Hardware validation

The core has been validated on an Opal Kelly XEM7320-A75T with the
SZG-DAC-AD911X installed in SYZYGY Port A. The hardware test confirmed:

- Successful AD9116 SPI configuration and selected-register readback.
- Output-amplifier enable after `o_config_ok` asserted.
- 125 MHz forwarded-clock operation and DDR I/Q sample delivery.
- A measured waveform at the module SMA output using a 500 kHz sine test.

The module's J2 and J4 SMA outputs are transformer-coupled by default and are
therefore AC-coupled. A constant code, a low-frequency signal, or a short
finite buffer can appear as a transient followed by decay. Use an appropriate
AC waveform for bring-up, or apply the module vendor's documented resistor
changes when the buffered output stage is required.

## References

- [Opal Kelly SZG-DAC-AD911X documentation](https://docs.opalkelly.com/syzygy-peripherals/szg-dac-ad911x/)
- [Analog Devices AD9114/AD9115/AD9116/AD9117 data sheet](https://www.analog.com/media/en/technical-documentation/data-sheets/ad9114_9115_9116_9117.pdf)
- [Controlled Confluence documentation](https://adiuvo-engineering.atlassian.net/wiki/spaces/AE/pages/523075585/IP_SYZYGY_DAC)
