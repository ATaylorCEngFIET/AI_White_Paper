-- Author: Adam Taylor
-- Description: Common definitions for the Opal Kelly SYZYGY AD911x DAC IP.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

PACKAGE syzygy_dac_ad911x_pkg IS

  SUBTYPE t_reg_addr_type IS INTEGER RANGE 0 TO 31;

  CONSTANT c_ad911x_reg_count : INTEGER RANGE 1 TO 32 := 32;
  CONSTANT c_ad911x_reg_width : INTEGER RANGE 1 TO 8 := 8;

  -- Byte N occupies bits (N * 8) + 7 DOWNTO (N * 8).
  CONSTANT c_default_reg_data : std_ulogic_vector(255 DOWNTO 0) :=
  x"0A000000000000000000000000003F000000000000000080A00080A000344000";

  -- Configure data control, internal I/Q RSET, and internal I/Q RCML.
  CONSTANT c_default_write_mask : std_ulogic_vector(31 DOWNTO 0) :=
  x"000001B4";

  -- Verify every default write and the device version at address 0x1F.
  CONSTANT c_default_verify_mask : std_ulogic_vector(31 DOWNTO 0) :=
  x"800001B4";

  -- Return one byte from a flattened AD911x register image.
  FUNCTION f_register_byte(
      i_register_data : std_ulogic_vector(255 DOWNTO 0);
      i_address       : INTEGER RANGE 0 TO 31
    ) RETURN std_ulogic_vector;

END PACKAGE syzygy_dac_ad911x_pkg;

PACKAGE BODY syzygy_dac_ad911x_pkg IS

  -- Return one byte from a flattened AD911x register image.
  FUNCTION f_register_byte(
      i_register_data : std_ulogic_vector(255 DOWNTO 0);
      i_address       : INTEGER RANGE 0 TO 31
    ) RETURN std_ulogic_vector IS
    VARIABLE v_register_byte : std_ulogic_vector(7 DOWNTO 0);
  BEGIN
    v_register_byte(0) := i_register_data((i_address * c_ad911x_reg_width) + 0);
    v_register_byte(1) := i_register_data((i_address * c_ad911x_reg_width) + 1);
    v_register_byte(2) := i_register_data((i_address * c_ad911x_reg_width) + 2);
    v_register_byte(3) := i_register_data((i_address * c_ad911x_reg_width) + 3);
    v_register_byte(4) := i_register_data((i_address * c_ad911x_reg_width) + 4);
    v_register_byte(5) := i_register_data((i_address * c_ad911x_reg_width) + 5);
    v_register_byte(6) := i_register_data((i_address * c_ad911x_reg_width) + 6);
    v_register_byte(7) := i_register_data((i_address * c_ad911x_reg_width) + 7);

    RETURN v_register_byte;
  END FUNCTION f_register_byte;

END PACKAGE BODY syzygy_dac_ad911x_pkg;

