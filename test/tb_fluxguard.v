/*
 * Testbench autoverificable de tt_um_fluxguard
 * iverilog -g2012 -o sim.vvp ../src/tt_um_fluxguard.v tb_fluxguard.v && vvp sim.vvp
 */

`default_nettype none
`timescale 1ns / 1ps

module tb_fluxguard;

  localparam CLK_NS = 100;           // 10 MHz
  localparam CPB    = 8;             // UART acelerado para simular rapido
  localparam BIT_NS = CLK_NS * CPB;

  reg        clk = 1'b0;
  reg        rst_n = 1'b0;
  reg        ena = 1'b1;
  reg  [7:0] ui_in = 8'd0;
  reg  [7:0] uio_in = 8'd0;
  wire [7:0] uo_out, uio_out, uio_oe;

  tt_um_fluxguard #(.CLKS_PER_BIT(CPB), .HB_BIT(4)) dut (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  always #(CLK_NS / 2) clk = ~clk;

  wire alert   = uo_out[0];
  wire over_i  = uo_out[1];
  wire over_t  = uo_out[2];
  wire uart_tx = uo_out[3];
  wire latched = uo_out[4];

  // ---------------- Receptor UART en segundo plano ----------------
  reg  [7:0] rx_buf [0:63];
  reg  [7:0] b;
  integer    rx_count = 0;
  integer    rx_ptr = 0;
  integer    errors = 0;
  integer    k;

  always begin
    @(negedge uart_tx);
    #(BIT_NS / 2);
    if (uart_tx == 1'b0) begin
      for (k = 0; k < 8; k = k + 1) begin
        #(BIT_NS);
        b[k] = uart_tx;
      end
      #(BIT_NS);
      if (uart_tx !== 1'b1) begin
        $display("ERROR: bit de stop invalido");
        errors = errors + 1;
      end
      rx_buf[rx_count] = b;
      rx_count = rx_count + 1;
    end
  end

  // ---------------- Tareas ----------------
  task bus_write(input [1:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      ui_in       = data;
      uio_in[1:0] = addr;
      @(negedge clk);
      uio_in[2] = 1'b1;
      repeat (4) @(negedge clk);
      uio_in[2] = 1'b0;
      repeat (4) @(negedge clk);
    end
  endtask

  task pulse_clr;
    begin
      @(negedge clk);
      uio_in[3] = 1'b1;
      repeat (4) @(negedge clk);
      uio_in[3] = 1'b0;
      repeat (4) @(negedge clk);
    end
  endtask

  task check(input cond, input [8*40-1:0] msg);
    begin
      if (!cond) begin
        $display("ERROR: %0s", msg);
        errors = errors + 1;
      end
    end
  endtask

  task expect_frame(input [7:0] ei, input [7:0] et, input [7:0] ef);
    integer n;
    begin
      n = 0;
      while (rx_count < rx_ptr + 5 && n < 2000) begin
        @(posedge clk);
        n = n + 1;
      end
      if (rx_count < rx_ptr + 5) begin
        $display("ERROR: trama no recibida (esperada A5 %h %h %h)", ei, et, ef);
        errors = errors + 1;
      end else begin
        if (rx_buf[rx_ptr] !== 8'hA5 || rx_buf[rx_ptr+1] !== ei || rx_buf[rx_ptr+2] !== et ||
            rx_buf[rx_ptr+3] !== ef || rx_buf[rx_ptr+4] !== (ei ^ et ^ ef)) begin
          $display("ERROR: trama %h %h %h %h %h, esperada A5 %h %h %h %h",
                   rx_buf[rx_ptr], rx_buf[rx_ptr+1], rx_buf[rx_ptr+2], rx_buf[rx_ptr+3],
                   rx_buf[rx_ptr+4], ei, et, ef, ei ^ et ^ ef);
          errors = errors + 1;
        end else begin
          $display("OK   trama A5 %h %h %h %h", ei, et, ef, ei ^ et ^ ef);
        end
        rx_ptr = rx_ptr + 5;
      end
    end
  endtask

  // ---------------- Secuencia de prueba ----------------
  initial begin
    $dumpfile("tb_fluxguard.vcd");
    $dumpvars(0, tb_fluxguard);

    repeat (5) @(negedge clk);
    rst_n = 1'b1;
    repeat (5) @(negedge clk);
    check(uart_tx === 1'b1, "UART en reposo debe estar en 1");
    check(alert === 1'b0, "sin alerta tras reset");

    // 1) 10 A (40 x 0.25 A): normal
    bus_write(2'd0, 8'd40);
    expect_frame(8'd40, 8'd0, 8'h00);
    check(alert === 1'b0, "10 A no debe alertar");

    // 2) Cable a 35 C: normal
    bus_write(2'd1, 8'd35);
    expect_frame(8'd40, 8'd35, 8'h00);

    // 3) 30 A > 25 A: sobrecorriente
    bus_write(2'd0, 8'd120);
    expect_frame(8'd120, 8'd35, 8'h05);
    check(alert === 1'b1 && over_i === 1'b1, "30 A debe activar OVER_I");
    check(latched === 1'b1, "alarma memorizada");

    // 4) 24.5 A: sigue activa por histeresis (umbral - 1 A = 24 A)
    bus_write(2'd0, 8'd98);
    expect_frame(8'd98, 8'd35, 8'h05);
    check(over_i === 1'b1, "histeresis mantiene OVER_I");

    // 5) 22.5 A: se libera, la alarma queda memorizada
    bus_write(2'd0, 8'd90);
    expect_frame(8'd90, 8'd35, 8'h04);
    check(alert === 1'b0 && latched === 1'b1, "OVER_I libre, LATCHED activo");

    // 6) CLR borra la alarma memorizada
    pulse_clr;
    expect_frame(8'd90, 8'd35, 8'h00);
    check(latched === 1'b0, "CLR debe borrar LATCHED");

    // 7) Cable a 75 C > 60 C: sobretemperatura
    bus_write(2'd1, 8'd75);
    expect_frame(8'd90, 8'd75, 8'h06);
    check(alert === 1'b1 && over_t === 1'b1, "75 C debe activar OVER_T");

    // 8) CLR con la condicion activa no debe borrar
    pulse_clr;
    check(latched === 1'b1, "CLR no borra con condicion activa");

    // 9) Subir umbral de temperatura a 80 C: se libera
    bus_write(2'd3, 8'd80);
    expect_frame(8'd90, 8'd75, 8'h04);
    check(over_t === 1'b0, "umbral 80 C libera OVER_T");

    // 10) CLR final
    pulse_clr;
    expect_frame(8'd90, 8'd75, 8'h00);

    // No debe haber tramas extra
    repeat (2000) @(posedge clk);
    check(rx_count == rx_ptr, "no debe haber tramas duplicadas");

    if (errors == 0) $display("PRUEBA EXITOSA");
    else             $display("PRUEBA FALLIDA: %0d errores", errors);
    $finish;
  end

endmodule
