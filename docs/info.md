<!---

This file is used to generate your project datasheet. Please fill in the information below and delete any unused
sections.

You can also include images in this folder and reference them in the markdown. Each image must be less than
512 kb in size, and the combined size of all images must be less than 1 MB.
-->

## How it works

FluxGuard es un monitor de sobrecorriente y sobretemperatura. Un microcontrolador externo (por ejemplo un ESP32)
escribe lecturas de 8 bits a través de un bus paralelo sencillo y el chip las compara contra umbrales programables.

Registros (seleccionados con `ADDR = uio[1:0]`, dato en `ui[7:0]`, escritura en el flanco de subida de `WR = uio[2]`):

| ADDR | Registro               | Escala      | Valor tras reset |
|------|------------------------|-------------|------------------|
| 00   | Corriente              | 0.25 A/LSB  | 0                |
| 01   | Temperatura del cable  | 1 °C/LSB    | 0                |
| 10   | Umbral de corriente    | 0.25 A/LSB  | 100 (25.0 A)     |
| 11   | Umbral de temperatura  | 1 °C/LSB    | 60 (60 °C)       |

- `OVER_I` / `OVER_T` se activan cuando la lectura supera su umbral y se liberan cuando baja de (umbral − 4 LSB)
  (histéresis de 1 A / 4 °C).
- `ALERT = OVER_I | OVER_T`.
- `LATCHED` memoriza cualquier alarma hasta un flanco de subida en `CLR = uio[3]`. CLR no tiene efecto mientras la
  condición siga activa.
- En cada escritura de corriente/temperatura, o cuando cambia el estado de las alarmas, se envía por `UART_TX`
  (115200 baud, 8N1 con reloj de 10 MHz) una trama de 5 bytes:
  `0xA5, CORRIENTE, TEMPERATURA, FLAGS, CHECKSUM`, donde `FLAGS = {5'b0, LATCHED, OVER_T, OVER_I}` y
  `CHECKSUM = CORRIENTE ^ TEMPERATURA ^ FLAGS`.
- `HEARTBEAT` parpadea a ~1.2 Hz para indicar que el chip está vivo.

## How to test

1. Aplica un reloj de 10 MHz y un pulso de reset (`rst_n` en bajo).
2. Conecta `UART_TX` (uo[3]) a un adaptador USB-serie a 115200 baud 8N1.
3. Para escribir un registro: pon el dato en `ui[7:0]` y la dirección en `uio[1:0]`, luego sube `WR` (uio[2]) al
   menos 3 ciclos de reloj y bájalo, manteniendo DATA/ADDR estables mientras `WR = 1`.
4. Escribe una corriente de 120 (30 A): `ALERT`, `OVER_I` y `LATCHED` se encienden y llega la trama
   `A5 78 00 05 7D`.
5. Escribe una corriente de 90 (22.5 A): `ALERT` se apaga y `LATCHED` sigue encendido. Da un pulso en `CLR` para
   borrarlo.

## External hardware

- Microcontrolador (ESP32 u otro) que escriba las lecturas por el bus paralelo.
- Sensor de corriente y sensor de temperatura conectados al microcontrolador.
- Adaptador USB-serie (3.3 V) para leer la salida UART.
- LEDs opcionales en `ALERT`, `LATCHED` y `HEARTBEAT`.
