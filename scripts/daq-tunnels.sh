#!/usr/bin/env bash
# Open SSH tunnels for Mu2e shifter GUIs
# Usage: daq-tunnels {start|stop|restart|status} [port_offset]

set -u

action="${1:-start}"
offset="${2:-0}"

kill_tunnels() {
    pkill -f "ssh.*mu2egateway" 2>/dev/null
    pkill -f "ssh.*mu2e-" 2>/dev/null
    pkill -f "ssh.*(cfo|dl|dcs)-01" 2>/dev/null
}

case "$action" in
    stop)
        echo "Stopping tunnels..."
        kill_tunnels
        sleep 2
        if lsof -i -P -n 2>/dev/null | grep ssh | grep -q LISTEN; then
            echo "  Some ports still bound, force killing..."
            pkill -9 -f "ssh.*mu2egateway" 2>/dev/null
            pkill -9 -f "ssh.*mu2e-" 2>/dev/null
            pkill -9 -f "ssh.*(cfo|dl|dcs)-01" 2>/dev/null
            sleep 1
        fi
        echo "  Done"
        ;;

    start)
        "$0" stop

        if ! klist -s 2>/dev/null; then
            echo "No valid Kerberos ticket. Please run kinit..."
            exit 1
        fi

        cfo=$((3095 + offset))
        calo=$((3025 + offset))
        crv=$((3085 + offset))
        shift_=$((3075 + offset))
        trig=$((3045 + offset))
        dqm=$((5029 + offset))
        dqmvis=$((5033 + offset))
        stm=$((30351 + offset))
        trk=$((3065 + offset))
        crvdqm=$((8877))

        echo "Starting DAQ tunnels (offset=$offset)..."
        ssh -f -K -N -q -o ExitOnForwardFailure=yes \
            -J mu2eshift@mu2egateway02.fnal.gov \
            -L $shift_:mu2e-cfo-01:$shift_ \
            -L $crv:mu2e-cfo-01:$crv \
            -L $calo:mu2e-cfo-01:$calo \
            -L $trig:mu2e-cfo-01:$trig \
            -L $dqm:mu2e-cfo-01:$dqm \
            -L $dqmvis:mu2e-dl-01-data:$dqmvis \
            -L $crvdqm:mu2e-dl-01:$crvdqm \
            -L $cfo:mu2e-cfo-01:$cfo \
            -L $stm:mu2e-cfo-01:$stm \
            -L $trk:mu2e-cfo-01:$trk \
            mu2eshift@mu2e-dcs-01.fnal.gov >/dev/null 2>&1 \
            && echo "  DAQ: OK" || echo "  DAQ: FAILED"

        echo "Starting Grafana tunnel..."
        ssh -f -K -N -q -o ExitOnForwardFailure=yes \
            -J mu2eshift@mu2egateway02.fnal.gov \
            -L 3000:mu2e-dcs-01:3000 \
            mu2eshift@mu2e-dcs-01.fnal.gov >/dev/null 2>&1 \
            && echo "  Grafana: OK" || echo "  Grafana: FAILED"
        ;;

    restart)
        "$0" stop
        "$0" start "$offset"
        ;;

    status)
        echo "Tunnel processes:"
        ps aux | grep -E "ssh.*(mu2e|cfo|dl|dcs)" | grep -v grep \
            || echo "  None running"
        echo ""
        echo "Forwarded ports:"
        lsof -i -P -n 2>/dev/null | grep ssh | grep LISTEN \
            || echo "  None"
        ;;

    *)
        echo "Usage: daq-tunnels {start|stop|restart|status} [port_offset]"
        exit 1
        ;;
esac
