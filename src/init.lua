local CP_MONITOR_META = { driver_name = "C.P Wallpad Network Monitor", driver_version = "v1.1.5", package_key = "cp-wallpad-network-monitor-v100", target_name = "Network Targets", transport = "tcp" }
local cp_monitor = require "cp_monitor"
local health_state = require "health_state"
local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local socket = require "cosock.socket"

local DRIVER_VERSION = "v1.1.5"
local AUTHOR = "치즈가루"
local DEVICE_DNI = "cp-wallpad-network-monitor"
local DEVICE_PROFILE = "cp-wallpad-network-monitor"
local MAX_TARGETS = 8

local monitor_cap = capabilities["buildbook37604.wallpadStatusV102"]
local summary_cap = capabilities["buildbook37604.wallpadSummaryV102"]
local checked_cap = capabilities["buildbook37604.wallpadCheckedV102"]
local info_cap = capabilities["buildbook37604.driverInformation"]

local generations = {}
local states = {}
local health = {}
local signatures = {}
local checked_emit_at = {}
local pref_restart_seq = {}
local summary_cache = {}

local availability_retry_after = {}
local AVAILABILITY_REFRESH_SECONDS = 60

-- The monitor device represents an active Edge monitor, not any one TCP target.
-- Keep SmartThings device availability independent from target1..target8 status;
-- marking the monitor OFFLINE when a target fails would hide the monitoring UI.
local function refresh_device_availability(device, force)
  local did = device.id
  local now = os.time()
  local next_due = availability_retry_after[did] or 0
  if not force and now < next_due then return end
  availability_retry_after[did] = now + AVAILABILITY_REFRESH_SECONDS
  local ok, err = pcall(function() device:online() end)
  if not ok then
    log.warn("Monitor availability refresh failed: " .. tostring(err))
  end
end

local function kst_now()
  return os.date("!%Y-%m-%d %H:%M:%S", os.time() + (9 * 60 * 60))
end

local function find_by_dni(driver, dni)
  for _, d in ipairs(driver:get_devices()) do
    if d.device_network_id == dni then return d end
  end
  return nil
end

local function ensure_device(driver)
  if find_by_dni(driver, DEVICE_DNI) then return end
  local metadata = {
    type = "LAN",
    device_network_id = DEVICE_DNI,
    label = "월패드 네트워크 상태",
    profile = DEVICE_PROFILE,
    manufacturer = "C.P",
    model = "Wallpad Network Monitor",
    vendor_provided_label = "월패드 네트워크 상태"
  }
  local ok, err = driver:try_create_device(metadata)
  if ok == false then log.error("try_create_device failed: " .. tostring(err)) end
end

local function discovery_handler(driver, opts, should_continue)
  log.info("Wallpad Network Monitor discovery requested")
  ensure_device(driver)
end

local function emit_info(device)
  if info_cap then
    device:emit_event(info_cap.author(AUTHOR))
    device:emit_event(info_cap.driverVersion(DRIVER_VERSION))
  end
end

local function pref(device, key, fallback)
  local v = device.preferences and device.preferences[key]
  if v == nil then return fallback end
  return v
end

local function as_bool(v, fallback)
  if v == nil then return fallback == true end
  if type(v) == "boolean" then return v end
  if type(v) == "number" then return v ~= 0 end
  if type(v) == "string" then
    local s = string.lower(v)
    if s == "true" or s == "1" or s == "on" or s == "yes" then return true end
    if s == "false" or s == "0" or s == "off" or s == "no" or s == "" then return false end
  end
  return fallback == true
end

local function target_config(device, slot)
  local raw_enabled = pref(device, "target" .. slot .. "Enabled", false)
  local ip = tostring(pref(device, "target" .. slot .. "Ip", "") or "")
  local configured_port = tonumber(pref(device, "target" .. slot .. "Port", 80)) or 80
  local port = configured_port

  -- IP101: 8899 is the live RS485 door bridge and must not be used for
  -- periodic health probes. Firmware exposes dedicated health TCP 8898.
  -- Existing installations that still have the old default 8899 are migrated
  -- internally so updating the driver does not require recreating the device.
  if ip == "192.168.1.101" and configured_port == 8899 then
    port = 8898
  end

  return {
    enabled = as_bool(raw_enabled, false),
    raw_enabled = raw_enabled,
    name = tostring(pref(device, "target" .. slot .. "Name", "대상 " .. slot) or "대상 " .. slot),
    ip = ip,
    port = port,
    configured_port = configured_port
  }
end

local function state_label(status)
  if status == "online" then return "정상" end
  if status == "offline" then return "비정상" end
  if status == "disabled" then return "미사용" end
  return "확인 중"
end

local function emit_slot_summary(device, slot, status, force)
  local cfg = target_config(device, slot)
  local addr = cfg.ip
  if addr ~= "" and cfg.port then addr = addr .. ":" .. tostring(cfg.port) end
  if addr == "" then addr = "주소 미설정" end
  local text = status == "disabled" and (cfg.name .. " · 미사용") or (cfg.name .. " · " .. state_label(status) .. " · " .. addr)

  local did = device.id
  summary_cache[did] = summary_cache[did] or {}
  if summary_cap and (force or summary_cache[did][slot] ~= text) then
    device:emit_component_event(device.profile.components["target" .. slot], summary_cap.summary(text))
    summary_cache[did][slot] = text
  end
end

local function genuine_state_transition(old, new)
  return (new == "offline" and (old == "online" or old == "checking")) or
         (old == "offline" and new == "online")
end

local function emit_slot_status(device, slot, status, force, suppress_alert)
  local did = device.id
  states[did] = states[did] or {}
  local old = states[did][slot]
  states[did][slot] = status
  local changed = old ~= status
  if monitor_cap and (force or changed) then
    local signal = changed and not suppress_alert and genuine_state_transition(old, status) or false
    device:emit_component_event(device.profile.components["target" .. slot],
      monitor_cap.status(status, { state_change = signal }))
    log.info(string.format("Target %d status %s -> %s (routine=%s)",
      slot, tostring(old), status, tostring(signal)))
  end
  emit_slot_summary(device, slot, status, force or changed)
end

local function recalc_overall(device, suppress_alert)
  local did = device.id
  states[did] = states[did] or {}
  local enabled, offline, checking = 0, 0, 0
  for i = 1, MAX_TARGETS do
    local cfg = target_config(device, i)
    if cfg.enabled then
      enabled = enabled + 1
      local st = states[did][i] or "checking"
      if st == "offline" then offline = offline + 1
      elseif st == "checking" then checking = checking + 1 end
    end
  end
  local overall = "online"
  if enabled == 0 then overall = "disabled"
  elseif offline > 0 then overall = "offline"
  elseif checking > 0 then overall = "checking" end
  if monitor_cap then
    local current = device:get_latest_state("main", monitor_cap.ID, "status")
    if current ~= overall then
      local signal = not suppress_alert and genuine_state_transition(current, overall) or false
      device:emit_event(monitor_cap.status(overall, { state_change = signal }))
    end
  end
  if checked_cap then
    local now = os.time()
    if not checked_emit_at[did] or now - checked_emit_at[did] >= 60 then
      device:emit_event(checked_cap.lastChecked(kst_now()))
      checked_emit_at[did] = now
    end
  end
end

-- Do not let a socket implementation/runtime exception terminate the worker.
-- An internal driver error is *not* evidence that a target is offline.
local function tcp_check(ip, port, timeout)
  if ip == nil or ip == "" or port == nil then return false, "missing address", "configuration" end
  local created, tcp, create_err = pcall(socket.tcp)
  if not created or not tcp then
    return false, "socket creation error: " .. tostring(created and create_err or tcp), "internal"
  end
  local configured, timeout_result, timeout_err = pcall(function() return tcp:settimeout(timeout) end)
  if not configured or timeout_result == nil or timeout_result == false then
    pcall(function() tcp:close() end)
    return false, "socket timeout setup error: " .. tostring(configured and timeout_err or timeout_result), "internal"
  end
  local executed, connected, err = pcall(function() return tcp:connect(ip, port) end)
  pcall(function() tcp:close() end)
  if not executed then return false, "socket connect exception: " .. tostring(connected), "internal" end
  if connected and connected ~= false then return true, nil, nil end
  return false, tostring(err or "TCP connect failed"), "target"
end

local function cached_target_status(device, slot)
  if not monitor_cap then return nil end
  local ok, value = pcall(function()
    return device:get_latest_state("target" .. slot, monitor_cap.ID, "status")
  end)
  if ok and (value == "online" or value == "offline") then return value end
  return nil
end

local function config_signature(cfg)
  return table.concat({ tostring(cfg.enabled), tostring(cfg.ip), tostring(cfg.port) }, "|")
end

local function restored_target_status(device, slot, signature)
  local ok_sig, stored_sig = pcall(function()
    return device:get_field("cp_nmon_signature_" .. slot)
  end)
  local ok_status, value = pcall(function()
    return device:get_field("cp_nmon_verified_status_" .. slot)
  end)
  if ok_sig and ok_status and stored_sig == signature and
      (value == "online" or value == "offline") then return value end
  return cached_target_status(device, slot)
end

local function persist_target_status(device, slot, signature, value)
  if value ~= "online" and value ~= "offline" then return end
  -- Write only on confirmed changes, not every probe, to avoid flash wear.
  pcall(function()
    device:set_field("cp_nmon_signature_" .. slot, signature, { persist = true })
    device:set_field("cp_nmon_verified_status_" .. slot, value, { persist = true })
  end)
end

local function run_monitor_cycle(device, generation)
  local did = device.id
  if generations[did] ~= generation then return end
  -- Reassert device availability after temporary hub/network disruption,
  -- even when one or more monitored services legitimately remain offline.
  refresh_device_availability(device, false)

  local timeout = math.max(1, math.min(10, tonumber(pref(device, "connectTimeout", 2)) or 2))
  local threshold = math.max(1, math.min(10, tonumber(pref(device, "failThreshold", 3)) or 3))
  local success_threshold = math.max(1, math.min(10, tonumber(pref(device, "successThreshold", 3)) or 3))
  local interval = math.max(5, math.min(300, tonumber(pref(device, "checkInterval", 10)) or 10))

  local state_changed_this_cycle = false
  for slot = 1, MAX_TARGETS do
    if generations[did] ~= generation then return end

    local cfg = target_config(device, slot)
    local observation = health[did] and health[did][slot]
    if not cfg.enabled then
      if not observation or observation.status ~= "disabled" then
        health[did][slot] = health_state.new("disabled")
        emit_slot_status(device, slot, "disabled", false, true)
      end
    elseif observation then
      log.debug(string.format("TCP service check target %d: %s %s:%d", slot, cfg.name, cfg.ip, cfg.port))
      local ok, err, category = tcp_check(cfg.ip, cfg.port, timeout)
      if generations[did] ~= generation then return end
      if category == "internal" then
        -- Skip this sample. Raising an offline event for a local socket error
        -- wrongly blames the ESP device and can cause notification storms.
        local now = os.time()
        if observation.last_internal_log == nil or now - observation.last_internal_log >= 60 then
          log.error(string.format("Monitor internal socket failure for target %d: %s", slot, tostring(err)))
          observation.last_internal_log = now
        end
      else
        local prev = observation.status
        local changed, signal = health_state.observe(observation, ok, os.time(), threshold, success_threshold)
        if changed then
          state_changed_this_cycle = state_changed_this_cycle or signal
          persist_target_status(device, slot, config_signature(cfg), observation.status)
          emit_slot_status(device, slot, observation.status, false, not signal)
          if observation.status == "offline" then
            log.error(string.format("Confirmed TCP service failure target %d: %s %s:%d; %s; failed for >=%ds",
              slot, cfg.name, cfg.ip, cfg.port, tostring(err), health_state.MIN_FAILURE_SECONDS))
          else
            log.info(string.format("TCP service target %d %s -> %s", slot, prev, observation.status))
          end
        elseif not ok then
          if observation.fail_count == 1 then
            log.warn(string.format("Transient TCP failure target %d: %s %s:%d: %s; holding %s",
              slot, cfg.name, cfg.ip, cfg.port, tostring(err), observation.status))
          else
            log.debug(string.format("TCP failure target %d (%d/%d): %s; holding %s",
              slot, observation.fail_count, threshold, tostring(err), observation.status))
          end
        end
        if ok then
          log.debug(string.format("TCP service OK target %d: %s:%d", slot, cfg.ip, cfg.port))
        else
          observation.last_error = tostring(err)
        end
      end
    end
  end

  recalc_overall(device, false)
  local offline_targets = {}
  for slot = 1, MAX_TARGETS do
    local cfg = target_config(device, slot)
    if cfg.enabled and states[did][slot] == "offline" then
      local obs = health[did] and health[did][slot]
      table.insert(offline_targets, string.format("target %d %s %s:%d (%s)",
        slot, cfg.name, cfg.ip, cfg.port, tostring(obs and obs.last_error or "no TCP response")))
    end
  end
  pcall(cp_monitor.poll, device, #offline_targets == 0,
    #offline_targets > 0 and table.concat(offline_targets, "; ") or nil)
  if state_changed_this_cycle then
    -- Capture a confirmed state transition in NAS telemetry immediately,
    -- rather than waiting for the ordinary 60-second Edge heartbeat.
    pcall(cp_monitor.send, device)
  end

  if generations[did] == generation then
    local invoke
    invoke = function()
      if generations[did] ~= generation then return end
      local success, message = pcall(run_monitor_cycle, device, generation)
      if not success then
        log.error("Network monitor worker error: " .. tostring(message))
        if generations[did] == generation then
          device.thread:call_with_delay(math.max(10, interval), invoke, "network-monitor-retry")
        end
      end
    end
    device.thread:call_with_delay(interval, invoke, "network-monitor-cycle")
  end
end

local function stop_workers(device)
  local did = device.id
  generations[did] = (generations[did] or 0) + 1
end

local function start_workers(device)
  stop_workers(device)
  local did = device.id
  local generation = generations[did]
  states[did] = states[did] or {}
  health[did] = health[did] or {}
  signatures[did] = signatures[did] or {}
  summary_cache[did] = summary_cache[did] or {}

  for i = 1, MAX_TARGETS do
    local cfg = target_config(device, i)
    local sig = config_signature(cfg)
    local new_or_changed = health[did][i] == nil or signatures[did][i] ~= sig
    if new_or_changed then
      -- Restore SmartThings' previous confirmed value. Do NOT emit an
      -- artificial 'checking' state during refresh or IP/port edits: an
      -- attribute value change can trigger automations even with
      -- state_change=false, according to SmartThings SDK semantics.
      local prior = states[did][i] or restored_target_status(device, i, sig)
      local initial
      if not cfg.enabled then
        initial = "disabled"
      elseif prior == "online" or prior == "offline" then
        initial = prior
      else
        initial = "checking"
      end
      health[did][i] = health_state.new(initial)
      signatures[did][i] = sig
      if prior == initial then
        states[did][i] = initial
        emit_slot_summary(device, i, initial, true)
      else
        emit_slot_status(device, i, initial, false, true)
      end
    else
      emit_slot_summary(device, i, health[did][i].status, false)
    end
  end
  recalc_overall(device, true)

  local invoke
  invoke = function()
    if generations[did] ~= generation then return end
    local success, message = pcall(run_monitor_cycle, device, generation)
    if not success then
      log.error("Network monitor initial worker error: " .. tostring(message))
      if generations[did] == generation then
        device.thread:call_with_delay(10, invoke, "network-monitor-start-retry")
      end
    end
  end
  device.thread:call_with_delay(0.2, invoke, "network-monitor-cycle")
end

local function activate_device(driver, device)
  device:try_update_metadata({ profile = DEVICE_PROFILE })
  -- Recover the existing LAN device's SmartThings OFFLINE status on driver init.
  refresh_device_availability(device, true)
  emit_info(device)
  start_workers(device)
end

local function added(driver, device)
  activate_device(driver, device)
end

local function init(driver, device)
  pcall(cp_monitor.start, device, CP_MONITOR_META)
  activate_device(driver, device)
end

local function info_changed(driver, device, event, args)
  local did = device.id
  pref_restart_seq[did] = (pref_restart_seq[did] or 0) + 1
  local seq = pref_restart_seq[did]

  -- SmartThings can deliver several preference changes back-to-back.
  -- Delay the restart briefly so device.preferences contains the final saved values.
  log.info("Preferences changed; waiting for final preference values")
  device.thread:call_with_delay(1.0, function()
    if pref_restart_seq[did] ~= seq then return end

    for i = 1, MAX_TARGETS do
      local cfg = target_config(device, i)
      log.info(string.format(
        "Applied target %d: enabled=%s raw=%s(%s) name=%s address=%s:%d",
        i, tostring(cfg.enabled), tostring(cfg.raw_enabled), type(cfg.raw_enabled), cfg.name, cfg.ip, cfg.port
      ))
      emit_slot_summary(device, i, cfg.enabled and (states[did] and states[did][i] or "checking") or "disabled", false)
    end

    emit_info(device)
    start_workers(device)
  end, "apply-network-monitor-preferences")
end

local function removed(driver, device)
  stop_workers(device)
  states[device.id] = nil
  health[device.id] = nil
  signatures[device.id] = nil
  checked_emit_at[device.id] = nil
  pref_restart_seq[device.id] = nil
  summary_cache[device.id] = nil
  availability_retry_after[device.id] = nil
end

local function refresh_handler(driver, device, command)
  log.info("Manual refresh requested")
  refresh_device_availability(device, true)
  start_workers(device)
end

log.info("C.P Wallpad Network Monitor " .. DRIVER_VERSION .. " loading")

local driver = Driver("cp-wallpad-network-monitor", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    added = added,
    init = init,
    infoChanged = info_changed,
    removed = removed
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler
    }
  }
})

driver:run()
