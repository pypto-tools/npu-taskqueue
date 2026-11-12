#!/usr/bin/env bash
# Compatibility entry point for obsolete timers. Hardware sampling now runs
# inside each queue job after the device locks have been acquired.
echo 'NPU sampling runs inside allocated tasks; the standalone timer is retired.' >&2
exit 0
