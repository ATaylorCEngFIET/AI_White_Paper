# SYZYGY ADC LTC226x AXI4-Stream IP

Dual-channel receive IP for the Opal Kelly SZG-ADC-LTC2264-12 and
SZG-ADC-LTC2268-14 peripherals on the XEM7320 Artix-7 platform.

The IP receives the ADC's source-synchronous LVDS interface, reconstructs one
sample from each channel on every conversion, and emits the pair on a 32-bit
AXI4-Stream master interface. The packaged default is the LTC2264-12 at
40 MSPS; set `g_adc_width` to 14 for the LTC2268-14.

## Main features

- VHDL-2002 synthesizable RTL and VHDL-2008 self-checking test benches.
- Xilinx 7-series `ISERDESE2` interface for the XEM7320 XC7A75T-1.
- Common two-lane, 16-bit ADC serialization mode for both pod variants.
- Automatic frame alignment using the ADC `FR` stream.
- 32-bit AXI4-Stream output with one simultaneous channel pair per transfer.
- Dual-clock elastic FIFO with a configurable power-of-two depth.
- Incoming samples are dropped when the FIFO is full; `o_overflow` is sticky.
- Generated differential ADC encode output from the supplied low-jitter
  `i_enc_clk`.
- Automatic SPI reset/configuration and A1/A2 readback verification.
- Diagnostic SPI error address, expected value and received value outputs.

Full integration and configuration information is in
[docs/confluence_page.md](docs/confluence_page.md).

## AXI4-Stream word format

| Bits | Contents |
| --- | --- |
| 31:16 | Channel 2, zero-extended to 16 bits |
| 15:0 | Channel 1, zero-extended to 16 bits |

Samples retain the ADC-selected offset-binary format by default. Set
`g_twos_complement` to `TRUE` to configure both ADC channels for two's
complement output.

## Clocks

- `i_enc_clk`: low-jitter conversion clock, 40 MHz for the LTC2264-12.
- ADC `DCO`: received by the IP and divided by four to form the sample domain.
- `i_axis_clk`: user AXI4-Stream and SPI controller clock.

The asynchronous FIFO safely crosses from the recovered sample domain into
`i_axis_clk`. The ADC cannot be paused by AXI backpressure.

Both the recovered sample-domain reset and AXI-domain reset assert
asynchronously and release through two flip-flops in their destination clock
domain.

## Questa regression

From the repository root:

```text
vsim -c -do scripts/run.do
```

For a location-independent invocation, run `scripts/run_questa.ps1` from any
working directory. The scripts create the simulation library under `sim`,
compile RTL as VHDL-2002, compile tests as VHDL-2008, and run FIFO, SPI,
12-bit and 14-bit core tests.

## Blue Pearl lint and CDC

Run the Adiuvo Blue Pearl ruleset with:

```powershell
.\scripts\run_bluepearl.ps1 `
  -InstructionsRoot C:\hdl_projects\00_AI_Instructions
```

Results are written to `bluepearl.results/`, including `results.sarif`. The
launcher clears the generated database before each run so the SARIF cannot
retain stale findings.

For the authoritative FIFO clock-domain-crossing analysis, run the portable
core as the Blue Pearl root:

```powershell
.\scripts\run_bluepearl.ps1 `
  -InstructionsRoot C:\hdl_projects\00_AI_Instructions `
  -CoreCdc
```

That report is written to `bluepearl.core.results/`. The full top-level run
enables Blue Pearl's AMD/Xilinx 2025.2 library and loads the vendor `glbl.v`
from the Vivado installation found on `PATH`. The analysis-only
`lint/syzygy_adc_ltc226x_bps.v` harness places `glbl` beside the real VHDL IP
so BPS can elaborate the vendor primitives without black boxes. The harness is
not included in Questa compilation, Vivado synthesis, or the packaged IP.

## Vivado synthesis check

```text
vivado -mode batch -nojournal -nolog -source scripts/synth_check.tcl
```

The check targets `xc7a75tfgg484-1`, the standard XEM7320-A75 device.

To produce a Vivado IP repository entry:

```text
vivado -mode batch -nojournal -nolog -source scripts/package_ip.tcl
```

The packaged component is written below `packaged_ip/`. Add that directory as
an IP repository in Vivado. The generated AXI4-Stream interface is named
`o_m_axis`; its clock and active-low reset are `i_axis_clk` and
`i_axis_reset_n`.

## Important SDO hardware note

SPI readback depends on the pod revision. Rev DXX has an incompatible SDO level
translator. On Rev EXX, resistor R36 must be fitted and VIO must be between
1.8 V and 3.3 V. On hardware without a working SDO path, configuration writes
still occur but `o_spi_error` will correctly report failed readback.

## XEM7320 FPGA FFT spectrum project

A Vivado 2025.2 IP Integrator system is included under `fpga/`. It combines
this ADC IP with the Opal Kelly FrontPanel Subsystem and an AMD 4096-point
streaming FFT, exposes raw and complex FFT data through FrontPanel block pipes,
and includes a packaged FrontPanel Platform waveform, spectrum, and colour
waterfall application. The completed outputs are:

- Vivado project: `build/spectrum_analyzer/project/ltc226x_spectrum.xpr`
- FPGA image: `build/spectrum_analyzer/output/ltc226x_spectrum.bit`
- FrontPanel app: `frontpanel_app/output/ltc226x-spectrum.fpp`

See [fpga/README.md](fpga/README.md) for the hardware design and endpoint map,
and [frontpanel_app/README.md](frontpanel_app/README.md) for the application.
