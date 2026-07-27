-- Author: Adam Taylor
-- Description: Xilinx 7-series SelectIO interface for the LTC226x ADC family.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

USE work.syzygy_adc_ltc226x_pkg.ALL;

ENTITY ltc226x_7series_io IS
  PORT (
    i_reset       : IN  std_ulogic;
    i_enc_clk     : IN  std_ulogic;
    i_adc_dco_p   : IN  std_ulogic;
    i_adc_dco_n   : IN  std_ulogic;
    i_adc_fr_p    : IN  std_ulogic;
    i_adc_fr_n    : IN  std_ulogic;
    i_adc_ch1a_p  : IN  std_ulogic;
    i_adc_ch1a_n  : IN  std_ulogic;
    i_adc_ch1b_p  : IN  std_ulogic;
    i_adc_ch1b_n  : IN  std_ulogic;
    i_adc_ch2a_p  : IN  std_ulogic;
    i_adc_ch2a_n  : IN  std_ulogic;
    i_adc_ch2b_p  : IN  std_ulogic;
    i_adc_ch2b_n  : IN  std_ulogic;
    o_adc_enc_p   : OUT std_ulogic;
    o_adc_enc_n   : OUT std_ulogic;
    o_sample_clk  : OUT std_ulogic;
    o_frame_word  : OUT t_lane_word_type;
    o_ch1a_word   : OUT t_lane_word_type;
    o_ch1b_word   : OUT t_lane_word_type;
    o_ch2a_word   : OUT t_lane_word_type;
    o_ch2b_word   : OUT t_lane_word_type
  );
END ENTITY ltc226x_7series_io;

ARCHITECTURE struct OF ltc226x_7series_io IS

  COMPONENT IBUFDS IS
    GENERIC (
      DIFF_TERM    : STRING := "FALSE";
      IBUF_LOW_PWR : STRING := "TRUE";
      IOSTANDARD   : STRING := "DEFAULT"
    );
    PORT (
      O  : OUT std_ulogic;
      I  : IN  std_ulogic;
      IB : IN  std_ulogic
    );
  END COMPONENT IBUFDS;

  COMPONENT BUFIO IS
    PORT (
      O : OUT std_ulogic;
      I : IN  std_ulogic
    );
  END COMPONENT BUFIO;

  COMPONENT BUFR IS
    GENERIC (
      BUFR_DIVIDE : STRING := "BYPASS";
      SIM_DEVICE  : STRING := "7SERIES"
    );
    PORT (
      O   : OUT std_ulogic;
      CE  : IN  std_ulogic;
      CLR : IN  std_ulogic;
      I   : IN  std_ulogic
    );
  END COMPONENT BUFR;

  COMPONENT ISERDESE2 IS
    GENERIC (
      DATA_RATE         : STRING := "DDR";
      DATA_WIDTH        : INTEGER := 4;
      DYN_CLKDIV_INV_EN : STRING := "FALSE";
      DYN_CLK_INV_EN    : STRING := "FALSE";
      INIT_Q1           : std_ulogic := '0';
      INIT_Q2           : std_ulogic := '0';
      INIT_Q3           : std_ulogic := '0';
      INIT_Q4           : std_ulogic := '0';
      INTERFACE_TYPE    : STRING := "MEMORY";
      IOBDELAY          : STRING := "NONE";
      NUM_CE            : INTEGER := 2;
      OFB_USED          : STRING := "FALSE";
      SERDES_MODE       : STRING := "MASTER";
      SRVAL_Q1          : std_ulogic := '0';
      SRVAL_Q2          : std_ulogic := '0';
      SRVAL_Q3          : std_ulogic := '0';
      SRVAL_Q4          : std_ulogic := '0'
    );
    PORT (
      O             : OUT std_ulogic;
      Q1            : OUT std_ulogic;
      Q2            : OUT std_ulogic;
      Q3            : OUT std_ulogic;
      Q4            : OUT std_ulogic;
      Q5            : OUT std_ulogic;
      Q6            : OUT std_ulogic;
      Q7            : OUT std_ulogic;
      Q8            : OUT std_ulogic;
      SHIFTOUT1     : OUT std_ulogic;
      SHIFTOUT2     : OUT std_ulogic;
      BITSLIP       : IN  std_ulogic;
      CE1           : IN  std_ulogic;
      CE2           : IN  std_ulogic;
      CLK           : IN  std_ulogic;
      CLKB          : IN  std_ulogic;
      CLKDIV        : IN  std_ulogic;
      CLKDIVP       : IN  std_ulogic;
      D             : IN  std_ulogic;
      DDLY          : IN  std_ulogic;
      DYNCLKDIVSEL  : IN  std_ulogic;
      DYNCLKSEL     : IN  std_ulogic;
      OCLK          : IN  std_ulogic;
      OCLKB         : IN  std_ulogic;
      OFB           : IN  std_ulogic;
      RST           : IN  std_ulogic;
      SHIFTIN1      : IN  std_ulogic;
      SHIFTIN2      : IN  std_ulogic
    );
  END COMPONENT ISERDESE2;

  COMPONENT ODDR IS
    GENERIC (
      DDR_CLK_EDGE : STRING := "OPPOSITE_EDGE";
      INIT         : std_ulogic := '0';
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

  COMPONENT OBUFDS IS
    GENERIC (
      IOSTANDARD : STRING := "DEFAULT";
      SLEW       : STRING := "SLOW"
    );
    PORT (
      O  : OUT std_ulogic;
      OB : OUT std_ulogic;
      I  : IN  std_ulogic
    );
  END COMPONENT OBUFDS;

  TYPE t_parallel_type IS ARRAY (0 TO c_serial_lanes - 1) OF t_lane_word_type;

  CONSTANT c_zero : std_ulogic := '0';
  CONSTANT c_one  : std_ulogic := '1';

  SIGNAL s_dco_p_int : std_ulogic;
  SIGNAL s_dco_p_io  : std_ulogic;
  SIGNAL s_dco_n_io  : std_ulogic;
  SIGNAL s_sample_clk : std_ulogic;
  SIGNAL s_serial     : std_ulogic_vector(c_serial_lanes - 1 DOWNTO 0);
  SIGNAL s_parallel   : t_parallel_type;
  SIGNAL s_enc_out   : std_ulogic;

BEGIN

  o_sample_clk <= s_sample_clk;
  o_frame_word <= s_parallel(0);
  o_ch1a_word <= s_parallel(1);
  o_ch1b_word <= s_parallel(2);
  o_ch2a_word <= s_parallel(3);
  o_ch2b_word <= s_parallel(4);

  u_dco_in : IBUFDS
    GENERIC MAP (
      DIFF_TERM    => "TRUE",
      IBUF_LOW_PWR => "FALSE",
      IOSTANDARD   => "LVDS_25"
    )
    PORT MAP (
      O  => s_dco_p_int,
      I  => i_adc_dco_p,
      IB => i_adc_dco_n
  );

  u_dco_p : BUFIO
    PORT MAP (
      O => s_dco_p_io,
      I => s_dco_p_int
  );

  -- ISERDESE2 requires CLKB to be the inverse of CLK.  Use the primitive's
  -- local clock inversion instead of trying to route the complementary
  -- IBUFDS output through a second BUFIO; a differential clock pair has only
  -- one direct BUFIO path in 7-series devices.
  s_dco_n_io <= NOT s_dco_p_io;

  u_dco_div : BUFR
    GENERIC MAP (
      BUFR_DIVIDE => "4",
      SIM_DEVICE  => "7SERIES"
    )
    PORT MAP (
      O   => s_sample_clk,
      CE  => c_one,
      CLR => i_reset,
      I   => s_dco_p_int
  );

  u_frame_in : IBUFDS
    GENERIC MAP (
      DIFF_TERM    => "TRUE",
      IBUF_LOW_PWR => "FALSE",
      IOSTANDARD   => "LVDS_25"
    )
    PORT MAP (
      O  => s_serial(0),
      I  => i_adc_fr_p,
      IB => i_adc_fr_n
  );

  u_ch1a_in : IBUFDS
    GENERIC MAP (
      DIFF_TERM    => "TRUE",
      IBUF_LOW_PWR => "FALSE",
      IOSTANDARD   => "LVDS_25"
    )
    PORT MAP (
      O  => s_serial(1),
      I  => i_adc_ch1a_p,
      IB => i_adc_ch1a_n
  );

  u_ch1b_in : IBUFDS
    GENERIC MAP (
      DIFF_TERM    => "TRUE",
      IBUF_LOW_PWR => "FALSE",
      IOSTANDARD   => "LVDS_25"
    )
    PORT MAP (
      O  => s_serial(2),
      I  => i_adc_ch1b_p,
      IB => i_adc_ch1b_n
  );

  u_ch2a_in : IBUFDS
    GENERIC MAP (
      DIFF_TERM    => "TRUE",
      IBUF_LOW_PWR => "FALSE",
      IOSTANDARD   => "LVDS_25"
    )
    PORT MAP (
      O  => s_serial(3),
      I  => i_adc_ch2a_p,
      IB => i_adc_ch2a_n
  );

  u_ch2b_in : IBUFDS
    GENERIC MAP (
      DIFF_TERM    => "TRUE",
      IBUF_LOW_PWR => "FALSE",
      IOSTANDARD   => "LVDS_25"
    )
    PORT MAP (
      O  => s_serial(4),
      I  => i_adc_ch2b_p,
      IB => i_adc_ch2b_n
  );

  gen_serdes : FOR index IN 0 TO c_serial_lanes - 1 GENERATE
    u_serdes : ISERDESE2
      GENERIC MAP (
        DATA_RATE         => "DDR",
        DATA_WIDTH        => c_lane_width,
        DYN_CLKDIV_INV_EN => "FALSE",
        DYN_CLK_INV_EN    => "FALSE",
        INIT_Q1           => '0',
        INIT_Q2           => '0',
        INIT_Q3           => '0',
        INIT_Q4           => '0',
        INTERFACE_TYPE    => "NETWORKING",
        IOBDELAY          => "NONE",
        NUM_CE            => 1,
        OFB_USED          => "FALSE",
        SERDES_MODE       => "MASTER",
        SRVAL_Q1          => '0',
        SRVAL_Q2          => '0',
        SRVAL_Q3          => '0',
        SRVAL_Q4          => '0'
      )
      PORT MAP (
        O            => OPEN,
        -- Q8 contains the first-received serial bit and is therefore vector bit 7.
        Q1           => s_parallel(index)(0),
        Q2           => s_parallel(index)(1),
        Q3           => s_parallel(index)(2),
        Q4           => s_parallel(index)(3),
        Q5           => s_parallel(index)(4),
        Q6           => s_parallel(index)(5),
        Q7           => s_parallel(index)(6),
        Q8           => s_parallel(index)(7),
        SHIFTOUT1    => OPEN,
        SHIFTOUT2    => OPEN,
        BITSLIP      => c_zero,
        CE1          => c_one,
        CE2          => c_one,
        CLK          => s_dco_p_io,
        CLKB         => s_dco_n_io,
        CLKDIV       => s_sample_clk,
        CLKDIVP      => c_zero,
        D            => s_serial(index),
        DDLY         => c_zero,
        DYNCLKDIVSEL => c_zero,
        DYNCLKSEL    => c_zero,
        OCLK         => c_zero,
        OCLKB        => c_zero,
        OFB          => c_zero,
        RST          => i_reset,
        SHIFTIN1     => c_zero,
        SHIFTIN2     => c_zero
    );
  END GENERATE gen_serdes;

  u_enc_ddr : ODDR
    GENERIC MAP (
      DDR_CLK_EDGE => "OPPOSITE_EDGE",
      INIT         => '0',
      SRTYPE       => "ASYNC"
    )
    PORT MAP (
      Q  => s_enc_out,
      C  => i_enc_clk,
      CE => c_one,
      D1 => c_one,
      D2 => c_zero,
      R  => i_reset,
      S  => c_zero
  );

  u_enc_out : OBUFDS
    GENERIC MAP (
      IOSTANDARD => "LVDS_25",
      SLEW       => "FAST"
    )
    PORT MAP (
      O  => o_adc_enc_p,
      OB => o_adc_enc_n,
      I  => s_enc_out
  );

END ARCHITECTURE struct;
