# SPDX-FileCopyrightText: © 2024 Tiny Tapeout
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

CLKS_PER_BIT = 87  # valor por defecto del diseno: 10 MHz / 115200 baud

# Direcciones del bus
ADDR_I, ADDR_T, ADDR_TH_I, ADDR_TH_T = 0, 1, 2, 3


def out_bit(dut, n):
    return (int(dut.uo_out.value) >> n) & 1


async def uart_rx(dut, rx):
    """Receptor UART 8N1 en segundo plano sobre uo_out[3]."""
    while True:
        await RisingEdge(dut.clk)
        if out_bit(dut, 3) != 0:
            continue
        await ClockCycles(dut.clk, CLKS_PER_BIT // 2)
        if out_bit(dut, 3) != 0:
            continue  # falso bit de start
        byte = 0
        for i in range(8):
            await ClockCycles(dut.clk, CLKS_PER_BIT)
            byte |= out_bit(dut, 3) << i
        await ClockCycles(dut.clk, CLKS_PER_BIT)
        assert out_bit(dut, 3) == 1, "bit de stop invalido"
        rx.append(byte)


async def bus_write(dut, addr, data):
    dut.ui_in.value = data
    dut.uio_in.value = addr
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = addr | 0b0100  # WR = 1
    await ClockCycles(dut.clk, 4)
    dut.uio_in.value = addr
    await ClockCycles(dut.clk, 4)


async def pulse_clr(dut):
    dut.uio_in.value = 0b1000  # CLR = 1
    await ClockCycles(dut.clk, 4)
    dut.uio_in.value = 0
    await ClockCycles(dut.clk, 4)


async def expect_frame(dut, rx, ei, et, ef):
    start = expect_frame.ptr  # primer byte aun no verificado
    for _ in range(20000):
        if len(rx) >= start + 5:
            break
        await RisingEdge(dut.clk)
    assert len(rx) >= start + 5, f"trama no recibida (esperada A5 {ei:02x} {et:02x} {ef:02x})"
    frame = rx[start:start + 5]
    expected = [0xA5, ei, et, ef, ei ^ et ^ ef]
    assert frame == expected, f"trama {[hex(b) for b in frame]}, esperada {[hex(b) for b in expected]}"
    expect_frame.ptr += 5
    dut._log.info(f"OK trama {' '.join(f'{b:02x}' for b in frame)}")


@cocotb.test()
async def test_project(dut):
    dut._log.info("Start")

    # Reloj de 10 MHz (100 ns), el mismo de info.yaml
    clock = Clock(dut.clk, 100, unit="ns")
    cocotb.start_soon(clock.start())

    # Reset
    dut._log.info("Reset")
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    rx = []
    expect_frame.ptr = 0
    cocotb.start_soon(uart_rx(dut, rx))

    assert out_bit(dut, 3) == 1, "UART en reposo debe estar en 1"
    assert out_bit(dut, 0) == 0, "sin alerta tras reset"
    assert int(dut.uio_oe.value) == 0, "todos los uio deben ser entradas"

    dut._log.info("10 A: normal")
    await bus_write(dut, ADDR_I, 40)
    await expect_frame(dut, rx, 40, 0, 0x00)
    assert out_bit(dut, 0) == 0

    dut._log.info("Cable a 35 C: normal")
    await bus_write(dut, ADDR_T, 35)
    await expect_frame(dut, rx, 40, 35, 0x00)

    dut._log.info("30 A > 25 A: sobrecorriente")
    await bus_write(dut, ADDR_I, 120)
    await expect_frame(dut, rx, 120, 35, 0x05)
    assert out_bit(dut, 0) == 1, "ALERT"
    assert out_bit(dut, 1) == 1, "OVER_I"
    assert out_bit(dut, 4) == 1, "LATCHED"

    dut._log.info("22.5 A: se libera, la alarma queda memorizada")
    await bus_write(dut, ADDR_I, 90)
    await expect_frame(dut, rx, 90, 35, 0x04)
    assert out_bit(dut, 0) == 0, "ALERT libre"
    assert out_bit(dut, 4) == 1, "LATCHED activo"

    dut._log.info("CLR borra la alarma memorizada")
    await pulse_clr(dut)
    await expect_frame(dut, rx, 90, 35, 0x00)
    assert out_bit(dut, 4) == 0, "CLR debe borrar LATCHED"

    dut._log.info("Cable a 75 C > 60 C: sobretemperatura")
    await bus_write(dut, ADDR_T, 75)
    await expect_frame(dut, rx, 90, 75, 0x06)
    assert out_bit(dut, 0) == 1, "ALERT"
    assert out_bit(dut, 2) == 1, "OVER_T"
