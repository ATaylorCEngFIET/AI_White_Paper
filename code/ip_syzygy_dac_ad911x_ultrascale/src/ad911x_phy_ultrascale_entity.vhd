-- Author: Adam Taylor
-- Description: UltraScale+ DDR output PHY for the AD911x DAC.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

LIBRARY unisim;
USE unisim.vcomponents.ALL;

USE work.syzygy_dac_ad911x_pkg.ALL;

ENTITY ad911x_phy_ultrascale IS
  GENERIC (
    g_initial_sample : std_ulogic_vector(c_dac_data_width - 1 DOWNTO 0) := x"800";
    g_simulation     : BOOLEAN := FALSE
  );
  PORT (
    i_data_clk    : IN  std_ulogic;
    i_dac_clk_90  : IN  std_ulogic;
    i_data_reset  : IN  std_ulogic;
    i_clock_reset : IN  std_ulogic;
    i_data_i      : IN  std_ulogic_vector(c_dac_data_width - 1 DOWNTO 0);
    i_data_q      : IN  std_ulogic_vector(c_dac_data_width - 1 DOWNTO 0);
    o_dac_db      : OUT std_ulogic_vector(c_dac_data_width - 1 DOWNTO 0);
    o_dac_clkin   : OUT std_ulogic
  );
END ENTITY ad911x_phy_ultrascale;

ARCHITECTURE rtl OF ad911x_phy_ultrascale IS

  SIGNAL s_sim_dac_db    : t_dac_data_type;
  SIGNAL s_sim_dac_clk   : std_ulogic;
  SIGNAL s_synth_dac_db  : t_dac_data_type;
  SIGNAL s_synth_dac_clk : std_ulogic;
  SIGNAL s_data_i        : t_dac_data_type;
  SIGNAL s_data_q        : t_dac_data_type;

BEGIN

  o_dac_db <= s_sim_dac_db WHEN g_simulation ELSE s_synth_dac_db;
  o_dac_clkin <= s_sim_dac_clk WHEN g_simulation ELSE s_synth_dac_clk;

  -- ODDRE1 can only reset Q low. Select the requested initial word at D1/D2
  -- while reset is asserted instead. The data clock remains active while the
  -- forwarded DAC clock is held low, so the complete word is loaded before
  -- the AD911x sees its first clock edge.
  s_data_i <= g_initial_sample WHEN i_data_reset = '1' ELSE i_data_i;
  s_data_q <= g_initial_sample WHEN i_data_reset = '1' ELSE i_data_q;

  gen_simulation : IF g_simulation GENERATE
  BEGIN
    s_sim_dac_clk <= i_dac_clk_90 WHEN i_clock_reset = '0' ELSE '0';

    p_sim_ddr : PROCESS(i_data_clk, i_data_reset)
    BEGIN
      IF i_data_reset = '1' THEN
        s_sim_dac_db <= g_initial_sample;
      ELSIF rising_edge(i_data_clk) THEN
        s_sim_dac_db <= i_data_i;
      ELSIF falling_edge(i_data_clk) THEN
        s_sim_dac_db <= i_data_q;
      END IF;
    END PROCESS p_sim_ddr;
  END GENERATE gen_simulation;

  gen_synthesis : IF NOT g_simulation GENERATE
  BEGIN
    u_clock_oddre1 : ODDRE1
      GENERIC MAP (
        IS_C_INVERTED  => '0',
        IS_D1_INVERTED => '0',
        IS_D2_INVERTED => '0',
        SIM_DEVICE     => "ULTRASCALE_PLUS",
        SRVAL          => '0'
      )
      PORT MAP (
        Q  => s_synth_dac_clk,
        C  => i_dac_clk_90,
        D1 => '1',
        D2 => '0',
        SR => i_clock_reset
      );

    gen_data_bits : FOR i IN t_dac_bit_index_type GENERATE
    BEGIN
      u_data_oddre1 : ODDRE1
        GENERIC MAP (
          IS_C_INVERTED  => '0',
          IS_D1_INVERTED => '0',
          IS_D2_INVERTED => '0',
          SIM_DEVICE     => "ULTRASCALE_PLUS",
          SRVAL          => '0'
        )
        PORT MAP (
          Q  => s_synth_dac_db(i),
          C  => i_data_clk,
          D1 => s_data_i(i),
          D2 => s_data_q(i),
          SR => '0'
        );
    END GENERATE gen_data_bits;
  END GENERATE gen_synthesis;

END ARCHITECTURE rtl;
