C.P Wallpad Network Monitor v1.1.5 - Online Recovery

Update on the existing SmartThings hub:
1. Extract ZIP to its own folder.
2. Double-click UPDATE-EXISTING.cmd. (UPDATE-DRIVER.cmd is the same updater.)
3. Do NOT run first-time setup or delete/re-add the device.
4. Confirm the existing device '월패드 네트워크 상태' becomes ONLINE.
5. Confirm 8 target statuses, names, intervals, 90-second failure and
   20-second recovery timing, and routines continue to work as before.

The monitoring device is ONLINE when the Edge driver itself runs.
Individual TCP targets are evaluated separately; a failed target does NOT
mark the monitor device offline. On init and every 60 seconds it reasserts
its own availability to SmartThings. Target outage/recovery events stay as is.

UNCHANGED: 8 targets, target host/port settings, 101:8899 -> 8898 probe
redirect, routines, TCP classification rules, monitor telemetry, capabilities,
profile, device presentation VID and packageKey.

Existing identity:
Package key cp-wallpad-network-monitor-v100
Driver ID b08dbe13-6340-4c77-8939-5b3e2ea4c837
Hub ID c9e6b370-41a7-499a-ae95-3496747cd165
Channel ID cd373cad-c1db-4b2a-943b-6ed6fb51d2fa
VID 40758e17-c4bc-3b3f-a549-a3562f312024

Local Lua/JSON/YAML/ZIP checks do not guarantee successful deployment.
Update on the real hub and verify the existing device afterwards.

Previous v1.1.4 notes retained in docs/README-v1.1.4.txt.
