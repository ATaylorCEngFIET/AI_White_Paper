-- Author: Adam Taylor
-- Description: Single-byte, three-wire SPI controller for the AD911x DAC.

LIBRARY ieee;
USE ieee.std_logic_1164.ALL;

USE work.syzygy_dac_ad911x_pkg.ALL;

ENTITY ad911x_spi_master IS
  GENERIC (
    g_sclk_divisor : POSITIVE := 4
  );
  PORT (
    i_clk        : IN  std_ulogic;
    i_aresetn    : IN  std_ulogic;

    i_start      : IN  std_ulogic;
    i_read       : IN  std_ulogic;
    i_address    : IN  std_ulogic_vector(c_spi_address_width - 1 DOWNTO 0);
    i_write_data : IN  std_ulogic_vector(c_ad911x_reg_width - 1 DOWNTO 0);
    o_read_data  : OUT std_ulogic_vector(c_ad911x_reg_width - 1 DOWNTO 0);
    o_busy       : OUT std_ulogic;
    o_done       : OUT std_ulogic;

    o_sclk       : OUT std_ulogic;
    o_cs_n       : OUT std_ulogic;
    i_sdio       : IN  std_ulogic;
    o_sdio       : OUT std_ulogic;
    o_sdio_oe    : OUT std_ulogic
  );
END ENTITY ad911x_spi_master;

ARCHITECTURE rtl OF ad911x_spi_master IS

  SIGNAL s_active     : std_ulogic;
  SIGNAL s_read       : std_ulogic;
  SIGNAL s_sclk       : std_ulogic;
  SIGNAL s_cs_n       : std_ulogic;
  SIGNAL s_sdio       : std_ulogic;
  SIGNAL s_sdio_oe    : std_ulogic;
  SIGNAL s_done       : std_ulogic;
  SIGNAL s_tx_word    : t_spi_transaction_type;
  SIGNAL s_rx_byte    : t_register_byte_type;
  SIGNAL s_read_data  : t_register_byte_type;
  SIGNAL s_bit_index  : t_spi_bit_index_type;
  SIGNAL s_div_count  : NATURAL RANGE 0 TO g_sclk_divisor - 1;

BEGIN

  o_read_data <= s_read_data;
  o_busy <= s_active;
  o_done <= s_done;
  o_sclk <= s_sclk;
  o_cs_n <= s_cs_n;
  o_sdio <= s_sdio;
  o_sdio_oe <= s_sdio_oe;

  -- Execute one 16-bit AD911x instruction and data transaction.
  p_transfer : PROCESS(i_clk, i_aresetn)
  BEGIN
    IF i_aresetn = '0' THEN
      s_active <= '0';
      s_read <= '0';
      s_sclk <= '0';
      s_cs_n <= '1';
      s_sdio <= '0';
      s_sdio_oe <= '0';
      s_done <= '0';
      s_tx_word <= (OTHERS => '0');
      s_rx_byte <= (OTHERS => '0');
      s_read_data <= (OTHERS => '0');
      s_bit_index <= t_spi_bit_index_type'LOW;
      s_div_count <= NATURAL'LOW;
    ELSIF rising_edge(i_clk) THEN
      s_done <= '0';

      IF s_active = '0' THEN
        s_sclk <= '0';
        s_cs_n <= '1';
        s_sdio_oe <= '0';
        s_div_count <= NATURAL'LOW;

        IF i_start = '1' THEN
          s_active <= '1';
          s_read <= i_read;
          s_cs_n <= '0';
          s_sdio <= i_read;
          s_sdio_oe <= '1';
          s_tx_word <= i_read & "00" & i_address & i_write_data;
          s_rx_byte <= (OTHERS => '0');
          s_bit_index <= t_spi_bit_index_type'HIGH;
        END IF;
      ELSIF s_div_count = g_sclk_divisor - 1 THEN
        s_div_count <= NATURAL'LOW;

        IF s_sclk = '0' THEN
          s_sclk <= '1';

          IF (s_read = '1') AND (s_bit_index <= 7) THEN
            s_rx_byte <= s_rx_byte(c_ad911x_reg_width - 2 DOWNTO 0) & i_sdio;
          END IF;

          IF (s_read = '1') AND (s_bit_index = 8) THEN
            s_sdio_oe <= '0';
          END IF;
        ELSE
          s_sclk <= '0';

          IF s_bit_index = t_spi_bit_index_type'LOW THEN
            s_active <= '0';
            s_cs_n <= '1';
            s_sdio_oe <= '0';
            s_done <= '1';
            s_read_data <= s_rx_byte;
          ELSE
            s_bit_index <= s_bit_index - 1;

            IF (s_read = '0') OR (s_bit_index > 8) THEN
              s_sdio <= s_tx_word(s_bit_index - 1);
            END IF;
          END IF;
        END IF;
      ELSE
        s_div_count <= s_div_count + 1;
      END IF;
    END IF;
  END PROCESS p_transfer;

END ARCHITECTURE rtl;
