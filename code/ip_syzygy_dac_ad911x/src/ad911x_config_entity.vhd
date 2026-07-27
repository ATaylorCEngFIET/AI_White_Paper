-- Author: Adam Taylor
-- Description: Reset, generic register initialization, and readback checking controller for the AD911x DAC.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

USE work.syzygy_dac_ad911x_pkg.ALL;

ENTITY ad911x_config IS
  GENERIC (
    g_reset_cycles      : INTEGER RANGE 1 TO 1000000 := 16;
    g_post_reset_cycles : INTEGER RANGE 1 TO 1000000 := 256;
    g_register_data     : std_ulogic_vector(255 DOWNTO 0) := c_default_reg_data;
    g_write_mask        : std_ulogic_vector(31 DOWNTO 0) := c_default_write_mask;
    g_verify_mask       : std_ulogic_vector(31 DOWNTO 0) := c_default_verify_mask
  );
  PORT (
    i_clk            : IN  std_ulogic;
    i_aresetn        : IN  std_ulogic;
    i_spi_read_data  : IN  std_ulogic_vector(7 DOWNTO 0);
    i_spi_busy       : IN  std_ulogic;
    i_spi_done       : IN  std_ulogic;
    o_spi_start      : OUT std_ulogic;
    o_spi_read       : OUT std_ulogic;
    o_spi_address    : OUT std_ulogic_vector(4 DOWNTO 0);
    o_spi_write_data : OUT std_ulogic_vector(7 DOWNTO 0);
    o_dac_reset      : OUT std_ulogic;
    o_config_ok      : OUT std_ulogic;
    o_config_error   : OUT std_ulogic;
    o_opamp_enable   : OUT std_ulogic
  );
END ENTITY ad911x_config;

ARCHITECTURE rtl OF ad911x_config IS

  SUBTYPE t_delay_type IS INTEGER RANGE 1 TO 1000000;

  -- Return the larger of two delay values.
  FUNCTION f_maximum(
      i_left  : t_delay_type;
      i_right : t_delay_type
    ) RETURN t_delay_type IS
  BEGIN
    IF i_left > i_right THEN
      RETURN i_left;
    END IF;

    RETURN i_right;
  END FUNCTION f_maximum;

  TYPE t_state_type IS (
      reset_assert,
      post_reset_wait,
      find_write,
      start_write,
      wait_write,
      find_verify,
      start_read,
      wait_read,
      configured,
      config_failed
    );

  CONSTANT c_max_delay : t_delay_type :=
    f_maximum(g_reset_cycles, g_post_reset_cycles);

  SIGNAL s_state       : t_state_type;
  SIGNAL s_delay_count : INTEGER RANGE 0 TO c_max_delay;
  SIGNAL s_address     : INTEGER RANGE 0 TO c_ad911x_reg_count;
  SIGNAL s_spi_start   : std_ulogic;
  SIGNAL s_spi_read    : std_ulogic;
  SIGNAL s_dac_reset   : std_ulogic;
  SIGNAL s_config_ok   : std_ulogic;
  SIGNAL s_config_err  : std_ulogic;

BEGIN

  o_spi_start <= s_spi_start;
  o_spi_read <= s_spi_read;
  o_spi_address <= std_ulogic_vector(to_unsigned(s_address, 5)) WHEN
    s_address < c_ad911x_reg_count ELSE (OTHERS => '0');
  o_spi_write_data <= f_register_byte(g_register_data, s_address) WHEN
    s_address < c_ad911x_reg_count ELSE (OTHERS => '0');
  o_dac_reset <= s_dac_reset;
  o_config_ok <= s_config_ok;
  o_config_error <= s_config_err;
  o_opamp_enable <= s_config_ok;

  -- Apply reset, write enabled registers, and verify enabled registers.
  p_config : PROCESS(i_clk, i_aresetn)
  BEGIN
    IF i_aresetn = '0' THEN
      s_state <= reset_assert;
      s_delay_count <= 0;
      s_address <= 0;
      s_spi_start <= '0';
      s_spi_read <= '0';
      s_dac_reset <= '1';
      s_config_ok <= '0';
      s_config_err <= '0';
    ELSIF rising_edge(i_clk) THEN
      s_spi_start <= '0';

      CASE s_state IS
        WHEN reset_assert =>
          s_dac_reset <= '1';
          s_config_ok <= '0';
          s_config_err <= '0';

          IF s_delay_count = g_reset_cycles - 1 THEN
            s_delay_count <= 0;
            s_dac_reset <= '0';
            s_state <= post_reset_wait;
          ELSE
            s_delay_count <= s_delay_count + 1;
          END IF;

        WHEN post_reset_wait =>
          IF s_delay_count = g_post_reset_cycles - 1 THEN
            s_delay_count <= 0;
            s_address <= 0;
            s_state <= find_write;
          ELSE
            s_delay_count <= s_delay_count + 1;
          END IF;

        WHEN find_write =>
          IF s_address = c_ad911x_reg_count THEN
            s_address <= 0;
            s_state <= find_verify;
          ELSIF g_write_mask(s_address) = '1' THEN
            s_state <= start_write;
          ELSE
            s_address <= s_address + 1;
          END IF;

        WHEN start_write =>
          IF i_spi_busy = '0' THEN
            s_spi_read <= '0';
            s_spi_start <= '1';
            s_state <= wait_write;
          END IF;

        WHEN wait_write =>
          IF i_spi_done = '1' THEN
            s_address <= s_address + 1;
            s_state <= find_write;
          END IF;

        WHEN find_verify =>
          IF s_address = c_ad911x_reg_count THEN
            s_state <= configured;
          ELSIF g_verify_mask(s_address) = '1' THEN
            s_state <= start_read;
          ELSE
            s_address <= s_address + 1;
          END IF;

        WHEN start_read =>
          IF i_spi_busy = '0' THEN
            s_spi_read <= '1';
            s_spi_start <= '1';
            s_state <= wait_read;
          END IF;

        WHEN wait_read =>
          IF i_spi_done = '1' THEN
            IF i_spi_read_data = f_register_byte(g_register_data, s_address) THEN
              s_address <= s_address + 1;
              s_state <= find_verify;
            ELSE
              s_config_err <= '1';
              s_state <= config_failed;
            END IF;
          END IF;

        WHEN configured =>
          s_config_ok <= '1';

        WHEN config_failed =>
          s_config_ok <= '0';
          s_config_err <= '1';
      END CASE;
    END IF;
  END PROCESS p_config;

END ARCHITECTURE rtl;
