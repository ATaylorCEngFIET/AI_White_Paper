-- Author: Adam Taylor
-- Description: Selectable ramp, full-scale, and calibrated voltage-step generator.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

ENTITY step_counter IS
  GENERIC (
    g_clk_freq_hz     : INTEGER RANGE 1 TO 1_000_000_000 := 200000000;  -- Clock frequency in Hz
    g_data_width      : INTEGER RANGE 1 TO 30 := 16;         -- Counter width (16 bits)
    g_ramp_period_sec : INTEGER RANGE 1 TO 60 := 1;          -- Mode 0: complete triangle period
    g_output_mode     : INTEGER RANGE 0 TO 2 := 2;          -- 0 = triangle, 1 = full-scale levels, 2 = +/-1 V levels
    g_level_hold_sec  : INTEGER RANGE 1 TO 60 := 2;          -- Mode 1: hold time for each level
    g_voltage_hold_sec : INTEGER RANGE 1 TO 60 := 1          -- Mode 2: hold time for each voltage level
  );
  PORT (
    -- Clock and reset
    i_clk             : IN  std_ulogic;        -- System clock
    i_aresetn         : IN  std_ulogic;        -- Asynchronous active-low reset
    
    -- Control
    i_enable          : IN  std_ulogic;        -- Enable counter
    i_ready           : IN  std_ulogic;        -- Downstream ready (backpressure)
    
    -- Outputs
    o_count           : OUT std_ulogic_vector(g_data_width - 1 DOWNTO 0);
    o_count_valid     : OUT std_ulogic;        -- Held high until i_ready accepts o_count
    o_flag            : OUT std_ulogic         -- Single-clock pulse on each accepted count
  );
END ENTITY step_counter;

ARCHITECTURE rtl OF step_counter IS

  FUNCTION f_max (p_left, p_right : INTEGER RANGE 1 TO INTEGER'HIGH) RETURN INTEGER IS
  BEGIN
    IF p_left > p_right THEN
      RETURN p_left;
    ELSE
      RETURN p_right;
    END IF;
  END FUNCTION f_max;

  ----------------------------------------------------------------------------
  -- Constants
  ----------------------------------------------------------------------------
  -- Full-scale value
  CONSTANT c_full_scale     : unsigned(g_data_width - 1 DOWNTO 0) := (OTHERS => '1');
  
  -- Zero value
  CONSTANT c_zero           : unsigned(g_data_width - 1 DOWNTO 0) := (OTHERS => '0');

  -- Mid-scale value (0x8000 for the 16-bit TX project).
  CONSTANT c_mid_scale      : unsigned(g_data_width - 1 DOWNTO 0) :=
  shift_left(to_unsigned(1, g_data_width),
    g_data_width - 1);

  -- Calibrated DAC codes used by the bipolar voltage-step test pattern.
  CONSTANT c_neg_one_volt   : unsigned(g_data_width - 1 DOWNTO 0) :=
  resize(to_unsigned(16#7F33#, 16), g_data_width);
  CONSTANT c_zero_volt      : unsigned(g_data_width - 1 DOWNTO 0) :=
  resize(to_unsigned(16#8000#, 16), g_data_width);
  CONSTANT c_pos_one_volt   : unsigned(g_data_width - 1 DOWNTO 0) :=
  resize(to_unsigned(16#80CD#, 16), g_data_width);

  CONSTANT c_mode_ramp        : INTEGER RANGE 0 TO 2 := 0;
  CONSTANT c_mode_three_level : INTEGER RANGE 0 TO 2 := 1;
  CONSTANT c_mode_voltage_steps : INTEGER RANGE 0 TO 2 := 2;
  CONSTANT c_index_zero         : INTEGER RANGE 0 TO 2 := 0;
  CONSTANT c_index_one          : INTEGER RANGE 0 TO 2 := 1;
  CONSTANT c_index_two          : INTEGER RANGE 0 TO 2 := 2;
  
  -- A complete triangle has one transition for every increment and decrement.
  CONSTANT c_num_levels       : INTEGER RANGE 1 TO INTEGER'HIGH := 2**g_data_width;
  CONSTANT c_num_transitions  : INTEGER RANGE 1 TO INTEGER'HIGH := 2 * (c_num_levels - 1);
  CONSTANT c_period_clocks    : INTEGER RANGE 1 TO INTEGER'HIGH := g_clk_freq_hz * g_ramp_period_sec;
  CONSTANT c_level_hold_clocks : INTEGER RANGE 1 TO INTEGER'HIGH := g_clk_freq_hz * g_level_hold_sec;
  CONSTANT c_voltage_hold_clocks : INTEGER RANGE 1 TO INTEGER'HIGH := g_clk_freq_hz * g_voltage_hold_sec;
  CONSTANT c_max_hold_clocks  : INTEGER RANGE 1 TO INTEGER'HIGH := f_max(c_level_hold_clocks,
    c_voltage_hold_clocks);
  
  ----------------------------------------------------------------------------
  -- Signals
  ----------------------------------------------------------------------------
  SIGNAL s_phase_acc       : INTEGER RANGE 0 TO c_period_clocks - 1;
  SIGNAL s_level_hold_cnt  : INTEGER RANGE 0 TO c_max_hold_clocks - 1;
  SIGNAL s_level_index     : INTEGER RANGE 0 TO 2;
  SIGNAL s_output_value    : unsigned(g_data_width - 1 DOWNTO 0);
  SIGNAL s_direction_up    : std_ulogic;
  SIGNAL s_started         : std_ulogic;
  SIGNAL s_flag            : std_ulogic;
  SIGNAL s_count_valid     : std_ulogic;

BEGIN

  ASSERT g_output_mode = c_mode_ramp OR
  g_output_mode = c_mode_three_level OR
  g_output_mode = c_mode_voltage_steps
  REPORT "step_counter g_output_mode must be 0 (ramp), 1 (full-scale levels), or 2 (voltage steps)"
  SEVERITY FAILURE;

  ASSERT g_output_mode /= c_mode_voltage_steps OR g_data_width >= 16
  REPORT "step_counter voltage-step mode requires g_data_width >= 16"
  SEVERITY FAILURE;

  ASSERT g_level_hold_sec > 0 AND g_voltage_hold_sec > 0
  REPORT "step_counter hold times must be greater than zero"
  SEVERITY FAILURE;

  ASSERT g_output_mode /= c_mode_ramp OR
  c_period_clocks >= c_num_transitions
  REPORT "step_counter requires at least one clock per ramp transition"
  SEVERITY FAILURE;

  ----------------------------------------------------------------------------
  -- Triangle ramp and fractional step scheduler.
  --
  -- Adding c_num_transitions every usable clock and subtracting
  -- c_period_clocks on overflow generates exactly c_num_transitions events in
  -- c_period_clocks. The phase freezes while the receiver applies backpressure,
  -- so samples are never discarded and every accepted ramp remains contiguous.
  ----------------------------------------------------------------------------
  p_ramp : PROCESS (i_clk, i_aresetn)
  BEGIN
    IF i_aresetn = '0' THEN
      s_phase_acc    <= c_index_zero;
      s_level_hold_cnt <= c_index_zero;
      s_level_index  <= c_index_zero;
      IF g_output_mode = c_mode_voltage_steps THEN
        s_output_value <= c_neg_one_volt;
      ELSE
        s_output_value <= c_zero;
      END IF;
      s_direction_up <= '1';
      s_started      <= '0';
      s_flag         <= '0';
      s_count_valid  <= '0';
      
    ELSIF rising_edge(i_clk) THEN
      s_flag <= '0';
      
      IF i_enable = '0' THEN
        s_phase_acc    <= c_index_zero;
        s_level_hold_cnt <= c_index_zero;
        s_level_index  <= c_index_zero;
        IF g_output_mode = c_mode_voltage_steps THEN
          s_output_value <= c_neg_one_volt;
        ELSE
          s_output_value <= c_zero;
        END IF;
        s_direction_up <= '1';
        s_started      <= '0';
        s_count_valid  <= '0';
      ELSE
        -- Offer the initial pattern value immediately, holding it through
        -- backpressure.
        IF s_started = '0' THEN
          s_phase_acc    <= c_index_zero;
          s_level_hold_cnt <= c_index_zero;
          s_level_index  <= c_index_zero;
          IF g_output_mode = c_mode_voltage_steps THEN
            s_output_value <= c_neg_one_volt;
          ELSE
            s_output_value <= c_zero;
          END IF;
          s_direction_up <= '1';
          s_started      <= '1';
          s_count_valid  <= '1';
        ELSE
          IF s_count_valid = '1' AND i_ready = '1' THEN
            s_count_valid <= '0';
            s_flag        <= '1';
          END IF;

          IF g_output_mode = c_mode_ramp THEN
            -- Preserve every ramp sample by freezing its phase during
            -- backpressure.
            IF i_ready = '1' THEN
              IF s_phase_acc >= c_period_clocks - c_num_transitions THEN
                s_phase_acc   <= s_phase_acc + c_num_transitions - c_period_clocks;
                s_count_valid <= '1';

                IF s_direction_up = '1' THEN
                  s_output_value <= s_output_value + 1;
                  IF s_output_value = c_full_scale - 1 THEN
                    s_direction_up <= '0';
                  END IF;
                ELSE
                  s_output_value <= s_output_value - 1;
                  IF s_output_value = c_zero + 1 THEN
                    s_direction_up <= '1';
                  END IF;
                END IF;
              ELSE
                s_phase_acc <= s_phase_acc + c_num_transitions;
              END IF;
            END IF;
          ELSIF g_output_mode = c_mode_three_level THEN
            -- The three-level hold timer continues while ready is temporarily
            -- low. If a transition itself cannot be accepted, the new value
            -- remains asserted and its next two-second hold starts on
            -- acceptance.
            IF s_count_valid = '0' OR i_ready = '1' THEN
              IF s_level_hold_cnt = c_level_hold_clocks - 1 THEN
                s_level_hold_cnt <= c_index_zero;
                s_count_valid    <= '1';

                CASE s_level_index IS
                  WHEN 0 =>
                    s_output_value <= c_mid_scale;
                    s_level_index  <= c_index_one;
                  WHEN 1 =>
                    s_output_value <= c_full_scale;
                    s_level_index  <= c_index_two;
                  WHEN OTHERS =>
                    s_output_value <= c_zero;
                    s_level_index  <= c_index_zero;
                END CASE;
              ELSE
                s_level_hold_cnt <= s_level_hold_cnt + 1;
              END IF;
            END IF;
          ELSE
            -- Calibrated voltage steps: -1 V, 0 V, and +1 V. Each accepted
            -- value is separated from the next by exactly g_voltage_hold_sec.
            IF s_count_valid = '0' OR i_ready = '1' THEN
              IF s_level_hold_cnt = c_voltage_hold_clocks - 1 THEN
                s_level_hold_cnt <= c_index_zero;
                s_count_valid    <= '1';

                CASE s_level_index IS
                  WHEN 0 =>
                    s_output_value <= c_zero_volt;
                    s_level_index  <= c_index_one;
                  WHEN 1 =>
                    s_output_value <= c_pos_one_volt;
                    s_level_index  <= c_index_two;
                  WHEN OTHERS =>
                    s_output_value <= c_neg_one_volt;
                    s_level_index  <= c_index_zero;
                END CASE;
              ELSE
                s_level_hold_cnt <= s_level_hold_cnt + 1;
              END IF;
            END IF;
          END IF;
        END IF;
      END IF;
    END IF;
  END PROCESS p_ramp;

  ----------------------------------------------------------------------------
  -- Output Assignments
  ----------------------------------------------------------------------------
  o_count       <= std_ulogic_vector(s_output_value);
  o_count_valid <= s_count_valid;
  o_flag        <= s_flag;

END ARCHITECTURE rtl;
