-- Author: Adam Taylor
-- Description: 8b/10b encode and decode helpers for the single-lane LVDS link.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;
USE ieee.numeric_std.ALL;

PACKAGE lvds_8b10b_pkg IS

  SUBTYPE t_8b10b_data   IS std_ulogic_vector(7 DOWNTO 0);
  SUBTYPE t_8b10b_symbol IS std_ulogic_vector(9 DOWNTO 0);

  TYPE t_decoded_8b10b_type IS RECORD
    data  : t_8b10b_data;
    is_k  : std_ulogic;
    valid : std_ulogic;
  END RECORD;

  CONSTANT c_8b10b_rd_neg : std_ulogic := '0';
  CONSTANT c_8b10b_rd_pos : std_ulogic := '1';
  CONSTANT c_8b10b_k28_1  : t_8b10b_data := x"3C";
  CONSTANT c_8b10b_k28_5  : t_8b10b_data := x"BC";

  FUNCTION f_8b10b_encode (
      CONSTANT c_data  : t_8b10b_data;
      CONSTANT c_is_k  : std_ulogic;
      CONSTANT c_rd_in : std_ulogic
    ) RETURN t_8b10b_symbol;

  FUNCTION f_8b10b_decode (
      CONSTANT c_symbol : t_8b10b_symbol
    ) RETURN t_decoded_8b10b_type;

  FUNCTION f_8b10b_next_rd (
      CONSTANT c_symbol : t_8b10b_symbol;
      CONSTANT c_rd_in  : std_ulogic
    ) RETURN std_ulogic;

  FUNCTION f_8b10b_is_k28_5 (
      CONSTANT c_symbol : t_8b10b_symbol
    ) RETURN BOOLEAN;

  FUNCTION f_8b10b_is_k28_1 (
      CONSTANT c_symbol : t_8b10b_symbol
    ) RETURN BOOLEAN;

END PACKAGE lvds_8b10b_pkg;

PACKAGE BODY lvds_8b10b_pkg IS

  SUBTYPE t_code6 IS std_ulogic_vector(5 DOWNTO 0); -- abcdei
  SUBTYPE t_code4 IS std_ulogic_vector(3 DOWNTO 0); -- fghj

  TYPE t_code6_pair_type IS ARRAY (0 TO 1) OF t_code6;
  TYPE t_code6_table_type IS ARRAY (0 TO 31) OF t_code6_pair_type;

  CONSTANT c_data_6b : t_code6_table_type := (
    0 => ("100111", "011000"),
    1 => ("011101", "100010"),
    2 => ("101101", "010010"),
    3 => ("110001", "110001"),
    4 => ("110101", "001010"),
    5 => ("101001", "101001"),
    6 => ("011001", "011001"),
    7 => ("111000", "000111"),
    8 => ("111001", "000110"),
    9 => ("100101", "100101"),
    10 => ("010101", "010101"),
    11 => ("110100", "110100"),
    12 => ("001101", "001101"),
    13 => ("101100", "101100"),
    14 => ("011100", "011100"),
    15 => ("010111", "101000"),
    16 => ("011011", "100100"),
    17 => ("100011", "100011"),
    18 => ("010011", "010011"),
    19 => ("110010", "110010"),
    20 => ("001011", "001011"),
    21 => ("101010", "101010"),
    22 => ("011010", "011010"),
    23 => ("111010", "000101"),
    24 => ("110011", "001100"),
    25 => ("100110", "100110"),
    26 => ("010110", "010110"),
    27 => ("110110", "001001"),
    28 => ("001110", "001110"),
    29 => ("101110", "010001"),
    30 => ("011110", "100001"),
    31 => ("101011", "010100")
  );

  FUNCTION f_rd_index (
      CONSTANT c_rd : std_ulogic
    ) RETURN INTEGER IS
  BEGIN
    IF c_rd = c_8b10b_rd_pos THEN
      RETURN 1;
    END IF;
    RETURN 0;
  END FUNCTION f_rd_index;

  FUNCTION f_count_ones (
      CONSTANT c_value : std_ulogic_vector
    ) RETURN NATURAL IS
    VARIABLE v_count : INTEGER RANGE 0 TO c_value'LENGTH := 0;
    SUBTYPE t_value_index_type IS INTEGER RANGE c_value'RANGE;
  BEGIN
    FOR i IN t_value_index_type LOOP
      IF c_value(i) = '1' THEN
        v_count := v_count + 1;
      END IF;
    END LOOP;
    RETURN v_count;
  END FUNCTION f_count_ones;

  FUNCTION f_next_rd_bits (
      CONSTANT c_value : std_ulogic_vector;
      CONSTANT c_rd_in : std_ulogic
    ) RETURN std_ulogic IS
    CONSTANT c_width : INTEGER RANGE 0 TO INTEGER'HIGH := c_value'LENGTH;
    VARIABLE v_ones  : INTEGER RANGE 0 TO INTEGER'HIGH;
  BEGIN
    v_ones := f_count_ones(c_value);
    IF v_ones * 2 > c_width THEN
      RETURN c_8b10b_rd_pos;
    ELSIF v_ones * 2 < c_width THEN
      RETURN c_8b10b_rd_neg;
    END IF;
    RETURN c_rd_in;
  END FUNCTION f_next_rd_bits;

  FUNCTION f_make_symbol (
      CONSTANT c_code6 : t_code6;
      CONSTANT c_code4 : t_code4
    ) RETURN t_8b10b_symbol IS
    VARIABLE v_symbol : t_8b10b_symbol;
  BEGIN
    -- Store in the same order the serializer shifts: a first through j last.
    v_symbol(0) := c_code6(5);
    v_symbol(1) := c_code6(4);
    v_symbol(2) := c_code6(3);
    v_symbol(3) := c_code6(2);
    v_symbol(4) := c_code6(1);
    v_symbol(5) := c_code6(0);
    v_symbol(6) := c_code4(3);
    v_symbol(7) := c_code4(2);
    v_symbol(8) := c_code4(1);
    v_symbol(9) := c_code4(0);
    RETURN v_symbol;
  END FUNCTION f_make_symbol;

  FUNCTION f_symbol_code6 (
      CONSTANT c_symbol : t_8b10b_symbol
    ) RETURN t_code6 IS
    VARIABLE v_code6 : t_code6;
  BEGIN
    v_code6(5) := c_symbol(0);
    v_code6(4) := c_symbol(1);
    v_code6(3) := c_symbol(2);
    v_code6(2) := c_symbol(3);
    v_code6(1) := c_symbol(4);
    v_code6(0) := c_symbol(5);
    RETURN v_code6;
  END FUNCTION f_symbol_code6;

  FUNCTION f_symbol_code4 (
      CONSTANT c_symbol : t_8b10b_symbol
    ) RETURN t_code4 IS
    VARIABLE v_code4 : t_code4;
  BEGIN
    v_code4(3) := c_symbol(6);
    v_code4(2) := c_symbol(7);
    v_code4(1) := c_symbol(8);
    v_code4(0) := c_symbol(9);
    RETURN v_code4;
  END FUNCTION f_symbol_code4;

  FUNCTION f_code4_data (
      CONSTANT c_y      : INTEGER RANGE 0 TO 7;
      CONSTANT c_x      : INTEGER RANGE 0 TO 31;
      CONSTANT c_rd_in  : std_ulogic
    ) RETURN t_code4 IS
  BEGIN
    IF c_rd_in = c_8b10b_rd_neg THEN
      CASE c_y IS
        WHEN 0 => RETURN "1011";
        WHEN 1 => RETURN "1001";
        WHEN 2 => RETURN "0101";
        WHEN 3 => RETURN "1100";
        WHEN 4 => RETURN "1101";
        WHEN 5 => RETURN "1010";
        WHEN 6 => RETURN "0110";
        WHEN 7 =>
          IF c_x = 17 OR c_x = 18 OR c_x = 20 THEN
            RETURN "0111";
          END IF;
          RETURN "1110";
        WHEN OTHERS => RETURN "0000";
      END CASE;
    ELSE
      CASE c_y IS
        WHEN 0 => RETURN "0100";
        WHEN 1 => RETURN "1001";
        WHEN 2 => RETURN "0101";
        WHEN 3 => RETURN "0011";
        WHEN 4 => RETURN "0010";
        WHEN 5 => RETURN "1010";
        WHEN 6 => RETURN "0110";
        WHEN 7 =>
          IF c_x = 11 OR c_x = 13 OR c_x = 14 THEN
            RETURN "1000";
          END IF;
          RETURN "0001";
        WHEN OTHERS => RETURN "0000";
      END CASE;
    END IF;
  END FUNCTION f_code4_data;

  FUNCTION f_decode_6b (
      CONSTANT c_code6 : t_code6
    ) RETURN INTEGER IS
  BEGIN
    CASE c_code6 IS
      WHEN "100111" | "011000" => RETURN 0;
      WHEN "011101" | "100010" => RETURN 1;
      WHEN "101101" | "010010" => RETURN 2;
      WHEN "110001"            => RETURN 3;
      WHEN "110101" | "001010" => RETURN 4;
      WHEN "101001"            => RETURN 5;
      WHEN "011001"            => RETURN 6;
      WHEN "111000" | "000111" => RETURN 7;
      WHEN "111001" | "000110" => RETURN 8;
      WHEN "100101"            => RETURN 9;
      WHEN "010101"            => RETURN 10;
      WHEN "110100"            => RETURN 11;
      WHEN "001101"            => RETURN 12;
      WHEN "101100"            => RETURN 13;
      WHEN "011100"            => RETURN 14;
      WHEN "010111" | "101000" => RETURN 15;
      WHEN "011011" | "100100" => RETURN 16;
      WHEN "100011"            => RETURN 17;
      WHEN "010011"            => RETURN 18;
      WHEN "110010"            => RETURN 19;
      WHEN "001011"            => RETURN 20;
      WHEN "101010"            => RETURN 21;
      WHEN "011010"            => RETURN 22;
      WHEN "111010" | "000101" => RETURN 23;
      WHEN "110011" | "001100" => RETURN 24;
      WHEN "100110"            => RETURN 25;
      WHEN "010110"            => RETURN 26;
      WHEN "110110" | "001001" => RETURN 27;
      WHEN "001110"            => RETURN 28;
      WHEN "101110" | "010001" => RETURN 29;
      WHEN "011110" | "100001" => RETURN 30;
      WHEN "101011" | "010100" => RETURN 31;
      WHEN OTHERS              => RETURN -1;
    END CASE;
  END FUNCTION f_decode_6b;

  FUNCTION f_decode_4b (
      CONSTANT c_code4 : t_code4
    ) RETURN INTEGER IS
  BEGIN
    CASE c_code4 IS
      WHEN "1011" | "0100" => RETURN 0;
      WHEN "1001"          => RETURN 1;
      WHEN "0101"          => RETURN 2;
      WHEN "1100" | "0011" => RETURN 3;
      WHEN "1101" | "0010" => RETURN 4;
      WHEN "1010"          => RETURN 5;
      WHEN "0110"          => RETURN 6;
      WHEN "1110" | "0001" | "0111" | "1000" =>
        RETURN 7;
      WHEN OTHERS =>
        RETURN -1;
    END CASE;
  END FUNCTION f_decode_4b;

  FUNCTION f_8b10b_encode (
      CONSTANT c_data  : t_8b10b_data;
      CONSTANT c_is_k  : std_ulogic;
      CONSTANT c_rd_in : std_ulogic
    ) RETURN t_8b10b_symbol IS
    VARIABLE v_x     : INTEGER RANGE 0 TO 31;
    VARIABLE v_y     : INTEGER RANGE 0 TO 7;
    VARIABLE v_code6 : t_code6;
    VARIABLE v_code4 : t_code4;
    VARIABLE v_rd    : std_ulogic;
  BEGIN
    IF c_is_k = '1' THEN
      -- K28.1 is the ordered-set marker immediately preceding a training
      -- preamble. K28.5 remains the normal frame comma/header.
      IF c_data = c_8b10b_k28_1 THEN
        IF c_rd_in = c_8b10b_rd_neg THEN
          RETURN f_make_symbol("001111", "1001");
        END IF;
        RETURN f_make_symbol("110000", "1001");
      END IF;

      IF c_rd_in = c_8b10b_rd_neg THEN
        RETURN f_make_symbol("001111", "1010");
      END IF;
      RETURN f_make_symbol("110000", "0101");
    END IF;

    v_x     := to_integer(unsigned(c_data(4 DOWNTO 0)));
    v_y     := to_integer(unsigned(c_data(7 DOWNTO 5)));
    v_code6 := c_data_6b(v_x)(f_rd_index(c_rd_in));
    v_rd    := f_next_rd_bits(v_code6, c_rd_in);
    v_code4 := f_code4_data(v_y, v_x, v_rd);

    RETURN f_make_symbol(v_code6, v_code4);
  END FUNCTION f_8b10b_encode;

  FUNCTION f_8b10b_decode (
      CONSTANT c_symbol : t_8b10b_symbol
    ) RETURN t_decoded_8b10b_type IS
    VARIABLE v_result : t_decoded_8b10b_type := (
      data  => (OTHERS => '0'),
      is_k  => '0',
      valid => '0'
    );
    VARIABLE v_x       : INTEGER RANGE -1 TO 31 := 0;
    VARIABLE v_y       : INTEGER RANGE -1 TO 7 := 0;
    VARIABLE v_data    : t_8b10b_data;
  BEGIN
    IF f_8b10b_is_k28_1(c_symbol) THEN
      v_result.data  := c_8b10b_k28_1;
      v_result.is_k  := '1';
      v_result.valid := '1';
      RETURN v_result;
    END IF;

    IF f_8b10b_is_k28_5(c_symbol) THEN
      v_result.data  := c_8b10b_k28_5;
      v_result.is_k  := '1';
      v_result.valid := '1';
      RETURN v_result;
    END IF;

    v_x := f_decode_6b(f_symbol_code6(c_symbol));
    v_y := f_decode_4b(f_symbol_code4(c_symbol));

    IF v_x >= 0 AND v_y >= 0 THEN
      v_data := std_ulogic_vector(to_unsigned(v_y, 3)) &
      std_ulogic_vector(to_unsigned(v_x, 5));

      -- Reject K-only or alternate encodings that split-decode as data.
      IF c_symbol = f_8b10b_encode(v_data, '0', c_8b10b_rd_neg) OR
        c_symbol = f_8b10b_encode(v_data, '0', c_8b10b_rd_pos) THEN
        v_result.data  := v_data;
        v_result.is_k  := '0';
        v_result.valid := '1';
      END IF;
    END IF;

    RETURN v_result;
  END FUNCTION f_8b10b_decode;

  FUNCTION f_8b10b_next_rd (
      CONSTANT c_symbol : t_8b10b_symbol;
      CONSTANT c_rd_in  : std_ulogic
    ) RETURN std_ulogic IS
  BEGIN
    RETURN f_next_rd_bits(c_symbol, c_rd_in);
  END FUNCTION f_8b10b_next_rd;

  FUNCTION f_8b10b_is_k28_5 (
      CONSTANT c_symbol : t_8b10b_symbol
    ) RETURN BOOLEAN IS
  BEGIN
    RETURN c_symbol = f_8b10b_encode(c_8b10b_k28_5, '1', c_8b10b_rd_neg) OR
    c_symbol = f_8b10b_encode(c_8b10b_k28_5, '1', c_8b10b_rd_pos);
  END FUNCTION f_8b10b_is_k28_5;

  FUNCTION f_8b10b_is_k28_1 (
      CONSTANT c_symbol : t_8b10b_symbol
    ) RETURN BOOLEAN IS
  BEGIN
    RETURN c_symbol = f_8b10b_encode(c_8b10b_k28_1, '1', c_8b10b_rd_neg) OR
    c_symbol = f_8b10b_encode(c_8b10b_k28_1, '1', c_8b10b_rd_pos);
  END FUNCTION f_8b10b_is_k28_1;

END PACKAGE BODY lvds_8b10b_pkg;
