-- Author: Adam Taylor
-- Description: AXI Stream bridge with parallel input and backpressure support.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY axis_bridge IS
  GENERIC (
    g_data_width      : INTEGER RANGE 1 TO 1024 := 16          -- Data width
  );
  PORT (
    -- Clock and reset
    i_clk             : IN  std_ulogic;        -- System clock
    i_aresetn         : IN  std_ulogic;        -- Asynchronous active-low reset
    
    -- Parallel data input
    i_data            : IN  std_ulogic_vector(g_data_width - 1 DOWNTO 0);
    i_data_valid      : IN  std_ulogic;        -- Data valid strobe
    
    -- AXI Stream master output
    o_axis_tdata      : OUT std_ulogic_vector(g_data_width - 1 DOWNTO 0);
    o_axis_tvalid     : OUT std_ulogic;
    i_axis_tready     : IN  std_ulogic
  );
END ENTITY axis_bridge;

ARCHITECTURE rtl OF axis_bridge IS

  ----------------------------------------------------------------------------
  -- Signals
  ----------------------------------------------------------------------------
  SIGNAL s_tdata      : std_ulogic_vector(g_data_width - 1 DOWNTO 0);
  SIGNAL s_tvalid     : std_ulogic;

BEGIN

  ----------------------------------------------------------------------------
  -- AXI Stream Bridge Process
  ----------------------------------------------------------------------------
  p_bridge : PROCESS (i_clk, i_aresetn)
  BEGIN
    IF i_aresetn = '0' THEN
      s_tdata  <= (OTHERS => '0');
      s_tvalid <= '0';
      
    ELSIF rising_edge(i_clk) THEN
      -- Clear valid when accepted by downstream
      IF s_tvalid = '1' AND i_axis_tready = '1' THEN
        s_tvalid <= '0';
      END IF;
      
      -- Load new data when available
      IF i_data_valid = '1' THEN
        s_tdata  <= i_data;
        s_tvalid <= '1';
      END IF;
    END IF;
  END PROCESS p_bridge;

  ----------------------------------------------------------------------------
  -- Output Assignments
  ----------------------------------------------------------------------------
  o_axis_tdata  <= s_tdata;
  o_axis_tvalid <= s_tvalid;

END ARCHITECTURE rtl;
