-- Author: Adam Taylor
-- Description: Aligns four deserialised ADC lanes using the 00001111 frame pattern.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

USE work.syzygy_adc_ltc226x_pkg.ALL;

ENTITY ltc226x_frame_align IS
  GENERIC (
    g_lock_cycles : t_lock_cycles_type := 4
  );
  PORT (
    i_clk            : IN  std_ulogic;
    i_reset_n        : IN  std_ulogic;
    i_frame_word     : IN  t_lane_word_type;
    i_ch1a_word      : IN  t_lane_word_type;
    i_ch1b_word      : IN  t_lane_word_type;
    i_ch2a_word      : IN  t_lane_word_type;
    i_ch2b_word      : IN  t_lane_word_type;
    o_ch1a_word      : OUT t_lane_word_type;
    o_ch1b_word      : OUT t_lane_word_type;
    o_ch2a_word      : OUT t_lane_word_type;
    o_ch2b_word      : OUT t_lane_word_type;
    o_sample_valid   : OUT std_ulogic;
    o_capture_locked : OUT std_ulogic
  );
END ENTITY ltc226x_frame_align;

ARCHITECTURE rtl OF ltc226x_frame_align IS

  SUBTYPE t_slip_type IS INTEGER RANGE -1 TO 7;
  SUBTYPE t_slip_count_type IS INTEGER RANGE 0 TO 7;
  SUBTYPE t_lock_count_type IS INTEGER RANGE 0 TO g_lock_cycles;

  SIGNAL s_frame_new    : t_lane_word_type;
  SIGNAL s_frame_old    : t_lane_word_type;
  SIGNAL s_ch1a_new     : t_lane_word_type;
  SIGNAL s_ch1a_old     : t_lane_word_type;
  SIGNAL s_ch1b_new     : t_lane_word_type;
  SIGNAL s_ch1b_old     : t_lane_word_type;
  SIGNAL s_ch2a_new     : t_lane_word_type;
  SIGNAL s_ch2a_old     : t_lane_word_type;
  SIGNAL s_ch2b_new     : t_lane_word_type;
  SIGNAL s_ch2b_old     : t_lane_word_type;
  SIGNAL s_slip         : t_slip_count_type;
  SIGNAL s_lock_count   : t_lock_count_type;
  SIGNAL s_decoded_slip : t_slip_type;
  SIGNAL s_locked       : std_ulogic;

  -- Decode the frame-word rotation into a software bit-slip count.
  FUNCTION decode_slip(i_frame : t_lane_word_type) RETURN t_slip_type IS
  BEGIN
    CASE i_frame IS
      WHEN "00001111" =>
        RETURN 0;
      WHEN "00011110" =>
        RETURN 1;
      WHEN "00111100" =>
        RETURN 2;
      WHEN "01111000" =>
        RETURN 3;
      WHEN "11110000" =>
        RETURN 4;
      WHEN "11100001" =>
        RETURN 5;
      WHEN "11000011" =>
        RETURN 6;
      WHEN "10000111" =>
        RETURN 7;
      WHEN OTHERS =>
        RETURN -1;
    END CASE;
  END FUNCTION decode_slip;

  -- Join adjacent deserialiser words at the selected serial-bit boundary.
  FUNCTION align_word(
      i_new_word : t_lane_word_type;
      i_old_word : t_lane_word_type;
      i_slip     : INTEGER RANGE 0 TO 7
    ) RETURN t_lane_word_type IS
    VARIABLE v_result : t_lane_word_type;
  BEGIN
    CASE i_slip IS
      WHEN 0 =>
        v_result := i_old_word;
      WHEN 1 =>
        v_result := i_new_word(0) & i_old_word(7 DOWNTO 1);
      WHEN 2 =>
        v_result := i_new_word(1 DOWNTO 0) & i_old_word(7 DOWNTO 2);
      WHEN 3 =>
        v_result := i_new_word(2 DOWNTO 0) & i_old_word(7 DOWNTO 3);
      WHEN 4 =>
        v_result := i_new_word(3 DOWNTO 0) & i_old_word(7 DOWNTO 4);
      WHEN 5 =>
        v_result := i_new_word(4 DOWNTO 0) & i_old_word(7 DOWNTO 5);
      WHEN 6 =>
        v_result := i_new_word(5 DOWNTO 0) & i_old_word(7 DOWNTO 6);
      WHEN OTHERS =>
        v_result := i_new_word(6 DOWNTO 0) & i_old_word(7);
    END CASE;

    RETURN v_result;
  END FUNCTION align_word;

BEGIN

  o_capture_locked <= s_locked;
  s_decoded_slip <= decode_slip(s_frame_old);

  -- Pipeline the ISERDES words, determine frame stability and align all lanes.
  p_align : PROCESS (i_clk, i_reset_n)
  BEGIN
    IF i_reset_n = '0' THEN
      s_frame_new <= (OTHERS => '0');
      s_frame_old <= (OTHERS => '0');
      s_ch1a_new <= (OTHERS => '0');
      s_ch1a_old <= (OTHERS => '0');
      s_ch1b_new <= (OTHERS => '0');
      s_ch1b_old <= (OTHERS => '0');
      s_ch2a_new <= (OTHERS => '0');
      s_ch2a_old <= (OTHERS => '0');
      s_ch2b_new <= (OTHERS => '0');
      s_ch2b_old <= (OTHERS => '0');
      s_slip <= t_slip_count_type'LOW;
      s_lock_count <= t_lock_count_type'LOW;
      s_locked <= '0';
      o_ch1a_word <= (OTHERS => '0');
      o_ch1b_word <= (OTHERS => '0');
      o_ch2a_word <= (OTHERS => '0');
      o_ch2b_word <= (OTHERS => '0');
      o_sample_valid <= '0';
    ELSIF RISING_EDGE(i_clk) THEN
      s_frame_new <= i_frame_word;
      s_frame_old <= s_frame_new;
      s_ch1a_new <= i_ch1a_word;
      s_ch1a_old <= s_ch1a_new;
      s_ch1b_new <= i_ch1b_word;
      s_ch1b_old <= s_ch1b_new;
      s_ch2a_new <= i_ch2a_word;
      s_ch2a_old <= s_ch2a_new;
      s_ch2b_new <= i_ch2b_word;
      s_ch2b_old <= s_ch2b_new;

      o_sample_valid <= '0';

      IF s_decoded_slip < 0 THEN
        s_lock_count <= t_lock_count_type'LOW;
        s_locked <= '0';
      ELSIF s_decoded_slip /= s_slip THEN
        s_slip <= s_decoded_slip;
        s_lock_count <= t_lock_count_type'LOW + 1;
        s_locked <= '0';
      ELSIF s_lock_count < g_lock_cycles THEN
        s_lock_count <= s_lock_count + 1;

        IF s_lock_count = g_lock_cycles - 1 THEN
          s_locked <= '1';
        END IF;
      ELSE
        s_locked <= '1';
      END IF;

      IF s_locked = '1' THEN
        o_ch1a_word <= align_word(s_ch1a_new, s_ch1a_old, s_slip);
        o_ch1b_word <= align_word(s_ch1b_new, s_ch1b_old, s_slip);
        o_ch2a_word <= align_word(s_ch2a_new, s_ch2a_old, s_slip);
        o_ch2b_word <= align_word(s_ch2b_new, s_ch2b_old, s_slip);
        o_sample_valid <= '1';
      END IF;
    END IF;
  END PROCESS p_align;

END ARCHITECTURE rtl;
