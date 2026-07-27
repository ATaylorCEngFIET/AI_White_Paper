-- Author: Adam Taylor
-- Description: Aligns, reconstructs, buffers and streams both LTC226x ADC channels.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

USE work.syzygy_adc_ltc226x_pkg.ALL;

ENTITY syzygy_adc_ltc226x_core IS
  GENERIC (
    g_adc_width       : t_adc_width_type := 12;
    g_fifo_depth      : t_fifo_depth_type := 16;
    g_lock_cycles     : t_lock_cycles_type := 4;
    g_spi_clk_div     : t_spi_div_type := 4;
    g_spi_start_delay : t_spi_delay_type := 1024;
    g_twos_complement : BOOLEAN := FALSE
  );
  PORT (
    i_sample_clk     : IN  std_ulogic;
    i_sample_reset_n : IN  std_ulogic;
    i_frame_word     : IN  t_lane_word_type;
    i_ch1a_word      : IN  t_lane_word_type;
    i_ch1b_word      : IN  t_lane_word_type;
    i_ch2a_word      : IN  t_lane_word_type;
    i_ch2b_word      : IN  t_lane_word_type;
    i_axis_clk       : IN  std_ulogic;
    i_axis_reset_n   : IN  std_ulogic;
    o_axis_tdata     : OUT t_axis_word_type;
    o_axis_tvalid    : OUT std_ulogic;
    i_axis_tready    : IN  std_ulogic;
    i_adc_sdo        : IN  std_ulogic;
    o_adc_sdi        : OUT std_ulogic;
    o_adc_sclk       : OUT std_ulogic;
    o_adc_cs_n       : OUT std_ulogic;
    o_capture_locked : OUT std_ulogic;
    o_spi_done       : OUT std_ulogic;
    o_spi_error      : OUT std_ulogic;
    o_spi_error_addr : OUT t_spi_addr_type;
    o_spi_expected   : OUT t_byte_type;
    o_spi_received   : OUT t_byte_type;
    o_overflow       : OUT std_ulogic
  );
END ENTITY syzygy_adc_ltc226x_core;

ARCHITECTURE rtl OF syzygy_adc_ltc226x_core IS

  SIGNAL s_ch1a_align   : t_lane_word_type;
  SIGNAL s_ch1b_align   : t_lane_word_type;
  SIGNAL s_ch2a_align   : t_lane_word_type;
  SIGNAL s_ch2b_align   : t_lane_word_type;
  SIGNAL s_ch1_full     : t_adc_word_type;
  SIGNAL s_ch2_full     : t_adc_word_type;
  SIGNAL s_ch1_data     : t_adc_word_type;
  SIGNAL s_ch2_data     : t_adc_word_type;
  SIGNAL s_sample_valid : std_ulogic;
  SIGNAL s_fifo_data    : t_axis_word_type;

  -- Zero-extend the selected converter resolution into a 16-bit AXI field.
  FUNCTION adc_word(
      i_data  : t_adc_word_type;
      i_width : t_adc_width_type
    ) RETURN t_adc_word_type IS
    VARIABLE v_result : t_adc_word_type;
  BEGIN
    v_result := (OTHERS => '0');
    v_result(i_width - 1 DOWNTO 0) := i_data(c_adc_word_width - 1 DOWNTO c_adc_word_width - i_width);

    RETURN v_result;
  END FUNCTION adc_word;

BEGIN

  ASSERT g_adc_width = 12 OR g_adc_width = 14
  REPORT "g_adc_width must be 12 or 14"
  SEVERITY FAILURE;

  u_align : ENTITY work.ltc226x_frame_align(rtl)
    GENERIC MAP (
      g_lock_cycles => g_lock_cycles
    )
    PORT MAP (
      i_clk            => i_sample_clk,
      i_reset_n        => i_sample_reset_n,
      i_frame_word     => i_frame_word,
      i_ch1a_word      => i_ch1a_word,
      i_ch1b_word      => i_ch1b_word,
      i_ch2a_word      => i_ch2a_word,
      i_ch2b_word      => i_ch2b_word,
      o_ch1a_word      => s_ch1a_align,
      o_ch1b_word      => s_ch1b_align,
      o_ch2a_word      => s_ch2a_align,
      o_ch2b_word      => s_ch2b_align,
      o_sample_valid   => s_sample_valid,
      o_capture_locked => o_capture_locked
  );

  -- Interleave lane A odd bits and lane B even bits as defined by LTC226x.
  gen_unpack : FOR index IN 0 TO c_lane_width - 1 GENERATE
    s_ch1_full((2 * index) + 1) <= s_ch1a_align((c_lane_width - 1) - index);
    s_ch1_full(2 * index) <= s_ch1b_align((c_lane_width - 1) - index);
    s_ch2_full((2 * index) + 1) <= s_ch2a_align((c_lane_width - 1) - index);
    s_ch2_full(2 * index) <= s_ch2b_align((c_lane_width - 1) - index);
  END GENERATE gen_unpack;

  s_ch1_data <= adc_word(s_ch1_full, g_adc_width);
  s_ch2_data <= adc_word(s_ch2_full, g_adc_width);

  s_fifo_data <= s_ch2_data & s_ch1_data;

  u_fifo : ENTITY work.ltc226x_axis_fifo(rtl)
    GENERIC MAP (
      g_data_width => c_axis_width,
      g_fifo_depth => g_fifo_depth
    )
    PORT MAP (
      i_wr_clk     => i_sample_clk,
      i_wr_reset_n => i_sample_reset_n,
      i_wr_valid   => s_sample_valid,
      i_wr_data    => s_fifo_data,
      i_rd_clk     => i_axis_clk,
      i_rd_reset_n => i_axis_reset_n,
      o_rd_valid   => o_axis_tvalid,
      i_rd_ready   => i_axis_tready,
      o_rd_data    => o_axis_tdata,
      o_overflow   => o_overflow
  );

  u_spi : ENTITY work.ltc226x_spi_ctrl(rtl)
    GENERIC MAP (
      g_clk_div         => g_spi_clk_div,
      g_start_delay     => g_spi_start_delay,
      g_twos_complement => g_twos_complement
    )
    PORT MAP (
      i_clk        => i_axis_clk,
      i_reset_n    => i_axis_reset_n,
      i_sdo        => i_adc_sdo,
      o_sdi        => o_adc_sdi,
      o_sclk       => o_adc_sclk,
      o_cs_n       => o_adc_cs_n,
      o_done       => o_spi_done,
      o_error      => o_spi_error,
      o_error_addr => o_spi_error_addr,
      o_expected   => o_spi_expected,
      o_received   => o_spi_received
  );

END ARCHITECTURE rtl;
