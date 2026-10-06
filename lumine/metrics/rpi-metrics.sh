#!/usr/bin/env bash
# Raspberry Pi metrics node_exporter can't see on its own, from the
# firmware via vcgencmd, written for its textfile collector. Run by
# rpi-metrics.timer every 15 s (lumine/systemd/). node_exporter's hwmon
# collector already has cpu_thermal, the fan (pwmfan) and the under-voltage
# alarm (rpi_volt), so this covers the rest:
#
#   rpi_temperature_celsius{sensor}    SoC, and the PMIC on a Pi 5
#   rpi_throttled{flag}                each get_throttled bit: 1 = set
#   rpi_throttled_raw                  the raw bitmask
#   rpi_clock_hz{clock}                ARM, core, V3D, ISP, HEVC, EMMC, ...
#   rpi_pmic_volts{rail} / rpi_pmic_amps{rail} / rpi_pmic_watts{rail}
#                                      Pi 5 PMIC ADC, per supply rail
#   rpi_power_watts                    sum over the measured rails (the SoC +
#                                      board, not USB peripherals)
#   rpi_input_volts                    the 5 V input (EXT5V), the under-voltage source
#   rpi_firmware_info / rpi_bootloader_info / rpi_sd_card_info   (value 1)
set -euo pipefail

dir=/var/lib/prometheus/node-exporter
out=$dir/rpi.prom
vc=/usr/bin/vcgencmd
tmp=$(mktemp "$dir/.rpi.prom.XXXXXX")
trap 'rm -f "$tmp"' EXIT

num() { sed -E 's/^[^=]*=([-0-9.]+).*/\1/'; }

{
  echo "# HELP rpi_temperature_celsius Temperature reported by the firmware."
  echo "# TYPE rpi_temperature_celsius gauge"
  echo "rpi_temperature_celsius{sensor=\"soc\"} $($vc measure_temp | num)"
  if pmic=$($vc measure_temp pmic 2>/dev/null) && [[ $pmic == temp=* ]]; then
    echo "rpi_temperature_celsius{sensor=\"pmic\"} $(num <<<"$pmic")"
  fi

  # Bits of `vcgencmd get_throttled` (Raspberry Pi docs, "vcgencmd").
  raw=$($vc get_throttled | cut -d= -f2)
  echo "# HELP rpi_throttled_raw Raw get_throttled bitmask (0 = healthy since boot)."
  echo "# TYPE rpi_throttled_raw gauge"
  echo "rpi_throttled_raw $((raw))"
  echo "# HELP rpi_throttled One get_throttled flag: _now = currently, _occurred = at some point since boot."
  echo "# TYPE rpi_throttled gauge"
  for pair in 0:under_voltage_now 1:freq_capped_now 2:throttled_now 3:soft_temp_limit_now \
    16:under_voltage_occurred 17:freq_capped_occurred 18:throttled_occurred 19:soft_temp_limit_occurred; do
    echo "rpi_throttled{flag=\"${pair#*:}\"} $(((raw >> ${pair%%:*}) & 1))"
  done

  echo "# HELP rpi_clock_hz Clock frequency reported by the firmware."
  echo "# TYPE rpi_clock_hz gauge"
  for c in arm core v3d isp hevc emmc emmc2 uart pwm pixel hdmi; do
    v=$($vc measure_clock "$c" 2>/dev/null | sed -nE 's/^frequency\([0-9]+\)=([0-9]+)$/\1/p')
    [ -n "$v" ] && echo "rpi_clock_hz{clock=\"$c\"} $v"
  done

  # Pi 5 only: `<RAIL>_A current(n)=x A` and `<RAIL>_V volt(n)=y V` lines.
  if adc=$($vc pmic_read_adc 2>/dev/null) && [ -n "$adc" ]; then
    awk '
      { gsub(/^ +/, "") }
      $1 ~ /_A$/ { r = substr($1, 1, length($1) - 2); split($2, a, "="); amps[r] = a[2] + 0 }
      $1 ~ /_V$/ { r = substr($1, 1, length($1) - 2); split($2, a, "="); volts[r] = a[2] + 0 }
      END {
        print "# HELP rpi_pmic_volts Rail voltage from the Pi 5 PMIC ADC."
        print "# TYPE rpi_pmic_volts gauge"
        for (r in volts) printf "rpi_pmic_volts{rail=\"%s\"} %.6f\n", r, volts[r]
        print "# HELP rpi_pmic_amps Rail current from the Pi 5 PMIC ADC."
        print "# TYPE rpi_pmic_amps gauge"
        for (r in amps) printf "rpi_pmic_amps{rail=\"%s\"} %.6f\n", r, amps[r]
        print "# HELP rpi_pmic_watts Rail power (volts x amps) for rails with both readings."
        print "# TYPE rpi_pmic_watts gauge"
        total = 0
        for (r in amps) if (r in volts) { w = amps[r] * volts[r]; total += w; printf "rpi_pmic_watts{rail=\"%s\"} %.6f\n", r, w }
        print "# HELP rpi_power_watts Sum of rpi_pmic_watts: SoC + board power, excluding USB peripherals."
        print "# TYPE rpi_power_watts gauge"
        printf "rpi_power_watts %.6f\n", total
        if ("EXT5V" in volts) {
          print "# HELP rpi_input_volts 5 V input voltage (EXT5V)."
          print "# TYPE rpi_input_volts gauge"
          printf "rpi_input_volts %.6f\n", volts["EXT5V"]
        }
      }' <<<"$adc"
  fi

  fw=$($vc version)
  echo "# HELP rpi_firmware_info VideoCore firmware build."
  echo "# TYPE rpi_firmware_info gauge"
  echo "rpi_firmware_info{date=\"$(sed -n 1p <<<"$fw")\",version=\"$(sed -nE 's/^version ([0-9a-f]+).*/\1/p' <<<"$fw")\"} 1"
  if bl=$($vc bootloader_version 2>/dev/null); then
    echo "# HELP rpi_bootloader_info EEPROM bootloader build."
    echo "# TYPE rpi_bootloader_info gauge"
    echo "rpi_bootloader_info{date=\"$(sed -n 1p <<<"$bl")\",version=\"$(sed -nE 's/^version ([0-9a-f]+).*/\1/p' <<<"$bl")\"} 1"
  fi

  # The SD card has no SMART; its identity at least shows when it's swapped.
  d=/sys/block/mmcblk0/device
  if [ -r "$d/name" ]; then
    echo "# HELP rpi_sd_card_info The boot SD card's identity (CID fields)."
    echo "# TYPE rpi_sd_card_info gauge"
    echo "rpi_sd_card_info{name=\"$(cat "$d/name")\",manfid=\"$(cat "$d/manfid")\",oemid=\"$(cat "$d/oemid")\",date=\"$(cat "$d/date")\"} 1"
  fi
} >"$tmp"

chmod 0644 "$tmp"
mv "$tmp" "$out"
trap - EXIT
