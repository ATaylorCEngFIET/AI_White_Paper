-- Author: Adam Taylor
-- Description: Clock-forwarded 8b/10b LVDS transmitter with periodic link training.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

USE work.lvds_8b10b_pkg.ALL;

LIBRARY unisim;
USE unisim.vcomponents.ALL;

ENTITY lvds_tx_async IS
  GENERIC (
    g_data_width      : INTEGER RANGE 1 TO 1024 := 16;         -- Parallel data width
    -- Number of training-preamble bits sent each time the preamble runs. Must
    -- comfortably exceed the receiver's full IDELAY sweep duration:
    --   32 taps * (settle cycles + g_sample_window) + margin.
    -- Default sized for g_sample_window = 256 plus IDELAYCTRL startup time:
    -- 131072 bits is about 655 us at 200 Mb/s, giving comfortable hardware
    -- margin beyond the complete dual-edge/tap receive sweep.
    g_train_bits      : INTEGER RANGE 1 TO INTEGER'HIGH := 131072;
    -- Clock frequency of i_clk_200 in Hz, used to compute the re-train count.
    g_clk_freq_hz     : INTEGER RANGE 1 TO 1_000_000_000 := 200_000_000;
    -- Periodic re-train interval in milliseconds.  The transmitter sends the
    -- in-band K28.1 marker before the raw training preamble; the receiver starts
    -- its sweep from that marker and therefore needs no independently phased
    -- re-train timer.
    g_retrain_ms      : INTEGER RANGE 1 TO INTEGER'HIGH := 10_000
  );
  PORT (
    -- Clock and reset
    i_clk_200         : IN  std_ulogic;        -- 200 MHz serialisation clock
    i_aresetn         : IN  std_ulogic;        -- Asynchronous active-low reset
    
    -- Parallel data input
    i_data            : IN  std_ulogic_vector(g_data_width - 1 DOWNTO 0);
    i_data_valid      : IN  std_ulogic;        -- Data valid strobe
    o_data_ready      : OUT std_ulogic;        -- Ready for new data

    -- Status
    o_training        : OUT std_ulogic;        -- High while sending preamble

    -- LVDS differential outputs
    o_lvds_data_p     : OUT std_ulogic;        -- LVDS data positive
    o_lvds_data_n     : OUT std_ulogic;        -- LVDS data negative
    o_lvds_clk_p      : OUT std_ulogic;        -- LVDS clock positive
    o_lvds_clk_n      : OUT std_ulogic         -- LVDS clock negative
  );
END ENTITY lvds_tx_async;

ARCHITECTURE rtl OF lvds_tx_async IS

  CONSTANT c_max_frame       : INTEGER RANGE 1 TO 64 := 30;
  CONSTANT c_marker_symbols  : INTEGER RANGE 1 TO 8 := 4;

  TYPE t_tx_state_type IS (ST_MARKER, ST_TRAIN, ST_IDLE, ST_SHIFT);
  TYPE t_encode_state_type IS (ENC_IDLE, ENC_LOW, ENC_HIGH);

  TYPE t_frame_build_type IS RECORD
    bits     : std_ulogic_vector(c_max_frame - 1 DOWNTO 0);
    last_bit : unsigned(5 DOWNTO 0);
    rd       : std_ulogic;
  END RECORD;

  SIGNAL s_reset_pipe       : std_ulogic_vector(1 DOWNTO 0);
  SIGNAL s_resetn           : std_ulogic;
  SIGNAL s_oddr_rst         : std_ulogic;

  SIGNAL s_state            : t_tx_state_type;
  SIGNAL s_shift_reg        : std_ulogic_vector(c_max_frame - 1 DOWNTO 0);
  SIGNAL s_bit_cnt          : unsigned(5 DOWNTO 0);
  SIGNAL s_frame_len        : unsigned(5 DOWNTO 0);
  SIGNAL s_data_launch      : std_ulogic;
  SIGNAL s_data_fwd         : std_ulogic;
  SIGNAL s_clk_fwd          : std_ulogic;
  SIGNAL s_train_cnt        : unsigned(31 DOWNTO 0);
  SIGNAL s_marker_count     : unsigned(2 DOWNTO 0);
  SIGNAL s_training         : std_ulogic;
  SIGNAL s_running_disp     : std_ulogic;

  SIGNAL s_encode_state     : t_encode_state_type;
  SIGNAL s_encode_data      : std_ulogic_vector(g_data_width - 1 DOWNTO 0);
  SIGNAL s_frame_neg        : std_ulogic_vector(c_max_frame - 1 DOWNTO 0);
  SIGNAL s_frame_pos        : std_ulogic_vector(c_max_frame - 1 DOWNTO 0);
  SIGNAL s_header_rd_neg    : std_ulogic;
  SIGNAL s_header_rd_pos    : std_ulogic;
  SIGNAL s_low_rd_neg       : std_ulogic;
  SIGNAL s_low_rd_pos       : std_ulogic;
  SIGNAL s_frame_rd_neg     : std_ulogic;
  SIGNAL s_frame_rd_pos     : std_ulogic;
  SIGNAL s_frame_valid      : std_ulogic;
  SIGNAL s_frame_taken      : std_ulogic;
  SIGNAL s_data_ready       : std_ulogic;

  SIGNAL s_retrain_timer    : unsigned(63 DOWNTO 0);
  SIGNAL s_retrain_due      : std_ulogic;

  ATTRIBUTE ASYNC_REG : STRING;
  ATTRIBUTE ASYNC_REG OF s_reset_pipe : SIGNAL IS "TRUE";

  FUNCTION f_retrain_cycles RETURN unsigned IS
    VARIABLE v_ms   : unsigned(63 DOWNTO 0);
    VARIABLE v_freq : unsigned(63 DOWNTO 0);
  BEGIN
    v_ms   := to_unsigned(g_retrain_ms, 64);
    v_freq := to_unsigned(g_clk_freq_hz, 64);
    RETURN resize((v_ms * v_freq) / to_unsigned(1000, 64), 64);
  END FUNCTION;

  CONSTANT c_retrain_cycles : unsigned(63 DOWNTO 0) := f_retrain_cycles;

  FUNCTION f_control_frame (
      CONSTANT c_control : t_8b10b_data;
      CONSTANT c_rd_in   : std_ulogic
    ) RETURN t_frame_build_type IS
    VARIABLE v_frame  : t_frame_build_type;
    VARIABLE v_symbol : t_8b10b_symbol;
  BEGIN
    v_frame.bits     := (OTHERS => '0');
    v_frame.last_bit := to_unsigned(9, v_frame.last_bit'LENGTH);
    v_symbol         := f_8b10b_encode(c_control, '1', c_rd_in);
    v_frame.bits(9 DOWNTO 0) := v_symbol;
    v_frame.rd       := f_8b10b_next_rd(v_symbol, c_rd_in);
    RETURN v_frame;
  END FUNCTION f_control_frame;

BEGIN

  --------------------------------------------------------------------------
  -- Asynchronous assertion, synchronous release in the TX clock domain.
  --------------------------------------------------------------------------
  p_reset_sync : PROCESS (i_clk_200, i_aresetn)
  BEGIN
    IF i_aresetn = '0' THEN
      s_reset_pipe <= (OTHERS => '0');
    ELSIF rising_edge(i_clk_200) THEN
      s_reset_pipe(0) <= '1';
      s_reset_pipe(1) <= s_reset_pipe(0);
    END IF;
  END PROCESS p_reset_sync;

  s_resetn   <= s_reset_pipe(1);
  s_oddr_rst <= NOT s_resetn;

  --------------------------------------------------------------------------
  -- Three-stage frame encoder. Both possible input-disparity variants are
  -- prepared so the serializer can select the correct one at a frame boundary
  -- without placing the encoder on a half-cycle path.
  --------------------------------------------------------------------------
  p_frame_encoder : PROCESS (i_clk_200, s_resetn)
    VARIABLE v_symbol_neg : t_8b10b_symbol;
    VARIABLE v_symbol_pos : t_8b10b_symbol;
  BEGIN
    IF s_resetn = '0' THEN
      s_encode_state  <= ENC_IDLE;
      s_encode_data   <= (OTHERS => '0');
      s_frame_neg     <= (OTHERS => '0');
      s_frame_pos     <= (OTHERS => '0');
      s_header_rd_neg <= c_8b10b_rd_neg;
      s_header_rd_pos <= c_8b10b_rd_pos;
      s_low_rd_neg    <= c_8b10b_rd_neg;
      s_low_rd_pos    <= c_8b10b_rd_pos;
      s_frame_rd_neg  <= c_8b10b_rd_neg;
      s_frame_rd_pos  <= c_8b10b_rd_pos;
      s_frame_valid   <= '0';
      s_data_ready    <= '0';
      s_retrain_timer <= (OTHERS => '0');
      s_retrain_due   <= '0';

    ELSIF rising_edge(i_clk_200) THEN
      IF s_training = '1' THEN
        s_retrain_timer <= (OTHERS => '0');
        s_retrain_due   <= '0';
      ELSIF s_retrain_timer >= c_retrain_cycles - 1 THEN
        s_retrain_timer <= (OTHERS => '0');
        s_retrain_due   <= '1';
      ELSE
        s_retrain_timer <= s_retrain_timer + 1;
      END IF;

      IF s_frame_taken = '1' THEN
        s_frame_valid <= '0';
      END IF;

      IF s_training = '1' THEN
        s_data_ready <= '0';
      ELSE
        CASE s_encode_state IS
          WHEN ENC_IDLE =>
            IF s_frame_valid = '0' THEN
              s_data_ready <= '1';
              IF i_data_valid = '1' AND s_data_ready = '1' THEN
                s_data_ready  <= '0';
                s_encode_data <= i_data;
                s_frame_neg   <= (OTHERS => '0');
                s_frame_pos   <= (OTHERS => '0');

                v_symbol_neg := f_8b10b_encode(c_8b10b_k28_5, '1', c_8b10b_rd_neg);
                v_symbol_pos := f_8b10b_encode(c_8b10b_k28_5, '1', c_8b10b_rd_pos);
                s_frame_neg(9 DOWNTO 0) <= v_symbol_neg;
                s_frame_pos(9 DOWNTO 0) <= v_symbol_pos;
                s_header_rd_neg <= f_8b10b_next_rd(v_symbol_neg, c_8b10b_rd_neg);
                s_header_rd_pos <= f_8b10b_next_rd(v_symbol_pos, c_8b10b_rd_pos);
                s_encode_state <= ENC_LOW;
              END IF;
            ELSE
              s_data_ready <= '0';
            END IF;

          WHEN ENC_LOW =>
            v_symbol_neg := f_8b10b_encode(s_encode_data(7 DOWNTO 0), '0', s_header_rd_neg);
            v_symbol_pos := f_8b10b_encode(s_encode_data(7 DOWNTO 0), '0', s_header_rd_pos);
            s_frame_neg(19 DOWNTO 10) <= v_symbol_neg;
            s_frame_pos(19 DOWNTO 10) <= v_symbol_pos;
            s_low_rd_neg <= f_8b10b_next_rd(v_symbol_neg, s_header_rd_neg);
            s_low_rd_pos <= f_8b10b_next_rd(v_symbol_pos, s_header_rd_pos);
            s_encode_state <= ENC_HIGH;

          WHEN ENC_HIGH =>
            v_symbol_neg := f_8b10b_encode(s_encode_data(15 DOWNTO 8), '0', s_low_rd_neg);
            v_symbol_pos := f_8b10b_encode(s_encode_data(15 DOWNTO 8), '0', s_low_rd_pos);
            s_frame_neg(29 DOWNTO 20) <= v_symbol_neg;
            s_frame_pos(29 DOWNTO 20) <= v_symbol_pos;
            s_frame_rd_neg <= f_8b10b_next_rd(v_symbol_neg, s_low_rd_neg);
            s_frame_rd_pos <= f_8b10b_next_rd(v_symbol_pos, s_low_rd_pos);
            s_frame_valid  <= '1';
            s_encode_state <= ENC_IDLE;

          WHEN OTHERS =>
            s_encode_state <= ENC_IDLE;
        END CASE;
      END IF;
    END IF;
  END PROCESS p_frame_encoder;

  --------------------------------------------------------------------------
  -- Rising-edge serializer. s_data_launch is sampled by the data ODDR on the
  -- falling edge, keeping the serial data transition in OLOGIC and centred
  -- between receiver rising-edge samples.
  --------------------------------------------------------------------------
  p_tx_fsm : PROCESS (i_clk_200, s_resetn)
    VARIABLE v_next_frame : t_frame_build_type;
  BEGIN
    IF s_resetn = '0' THEN
      v_next_frame := f_control_frame(c_8b10b_k28_1, c_8b10b_rd_neg);
      s_state        <= ST_MARKER;
      s_shift_reg    <= v_next_frame.bits;
      s_bit_cnt      <= (OTHERS => '0');
      s_frame_len    <= v_next_frame.last_bit;
      s_data_launch  <= '0';
      s_train_cnt    <= (OTHERS => '0');
      s_marker_count <= (OTHERS => '0');
      s_training     <= '1';
      s_running_disp <= v_next_frame.rd;
      s_frame_taken  <= '0';

    ELSIF rising_edge(i_clk_200) THEN
      s_frame_taken <= '0';

      CASE s_state IS
        WHEN ST_MARKER =>
          s_training    <= '1';
          s_data_launch <= s_shift_reg(0);
          s_shift_reg   <= '0' & s_shift_reg(c_max_frame - 1 DOWNTO 1);

          IF s_bit_cnt >= to_unsigned(9, s_bit_cnt'LENGTH) THEN
            s_bit_cnt <= (OTHERS => '0');
            IF s_marker_count = to_unsigned(c_marker_symbols - 1, s_marker_count'LENGTH) THEN
              s_train_cnt <= (OTHERS => '0');
              s_state     <= ST_TRAIN;
            ELSE
              v_next_frame := f_control_frame(c_8b10b_k28_1, s_running_disp);
              s_shift_reg    <= v_next_frame.bits;
              s_running_disp <= v_next_frame.rd;
              s_marker_count <= s_marker_count + 1;
            END IF;
          ELSE
            s_bit_cnt <= s_bit_cnt + 1;
          END IF;

        WHEN ST_TRAIN =>
          s_training    <= '1';
          s_data_launch <= s_train_cnt(0);
          IF s_train_cnt = to_unsigned(g_train_bits - 1, s_train_cnt'LENGTH) THEN
            s_training     <= '0';
            s_running_disp <= c_8b10b_rd_neg;
            s_state        <= ST_IDLE;
          ELSE
            s_train_cnt <= s_train_cnt + 1;
          END IF;

        WHEN ST_IDLE =>
          IF s_retrain_due = '1' THEN
            v_next_frame := f_control_frame(c_8b10b_k28_1, s_running_disp);
            s_shift_reg    <= v_next_frame.bits;
            s_frame_len    <= v_next_frame.last_bit;
            s_running_disp <= v_next_frame.rd;
            s_bit_cnt      <= (OTHERS => '0');
            s_marker_count <= (OTHERS => '0');
            s_training     <= '1';
            s_state        <= ST_MARKER;
          ELSIF s_frame_valid = '1' THEN
            IF s_running_disp = c_8b10b_rd_neg THEN
              s_shift_reg    <= s_frame_neg;
              s_running_disp <= s_frame_rd_neg;
            ELSE
              s_shift_reg    <= s_frame_pos;
              s_running_disp <= s_frame_rd_pos;
            END IF;
            s_frame_len   <= to_unsigned(29, s_frame_len'LENGTH);
            s_bit_cnt     <= (OTHERS => '0');
            s_frame_taken <= '1';
            s_state       <= ST_SHIFT;
          ELSE
            v_next_frame := f_control_frame(c_8b10b_k28_5, s_running_disp);
            s_shift_reg    <= v_next_frame.bits;
            s_frame_len    <= v_next_frame.last_bit;
            s_running_disp <= v_next_frame.rd;
            s_bit_cnt      <= (OTHERS => '0');
            s_state        <= ST_SHIFT;
          END IF;

        WHEN ST_SHIFT =>
          s_data_launch <= s_shift_reg(0);
          s_shift_reg   <= '0' & s_shift_reg(c_max_frame - 1 DOWNTO 1);

          IF s_bit_cnt >= s_frame_len THEN
            s_bit_cnt <= (OTHERS => '0');
            IF s_retrain_due = '1' THEN
              v_next_frame := f_control_frame(c_8b10b_k28_1, s_running_disp);
              s_shift_reg    <= v_next_frame.bits;
              s_frame_len    <= v_next_frame.last_bit;
              s_running_disp <= v_next_frame.rd;
              s_marker_count <= (OTHERS => '0');
              s_training     <= '1';
              s_state        <= ST_MARKER;
            ELSIF s_frame_valid = '1' THEN
              IF s_running_disp = c_8b10b_rd_neg THEN
                s_shift_reg    <= s_frame_neg;
                s_running_disp <= s_frame_rd_neg;
              ELSE
                s_shift_reg    <= s_frame_pos;
                s_running_disp <= s_frame_rd_pos;
              END IF;
              s_frame_len   <= to_unsigned(29, s_frame_len'LENGTH);
              s_frame_taken <= '1';
            ELSE
              v_next_frame := f_control_frame(c_8b10b_k28_5, s_running_disp);
              s_shift_reg    <= v_next_frame.bits;
              s_frame_len    <= v_next_frame.last_bit;
              s_running_disp <= v_next_frame.rd;
            END IF;
          ELSE
            s_bit_cnt <= s_bit_cnt + 1;
          END IF;

        WHEN OTHERS =>
          s_state <= ST_IDLE;
      END CASE;
    END IF;
  END PROCESS p_tx_fsm;

  --------------------------------------------------------------------------
  -- Data and clock share OLOGIC resources and the same TX clock. The data
  -- ODDR holds the current bit across the rising edge and launches the next
  -- bit on the falling edge.
  --------------------------------------------------------------------------
  u_oddr_data : ODDR
    GENERIC MAP (
      DDR_CLK_EDGE => "OPPOSITE_EDGE",
      INIT           => '0',
      IS_C_INVERTED  => '0',
      IS_D1_INVERTED => '0',
      IS_D2_INVERTED => '0',
      SRTYPE         => "ASYNC"
    )
    PORT MAP (
      Q  => s_data_fwd,
      C  => i_clk_200,
      CE => '1',
      D1 => s_data_launch,
      D2 => s_data_launch,
      R  => s_oddr_rst,
      S  => '0'
  );

  u_obufds_data : OBUFDS
    GENERIC MAP (
      CAPACITANCE => "DONT_CARE",
      IOSTANDARD  => "LVDS_25",
      SLEW        => "SLOW"
    )
    PORT MAP (
      I  => s_data_fwd,
      O  => o_lvds_data_p,
      OB => o_lvds_data_n
  );

  u_oddr_clk : ODDR
    GENERIC MAP (
      DDR_CLK_EDGE => "OPPOSITE_EDGE",
      INIT           => '0',
      IS_C_INVERTED  => '0',
      IS_D1_INVERTED => '0',
      IS_D2_INVERTED => '0',
      SRTYPE         => "ASYNC"
    )
    PORT MAP (
      Q  => s_clk_fwd,
      C  => i_clk_200,
      CE => '1',
      D1 => '1',
      D2 => '0',
      R  => s_oddr_rst,
      S  => '0'
  );

  u_obufds_clk : OBUFDS
    GENERIC MAP (
      CAPACITANCE => "DONT_CARE",
      IOSTANDARD  => "LVDS_25",
      SLEW        => "SLOW"
    )
    PORT MAP (
      I  => s_clk_fwd,
      O  => o_lvds_clk_p,
      OB => o_lvds_clk_n
  );

  o_data_ready <= s_data_ready;
  o_training   <= s_training;

END ARCHITECTURE rtl;
