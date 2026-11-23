#!/bin/zsh
# One take of the scripted iOS demo (integration_test/demo_flow_test.dart):
# record the simulator screen while the test drives the app, then write the raw
# video + the test log (with DEMO_MARK timestamps) to demo_out/.
# Needs: the simulator booted and the demo account signed in once by hand.
set -e
cd "$(dirname "$0")/.."
SIM=${SIM:-DF26F490-E22F-4416-9D33-D169465C64B9}
OUT=demo_out; mkdir -p $OUT
rm -f $OUT/raw.mov $OUT/test.log
xcrun simctl terminate $SIM com.imagiastore.studio 2>/dev/null || true
xcrun simctl status_bar $SIM override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
xcrun simctl io $SIM recordVideo --codec=h264 --force $OUT/raw.mov &
REC=$!
sleep 2
REC_START=$(python3 -c 'import time; print(int(time.time()*1000))')
echo "REC_START $REC_START" > $OUT/test.log
set +e
flutter test integration_test/demo_flow_test.dart -d $SIM 2>&1 | tee -a $OUT/test.log
RC=${pipestatus[1]}
set -e
sleep 1
kill -INT $REC; wait $REC 2>/dev/null || true
xcrun simctl status_bar $SIM clear || true
echo "test exit $RC; raw video $OUT/raw.mov"
exit $RC
