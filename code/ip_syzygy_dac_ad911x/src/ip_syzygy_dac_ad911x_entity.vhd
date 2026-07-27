-- Author: Adam Taylor
-- Description: AXI Stream controller and physical interface for the Opal Kelly SZG-DAC-AD911X module.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

LIBRARY xpm;
USE xpm.vcomponents.ALL;

USE work.syzygy_dac_ad911x_pkg.ALL;

ENTITY ip_syzygy_dac_ad911x IS
  GENERIC (
    g_clock_frequency_hz : INTEGER RANGE 1 TO 1000000000 := 125000000;
    g_spi_clk_divisor    : INTEGER RANGE 1 TO 1000000 := 4;
    g_reset_cycles       : INTEGER RANGE 1 TO 1000000 := 16;
    g_post_reset_cycles  : INTEGER RANGE 1 TO 1000000 := 256;
    g_initial_sample     : std_ulogic_vector(11 DOWNTO 0) := x"800";
    g_register_data      : std_ulogic_vector(255 DOWNTO 0) :=
    x"0A000000000000000000000000003F000000000000000080A00080A000344000";
    g_write_mask         : std_ulogic_vector(31 DOWNTO 0) := x"000001B4";
    g_verify_mask        : std_ulogic_vector(31 DOWNTO 0) := x"800001B4";
    g_simulation         : BOOLEAN := FALSE
  );
  PORT (
    i_axis_aclk        : IN  std_ulogic;
    i_axis_aresetn     : IN  std_ulogic;
    i_dac_clk_90       : IN  std_ulogic;
    i_s_axis_tdata     : IN  std_ulogic_vector(31 DOWNTO 0);
    i_s_axis_tvalid    : IN  std_ulogic;
    i_dac_sdio         : IN  std_ulogic;
    o_s_axis_tready    : OUT std_ulogic;
    o_dac_db           : OUT std_ulogic_vector(11 DOWNTO 0);
    o_dac_clkin        : OUT std_ulogic;
    o_dac_cs_n         : OUT std_ulogic;
    o_dac_sclk         : OUT std_ulogic;
    o_dac_sdio         : OUT std_ulogic;
    o_dac_sdio_t       : OUT std_ulogic;
    o_dac_reset_pinmd  : OUT std_ulogic;
    o_dac_opamp_enable : OUT std_ulogic;
    o_config_ok        : OUT std_ulogic;
    o_config_error     : OUT std_ulogic
  );
END ENTITY ip_syzygy_dac_ad911x;

ARCHITECTURE rtl OF ip_syzygy_dac_ad911x IS

  SIGNAL s_data_i           : std_ulogic_vector(11 DOWNTO 0);
  SIGNAL s_data_q           : std_ulogic_vector(11 DOWNTO 0);
  SIGNAL s_spi_start        : std_ulogic;
  SIGNAL s_spi_read         : std_ulogic;
  SIGNAL s_spi_address      : std_ulogic_vector(4 DOWNTO 0);
  SIGNAL s_spi_write_data   : std_ulogic_vector(7 DOWNTO 0);
  SIGNAL s_spi_read_data    : std_ulogic_vector(7 DOWNTO 0);
  SIGNAL s_spi_busy         : std_ulogic;
  SIGNAL s_spi_done         : std_ulogic;
  SIGNAL s_spi_sdio_i       : std_ulogic;
  SIGNAL s_spi_sdio_o       : std_ulogic;
  SIGNAL s_spi_sdio_oe      : std_ulogic;
  SIGNAL s_config_ok        : std_ulogic;
  SIGNAL s_config_error     : std_ulogic;
  SIGNAL s_data_reset       : std_ulogic;
  SIGNAL s_clock_reset_async : std_ulogic;
  SIGNAL s_clock_reset      : std_ulogic;

BEGIN

  ASSERT (g_clock_frequency_hz / (2 * g_spi_clk_divisor)) <= 25000000
    REPORT "Configured AD911x SCLK exceeds the 25 MHz device limit"
  SEVERITY FAILURE;

  o_s_axis_tready <= s_config_ok;
  o_config_ok <= s_config_ok;
  o_config_error <= s_config_error;
  s_data_reset <= NOT (i_axis_aresetn AND s_config_ok);
  s_clock_reset_async <= NOT i_axis_aresetn;

  -- Re-synchronize reset release to the 90-degree forwarded-clock domain.
  u_rst_sync : xpm_cdc_async_rst
    GENERIC MAP (
      DEST_SYNC_FF    => 4,
      INIT_SYNC_FF    => 0,
      RST_ACTIVE_HIGH => 1
    )
    PORT MAP (
      src_arst  => s_clock_reset_async,
      dest_clk  => i_dac_clk_90,
      dest_arst => s_clock_reset
  );

  s_spi_sdio_i <= i_dac_sdio;
  o_dac_sdio <= s_spi_sdio_o;
  o_dac_sdio_t <= NOT s_spi_sdio_oe;

  -- Capture one I/Q pair per accepted AXI Stream transfer and otherwise hold.
  p_axis_capture : PROCESS(i_axis_aclk, i_axis_aresetn)
  BEGIN
    IF i_axis_aresetn = '0' THEN
      s_data_i <= g_initial_sample;
      s_data_q <= g_initial_sample;
    ELSIF rising_edge(i_axis_aclk) THEN
      IF (i_s_axis_tvalid = '1') AND (s_config_ok = '1') THEN
        s_data_i <= i_s_axis_tdata(11 DOWNTO 0);
        s_data_q <= i_s_axis_tdata(27 DOWNTO 16);
      END IF;
    END IF;
  END PROCESS p_axis_capture;

  u_spi : ENTITY work.ad911x_spi_master
    GENERIC MAP (
      g_sclk_divisor => g_spi_clk_divisor
    )
    PORT MAP (
      i_clk        => i_axis_aclk,
      i_aresetn    => i_axis_aresetn,
      i_start      => s_spi_start,
      i_read       => s_spi_read,
      i_address    => s_spi_address,
      i_write_data => s_spi_write_data,
      i_sdio       => s_spi_sdio_i,
      o_read_data  => s_spi_read_data,
      o_busy       => s_spi_busy,
      o_done       => s_spi_done,
      o_sclk       => o_dac_sclk,
      o_cs_n       => o_dac_cs_n,
      o_sdio       => s_spi_sdio_o,
      o_sdio_oe    => s_spi_sdio_oe
  );

  u_config : ENTITY work.ad911x_config
    GENERIC MAP (
      g_reset_cycles      => g_reset_cycles,
      g_post_reset_cycles => g_post_reset_cycles,
      g_register_data     => g_register_data,
      g_write_mask        => g_write_mask,
      g_verify_mask       => g_verify_mask
    )
    PORT MAP (
      i_clk            => i_axis_aclk,
      i_aresetn        => i_axis_aresetn,
      i_spi_read_data  => s_spi_read_data,
      i_spi_busy       => s_spi_busy,
      i_spi_done       => s_spi_done,
      o_spi_start      => s_spi_start,
      o_spi_read       => s_spi_read,
      o_spi_address    => s_spi_address,
      o_spi_write_data => s_spi_write_data,
      o_dac_reset      => o_dac_reset_pinmd,
      o_config_ok      => s_config_ok,
      o_config_error   => s_config_error,
      o_opamp_enable   => o_dac_opamp_enable
  );

  u_phy : ENTITY work.ad911x_phy_7series
    GENERIC MAP (
      g_initial_sample => g_initial_sample,
      g_simulation     => g_simulation
    )
    PORT MAP (
      i_data_clk    => i_axis_aclk,
      i_dac_clk_90  => i_dac_clk_90,
      i_data_reset  => s_data_reset,
      i_clock_reset => s_clock_reset,
      i_data_i      => s_data_i,
      i_data_q      => s_data_q,
      o_dac_db      => o_dac_db,
      o_dac_clkin   => o_dac_clkin
  );

END ARCHITECTURE rtl;
