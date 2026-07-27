-- Author: Adam Taylor
-- Description: IDELAY-trained 8b/10b LVDS receiver for separate clock and data fibres.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

USE work.lvds_8b10b_pkg.ALL;

LIBRARY unisim;
USE unisim.vcomponents.ALL;

-- IBUFDS used for LVDS_25 differential input
-- IDELAYE2 / IDELAYCTRL used for data-line eye-centring

ENTITY lvds_rx IS
  GENERIC (
    g_data_width      : INTEGER RANGE 1 TO 1024 := 16;         -- Parallel data width
    -- Number of recovered-clock cycles to sample per tap during the sweep.
    -- Larger = more confidence the tap is good, longer training.
    g_sample_window   : INTEGER RANGE 1 TO 65_535 := 256;
    -- Retained for block-design compatibility. Re-training is now initiated by
    -- the in-band K28.1 marker sent by the transmitter, not a free-running RX
    -- timer, so these two generics are not used by the receive datapath.
    g_clk_freq_hz     : INTEGER RANGE 1 TO 1_000_000_000 := 200_000_000;
    g_retrain_ms      : INTEGER RANGE 1 TO INTEGER'HIGH := 10_000
  );
  PORT (
    -- Clock and reset
    i_clk_200         : IN  std_ulogic;        -- 200 MHz system clock for output domain
    i_ref_clk_200     : IN  std_ulogic;        -- Stable 200 MHz reference for IDELAYCTRL
    -- Reference clock must run independently from the recovered link clock.
    -- This input must remain active during link loss and retraining.
    i_aresetn         : IN  std_ulogic;        -- Asynchronous active-low reset
    
    -- LVDS differential inputs
    i_lvds_data_p     : IN  std_ulogic;        -- LVDS data positive
    i_lvds_data_n     : IN  std_ulogic;        -- LVDS data negative
    i_lvds_clk_p      : IN  std_ulogic;        -- LVDS clock positive
    i_lvds_clk_n      : IN  std_ulogic;        -- LVDS clock negative
    
    -- Parallel data output (in i_clk_200 domain)
    o_data            : OUT std_ulogic_vector(g_data_width - 1 DOWNTO 0);
    o_data_valid      : OUT std_ulogic;        -- Data valid strobe
    
    -- Status
    o_eye_locked      : OUT std_ulogic;        -- IDELAY tap centred on eye
    o_sync_locked     : OUT std_ulogic         -- Sync header detected, aligned
  );
END ENTITY lvds_rx;

ARCHITECTURE rtl OF lvds_rx IS

  ----------------------------------------------------------------------------
  -- Constants
  ----------------------------------------------------------------------------
  -- Training preamble bytes (alternating, transition every bit)
  CONSTANT c_train_a      : std_ulogic_vector(7 DOWNTO 0) := x"55";
  CONSTANT c_train_b      : std_ulogic_vector(7 DOWNTO 0) := x"AA";
  -- IDELAYE2 has 32 taps (0..31) on 7-series
  CONSTANT c_max_tap      : INTEGER RANGE 0 TO 31 := 31;

  -- Registered decode-ROM result layout.
  CONSTANT c_dec_is_k      : INTEGER RANGE 0 TO 13 := 8;
  CONSTANT c_dec_valid     : INTEGER RANGE 0 TO 13 := 9;
  CONSTANT c_dec_legal_neg : INTEGER RANGE 0 TO 13 := 10;
  CONSTANT c_dec_legal_pos : INTEGER RANGE 0 TO 13 := 11;
  CONSTANT c_dec_next_neg  : INTEGER RANGE 0 TO 13 := 12;
  CONSTANT c_dec_next_pos  : INTEGER RANGE 0 TO 13 := 13;
  
  ----------------------------------------------------------------------------
  -- Types
  ----------------------------------------------------------------------------
  -- Eye-centring (training) state machine, runs in recovered-clock domain
  TYPE t_train_state_type IS (
      TR_RESET,           -- Hold, load tap 0
      TR_SETTLE,          -- Wait for IDELAY tap to settle after a load
      TR_SAMPLE,          -- Count training-byte matches at current tap
      TR_NEXT,            -- Record pass/fail, advance tap
      TR_CENTRE,          -- Compute centre of widest passing window, load it
      TR_DONE             -- Eye centred, release frame FSM
  );

  -- Frame reception state machine
  TYPE t_rx_state_type IS (
      ST_HUNT,            -- Sliding-window hunt for K28.5 comma
      ST_SYMBOL_LOW,      -- Collecting encoded low data byte
      ST_SYMBOL_HIGH,     -- Collecting encoded high data byte
      ST_SYNC             -- Expecting next K28.5 comma/header
  );

  SUBTYPE t_decode_word IS std_ulogic_vector(13 DOWNTO 0);
  TYPE t_decode_rom_type IS ARRAY (0 TO 1023) OF t_decode_word;
  
  ----------------------------------------------------------------------------
  -- Signals - LVDS differential input via IBUFDS
  ----------------------------------------------------------------------------
  SIGNAL s_lvds_data_se   : std_ulogic;       -- Data, single-ended, BEFORE delay
  SIGNAL s_lvds_data_dly  : std_ulogic;       -- Data, single-ended, AFTER IDELAY
  SIGNAL s_lvds_clk_se    : std_ulogic;       -- Clock, single-ended
  SIGNAL s_lvds_clk_bufg  : std_ulogic;       -- Recovered clock on global buffer
  SIGNAL s_rx_bit         : std_ulogic;       -- Rising-edge ILOGIC sample
  SIGNAL s_rx_bit_fall    : std_ulogic;       -- Falling-edge ILOGIC sample
  SIGNAL s_selected_bit   : std_ulogic;       -- Trained phase selection
  SIGNAL s_rx_reset_pipe  : std_ulogic_vector(1 DOWNTO 0);
  SIGNAL s_rx_resetn      : std_ulogic;
  SIGNAL s_rx_reset       : std_ulogic;

  ----------------------------------------------------------------------------
  -- Signals - IDELAYE2 control (recovered-clock domain)
  ----------------------------------------------------------------------------
  SIGNAL s_idelay_ld      : std_ulogic;                       -- Load tap value
  SIGNAL s_idelay_val     : std_logic_vector(4 DOWNTO 0);     -- Tap to load (0..31)
  -- Match the data type required by the UNISIM delay-control input.
  SIGNAL s_idelayctrl_rdy : std_ulogic;                       -- IDELAYCTRL ready
  SIGNAL s_idelay_rdy_meta : std_ulogic;
  SIGNAL s_idelay_rdy_sync : std_ulogic;
  SIGNAL s_idelayctrl_rst : std_ulogic;                       -- IDELAYCTRL reset (static net for RST port)
  SIGNAL s_idelay_rst_cnt : unsigned(3 DOWNTO 0);

  ----------------------------------------------------------------------------
  -- Signals - Eye-centring / training (recovered-clock domain)
  ----------------------------------------------------------------------------
  SIGNAL s_train_state    : t_train_state_type;
  SIGNAL s_tap            : unsigned(4 DOWNTO 0);             -- Current tap under test
  SIGNAL s_settle_cnt     : unsigned(3 DOWNTO 0);             -- IDELAY settle wait
  SIGNAL s_sample_cnt     : unsigned(15 DOWNTO 0);            -- Samples this tap
  SIGNAL s_train_shift    : std_ulogic_vector(7 DOWNTO 0);    -- Bit window for train check
  SIGNAL s_tap_pass       : std_ulogic_vector(0 TO 63);       -- rising taps 0..31, falling 32..63
  SIGNAL s_tap_fail_flag  : std_ulogic;                       -- Any mismatch seen at this tap
  SIGNAL s_eye_locked     : std_ulogic;                       -- Training complete
  SIGNAL s_train_request  : std_ulogic;                       -- K28.1 marker detected
  SIGNAL s_train_edge     : std_ulogic;                       -- Edge currently being swept
  SIGNAL s_sample_falling : std_ulogic;                       -- Edge selected for payload sampling
  -- Window-centre search registers
  SIGNAL s_win_start      : unsigned(5 DOWNTO 0);
  SIGNAL s_win_len        : unsigned(5 DOWNTO 0);
  SIGNAL s_best_start     : unsigned(5 DOWNTO 0);
  SIGNAL s_best_len       : unsigned(5 DOWNTO 0);
  SIGNAL s_scan_idx       : unsigned(6 DOWNTO 0);
  
  ----------------------------------------------------------------------------
  -- Signals - registered bit capture, symbol assembly and decode pipeline
  ----------------------------------------------------------------------------
  SIGNAL s_symbol_shift   : t_8b10b_symbol;
  SIGNAL s_bit_cnt        : unsigned(3 DOWNTO 0);
  SIGNAL s_symbol_aligned : std_ulogic;
  SIGNAL s_symbol_event   : t_8b10b_symbol;
  SIGNAL s_symbol_valid   : std_ulogic;
  SIGNAL s_decode_word    : t_decode_word;
  SIGNAL s_decode_valid   : std_ulogic;
  SIGNAL s_rehunt_req     : std_ulogic;
  SIGNAL s_state          : t_rx_state_type;
  SIGNAL s_data_low       : std_ulogic_vector(7 DOWNTO 0);
  SIGNAL s_sync_locked    : std_ulogic;
  SIGNAL s_running_disp   : std_ulogic;
  
  ----------------------------------------------------------------------------
  -- Signals - CDC (toggle-based, LVDS -> system clock)
  ----------------------------------------------------------------------------
  SIGNAL s_cdc_data       : std_ulogic_vector(g_data_width - 1 DOWNTO 0);
  SIGNAL s_cdc_toggle     : std_ulogic;
  SIGNAL s_cdc_toggle_meta : std_ulogic;
  SIGNAL s_cdc_toggle_sync : std_ulogic;
  SIGNAL s_cdc_toggle_d   : std_ulogic;
  SIGNAL s_output_data    : std_ulogic_vector(g_data_width - 1 DOWNTO 0);
  SIGNAL s_output_valid   : std_ulogic;
  SIGNAL s_sync_meta      : std_ulogic;
  SIGNAL s_sync_sync      : std_ulogic;
  SIGNAL s_eye_meta       : std_ulogic;
  SIGNAL s_eye_sync       : std_ulogic;

  ATTRIBUTE ASYNC_REG : STRING;
  ATTRIBUTE ASYNC_REG OF s_rx_reset_pipe : SIGNAL IS "TRUE";
  ATTRIBUTE ASYNC_REG OF s_idelay_rdy_meta : SIGNAL IS "TRUE";
  ATTRIBUTE ASYNC_REG OF s_idelay_rdy_sync : SIGNAL IS "TRUE";
  ATTRIBUTE ASYNC_REG OF s_cdc_toggle_meta : SIGNAL IS "TRUE";
  ATTRIBUTE ASYNC_REG OF s_cdc_toggle_sync : SIGNAL IS "TRUE";
  ATTRIBUTE ASYNC_REG OF s_sync_meta : SIGNAL IS "TRUE";
  ATTRIBUTE ASYNC_REG OF s_sync_sync : SIGNAL IS "TRUE";
  ATTRIBUTE ASYNC_REG OF s_eye_meta : SIGNAL IS "TRUE";
  ATTRIBUTE ASYNC_REG OF s_eye_sync : SIGNAL IS "TRUE";

  FUNCTION f_init_decode_rom RETURN t_decode_rom_type IS
    VARIABLE v_rom     : t_decode_rom_type := (OTHERS => (OTHERS => '0'));
    VARIABLE v_symbol  : t_8b10b_symbol;
    VARIABLE v_decoded : t_decoded_8b10b_type;
    VARIABLE v_is_k    : std_ulogic;
    SUBTYPE t_decode_index_type IS INTEGER RANGE 0 TO 1023;
  BEGIN
    FOR i IN t_decode_index_type LOOP
      v_symbol  := std_ulogic_vector(to_unsigned(i, 10));
      v_decoded := f_8b10b_decode(v_symbol);
      IF v_decoded.valid = '1' THEN
        v_is_k := v_decoded.is_k;
        v_rom(i)(7 DOWNTO 0) := v_decoded.data;
        v_rom(i)(c_dec_is_k)  := v_is_k;
        v_rom(i)(c_dec_valid) := '1';
        IF v_symbol = f_8b10b_encode(v_decoded.data, v_is_k, c_8b10b_rd_neg) THEN
          v_rom(i)(c_dec_legal_neg) := '1';
        END IF;
        IF v_symbol = f_8b10b_encode(v_decoded.data, v_is_k, c_8b10b_rd_pos) THEN
          v_rom(i)(c_dec_legal_pos) := '1';
        END IF;
        v_rom(i)(c_dec_next_neg) := f_8b10b_next_rd(v_symbol, c_8b10b_rd_neg);
        v_rom(i)(c_dec_next_pos) := f_8b10b_next_rd(v_symbol, c_8b10b_rd_pos);
      END IF;
    END LOOP;
    RETURN v_rom;
  END FUNCTION f_init_decode_rom;

  CONSTANT c_decode_rom : t_decode_rom_type := f_init_decode_rom;

BEGIN

  ----------------------------------------------------------------------------
  -- LVDS Differential Input Buffers
  ----------------------------------------------------------------------------
  u_ibufds_data : IBUFDS
    GENERIC MAP (
      CAPACITANCE     => "DONT_CARE",
      DIFF_TERM       => TRUE,
      DQS_BIAS        => "FALSE",
      IBUF_DELAY_VALUE => "0",
      IBUF_LOW_PWR    => TRUE,
      IFD_DELAY_VALUE => "AUTO",
      IOSTANDARD      => "LVDS_25"
    )
    PORT MAP (
      I  => i_lvds_data_p,
      IB => i_lvds_data_n,
      O  => s_lvds_data_se
  );

  u_ibufds_clk : IBUFDS
    GENERIC MAP (
      CAPACITANCE     => "DONT_CARE",
      DIFF_TERM       => TRUE,
      DQS_BIAS        => "FALSE",
      IBUF_DELAY_VALUE => "0",
      IBUF_LOW_PWR    => TRUE,
      IFD_DELAY_VALUE => "AUTO",
      IOSTANDARD      => "LVDS_25"
    )
    PORT MAP (
      I  => i_lvds_clk_p,
      IB => i_lvds_clk_n,
      O  => s_lvds_clk_se
  );

  -- Forwarded clock onto a global buffer for fabric distribution.
  u_bufg_clk : BUFG
    PORT MAP (
      I => s_lvds_clk_se,
      O => s_lvds_clk_bufg
  );

  ----------------------------------------------------------------------------
  -- IDELAYCTRL - calibrates the IDELAYE2 tap delay using the 200 MHz reference.
  -- REFCLK MUST be a stable, free-running 200 MHz independent of the link.
  ----------------------------------------------------------------------------
  -- Hold IDELAYCTRL in reset for sixteen reference-clock cycles after the
  -- external reset releases. This satisfies the reset-width requirement and
  -- ensures the reference MMCM is already stable.
  p_idelayctrl_reset : PROCESS (i_ref_clk_200, i_aresetn)
  BEGIN
    IF i_aresetn = '0' THEN
      s_idelay_rst_cnt <= (OTHERS => '0');
      s_idelayctrl_rst <= '1';
    ELSIF rising_edge(i_ref_clk_200) THEN
      IF s_idelay_rst_cnt /= "1111" THEN
        s_idelay_rst_cnt <= s_idelay_rst_cnt + 1;
        s_idelayctrl_rst <= '1';
      ELSE
        s_idelayctrl_rst <= '0';
      END IF;
    END IF;
  END PROCESS p_idelayctrl_reset;

  u_idelayctrl : IDELAYCTRL
    GENERIC MAP (
      SIM_DEVICE => "7SERIES"
    )
    PORT MAP (
      RDY    => s_idelayctrl_rdy,
      REFCLK => i_ref_clk_200,
      RST    => s_idelayctrl_rst
  );

  ----------------------------------------------------------------------------
  -- IDELAYE2 on the DATA line - VARIABLE mode, tap loaded from training FSM.
  -- This absorbs the static clock-to-data skew between the two fibres.
  -- ~78 ps/tap, 32 taps -> ~2.4 ns range, against a 5 ns bit period.
  ----------------------------------------------------------------------------
  u_idelay_data : IDELAYE2
    GENERIC MAP (
      IDELAY_TYPE           => "VAR_LOAD",     -- Tap loaded via CNTVALUEIN/LD
      DELAY_SRC             => "IDATAIN",
      IDELAY_VALUE          => 0,
      HIGH_PERFORMANCE_MODE => "TRUE",
      IS_C_INVERTED         => '0',
      IS_DATAIN_INVERTED    => '0',
      IS_IDATAIN_INVERTED   => '0',
      SIGNAL_PATTERN        => "DATA",
      REFCLK_FREQUENCY      => 200.0,
      CINVCTRL_SEL          => "FALSE",
      PIPE_SEL              => "FALSE"
    )
    PORT MAP (
      DATAOUT     => s_lvds_data_dly,
      C           => s_lvds_clk_bufg,
      CE          => '0',
      INC         => '0',
      DATAIN      => '0',
      IDATAIN     => s_lvds_data_se,
      LD          => s_idelay_ld,
      LDPIPEEN    => '0',
      CINVCTRL    => '0',
      CNTVALUEIN  => s_idelay_val,
      CNTVALUEOUT => OPEN,
      REGRST      => '0'
  );

  --------------------------------------------------------------------------
  -- Capture the delayed input in ILOGIC before it reaches the fabric. Only
  -- the rising-edge sample is used; Q2 is retained for a future dual-edge
  -- phase-selection extension.
  --------------------------------------------------------------------------
  s_rx_reset <= NOT s_rx_resetn;

  u_iddr_data : IDDR
    GENERIC MAP (
      DDR_CLK_EDGE => "OPPOSITE_EDGE",
      INIT_Q1      => '0',
      INIT_Q2       => '0',
      IS_C_INVERTED => '0',
      IS_D_INVERTED => '0',
      SRTYPE        => "ASYNC"
    )
    PORT MAP (
      Q1 => s_rx_bit,
      Q2 => s_rx_bit_fall,
      C  => s_lvds_clk_bufg,
      CE => '1',
      D  => s_lvds_data_dly,
      R  => s_rx_reset,
      S  => '0'
  );

  s_selected_bit <= s_rx_bit_fall WHEN s_sample_falling = '1' ELSE s_rx_bit;

  --------------------------------------------------------------------------
  -- Recovered-clock reset and IDELAYCTRL-ready synchronizers.
  --------------------------------------------------------------------------
  p_rx_reset_sync : PROCESS (s_lvds_clk_bufg, i_aresetn)
  BEGIN
    IF i_aresetn = '0' THEN
      s_rx_reset_pipe <= (OTHERS => '0');
    ELSIF rising_edge(s_lvds_clk_bufg) THEN
      s_rx_reset_pipe(0) <= '1';
      s_rx_reset_pipe(1) <= s_rx_reset_pipe(0);
    END IF;
  END PROCESS p_rx_reset_sync;

  s_rx_resetn <= s_rx_reset_pipe(1);

  p_idelay_rdy_sync : PROCESS (s_lvds_clk_bufg, s_rx_resetn)
  BEGIN
    IF s_rx_resetn = '0' THEN
      s_idelay_rdy_meta <= '0';
      s_idelay_rdy_sync <= '0';
    ELSIF rising_edge(s_lvds_clk_bufg) THEN
      s_idelay_rdy_meta <= s_idelayctrl_rdy;
      s_idelay_rdy_sync <= s_idelay_rdy_meta;
    END IF;
  END PROCESS p_idelay_rdy_sync;

  ----------------------------------------------------------------------------
  -- Eye-Centring (Training) Process
  -- Runs in the recovered-clock domain. Sweeps both IDDR sampling edges across
  -- IDELAY taps 0..31 against a
  -- transition-rich training preamble (0x55/0xAA repeating). For each tap it
  -- samples the data and checks the 8-bit window holds a valid training byte;
  -- any mismatch marks the tap as failing. After the sweep it finds the widest
  -- run of passing taps and loads its centre. Holds the frame FSM in reset
  -- (s_eye_locked = '0') until centred.
  --
  -- A failing edge (where the sampling point clips a bit transition) bounds the
  -- eye; the centre of the passing run is the safest sampling phase.
  ----------------------------------------------------------------------------
  p_train : PROCESS (s_lvds_clk_bufg, s_rx_resetn)
    VARIABLE v_byte      : std_ulogic_vector(7 DOWNTO 0);
    VARIABLE v_sample    : std_ulogic;
    VARIABLE v_candidate : INTEGER RANGE 0 TO 63;
    VARIABLE v_center    : INTEGER RANGE 0 TO 63;
  BEGIN
    IF s_rx_resetn = '0' THEN
      s_train_state   <= TR_RESET;
      s_tap           <= (OTHERS => '0');
      s_settle_cnt    <= (OTHERS => '0');
      s_sample_cnt    <= (OTHERS => '0');
      s_train_shift   <= (OTHERS => '0');
      s_tap_pass      <= (OTHERS => '0');
      s_tap_fail_flag <= '0';
      s_eye_locked    <= '0';
      s_train_edge    <= '0';
      s_sample_falling <= '0';
      s_idelay_ld     <= '0';
      s_idelay_val    <= (OTHERS => '0');
      s_win_start     <= (OTHERS => '0');
      s_win_len       <= (OTHERS => '0');
      s_best_start    <= (OTHERS => '0');
      s_best_len      <= (OTHERS => '0');
      s_scan_idx      <= (OTHERS => '0');

    ELSIF rising_edge(s_lvds_clk_bufg) THEN
      -- Default: no tap load pulse
      s_idelay_ld <= '0';
      IF s_train_edge = '1' THEN
        v_sample := s_rx_bit_fall;
      ELSE
        v_sample := s_rx_bit;
      END IF;
      -- Continuously shift the (delayed) data so the training window is current
      s_train_shift <= v_sample & s_train_shift(7 DOWNTO 1);

      CASE s_train_state IS

        --------------------------------------------------------------------
        -- Wait for IDELAYCTRL ready, then load tap 0 and begin the sweep.
        --------------------------------------------------------------------
        WHEN TR_RESET =>
          IF s_idelay_rdy_sync = '1' THEN
            s_tap        <= (OTHERS => '0');
            s_train_edge <= '0';
            s_idelay_val <= (OTHERS => '0');
            s_idelay_ld  <= '1';            -- Load tap 0
            s_settle_cnt <= (OTHERS => '0');
            s_train_state <= TR_SETTLE;
          END IF;

          --------------------------------------------------------------------
          -- Let the newly loaded tap settle before sampling.
          --------------------------------------------------------------------
        WHEN TR_SETTLE =>
          s_settle_cnt <= s_settle_cnt + 1;
          IF s_settle_cnt = "1111" THEN
            s_sample_cnt    <= (OTHERS => '0');
            s_tap_fail_flag <= '0';
            s_train_state   <= TR_SAMPLE;
          END IF;

          --------------------------------------------------------------------
          -- Sample for g_sample_window cycles at this tap. The 8-bit window
          -- must always read a valid training byte; record any mismatch.
          --------------------------------------------------------------------
        WHEN TR_SAMPLE =>
          v_byte := v_sample & s_train_shift(7 DOWNTO 1);
          -- Only test once the window is full (allow shift register to fill)
          IF s_sample_cnt > to_unsigned(8, 16) THEN
            IF v_byte /= c_train_a AND v_byte /= c_train_b THEN
              s_tap_fail_flag <= '1';
            END IF;
          END IF;

          IF s_sample_cnt = to_unsigned(g_sample_window - 1, 16) THEN
            s_train_state <= TR_NEXT;
          ELSE
            s_sample_cnt <= s_sample_cnt + 1;
          END IF;

          --------------------------------------------------------------------
          -- Record pass/fail for this tap, advance to the next or finish.
          --------------------------------------------------------------------
        WHEN TR_NEXT =>
          IF s_train_edge = '1' THEN
            v_candidate := 32 + to_integer(s_tap);
          ELSE
            v_candidate := to_integer(s_tap);
          END IF;
          s_tap_pass(v_candidate) <= NOT s_tap_fail_flag;

          IF s_tap = to_unsigned(c_max_tap, 5) THEN
            IF s_train_edge = '0' THEN
              -- Repeat all taps using the falling-edge IDDR sample.
              s_train_edge <= '1';
              s_tap        <= (OTHERS => '0');
              s_idelay_val <= (OTHERS => '0');
              s_idelay_ld  <= '1';
              s_settle_cnt <= (OTHERS => '0');
              s_train_state <= TR_SETTLE;
            ELSE
              -- Both sampling phases complete: prepare window scan.
              s_scan_idx   <= (OTHERS => '0');
              s_win_start  <= (OTHERS => '0');
              s_win_len    <= (OTHERS => '0');
              s_best_start <= (OTHERS => '0');
              s_best_len   <= (OTHERS => '0');
              s_train_state <= TR_CENTRE;
            END IF;
          ELSE
            s_tap        <= s_tap + 1;
            s_idelay_val <= std_logic_vector(s_tap + 1);
            s_idelay_ld  <= '1';
            s_settle_cnt <= (OTHERS => '0');
            s_train_state <= TR_SETTLE;
          END IF;

          --------------------------------------------------------------------
          -- Find the widest run of passing taps (one tap scanned per cycle),
          -- then load its centre and finish.
          --------------------------------------------------------------------
        WHEN TR_CENTRE =>
          IF s_scan_idx <= to_unsigned(63, s_scan_idx'LENGTH) THEN
            -- Do not allow a passing run to cross from rising candidates into
            -- falling candidates at index 32.
            IF s_scan_idx = to_unsigned(32, s_scan_idx'LENGTH) THEN
              IF s_tap_pass(32) = '1' THEN
                s_win_start <= to_unsigned(32, s_win_start'LENGTH);
                s_win_len   <= to_unsigned(1, s_win_len'LENGTH);
                IF s_best_len < 1 THEN
                  s_best_start <= to_unsigned(32, s_best_start'LENGTH);
                  s_best_len   <= to_unsigned(1, s_best_len'LENGTH);
                END IF;
              ELSE
                s_win_len <= (OTHERS => '0');
              END IF;
            ELSIF s_tap_pass(to_integer(s_scan_idx(5 DOWNTO 0))) = '1' THEN
              -- Extend current run (start a new one if length is zero)
              IF s_win_len = 0 THEN
                s_win_start <= s_scan_idx(5 DOWNTO 0);
              END IF;
              s_win_len <= s_win_len + 1;
              IF s_win_len + 1 > s_best_len THEN
                s_best_len <= s_win_len + 1;
                IF s_win_len /= 0 THEN
                  s_best_start <= s_win_start;
                ELSE
                  s_best_start <= s_scan_idx(5 DOWNTO 0);
                END IF;
              END IF;
            ELSE
              s_win_len <= (OTHERS => '0');
            END IF;
            s_scan_idx <= s_scan_idx + 1;
          ELSE
            -- Load centre of best run: start + len/2
            IF s_best_len = 0 THEN
              -- No passing tap found, usually because the TX preamble was not
              -- present while sweeping. Retry so hardware can recover when the
              -- transmitter is reset or sends a periodic preamble.
              s_idelay_val <= std_logic_vector(to_unsigned(c_max_tap / 2, 5));
              s_idelay_ld  <= '1';
              s_eye_locked <= '0';
              s_tap_pass   <= (OTHERS => '0');
              s_train_state <= TR_RESET;
            ELSE
              v_center := to_integer(s_best_start) + to_integer(s_best_len) / 2;
              IF v_center >= 32 THEN
                s_sample_falling <= '1';
                s_idelay_val <= std_logic_vector(to_unsigned(v_center - 32, 5));
              ELSE
                s_sample_falling <= '0';
                s_idelay_val <= std_logic_vector(to_unsigned(v_center, 5));
              END IF;
              s_idelay_ld  <= '1';
              s_eye_locked <= '1';
              s_train_state <= TR_DONE;
            END IF;
          END IF;

          --------------------------------------------------------------------
          -- Centred. Stay here; frame FSM is released by s_eye_locked.
          -- On a periodic re-train pulse, drop the lock and restart the sweep.
          --------------------------------------------------------------------
        WHEN TR_DONE =>
          IF s_train_request = '1' THEN
            s_eye_locked    <= '0';
            s_tap           <= (OTHERS => '0');
            s_tap_pass      <= (OTHERS => '0');
            s_tap_fail_flag <= '0';
            s_train_edge    <= '0';
            s_train_state   <= TR_RESET;
          END IF;

        WHEN OTHERS =>
          s_train_state <= TR_RESET;

      END CASE;
    END IF;
  END PROCESS p_train;

  --------------------------------------------------------------------------
  -- Bit capture and symbol alignment. Only this small process touches the
  -- serial stream. Once a K28.5 comma is found, a completed symbol is handed
  -- to the registered decode pipeline every ten clocks.
  --------------------------------------------------------------------------
  p_symbol_capture : PROCESS (s_lvds_clk_bufg, s_rx_resetn)
    VARIABLE v_symbol : t_8b10b_symbol;
  BEGIN
    IF s_rx_resetn = '0' THEN
      s_symbol_shift   <= (OTHERS => '0');
      s_bit_cnt        <= (OTHERS => '0');
      s_symbol_aligned <= '0';
      s_symbol_event   <= (OTHERS => '0');
      s_symbol_valid   <= '0';

    ELSIF rising_edge(s_lvds_clk_bufg) THEN
      v_symbol := s_selected_bit & s_symbol_shift(9 DOWNTO 1);
      s_symbol_shift <= v_symbol;
      s_symbol_valid <= '0';

      IF s_eye_locked = '0' THEN
        s_symbol_aligned <= '0';
        s_bit_cnt        <= (OTHERS => '0');
      ELSIF s_rehunt_req = '1' THEN
        s_symbol_aligned <= '0';
        s_bit_cnt        <= (OTHERS => '0');
      ELSIF s_symbol_aligned = '0' THEN
        IF f_8b10b_is_k28_5(v_symbol) THEN
          s_symbol_aligned <= '1';
          s_symbol_event   <= v_symbol;
          s_symbol_valid   <= '1';
          s_bit_cnt        <= (OTHERS => '0');
        END IF;
      ELSE
        IF s_bit_cnt = to_unsigned(9, s_bit_cnt'LENGTH) THEN
          s_symbol_event <= v_symbol;
          s_symbol_valid <= '1';
          s_bit_cnt      <= (OTHERS => '0');
        ELSE
          s_bit_cnt <= s_bit_cnt + 1;
        END IF;
      END IF;
    END IF;
  END PROCESS p_symbol_capture;

  --------------------------------------------------------------------------
  -- Synchronous 1024-entry decode lookup. The table is built at elaboration
  -- from the canonical codec functions, so runtime decoding is a registered
  -- ROM access instead of a 16/17-level combinational path.
  --------------------------------------------------------------------------
  p_decode_lookup : PROCESS (s_lvds_clk_bufg, s_rx_resetn)
  BEGIN
    IF s_rx_resetn = '0' THEN
      s_decode_word  <= (OTHERS => '0');
      s_decode_valid <= '0';
    ELSIF rising_edge(s_lvds_clk_bufg) THEN
      s_decode_valid <= s_symbol_valid;
      IF s_symbol_valid = '1' THEN
        s_decode_word <= c_decode_rom(to_integer(unsigned(s_symbol_event)));
      END IF;
    END IF;
  END PROCESS p_decode_lookup;

  --------------------------------------------------------------------------
  -- Frame handling consumes the registered decode result. A K28.1 ordered
  -- set is reserved as TRAIN_START; it immediately requests an eye sweep and
  -- removes the need for an independently timed RX retrain counter.
  --------------------------------------------------------------------------
  p_frame_rx : PROCESS (s_lvds_clk_bufg, s_rx_resetn)
    VARIABLE v_legal  : std_ulogic;
    VARIABLE v_next_rd : std_ulogic;
  BEGIN
    IF s_rx_resetn = '0' THEN
      s_state         <= ST_HUNT;
      s_data_low      <= (OTHERS => '0');
      s_sync_locked   <= '0';
      s_running_disp  <= c_8b10b_rd_neg;
      s_cdc_data      <= (OTHERS => '0');
      s_cdc_toggle    <= '0';
      s_rehunt_req    <= '0';
      s_train_request <= '0';

    ELSIF rising_edge(s_lvds_clk_bufg) THEN
      s_rehunt_req    <= '0';
      s_train_request <= '0';

      IF s_eye_locked = '0' THEN
        s_state        <= ST_HUNT;
        s_sync_locked  <= '0';
        s_running_disp <= c_8b10b_rd_neg;
      ELSIF s_decode_valid = '1' THEN
        IF s_running_disp = c_8b10b_rd_neg THEN
          v_legal   := s_decode_word(c_dec_legal_neg);
          v_next_rd := s_decode_word(c_dec_next_neg);
        ELSE
          v_legal   := s_decode_word(c_dec_legal_pos);
          v_next_rd := s_decode_word(c_dec_next_pos);
        END IF;

        -- Training marker takes priority in every aligned frame state.
        IF s_decode_word(c_dec_valid) = '1' AND
          s_decode_word(c_dec_is_k) = '1' AND
          s_decode_word(7 DOWNTO 0) = c_8b10b_k28_1 THEN
          s_train_request <= '1';
          s_rehunt_req    <= '1';
          s_sync_locked   <= '0';
          s_state         <= ST_HUNT;

        ELSE
          CASE s_state IS
            WHEN ST_HUNT =>
              IF s_decode_word(c_dec_valid) = '1' AND
                s_decode_word(c_dec_is_k) = '1' AND
                s_decode_word(7 DOWNTO 0) = c_8b10b_k28_5 THEN
                s_sync_locked <= '1';
                -- At acquisition the incoming disparity is unknown. Select
                -- the next disparity from the encoding that actually matched.
                IF s_decode_word(c_dec_legal_neg) = '1' THEN
                  s_running_disp <= s_decode_word(c_dec_next_neg);
                ELSE
                  s_running_disp <= s_decode_word(c_dec_next_pos);
                END IF;
                s_state <= ST_SYMBOL_LOW;
              END IF;

            WHEN ST_SYMBOL_LOW =>
              IF s_decode_word(c_dec_valid) = '1' AND v_legal = '1' AND
                s_decode_word(c_dec_is_k) = '0' THEN
                s_data_low     <= s_decode_word(7 DOWNTO 0);
                s_running_disp <= v_next_rd;
                s_state        <= ST_SYMBOL_HIGH;
              ELSIF s_decode_word(c_dec_valid) = '1' AND v_legal = '1' AND
                s_decode_word(c_dec_is_k) = '1' AND
                s_decode_word(7 DOWNTO 0) = c_8b10b_k28_5 THEN
                s_running_disp <= v_next_rd;
              ELSE
                s_sync_locked  <= '0';
                s_running_disp <= c_8b10b_rd_neg;
                s_rehunt_req   <= '1';
                s_state        <= ST_HUNT;
              END IF;

            WHEN ST_SYMBOL_HIGH =>
              IF s_decode_word(c_dec_valid) = '1' AND v_legal = '1' AND
                s_decode_word(c_dec_is_k) = '0' THEN
                s_cdc_data     <= s_decode_word(7 DOWNTO 0) & s_data_low;
                s_cdc_toggle   <= NOT s_cdc_toggle;
                s_running_disp <= v_next_rd;
                s_state        <= ST_SYNC;
              ELSIF s_decode_word(c_dec_valid) = '1' AND v_legal = '1' AND
                s_decode_word(c_dec_is_k) = '1' AND
                s_decode_word(7 DOWNTO 0) = c_8b10b_k28_5 THEN
                s_running_disp <= v_next_rd;
                s_state        <= ST_SYMBOL_LOW;
              ELSE
                s_sync_locked  <= '0';
                s_running_disp <= c_8b10b_rd_neg;
                s_rehunt_req   <= '1';
                s_state        <= ST_HUNT;
              END IF;

            WHEN ST_SYNC =>
              IF s_decode_word(c_dec_valid) = '1' AND v_legal = '1' AND
                s_decode_word(c_dec_is_k) = '1' AND
                s_decode_word(7 DOWNTO 0) = c_8b10b_k28_5 THEN
                s_running_disp <= v_next_rd;
                s_state        <= ST_SYMBOL_LOW;
              ELSE
                s_sync_locked  <= '0';
                s_running_disp <= c_8b10b_rd_neg;
                s_rehunt_req   <= '1';
                s_state        <= ST_HUNT;
              END IF;

            WHEN OTHERS =>
              s_rehunt_req <= '1';
              s_state      <= ST_HUNT;
          END CASE;
        END IF;
      END IF;
    END IF;
  END PROCESS p_frame_rx;

  ----------------------------------------------------------------------------
  -- Clock Domain Crossing - LVDS clock to i_clk_200
  -- Toggle-based synchroniser (robust against narrow pulses)
  ----------------------------------------------------------------------------
  p_cdc_sync : PROCESS (i_clk_200, i_aresetn)
  BEGIN
    IF i_aresetn = '0' THEN
      s_cdc_toggle_meta <= '0';
      s_cdc_toggle_sync <= '0';
      s_cdc_toggle_d    <= '0';
      s_output_data     <= (OTHERS => '0');
      s_output_valid    <= '0';
      s_sync_meta       <= '0';
      s_sync_sync       <= '0';
      s_eye_meta        <= '0';
      s_eye_sync        <= '0';
      
    ELSIF rising_edge(i_clk_200) THEN
      -- Two-stage synchroniser for toggle signal
      s_cdc_toggle_meta <= s_cdc_toggle;
      s_cdc_toggle_sync <= s_cdc_toggle_meta;
      s_cdc_toggle_d    <= s_cdc_toggle_sync;
      
      -- Synchronise status flags
      s_sync_meta <= s_sync_locked;
      s_sync_sync <= s_sync_meta;
      s_eye_meta  <= s_eye_locked;
      s_eye_sync  <= s_eye_meta;
      
      -- Detect toggle transition (new data available)
      s_output_valid <= '0';
      IF s_cdc_toggle_sync /= s_cdc_toggle_d THEN
        s_output_data  <= s_cdc_data;
        s_output_valid <= '1';
      END IF;
    END IF;
  END PROCESS p_cdc_sync;

  ----------------------------------------------------------------------------
  -- Output Assignments
  ----------------------------------------------------------------------------
  o_data        <= s_output_data;
  o_data_valid  <= s_output_valid;
  o_sync_locked <= s_sync_sync;
  o_eye_locked  <= s_eye_sync;

END ARCHITECTURE rtl;
