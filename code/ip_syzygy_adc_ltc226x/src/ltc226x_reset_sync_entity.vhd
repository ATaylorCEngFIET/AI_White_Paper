-- Author: Adam Taylor
-- Description: Asynchronously asserts and synchronously releases an active-low reset.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

ENTITY ltc226x_reset_sync IS
  PORT (
    i_clk           : IN  std_ulogic;
    i_async_reset_n : IN  std_ulogic;
    o_reset_n       : OUT std_ulogic
  );
END ENTITY ltc226x_reset_sync;

ARCHITECTURE rtl OF ltc226x_reset_sync IS

  SIGNAL s_reset_meta : std_ulogic;
  SIGNAL s_reset_sync : std_ulogic;

  ATTRIBUTE async_reg : STRING;
  ATTRIBUTE async_reg OF s_reset_meta, s_reset_sync : SIGNAL IS "TRUE";

BEGIN

  o_reset_n <= s_reset_sync;

  -- Assert both stages asynchronously and release reset after two clock edges.
  p_reset : PROCESS (i_clk, i_async_reset_n)
  BEGIN
    IF i_async_reset_n = '0' THEN
      s_reset_meta <= '0';
      s_reset_sync <= '0';
    ELSIF RISING_EDGE(i_clk) THEN
      s_reset_meta <= '1';
      s_reset_sync <= s_reset_meta;
    END IF;
  END PROCESS p_reset;

END ARCHITECTURE rtl;
