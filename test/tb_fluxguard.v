/*
 * Testbench autoverificable de tt_um_mari464_fluxguard
 * iverilog -g2012 -o sim.vvp ../src/tt_um_mari464_fluxguard.v tb_fluxguard.v && vvp sim.vvp
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
  reg  [7:0] uio_in = 8'h10;          // PEAK_N (uio[4]) en reposo = 1 (pull-up)
  wire [7:0] uo_out, uio_out, uio_oe;

  // Retencion de pico corta (2^10 ciclos, mayor que una trama UART) para simular rapido
  localparam HOLD = 1024;
  tt_um_mari464_fluxguard #(.CLKS_PER_BIT(CPB), .HB_BIT(4), .PK_HOLD_BITS(10)) dut (
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
  wire trip    = uo_out[7];

  // ---------------- Receptor UART en segundo plano ----------------
  reg  [7:0] rx_buf [0:255];
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

  // Pulso activo en bajo en PEAK_N durante n ciclos (simula el comparador del SCT-013)
  task peak_pulse(input integer n);
    begin
      @(negedge clk);
      uio_in[4] = 1'b0;
      repeat (n) @(negedge clk);
      uio_in[4] = 1'b1;
    end
  endtask

  // Tren de picos: uno cada 'gap' ciclos (simula un pico por semiciclo de red)
  task peak_train(input integer count, input integer gap);
    integer j;
    begin
      for (j = 0; j < count; j = j + 1) begin
        peak_pulse(12);
        repeat (gap) @(negedge clk);
      end
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
      while (rx_count < rx_ptr + 5 && n < 4000) begin
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

    // ---------------- Camino rapido (SCT-013) ----------------
    // 11) Glitch de 4 ciclos (< PK_FILT = 8): se ignora
    peak_pulse(4);
    repeat (20) @(negedge clk);
    check(alert === 1'b0 && trip === 1'b0, "glitch corto no debe disparar");

    // 12) Pico real en modo 0: ALERT y TRIP en ~12 ciclos, sin ESP32
    fork
      peak_pulse(12);
      begin : lat
        integer c;
        c = 0;
        while (alert !== 1'b1 && c < 50) begin
          @(posedge clk);
          c = c + 1;
        end
        $display("INFO latencia PEAK_N -> ALERT: %0d ciclos", c);
        check(c <= 14, "latencia del camino rapido");
      end
    join
    expect_frame(8'd90, 8'd75, 8'h1C);  // TRIP | OVER_PK | LATCHED
    check(trip === 1'b1, "pico debe activar TRIP");

    // 13) CLR con picos presentes no rearma
    pulse_clr;
    check(trip === 1'b1, "CLR no rearma mientras haya picos");

    // 14) Picos cada 100 ciclos (< retencion): OVER_PK se mantiene sin tramas nuevas
    peak_train(3, 100);
    check(alert === 1'b1, "OVER_PK se mantiene entre semiciclos");

    // 15) Sin picos: OVER_PK se libera tras la retencion, TRIP queda memorizado
    expect_frame(8'd90, 8'd75, 8'h14);  // TRIP | LATCHED
    check(alert === 1'b0 && trip === 1'b1, "OVER_PK libre, TRIP memorizado");

    // 16) CLR rearma TRIP y LATCHED
    pulse_clr;
    expect_frame(8'd90, 8'd75, 8'h00);
    check(trip === 1'b0 && latched === 1'b0, "CLR rearma");

    // 17) Modo 1 (arranque de motor): 3 picos seguidos no disparan
    uio_in[5] = 1'b1;
    peak_train(3, 100);
    check(alert === 1'b0 && trip === 1'b0, "modo 1 tolera 3 picos");
    repeat (HOLD + 20) @(negedge clk);  // la cuenta se reinicia

    // 18) Modo 1: 6 picos seguidos si disparan
    peak_train(6, 100);
    check(trip === 1'b1, "modo 1 dispara con 6 picos");
    expect_frame(8'd90, 8'd75, 8'h1C);
    expect_frame(8'd90, 8'd75, 8'h14);  // se libera al terminar los picos
    pulse_clr;
    expect_frame(8'd90, 8'd75, 8'h00);
    uio_in[5] = 1'b0;

    // No debe haber tramas extra
    repeat (2000) @(posedge clk);
    check(rx_count == rx_ptr, "no debe haber tramas duplicadas");

    if (errors == 0) $display("PRUEBA EXITOSA");
    else             $display("PRUEBA FALLIDA: %0d errores", errors);
    $finish;
  end

endmodule
