-- Author: Adam Taylor
-- Description: Common definitions for the Opal Kelly SYZYGY AD911x DAC IP.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

PACKAGE syzygy_dac_ad911x_pkg IS

  CONSTANT c_ad911x_reg_count : POSITIVE RANGE 1 TO 32 := 32;
  CONSTANT c_ad911x_reg_width : POSITIVE RANGE 1 TO 8 := 8;
  CONSTANT c_dac_data_width : POSITIVE RANGE 1 TO 16 := 12;
  CONSTANT c_axis_data_width : POSITIVE RANGE 1 TO 64 := 32;
  CONSTANT c_spi_address_width : POSITIVE RANGE 1 TO 8 := 5;
  CONSTANT c_spi_transaction_width : POSITIVE RANGE 1 TO 32 := 16;

  SUBTYPE t_reg_addr_type IS NATURAL RANGE 0 TO c_ad911x_reg_count - 1;
  SUBTYPE t_reg_scan_addr_type IS NATURAL RANGE 0 TO c_ad911x_reg_count;
  SUBTYPE t_register_bit_index_type IS NATURAL RANGE
    0 TO (c_ad911x_reg_count * c_ad911x_reg_width) - 1;
  SUBTYPE t_register_byte_index_type IS NATURAL RANGE
    0 TO c_ad911x_reg_width - 1;
  SUBTYPE t_dac_bit_index_type IS NATURAL RANGE 0 TO c_dac_data_width - 1;
  SUBTYPE t_spi_bit_index_type IS NATURAL RANGE
    0 TO c_spi_transaction_width - 1;
  SUBTYPE t_clock_frequency_hz_type IS POSITIVE RANGE 1 TO 1000000000;
  SUBTYPE t_spi_divisor_type IS POSITIVE RANGE 1 TO 65536;
  SUBTYPE t_cycle_count_type IS POSITIVE RANGE 1 TO 1048576;

  SUBTYPE t_register_data_type IS std_ulogic_vector(
    (c_ad911x_reg_count * c_ad911x_reg_width) - 1 DOWNTO 0
  );
  SUBTYPE t_register_mask_type IS std_ulogic_vector(
    c_ad911x_reg_count - 1 DOWNTO 0
  );
  SUBTYPE t_register_byte_type IS std_ulogic_vector(
    c_ad911x_reg_width - 1 DOWNTO 0
  );
  SUBTYPE t_spi_address_type IS std_ulogic_vector(
    c_spi_address_width - 1 DOWNTO 0
  );
  SUBTYPE t_spi_transaction_type IS std_ulogic_vector(
    c_spi_transaction_width - 1 DOWNTO 0
  );
  SUBTYPE t_dac_data_type IS std_ulogic_vector(c_dac_data_width - 1 DOWNTO 0);
  SUBTYPE t_axis_data_type IS std_ulogic_vector(c_axis_data_width - 1 DOWNTO 0);

  -- Byte N occupies bits (N * 8) + 7 DOWNTO (N * 8).
  CONSTANT c_default_reg_data : t_register_data_type :=
    x"0A000000000000000000000000003F000000000000000080A00080A000344000";

  -- Configure data control, internal I/Q RSET, and internal I/Q RCML.
  CONSTANT c_default_write_mask : t_register_mask_type := x"000001B4";

  -- Verify every default write and the device version at address 0x1F.
  CONSTANT c_default_verify_mask : t_register_mask_type := x"800001B4";

  -- Return one byte from a flattened AD911x register image.
  FUNCTION f_register_byte(
    i_register_data : t_register_data_type;
    i_address       : t_reg_addr_type
  ) RETURN t_register_byte_type;

END PACKAGE syzygy_dac_ad911x_pkg;

PACKAGE BODY syzygy_dac_ad911x_pkg IS

  -- Return one byte from a flattened AD911x register image.
  FUNCTION f_register_byte(
    i_register_data : t_register_data_type;
    i_address       : t_reg_addr_type
  ) RETURN t_register_byte_type IS
    VARIABLE v_result : t_register_byte_type;
    VARIABLE v_bit_index : t_register_bit_index_type;
  BEGIN
    FOR i IN t_register_byte_index_type LOOP
      v_bit_index := (i_address * c_ad911x_reg_width) + i;
      v_result(i) := i_register_data(v_bit_index);
    END LOOP;

    RETURN v_result;
  END FUNCTION f_register_byte;

END PACKAGE BODY syzygy_dac_ad911x_pkg;
