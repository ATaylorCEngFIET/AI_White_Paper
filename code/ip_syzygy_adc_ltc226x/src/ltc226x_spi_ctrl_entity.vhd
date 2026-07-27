-- Author: Adam Taylor
-- Description: Configures the LTC226x over SPI and verifies A1/A2 by readback.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

USE work.syzygy_adc_ltc226x_pkg.ALL;

ENTITY ltc226x_spi_ctrl IS
  GENERIC (
    g_clk_div         : t_spi_div_type := 4;
    g_start_delay     : t_spi_delay_type := 1024;
    g_twos_complement : BOOLEAN := FALSE
  );
  PORT (
    i_clk        : IN  std_ulogic;
    i_reset_n    : IN  std_ulogic;
    i_sdo        : IN  std_ulogic;
    o_sdi        : OUT std_ulogic;
    o_sclk       : OUT std_ulogic;
    o_cs_n       : OUT std_ulogic;
    o_done       : OUT std_ulogic;
    o_error      : OUT std_ulogic;
    o_error_addr : OUT t_spi_addr_type;
    o_expected   : OUT t_byte_type;
    o_received   : OUT t_byte_type
  );
END ENTITY ltc226x_spi_ctrl;

ARCHITECTURE rtl OF ltc226x_spi_ctrl IS

  TYPE t_state_type IS (
      init_wait,
      start_word,
      clock_low,
      clock_high,
      finish_word,
      done_state
  );

  SUBTYPE t_delay_count_type IS INTEGER RANGE 0 TO g_start_delay;
  SUBTYPE t_div_count_type IS INTEGER RANGE 0 TO g_clk_div - 1;
  SUBTYPE t_cmd_index_type IS INTEGER RANGE 0 TO 4;
  SUBTYPE t_bit_index_type IS INTEGER RANGE 0 TO 15;

  SIGNAL s_state       : t_state_type;
  SIGNAL s_delay_count : t_delay_count_type;
  SIGNAL s_div_count   : t_div_count_type;
  SIGNAL s_cmd_index   : t_cmd_index_type;
  SIGNAL s_bit_index   : t_bit_index_type;
  SIGNAL s_tx_word     : t_adc_word_type;
  SIGNAL s_rx_word     : t_adc_word_type;
  SIGNAL s_command     : t_adc_word_type;
  SIGNAL s_expected    : t_byte_type;
  SIGNAL s_error       : std_ulogic;

  -- Select the requested ADC numerical output format.
  FUNCTION a1_data(i_twos : BOOLEAN) RETURN t_byte_type IS
  BEGIN
    IF i_twos THEN
      RETURN x"20";
    END IF;

    RETURN x"00";
  END FUNCTION a1_data;

  CONSTANT c_a1_data : t_byte_type := a1_data(g_twos_complement);
  CONSTANT c_a2_data : t_byte_type := x"00";

  -- Return each 16-bit, MSB-first initialisation or readback transaction.
  FUNCTION command_word(i_index : t_cmd_index_type)
    RETURN t_adc_word_type IS
    VARIABLE v_command : t_adc_word_type;
  BEGIN
    CASE i_index IS
      WHEN 0 =>
        v_command := x"0080";
      WHEN 1 =>
        v_command := x"01" & c_a1_data;
      WHEN 2 =>
        v_command := x"02" & c_a2_data;
      WHEN 3 =>
        v_command := x"8100";
      WHEN OTHERS =>
        v_command := x"8200";
    END CASE;

    RETURN v_command;
  END FUNCTION command_word;

BEGIN

  o_error <= s_error;
  s_command <= command_word(s_cmd_index);
  s_expected <= c_a1_data WHEN s_cmd_index = 3 ELSE c_a2_data;

  -- Generate all SPI edges and verify the two readable configuration values.
  p_spi : PROCESS (i_clk, i_reset_n)
  BEGIN
    IF i_reset_n = '0' THEN
      s_state <= init_wait;
      s_delay_count <= t_delay_count_type'LOW;
      s_div_count <= t_div_count_type'LOW;
      s_cmd_index <= t_cmd_index_type'LOW;
      s_bit_index <= t_bit_index_type'HIGH;
      s_tx_word <= (OTHERS => '0');
      s_rx_word <= (OTHERS => '0');
      o_sdi <= '0';
      o_sclk <= '0';
      o_cs_n <= '1';
      o_done <= '0';
      s_error <= '0';
      o_error_addr <= (OTHERS => '0');
      o_expected <= (OTHERS => '0');
      o_received <= (OTHERS => '0');
    ELSIF RISING_EDGE(i_clk) THEN
      CASE s_state IS
        WHEN init_wait =>
          o_cs_n <= '1';
          o_sclk <= '0';
          o_sdi <= '0';

          IF s_delay_count = g_start_delay THEN
            s_state <= start_word;
          ELSE
            s_delay_count <= s_delay_count + 1;
          END IF;

        WHEN start_word =>
          s_tx_word <= s_command;
          s_rx_word <= (OTHERS => '0');
          s_bit_index <= t_bit_index_type'HIGH;
          s_div_count <= g_clk_div - 1;
          o_cs_n <= '0';
          o_sclk <= '0';
          o_sdi <= s_command(s_command'HIGH);
          s_state <= clock_low;

        WHEN clock_low =>
          IF s_div_count = 0 THEN
            o_sclk <= '1';
            s_div_count <= g_clk_div - 1;
            s_state <= clock_high;
          ELSE
            s_div_count <= s_div_count - 1;
          END IF;

        WHEN clock_high =>
          IF s_div_count = 0 THEN
            o_sclk <= '0';
            s_rx_word(s_bit_index) <= i_sdo;
            s_div_count <= g_clk_div - 1;

            IF s_bit_index = 0 THEN
              s_state <= finish_word;
            ELSE
              s_bit_index <= s_bit_index - 1;
              o_sdi <= s_tx_word(s_bit_index - 1);
              s_state <= clock_low;
            END IF;
          ELSE
            s_div_count <= s_div_count - 1;
          END IF;

        WHEN finish_word =>
          o_cs_n <= '1';
          o_sclk <= '0';
          o_sdi <= '0';

          IF s_cmd_index >= 3 THEN
            IF s_rx_word(7 DOWNTO 0) /= s_expected AND s_error = '0' THEN
              s_error <= '1';
              o_error_addr <= std_ulogic_vector(TO_UNSIGNED(s_cmd_index - 2, c_spi_addr_width));
              o_expected <= s_expected;
              o_received <= s_rx_word(7 DOWNTO 0);
            END IF;
          END IF;

          IF s_cmd_index = 4 THEN
            s_state <= done_state;
          ELSE
            s_cmd_index <= s_cmd_index + 1;
            s_state <= start_word;
          END IF;

        WHEN done_state =>
          o_done <= '1';
          o_cs_n <= '1';
          o_sclk <= '0';
          o_sdi <= '0';
      END CASE;
    END IF;
  END PROCESS p_spi;

END ARCHITECTURE rtl;
