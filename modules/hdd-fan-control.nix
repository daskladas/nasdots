{ config, pkgs, lib, ... }:

let
  # ============================================================
  # HDD-Temperatur-basierte Lüftersteuerung
  #
  # Der IT8613E Auto-Mode (pwm_enable=2) regelt nur nach CPU-/
  # Mainboard-Temperaturen. Bei Schreiblast auf die HDDs bleiben
  # die Fans leise während die Platten kochen. Dieses Modul liest
  # die HDD-Temps alle 60 s via smartctl und setzt pwm2 (HDD-Cage
  # / Front-Fans) manuell anhand einer Kurve mit Hysterese.
  #
  # pwm3/pwm4/pwm5 bleiben im Auto-Mode (CPU/Mainboard) — siehe
  # fan-control.nix. Saubere Trennung: dieses Modul kümmert sich
  # ausschließlich um pwm2.
  #
  # Kurve (max. HDD-Temp → pwm2):
  #   alle Disks in Standby → 60   (nur Mainboard-Kühlung)
  #   < 40 °C               → 80
  #   40–44 °C              → 120
  #   45–49 °C              → 160
  #   50–54 °C              → 200
  #   ≥ 55 °C               → 255  (max, Brüll-Modus)
  #
  # Hysterese: 3 °C beim Runterregeln (Pumpen vermeiden).
  # Failsafe: bei smartctl-Fehler oder hwmon-Problem → pwm=200.
  # ============================================================

  hwmonName = "it8613";
  pwmChannel = "pwm2";
  disks = [ "/dev/sda" "/dev/sdb" "/dev/sdc" ];
  intervalSec = 60;
  failsafePwm = 200;

  hddFanControl = pkgs.writeShellApplication {
    name = "hdd-fan-control";
    runtimeInputs = with pkgs; [ smartmontools jq coreutils ];
    # shellcheck is happy because writeShellApplication runs it
    text = ''
      # writeShellApplication setzt bereits: set -euo pipefail
      HWMON_NAME="${hwmonName}"
      PWM_CH="${pwmChannel}"
      DISKS=( ${lib.concatStringsSep " " disks} )
      FAILSAFE_PWM=${toString failsafePwm}
      STATE_DIR=/run/hdd-fan-control
      STATE_FILE="$STATE_DIR/last_level"

      mkdir -p "$STATE_DIR"

      # ---------- hwmon suchen (Retry für Boot-Race) ----------
      HWMON=""
      for _ in 1 2 3 4 5; do
        for h in /sys/class/hwmon/hwmon*; do
          if [ -r "$h/name" ] && [ "$(cat "$h/name" 2>/dev/null)" = "$HWMON_NAME" ]; then
            HWMON="$h"
            break 2
          fi
        done
        sleep 2
      done

      if [ -z "$HWMON" ]; then
        echo "ERROR: hwmon '$HWMON_NAME' nicht gefunden — it87-Modul geladen?" >&2
        exit 1
      fi

      PWM_FILE="$HWMON/$PWM_CH"
      ENABLE_FILE="''${PWM_FILE}_enable"

      if [ ! -w "$PWM_FILE" ] || [ ! -w "$ENABLE_FILE" ]; then
        echo "ERROR: $PWM_FILE oder $ENABLE_FILE nicht beschreibbar" >&2
        exit 1
      fi

      # ---------- Manual-Mode aktivieren (nur wenn nötig) ----------
      CUR_ENABLE="$(cat "$ENABLE_FILE" 2>/dev/null || echo 0)"
      if [ "$CUR_ENABLE" != "1" ]; then
        if ! echo 1 > "$ENABLE_FILE" 2>/dev/null; then
          echo "ERROR: kann ''${PWM_CH}_enable=1 nicht setzen" >&2
          exit 1
        fi
      fi

      # ---------- HDD-Temps lesen ----------
      MAX_TEMP=0
      ACTIVE_COUNT=0
      STANDBY_COUNT=0
      ERROR_COUNT=0
      TEMPS_LOG=""

      for disk in "''${DISKS[@]}"; do
        name="$(basename "$disk")"
        # -n standby: nicht aufwecken, exit 2 = device in low-power state
        # -j: JSON-Output für sauberes Parsen
        # Idiom für RC-Capture unter `set -e`: cmd || RC=$?
        RC=0
        OUT="$(smartctl -n standby -A -j "$disk" 2>/dev/null)" || RC=$?

        if [ "$RC" -eq 0 ]; then
          TEMP="$(printf '%s' "$OUT" | jq -r '.temperature.current // empty' 2>/dev/null || true)"
          if [[ "$TEMP" =~ ^[0-9]+$ ]] && [ "$TEMP" -gt 0 ]; then
            TEMPS_LOG="$TEMPS_LOG $name=''${TEMP}C"
            ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
            if [ "$TEMP" -gt "$MAX_TEMP" ]; then
              MAX_TEMP=$TEMP
            fi
          else
            TEMPS_LOG="$TEMPS_LOG $name=?"
            ERROR_COUNT=$((ERROR_COUNT + 1))
          fi
        elif [ "$RC" -eq 2 ]; then
          # Disk im Standby — nicht aufwecken, nicht in max_temp einrechnen
          TEMPS_LOG="$TEMPS_LOG $name=STANDBY"
          STANDBY_COUNT=$((STANDBY_COUNT + 1))
        else
          TEMPS_LOG="$TEMPS_LOG $name=ERR(rc=$RC)"
          ERROR_COUNT=$((ERROR_COUNT + 1))
        fi
      done

      # ---------- Level berechnen ----------
      # Levels:  0=all standby  1=<40  2=40-44  3=45-49  4=50-54  5=>=55
      # PWMs:      60             80     120      160      200      255
      LAST_LEVEL="$(cat "$STATE_FILE" 2>/dev/null || echo 1)"
      case "$LAST_LEVEL" in
        0|1|2|3|4|5) ;;
        *) LAST_LEVEL=1 ;;
      esac

      # Kein einziger aktiver Messwert + mind. ein Fehler → Failsafe
      if [ "$ACTIVE_COUNT" -eq 0 ] && [ "$ERROR_COUNT" -gt 0 ]; then
        echo "ERROR: keine HDD-Temps lesbar (errors=$ERROR_COUNT standby=$STANDBY_COUNT) — Failsafe pwm=$FAILSAFE_PWM" >&2
        echo "$FAILSAFE_PWM" > "$PWM_FILE"
        # Level nicht persistieren, damit nächster Durchlauf frisch startet
        exit 1
      fi

      if [ "$ACTIVE_COUNT" -eq 0 ]; then
        # Alle Disks im Standby → minimaler Lüfter
        NEW_LEVEL=0
      else
        # Roh-Level aus max_temp
        if   [ "$MAX_TEMP" -ge 55 ]; then RAW=5
        elif [ "$MAX_TEMP" -ge 50 ]; then RAW=4
        elif [ "$MAX_TEMP" -ge 45 ]; then RAW=3
        elif [ "$MAX_TEMP" -ge 40 ]; then RAW=2
        else                              RAW=1
        fi

        if [ "$RAW" -ge "$LAST_LEVEL" ]; then
          # Hochregeln: sofort, keine Hysterese
          NEW_LEVEL=$RAW
        else
          # Runterregeln nur wenn 3 °C unter der unteren Grenze des aktuellen Levels
          case "$LAST_LEVEL" in
            5) DOWN=52 ;;   # 55 - 3
            4) DOWN=47 ;;   # 50 - 3
            3) DOWN=42 ;;   # 45 - 3
            2) DOWN=37 ;;   # 40 - 3
            *) DOWN=0 ;;
          esac
          if [ "$MAX_TEMP" -lt "$DOWN" ]; then
            NEW_LEVEL=$((LAST_LEVEL - 1))
          else
            NEW_LEVEL=$LAST_LEVEL
          fi
        fi
      fi

      case "$NEW_LEVEL" in
        0) PWM=60  ;;
        1) PWM=80  ;;
        2) PWM=120 ;;
        3) PWM=160 ;;
        4) PWM=200 ;;
        5) PWM=255 ;;
      esac

      if ! echo "$PWM" > "$PWM_FILE"; then
        echo "ERROR: konnte pwm=$PWM nicht nach $PWM_FILE schreiben" >&2
        exit 1
      fi
      echo "$NEW_LEVEL" > "$STATE_FILE"

      echo "hdd-fan-control: max=''${MAX_TEMP}C active=$ACTIVE_COUNT standby=$STANDBY_COUNT err=$ERROR_COUNT level=$NEW_LEVEL pwm=$PWM temps:$TEMPS_LOG"
    '';
  };
in
{
  # Script systemweit verfügbar machen (Debug / manuelles Ausführen)
  environment.systemPackages = [ hddFanControl ];

  # ------------------------------------------------------------
  # Service: ein Lauf der HDD-Fan-Kurve
  # ------------------------------------------------------------
  systemd.services.hdd-fan-control = {
    description = "HDD-temperature-based fan control (pwm2)";
    # Läuft NACH dem bestehenden fan-control.service, der pwmN_enable=2
    # setzt. Wir übernehmen dann pwm2 in Manual-Mode (=1).
    after = [ "fan-control.service" "systemd-modules-load.service" ];
    wants = [ "fan-control.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${hddFanControl}/bin/hdd-fan-control";
      # Kein Restart on failure — der Timer triggert eh alle 60 s neu.
      # StandardOutput landet automatisch im journal.
    };
  };

  # ------------------------------------------------------------
  # Timer: alle 60 s
  # ------------------------------------------------------------
  systemd.timers.hdd-fan-control = {
    description = "Run HDD fan control every ${toString intervalSec}s";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "${toString intervalSec}s";
      AccuracySec = "5s";
      Unit = "hdd-fan-control.service";
    };
  };
}
