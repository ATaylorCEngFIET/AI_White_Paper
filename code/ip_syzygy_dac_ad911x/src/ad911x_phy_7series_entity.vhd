-- Author: Adam Taylor
-- Description: Xilinx 7-series DDR output PHY for the AD911x multiplexed I/Q data bus and forwarded sample clock.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

ENTITY ad911x_phy_7series IS
  GENERIC (
    g_initial_sample : std_ulogic_vector(11 DOWNTO 0) := x"800";
    g_simulation     : BOOLEAN := FALSE
  );
  PORT (
    i_data_clk    : IN  std_ulogic;
    i_dac_clk_90  : IN  std_ulogic;
    i_data_reset  : IN  std_ulogic;
    i_clock_reset : IN  std_ulogic;
    i_data_i      : IN  std_ulogic_vector(11 DOWNTO 0);
    i_data_q      : IN  std_ulogic_vector(11 DOWNTO 0);
    o_dac_db      : OUT std_ulogic_vector(11 DOWNTO 0);
    o_dac_clkin   : OUT std_ulogic
  );
END ENTITY ad911x_phy_7series;

ARCHITECTURE rtl OF ad911x_phy_7series IS

  COMPONENT ODDR IS
    GENERIC (
      DDR_CLK_EDGE : STRING := "OPPOSITE_EDGE";
      SRTYPE       : STRING := "SYNC"
    );
    PORT (
      Q  : OUT std_ulogic;
      C  : IN  std_ulogic;
      CE : IN  std_ulogic;
      D1 : IN  std_ulogic;
      D2 : IN  std_ulogic;
      R  : IN  std_ulogic;
      S  : IN  std_ulogic
    );
  END COMPONENT ODDR;

  SIGNAL s_sim_dac_db    : std_ulogic_vector(11 DOWNTO 0);
  SIGNAL s_sim_dac_clk   : std_ulogic;
  SIGNAL s_synth_dac_db  : std_ulogic_vector(11 DOWNTO 0);
  SIGNAL s_synth_dac_clk : std_ulogic;
  SIGNAL s_data_enable   : std_ulogic;

BEGIN

  o_dac_db <= s_sim_dac_db WHEN g_simulation ELSE s_synth_dac_db;
  o_dac_clkin <= s_sim_dac_clk WHEN g_simulation ELSE s_synth_dac_clk;
  s_data_enable <= NOT i_data_reset;

  -- Simulation-only dual-edge behavioral model.
  g_sim : IF g_simulation GENERATE
  BEGIN
    s_sim_dac_clk <= i_dac_clk_90 WHEN i_clock_reset = '0' ELSE '0';

    -- Model the DDR data pins without requiring the vendor simulation library.
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
  END GENERATE g_sim;

  -- Synthesis implementation using Xilinx 7-series output DDR registers.
  g_synth : IF NOT g_simulation GENERATE
  BEGIN
    u_clk_oddr : ODDR
      GENERIC MAP (
        DDR_CLK_EDGE => "OPPOSITE_EDGE",
        SRTYPE       => "ASYNC"
      )
      PORT MAP (
        Q  => s_synth_dac_clk,
        C  => i_dac_clk_90,
        CE => '1',
        D1 => '1',
        D2 => '0',
        R  => i_clock_reset,
        S  => '0'
      );

    g_bits : FOR i IN 0 TO 11 GENERATE
    BEGIN
      u_db_oddr : ODDR
        GENERIC MAP (
          DDR_CLK_EDGE => "SAME_EDGE",
          SRTYPE       => "ASYNC"
        )
        PORT MAP (
          Q  => s_synth_dac_db(i),
          C  => i_data_clk,
          CE => s_data_enable,
          D1 => i_data_i(i),
          D2 => i_data_q(i),
          R  => '0',
          S  => '0'
        );
    END GENERATE g_bits;
  END GENERATE g_synth;

END ARCHITECTURE rtl;
