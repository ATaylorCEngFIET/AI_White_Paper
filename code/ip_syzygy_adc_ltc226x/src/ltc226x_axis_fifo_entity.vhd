-- Author: Adam Taylor
-- Description: Dual-clock AXI stream FIFO that drops new ADC samples while full.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

USE work.syzygy_adc_ltc226x_pkg.ALL;

ENTITY ltc226x_axis_fifo IS
  GENERIC (
    g_data_width : t_data_width_type := c_axis_width;
    g_fifo_depth : t_fifo_depth_type := 16
  );
  PORT (
    i_wr_clk     : IN  std_ulogic;
    i_wr_reset_n : IN  std_ulogic;
    i_wr_valid   : IN  std_ulogic;
    i_wr_data    : IN  std_ulogic_vector(g_data_width - 1 DOWNTO 0);
    i_rd_clk     : IN  std_ulogic;
    i_rd_reset_n : IN  std_ulogic;
    o_rd_valid   : OUT std_ulogic;
    i_rd_ready   : IN  std_ulogic;
    o_rd_data    : OUT std_ulogic_vector(g_data_width - 1 DOWNTO 0);
    o_overflow   : OUT std_ulogic
  );
END ENTITY ltc226x_axis_fifo;

ARCHITECTURE rtl OF ltc226x_axis_fifo IS

  CONSTANT c_addr_width : t_fifo_addr_type := clog2(g_fifo_depth);
  CONSTANT c_ptr_width  : INTEGER RANGE 2 TO c_fifo_addr_max + 1 := c_addr_width + 1;

  TYPE t_mem_type IS ARRAY (0 TO g_fifo_depth - 1) OF
    std_ulogic_vector(g_data_width - 1 DOWNTO 0);

  SIGNAL s_mem         : t_mem_type;
  SIGNAL s_wbin        : unsigned(c_ptr_width - 1 DOWNTO 0);
  SIGNAL s_wgray       : unsigned(c_ptr_width - 1 DOWNTO 0);
  SIGNAL s_rbin        : unsigned(c_ptr_width - 1 DOWNTO 0);
  SIGNAL s_rgray       : unsigned(c_ptr_width - 1 DOWNTO 0);
  SIGNAL s_rgray_w1    : unsigned(c_ptr_width - 1 DOWNTO 0);
  SIGNAL s_rgray_w2    : unsigned(c_ptr_width - 1 DOWNTO 0);
  SIGNAL s_wgray_r1    : unsigned(c_ptr_width - 1 DOWNTO 0);
  SIGNAL s_wgray_r2    : unsigned(c_ptr_width - 1 DOWNTO 0);
  SIGNAL s_full        : std_ulogic;
  SIGNAL s_empty       : std_ulogic;
  SIGNAL s_overflow    : std_ulogic;
  SIGNAL s_overflow_r1 : std_ulogic;
  SIGNAL s_overflow_r2 : std_ulogic;

  ATTRIBUTE async_reg : STRING;
  ATTRIBUTE async_reg OF s_rgray_w1, s_rgray_w2 : SIGNAL IS "TRUE";
  ATTRIBUTE async_reg OF s_wgray_r1, s_wgray_r2 : SIGNAL IS "TRUE";
  ATTRIBUTE async_reg OF s_overflow_r1, s_overflow_r2 : SIGNAL IS "TRUE";

  -- Form the Gray-code read pointer value that represents a full FIFO.
  FUNCTION full_target(i_gray : unsigned) RETURN unsigned IS
    VARIABLE v_result : unsigned(i_gray'RANGE);
  BEGIN
    v_result := i_gray;
    v_result(v_result'HIGH DOWNTO v_result'HIGH - 1) :=
    NOT i_gray(i_gray'HIGH DOWNTO i_gray'HIGH - 1);

    RETURN v_result;
  END FUNCTION full_target;

BEGIN

  ASSERT g_fifo_depth >= c_fifo_depth_min
  REPORT "g_fifo_depth must be at least four"
  SEVERITY FAILURE;

  ASSERT is_power_of_two(g_fifo_depth)
  REPORT "g_fifo_depth must be a power of two"
  SEVERITY FAILURE;

  s_full <= '0' WHEN i_wr_reset_n = '0' ELSE
    '1' WHEN s_wgray = full_target(s_rgray_w2) ELSE
  '0';
  s_empty <= '1' WHEN i_rd_reset_n = '0' ELSE
    '1' WHEN s_rgray = s_wgray_r2 ELSE
  '0';

  o_rd_valid <= NOT s_empty;
  o_rd_data <= s_mem(TO_INTEGER(s_rbin(c_addr_width - 1 DOWNTO 0))) WHEN s_empty = '0' ELSE
    (OTHERS => '0');
  o_overflow <= s_overflow_r2;

  -- Write valid samples into memory; memory contents do not require reset.
  p_memory : PROCESS (i_wr_clk)
  BEGIN
    IF RISING_EDGE(i_wr_clk) THEN
      IF i_wr_valid = '1' AND s_full = '0' THEN
        s_mem(TO_INTEGER(s_wbin(c_addr_width - 1 DOWNTO 0))) <= i_wr_data;
      END IF;
    END IF;
  END PROCESS p_memory;

  -- Advance the write pointer or record that a full FIFO discarded a sample.
  p_write : PROCESS (i_wr_clk, i_wr_reset_n)
  BEGIN
    IF i_wr_reset_n = '0' THEN
      s_wbin <= (OTHERS => '0');
      s_wgray <= (OTHERS => '0');
      s_overflow <= '0';
    ELSIF RISING_EDGE(i_wr_clk) THEN
      IF i_wr_valid = '1' AND s_full = '0' THEN
        s_wbin <= s_wbin + 1;
        s_wgray <= bin_to_gray(s_wbin + 1);
      ELSIF i_wr_valid = '1' THEN
        s_overflow <= '1';
      END IF;
    END IF;
  END PROCESS p_write;

  -- Advance the read pointer only after an AXI4-Stream transfer.
  p_read : PROCESS (i_rd_clk, i_rd_reset_n)
  BEGIN
    IF i_rd_reset_n = '0' THEN
      s_rbin <= (OTHERS => '0');
      s_rgray <= (OTHERS => '0');
    ELSIF RISING_EDGE(i_rd_clk) THEN
      IF s_empty = '0' AND i_rd_ready = '1' THEN
        s_rbin <= s_rbin + 1;
        s_rgray <= bin_to_gray(s_rbin + 1);
      END IF;
    END IF;
  END PROCESS p_read;

  -- Synchronise the Gray-coded read pointer into the ADC sample-clock domain.
  p_sync_read : PROCESS (i_wr_clk, i_wr_reset_n)
  BEGIN
    IF i_wr_reset_n = '0' THEN
      s_rgray_w1 <= (OTHERS => '0');
      s_rgray_w2 <= (OTHERS => '0');
    ELSIF RISING_EDGE(i_wr_clk) THEN
      s_rgray_w1 <= s_rgray;
      s_rgray_w2 <= s_rgray_w1;
    END IF;
  END PROCESS p_sync_read;

  -- Synchronise the write pointer and sticky overflow into the AXI domain.
  p_sync_write : PROCESS (i_rd_clk, i_rd_reset_n)
  BEGIN
    IF i_rd_reset_n = '0' THEN
      s_wgray_r1 <= (OTHERS => '0');
      s_wgray_r2 <= (OTHERS => '0');
      s_overflow_r1 <= '0';
      s_overflow_r2 <= '0';
    ELSIF RISING_EDGE(i_rd_clk) THEN
      s_wgray_r1 <= s_wgray;
      s_wgray_r2 <= s_wgray_r1;
      s_overflow_r1 <= s_overflow;
      s_overflow_r2 <= s_overflow_r1;
    END IF;
  END PROCESS p_sync_write;

END ARCHITECTURE rtl;
