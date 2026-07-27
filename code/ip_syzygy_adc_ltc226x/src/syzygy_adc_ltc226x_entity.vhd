-- Author: Adam Taylor
-- Description: Artix-7 top level for the LTC2264-12 and LTC2268-14 SYZYGY pods.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

USE work.syzygy_adc_ltc226x_pkg.ALL;

ENTITY syzygy_adc_ltc226x IS
  GENERIC (
    g_adc_width       : t_adc_width_type := 12;
    g_fifo_depth      : t_fifo_depth_type := 16;
    g_lock_cycles     : t_lock_cycles_type := 4;
    g_spi_clk_div     : t_spi_div_type := 4;
    g_spi_start_delay : t_spi_delay_type := 1024;
    g_twos_complement : BOOLEAN := FALSE
  );
  PORT (
    i_reset_n        : IN  std_ulogic;
    i_axis_clk       : IN  std_ulogic;
    i_axis_reset_n   : IN  std_ulogic;
    i_enc_clk        : IN  std_ulogic;
    i_adc_dco_p      : IN  std_ulogic;
    i_adc_dco_n      : IN  std_ulogic;
    i_adc_fr_p       : IN  std_ulogic;
    i_adc_fr_n       : IN  std_ulogic;
    i_adc_ch1a_p     : IN  std_ulogic;
    i_adc_ch1a_n     : IN  std_ulogic;
    i_adc_ch1b_p     : IN  std_ulogic;
    i_adc_ch1b_n     : IN  std_ulogic;
    i_adc_ch2a_p     : IN  std_ulogic;
    i_adc_ch2a_n     : IN  std_ulogic;
    i_adc_ch2b_p     : IN  std_ulogic;
    i_adc_ch2b_n     : IN  std_ulogic;
    o_adc_enc_p      : OUT std_ulogic;
    o_adc_enc_n      : OUT std_ulogic;
    i_adc_sdo        : IN  std_ulogic;
    o_adc_sdi        : OUT std_ulogic;
    o_adc_sclk       : OUT std_ulogic;
    o_adc_cs_n       : OUT std_ulogic;
    o_m_axis_tdata   : OUT std_ulogic_vector(c_axis_width - 1 DOWNTO 0);
    o_m_axis_tvalid  : OUT std_ulogic;
    i_m_axis_tready  : IN  std_ulogic;
    o_capture_locked : OUT std_ulogic;
    o_spi_done       : OUT std_ulogic;
    o_spi_error      : OUT std_ulogic;
    o_spi_error_addr : OUT std_ulogic_vector(c_spi_addr_width - 1 DOWNTO 0);
    o_spi_expected   : OUT std_ulogic_vector(c_lane_width - 1 DOWNTO 0);
    o_spi_received   : OUT std_ulogic_vector(c_lane_width - 1 DOWNTO 0);
    o_overflow       : OUT std_ulogic
  );
END ENTITY syzygy_adc_ltc226x;

ARCHITECTURE struct OF syzygy_adc_ltc226x IS

  SIGNAL s_reset          : std_ulogic;
  SIGNAL s_sample_clk     : std_ulogic;
  SIGNAL s_sample_reset_n : std_ulogic;
  SIGNAL s_axis_reset_n   : std_ulogic;
  SIGNAL s_frame_word     : t_lane_word_type;
  SIGNAL s_ch1a_word      : t_lane_word_type;
  SIGNAL s_ch1b_word      : t_lane_word_type;
  SIGNAL s_ch2a_word      : t_lane_word_type;
  SIGNAL s_ch2b_word      : t_lane_word_type;

BEGIN

  s_reset <= NOT i_reset_n;

  u_io : ENTITY work.ltc226x_7series_io(struct)
    PORT MAP (
      i_reset      => s_reset,
      i_enc_clk    => i_enc_clk,
      i_adc_dco_p  => i_adc_dco_p,
      i_adc_dco_n  => i_adc_dco_n,
      i_adc_fr_p   => i_adc_fr_p,
      i_adc_fr_n   => i_adc_fr_n,
      i_adc_ch1a_p => i_adc_ch1a_p,
      i_adc_ch1a_n => i_adc_ch1a_n,
      i_adc_ch1b_p => i_adc_ch1b_p,
      i_adc_ch1b_n => i_adc_ch1b_n,
      i_adc_ch2a_p => i_adc_ch2a_p,
      i_adc_ch2a_n => i_adc_ch2a_n,
      i_adc_ch2b_p => i_adc_ch2b_p,
      i_adc_ch2b_n => i_adc_ch2b_n,
      o_adc_enc_p  => o_adc_enc_p,
      o_adc_enc_n  => o_adc_enc_n,
      o_sample_clk => s_sample_clk,
      o_frame_word => s_frame_word,
      o_ch1a_word  => s_ch1a_word,
      o_ch1b_word  => s_ch1b_word,
      o_ch2a_word  => s_ch2a_word,
      o_ch2b_word  => s_ch2b_word
  );

  u_rst_adc : ENTITY work.ltc226x_reset_sync(rtl)
    PORT MAP (
      i_clk           => s_sample_clk,
      i_async_reset_n => i_reset_n,
      o_reset_n       => s_sample_reset_n
  );

  u_rst_axis : ENTITY work.ltc226x_reset_sync(rtl)
    PORT MAP (
      i_clk           => i_axis_clk,
      i_async_reset_n => i_axis_reset_n,
      o_reset_n       => s_axis_reset_n
  );

  u_core : ENTITY work.syzygy_adc_ltc226x_core(rtl)
    GENERIC MAP (
      g_adc_width       => g_adc_width,
      g_fifo_depth      => g_fifo_depth,
      g_lock_cycles     => g_lock_cycles,
      g_spi_clk_div     => g_spi_clk_div,
      g_spi_start_delay => g_spi_start_delay,
      g_twos_complement => g_twos_complement
    )
    PORT MAP (
      i_sample_clk     => s_sample_clk,
      i_sample_reset_n => s_sample_reset_n,
      i_frame_word     => s_frame_word,
      i_ch1a_word      => s_ch1a_word,
      i_ch1b_word      => s_ch1b_word,
      i_ch2a_word      => s_ch2a_word,
      i_ch2b_word      => s_ch2b_word,
      i_axis_clk       => i_axis_clk,
      i_axis_reset_n   => s_axis_reset_n,
      o_axis_tdata     => o_m_axis_tdata,
      o_axis_tvalid    => o_m_axis_tvalid,
      i_axis_tready    => i_m_axis_tready,
      i_adc_sdo        => i_adc_sdo,
      o_adc_sdi        => o_adc_sdi,
      o_adc_sclk       => o_adc_sclk,
      o_adc_cs_n       => o_adc_cs_n,
      o_capture_locked => o_capture_locked,
      o_spi_done       => o_spi_done,
      o_spi_error      => o_spi_error,
      o_spi_error_addr => o_spi_error_addr,
      o_spi_expected   => o_spi_expected,
      o_spi_received   => o_spi_received,
      o_overflow       => o_overflow
  );

END ARCHITECTURE struct;
