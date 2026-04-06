{ config, pkgs, lib, ... }:

let
  # ============================================================
  # HDD-Temperatur-basierte Lüftersteuerung (adaptive daemon)
  #
  # Läuft als long-running systemd-Service (Type=simple) mit
  # interner Sleep-Schleife. Liest HDD-Temps via smartctl und
  # regelt pwm2 (HDD-Cage / Front-Fans) am IT8613E.
  #
  # Design-Ziele:
  #   - Im Idle quasi lautlos (Platten Standby → pwm=25)
  #   - Adaptive Poll-Frequenz: kalt = selten, heiß = oft
  #   - Breite Dead-Zones → keine Fan-Oszillation
  #   - Zuverlässige schnelle Reaktion unter Last
  #
  # Level / PWM / Sleep:
  #   0  all standby        pwm=25   sleep=600s  (free polling)
  #   1  active <38°C       pwm=50   sleep=600s  (minimize pokes)
  #   2  38-44°C            pwm=130  sleep=120s
  #   3  45-52°C            pwm=200  sleep=30s
  #   4  >=53°C             pwm=255  sleep=15s   (critical)
  #
  # Hysterese: 4°C beim Runterregeln
  #   Level 4 -> 3 erst wenn <49°C
  #   Level 3 -> 2 erst wenn <41°C
  #   Level 2 -> 1 erst wenn <34°C
  #
  # Failsafe: smartctl-Fehler auf allen Platten -> pwm=220
  # Cleanup:  bei SIGTERM/SIGINT -> pwm2_enable=2 (Auto zurück)
  # ============================================================

  hwmonName = "it8613";
  pwmChannel = "pwm2";
  disks = [ "/dev/sda" "/dev/sdb" "/dev/sdc" ];
  failsafePwm = 220;

  hddFanControl = pkgs.writeShellApplication {
    name = "hdd-fan-control";
    runtimeInputs = with pkgs; [ smartmontools jq coreutils ];
    text = ''
      HWMON_NAME="${hwmonName}"
      PWM_CH="${pwmChannel}"
      DISKS=( ${lib.concatStringsSep " " disks} )
      FAILSAFE_PWM=${toString failsafePwm}
      STATE_DIR=/run/hdd-fan-control
      STATE_FILE="$STATE_DIR/last_level"

      mkdir -p "$STATE_DIR"

      # ---------- hwmon suchen (Boot-Race Toleranz) ----------
      HWMON=""
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        for h in /sys/class/hwmon/hwmon*; do
          if [ -r "$h/name" ] && [ "$(cat "$h/name" 2>/dev/null)" = "$HWMON_NAME" ]; then
            HWMON="$h"
            break 2
          fi
        done
        sleep 2
      done

      if [ -z "$HWMON" ]; then
        echo "FATAL: hwmon '$HWMON_NAME' nicht gefunden — it87-Modul geladen?" >&2
        exit 1
      fi

      PWM_FILE="$HWMON/$PWM_CH"
      ENABLE_FILE="''${PWM_FILE}_enable"

      if [ ! -w "$PWM_FILE" ] || [ ! -w "$ENABLE_FILE" ]; then
        echo "FATAL: $PWM_FILE nicht beschreibbar" >&2
        exit 1
      fi

      # ---------- Einmalig: Manual-Mode übernehmen ----------
      if ! echo 1 > "$ENABLE_FILE"; then
        echo "FATAL: kann ''${PWM_CH}_enable=1 nicht setzen" >&2
        exit 1
      fi
      echo "hdd-fan-control: gestartet auf $HWMON, pwm2 in Manual-Mode"

      # ---------- Cleanup bei Stop/Restart ----------
      cleanup() {
        echo "hdd-fan-control: Shutdown — stelle Auto-Mode wieder her"
        echo 2 > "$ENABLE_FILE" 2>/dev/null || true
        exit 0
      }
      trap cleanup TERM INT

      # ============================================================
      # Haupt-Schleife
      # ============================================================
      while true; do
        # Enable-Mode bei jedem Durchlauf neu durchsetzen. Schützt
        # gegen fan-control.service-Restarts (die pwm2_enable=2
        # setzen würden), manuelle Eingriffe, oder sonstige Reset-
        # Ereignisse. Ohne diesen Check würden PWM-Writes mit
        # "Device or resource busy" fehlschlagen und der Daemon
        # würde stillschweigend in einem Retry-Loop hängen.
        CUR_ENABLE="$(cat "$ENABLE_FILE" 2>/dev/null || echo 0)"
        if [ "$CUR_ENABLE" != "1" ]; then
          echo "hdd-fan-control: pwm2_enable=$CUR_ENABLE -> setze auf 1 (Manual)"
          if ! echo 1 > "$ENABLE_FILE" 2>/dev/null; then
            echo "ERROR: konnte ''${PWM_CH}_enable nicht auf 1 setzen" >&2
            sleep 30
            continue
          fi
        fi

        MAX_TEMP=0
        ACTIVE_COUNT=0
        STANDBY_COUNT=0
        ERROR_COUNT=0
        TEMPS_LOG=""

        for disk in "''${DISKS[@]}"; do
          name="$(basename "$disk")"
          # -n standby: wenn Platte schläft, rc=2 ohne Disk-Zugriff (kostenlos)
          RC=0
          OUT="$(smartctl -n standby -A -j "$disk" 2>/dev/null)" || RC=$?

          if [ "$RC" -eq 0 ]; then
            TEMP="$(printf '%s' "$OUT" | jq -r '.temperature.current // empty' 2>/dev/null || true)"
            if [[ "$TEMP" =~ ^[0-9]+$ ]] && [ "$TEMP" -gt 0 ]; then
              TEMPS_LOG="$TEMPS_LOG $name=''${TEMP}C"
              ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
              [ "$TEMP" -gt "$MAX_TEMP" ] && MAX_TEMP=$TEMP
            else
              TEMPS_LOG="$TEMPS_LOG $name=?"
              ERROR_COUNT=$((ERROR_COUNT + 1))
            fi
          elif [ "$RC" -eq 2 ]; then
            # Platte im Standby — nicht geweckt, nicht in max_temp eingerechnet
            TEMPS_LOG="$TEMPS_LOG $name=STANDBY"
            STANDBY_COUNT=$((STANDBY_COUNT + 1))
          else
            TEMPS_LOG="$TEMPS_LOG $name=ERR(rc=$RC)"
            ERROR_COUNT=$((ERROR_COUNT + 1))
          fi
        done

        LAST_LEVEL="$(cat "$STATE_FILE" 2>/dev/null || echo 1)"
        case "$LAST_LEVEL" in 0|1|2|3|4) ;; *) LAST_LEVEL=1 ;; esac

        # ---------- Failsafe: alle Platten unlesbar ----------
        if [ "$ACTIVE_COUNT" -eq 0 ] && [ "$STANDBY_COUNT" -eq 0 ] && [ "$ERROR_COUNT" -gt 0 ]; then
          echo "ERROR: keine HDD lesbar (err=$ERROR_COUNT) — Failsafe pwm=$FAILSAFE_PWM" >&2
          echo "$FAILSAFE_PWM" > "$PWM_FILE"
          sleep 30
          continue
        fi

        # ---------- Level berechnen ----------
        if [ "$ACTIVE_COUNT" -eq 0 ]; then
          NEW_LEVEL=0
        else
          if   [ "$MAX_TEMP" -ge 53 ]; then RAW=4
          elif [ "$MAX_TEMP" -ge 45 ]; then RAW=3
          elif [ "$MAX_TEMP" -ge 38 ]; then RAW=2
          else                              RAW=1
          fi

          if [ "$RAW" -ge "$LAST_LEVEL" ]; then
            # Hochregeln: sofort
            NEW_LEVEL=$RAW
          else
            # Runterregeln nur bei 4°C unter der unteren Level-Grenze
            case "$LAST_LEVEL" in
              4) DOWN=49 ;;   # 53 - 4
              3) DOWN=41 ;;   # 45 - 4
              2) DOWN=34 ;;   # 38 - 4
              *) DOWN=0  ;;
            esac
            if [ "$MAX_TEMP" -lt "$DOWN" ]; then
              NEW_LEVEL=$((LAST_LEVEL - 1))
            else
              NEW_LEVEL=$LAST_LEVEL
            fi
          fi
        fi

        # ---------- PWM + Sleep zum Level ----------
        case "$NEW_LEVEL" in
          0) PWM=25;  SLEEP=600 ;;
          1) PWM=50;  SLEEP=600 ;;
          2) PWM=130; SLEEP=120 ;;
          3) PWM=200; SLEEP=30  ;;
          4) PWM=255; SLEEP=15  ;;
        esac

        if ! echo "$PWM" > "$PWM_FILE"; then
          echo "ERROR: konnte pwm=$PWM nicht schreiben" >&2
          sleep 30
          continue
        fi
        echo "$NEW_LEVEL" > "$STATE_FILE"

        echo "hdd-fan-control: max=''${MAX_TEMP}C active=$ACTIVE_COUNT standby=$STANDBY_COUNT err=$ERROR_COUNT level=$NEW_LEVEL pwm=$PWM next=''${SLEEP}s temps:$TEMPS_LOG"

        sleep "$SLEEP"
      done
    '';
  };
in
{
  environment.systemPackages = [ hddFanControl ];

  # ------------------------------------------------------------
  # Long-running Daemon (kein Timer mehr!)
  # ------------------------------------------------------------
  systemd.services.hdd-fan-control = {
    description = "HDD-temperature-based fan control daemon (adaptive)";
    wantedBy = [ "multi-user.target" ];
    after = [ "fan-control.service" "systemd-modules-load.service" ];
    wants = [ "fan-control.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${hddFanControl}/bin/hdd-fan-control";
      Restart = "on-failure";
      RestartSec = "30s";
      # SIGTERM an das Script -> cleanup trap -> Auto-Mode restore
      KillSignal = "SIGTERM";
      TimeoutStopSec = "10s";
    };
  };
}
