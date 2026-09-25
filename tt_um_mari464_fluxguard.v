/*
 * FluxGuard ASIC - Monitor de sobrecorriente y sobretemperatura
 * Tiny Tapeout (SkyWater 130 nm)
 *
 * El ESP32 escribe lecturas de 8 bits por un bus paralelo:
 *   ui_in[7:0]  DATA
 *   uio_in[1:0] ADDR  00 corriente (0.25 A/LSB)   01 temperatura cable (1 C/LSB)
 *                     10 umbral corriente         11 umbral temperatura
 *   uio_in[2]   WR    flanco de subida = escribir (mantener DATA/ADDR mientras WR=1)
 *   uio_in[3]   CLR   flanco de subida = borrar alarma memorizada
 *
 * Salidas:
 *   uo_out[0] ALERT   (LED / IRQ) sobrecorriente o sobretemperatura activa
 *   uo_out[1] OVER_I
 *   uo_out[2] OVER_T
 *   uo_out[3] UART_TX 115200 8N1 a 10 MHz
 *   uo_out[4] LATCHED alarma memorizada hasta CLR
 *   uo_out[5] UART_BUSY
 *   uo_out[6] HEARTBEAT
 *
 * Trama UART (se envia al escribir una lectura o al cambiar el estado):
 *   0xA5, CORRIENTE, TEMPERATURA, FLAGS, CHECKSUM (CORRIENTE ^ TEMPERATURA ^ FLAGS)
 *   FLAGS = {5'b0, LATCHED, OVER_T, OVER_I}
 */

`default_nettype none

module tt_um_mari464_fluxguard #(
    parameter       CLKS_PER_BIT = 87,     // 10 MHz / 115200 baud
    parameter       HB_BIT       = 22,     // latido ~1.2 Hz a 10 MHz
    parameter [7:0] TH_I_DEF     = 8'd100, // 25.0 A
    parameter [7:0] TH_T_DEF     = 8'd60,  // 60 C
    parameter [7:0] HYST         = 8'd4    // 1 A / 4 C de histeresis
) (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // ---------------- Bus de escritura (entradas asincronas) ----------------
  wire [7:0] bus_data = ui_in;
  wire [1:0] bus_addr = uio_in[1:0];

  reg [2:0] wr_s, clr_s;
  always @(posedge clk) begin
    if (!rst_n) begin
      wr_s  <= 3'b000;
      clr_s <= 3'b000;
    end else begin
      wr_s  <= {wr_s[1:0], uio_in[2]};
      clr_s <= {clr_s[1:0], uio_in[3]};
    end
  end
  wire wr_edge  = wr_s[1] & ~wr_s[2];
  wire clr_edge = clr_s[1] & ~clr_s[2];

  // ---------------- Registros de lectura y umbrales ----------------
  reg [7:0] i_val, t_val, th_i, th_t;
  always @(posedge clk) begin
    if (!rst_n) begin
      i_val <= 8'd0;
      t_val <= 8'd0;
      th_i  <= TH_I_DEF;
      th_t  <= TH_T_DEF;
    end else if (wr_edge) begin
      case (bus_addr)
        2'd0: i_val <= bus_data;
        2'd1: t_val <= bus_data;
        2'd2: th_i  <= bus_data;
        2'd3: th_t  <= bus_data;
      endcase
    end
  end

  // ---------------- Comparadores con histeresis ----------------
  // Se activa al superar el umbral y se desactiva al bajar de (umbral - HYST)
  reg over_i, over_t, latched;
  wire over_i_next = (i_val > th_i) |
                     (over_i & (({1'b0, i_val} + {1'b0, HYST}) > {1'b0, th_i}));
  wire over_t_next = (t_val > th_t) |
                     (over_t & (({1'b0, t_val} + {1'b0, HYST}) > {1'b0, th_t}));

  always @(posedge clk) begin
    if (!rst_n) begin
      over_i  <= 1'b0;
      over_t  <= 1'b0;
      latched <= 1'b0;
    end else begin
      over_i <= over_i_next;
      over_t <= over_t_next;
      // CLR no borra la alarma mientras la condicion siga activa
      if (over_i_next | over_t_next) latched <= 1'b1;
      else if (clr_edge)             latched <= 1'b0;
    end
  end

  wire       alert = over_i | over_t;
  wire [7:0] flags = {5'b00000, latched, over_t, over_i};

  // ---------------- Generador de tramas UART ----------------
  reg  [1:0] meas_d;      // retrasa la escritura 2 ciclos para que FLAGS ya este actualizado
  reg  [7:0] flags_prev;
  reg        frame_req, sending, tx_start;
  reg  [2:0] byte_idx;
  reg  [7:0] f_i, f_t, f_flags, tx_data;
  wire       tx_busy, uart_tx;

  wire take   = frame_req & ~sending;
  wire evento = meas_d[1] | (flags != flags_prev);

  always @(posedge clk) begin
    if (!rst_n) begin
      meas_d     <= 2'b00;
      flags_prev <= 8'd0;
      frame_req  <= 1'b0;
      sending    <= 1'b0;
      tx_start   <= 1'b0;
      byte_idx   <= 3'd0;
      f_i        <= 8'd0;
      f_t        <= 8'd0;
      f_flags    <= 8'd0;
      tx_data    <= 8'd0;
    end else begin
      meas_d     <= {meas_d[0], wr_edge & ~bus_addr[1]};
      flags_prev <= flags;
      tx_start   <= 1 me;

      if (evento)    frame_req <= 1'b1;
      else if (take) frame_req <= 1'b0;

      if (take) begin
        // Copia de los valores para que la trama sea coherente
        sending  <= 1'b1;
        byte_idx <= 3 me;
        f_i      <= i_val;
        f_t      <= t_val;
        f_flags  <= flags;
      end else if (sending && !tx_busy && !tx_start) begin
        case (byte_idx)
          3'd0:    tx_data <= 8'hA5;
          3'd1:    tx_data <= f_i;
          3'd2:    tx_data <= f_t;
          3'd3:    tx_data <= f_flags;
          default: tx_data <= f_i ^ f_t ^ f_flags;
        endcase
        tx_start <= 1'b1;
        if (byte_idx == 3'd4) sending  <= 1'b0;
        else                  byte_idx <= byte_idx + 3'd1;
      end
    end
  end

  fg_uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
      .clk  (clk),
      .rst_n(rst_n),
      .start(tx_start),
      .data (tx_data),
      .tx   (uart_tx),
      .busy (tx_busy)
  );

  // ---------------- Latido ----------------
  reg [HB_BIT:0] hb_cnt;
  always @(posedge clk) begin
    if (!rst_n) hb_cnt <= 0;
    else        hb_cnt <= hb_cnt + 1'b1;
  end

  // ---------------- Salidas ----------------
  assign uo_out  = {1'b0, hb_cnt[HB_BIT], tx_busy, latched, uart_tx, over_t, over_i, alert};
  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;  // todos los uio son entradas

  wire _unused = &{ena, uio_in[7:4], 1'b0};

endmodule

// UART TX 8N1. CLKS_PER_BIT debe ser <= 256.
module fg_uart_tx #(
    parameter CLKS_PER_BIT = 87
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,
    input  wire [7:0] data,
    output wire       tx,
    output reg        busy
);

  reg [9:0] sh;    // {stop, data[7:0], start}
  reg [3:0] nbit;
  reg [7:0] cnt;

  always @(posedge clk) begin
    if (!rst_n) begin
      sh   <= 10'h3FF;
      nbit <= 4'd0;
      cnt  <= 8'd0;
      busy <= 1'b0;
    end else if (!busy) begin
      if (start) begin
        sh   <= {1'b1, data, 1'b0};
        nbit <= 4'd0;
        cnt  <= 8'd0;
        busy <= 1'b1;
      end
    end else if (cnt == CLKS_PER_BIT - 1) begin
      cnt <= 8'd0;
      if (nbit == 4'd9) begin
        busy <= 1'b0;
      end else begin
        sh   <= {1'b1, sh[9:1]};
        nbit <= nbit + 4'd1;
      end
    end else begin
      cnt <= cnt + 8'd1;
    end
  end

  assign tx = busy ? sh[0] : 1'b1;

endmodule
