-- Author: Adam Taylor
-- Description: Common constrained types, constants and functions for the SYZYGY LTC226x ADC IP.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

PACKAGE syzygy_adc_ltc226x_pkg IS

  CONSTANT c_lane_width     : POSITIVE := 8;
  CONSTANT c_adc_word_width : POSITIVE := 16;
  CONSTANT c_axis_width     : POSITIVE := 32;
  CONSTANT c_spi_addr_width : POSITIVE := 7;
  CONSTANT c_serial_lanes   : POSITIVE := 5;
  CONSTANT c_fifo_depth_min : POSITIVE := 4;
  CONSTANT c_fifo_depth_max : POSITIVE := 256;
  CONSTANT c_fifo_addr_max  : POSITIVE := 8;
  CONSTANT c_lock_cycles_max : POSITIVE := 32;
  CONSTANT c_spi_div_max    : POSITIVE := 1024;
  CONSTANT c_spi_delay_max  : POSITIVE := 1048575;
  CONSTANT c_data_width_max : POSITIVE := 64;

  SUBTYPE t_adc_width_type IS INTEGER RANGE 12 TO 14;
  SUBTYPE t_fifo_depth_type IS INTEGER RANGE c_fifo_depth_min TO c_fifo_depth_max;
  SUBTYPE t_fifo_addr_type IS INTEGER RANGE 1 TO c_fifo_addr_max;
  SUBTYPE t_fifo_check_type IS INTEGER RANGE 1 TO c_fifo_depth_max;
  SUBTYPE t_lock_cycles_type IS INTEGER RANGE 2 TO c_lock_cycles_max;
  SUBTYPE t_spi_div_type IS INTEGER RANGE 1 TO c_spi_div_max;
  SUBTYPE t_spi_delay_type IS INTEGER RANGE 0 TO c_spi_delay_max;
  SUBTYPE t_data_width_type IS INTEGER RANGE 1 TO c_data_width_max;
  SUBTYPE t_lane_word_type IS std_ulogic_vector(c_lane_width - 1 DOWNTO 0);
  SUBTYPE t_adc_word_type IS std_ulogic_vector(c_adc_word_width - 1 DOWNTO 0);
  SUBTYPE t_axis_word_type IS std_ulogic_vector(c_axis_width - 1 DOWNTO 0);
  SUBTYPE t_spi_addr_type IS std_ulogic_vector(c_spi_addr_width - 1 DOWNTO 0);
  SUBTYPE t_byte_type IS std_ulogic_vector(c_lane_width - 1 DOWNTO 0);

  FUNCTION clog2(i_value : t_fifo_depth_type) RETURN t_fifo_addr_type;

  FUNCTION is_power_of_two(i_value : t_fifo_depth_type) RETURN BOOLEAN;

  FUNCTION bin_to_gray(i_value : unsigned) RETURN unsigned;

END PACKAGE syzygy_adc_ltc226x_pkg;

PACKAGE BODY syzygy_adc_ltc226x_pkg IS

  -- Return the number of address bits required to represent i_value entries.
  FUNCTION clog2(i_value : t_fifo_depth_type) RETURN t_fifo_addr_type IS
    VARIABLE v_value  : INTEGER RANGE 0 TO c_fifo_depth_max := i_value - 1;
    VARIABLE v_result : t_fifo_addr_type := 1;
  BEGIN
    WHILE v_value > 1 LOOP
        v_value := v_value / 2;
        v_result := v_result + 1;
      END LOOP;

      RETURN v_result;
  END FUNCTION clog2;

  -- Return TRUE when i_value is an exact power of two.
  FUNCTION is_power_of_two(i_value : t_fifo_depth_type) RETURN BOOLEAN IS
    VARIABLE v_value : t_fifo_check_type := i_value;
  BEGIN
    WHILE (v_value MOD 2) = 0 LOOP
        v_value := v_value / 2;
      END LOOP;

      RETURN v_value = 1;
  END FUNCTION is_power_of_two;

  -- Convert a binary count to its reflected Gray-code representation.
  FUNCTION bin_to_gray(i_value : unsigned) RETURN unsigned IS
  BEGIN
    RETURN i_value XOR ('0' & i_value(i_value'HIGH DOWNTO 1));
  END FUNCTION bin_to_gray;

END PACKAGE BODY syzygy_adc_ltc226x_pkg;
