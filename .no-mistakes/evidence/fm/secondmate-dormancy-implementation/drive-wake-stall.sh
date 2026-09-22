#!/usr/bin/env bash
# Live-drive the wake-loop stall gate for a dormant mate (bin/fm-watch-checkpoint.sh).
# A dormant mate's frozen queue must NOT escalate as a stalled wake loop; the same
# frozen queue escalates once the mate is awake.
set -u
ROOT=${ROOT:?}
export FM_GATE_REFUSE_BYPASS=1

dir=$(mktemp -d /tmp/fm-wake-dormancy.XXXXXX)
state=$dir/state
sub=$dir/secondmate
mkdir -p "$state" "$sub/state"
printf 'mate\n' > "$sub/.fm-secondmate-home"
printf 'window=firstmate:fm-mate\nkind=secondmate\nhome=%s\n' "$sub" > "$state/mate.meta"
epoch=$(( $(date +%s) - 10 ))
printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$epoch" > "$sub/state/.wake-queue"
fakebin=$dir/fakebin
mkdir -p "$fakebin"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' 'firstmate:fm-mate' ;;
  capture-pane) printf 'ready\n' ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fakebin/tmux"
: > "$state/mate.dormant"

PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$state" FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 4 \
  > "$dir/watch-dormant.out" 2> "$dir/watch-dormant.err" || true
echo "dormant-stall-escalated=$(grep -c 'secondmate wake-loop stalled' "$dir/watch-dormant.out" || true)"
echo "dormant-durable-notice=$(test -s "$state/.wake-queue" && echo present || echo absent)"

rm -f "$state/mate.dormant"
printf '%s\t%s-7\n' "$epoch" "$epoch" > "$state/.secondmate-wake-progress-mate"
PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$state" FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 \
  FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 4 \
  > "$dir/watch-awake.out" 2> "$dir/watch-awake.err" || true
echo "awake-stall-line=$(grep -c 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch-awake.out" || true)"
echo "awake-durable-notices=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)"
echo "TMP=$dir"
