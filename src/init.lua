local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local log = require "log"
local socket = require "cosock.socket"

local DRIVER_VERSION = "v1.1.2"
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
local failures = {}
local successes = {}
local pref_restart_seq = {}
local summary_cache = {}

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

local function emit_slot_status(device, slot, status, force)
  local did = device.id
  states[did] = states[did] or {}
  local old = states[did][slot]
  states[did][slot] = status
  local changed = old ~= status
  if monitor_cap and (force or changed) then
    device:emit_component_event(device.profile.components["target" .. slot], monitor_cap.status(status, { state_change = changed }))
    log.info(string.format("Target %d status %s -> %s", slot, tostring(old), status))
  end
  emit_slot_summary(device, slot, status, force or changed)
end

local function recalc_overall(device)
  local did = device.id
  states[did] = states[did] or {}
  local enabled, offline, checking = 0, 0, 0
  for i = 1, MAX_TARGETS do
    local cfg = target_config(device, i)
    if cfg.enabled then
      enabled = enabled + 1
      local st = states[did][i] or "checking"
      if st == "offline" then offline = offline + 1 elseif st == "checking" then checking = checking + 1 end
    end
  end
  local overall = "online"
  if enabled == 0 then overall = "disabled" elseif offline > 0 then overall = "offline" elseif checking > 0 then overall = "checking" end
  if monitor_cap then
    local current = device:get_latest_state("main", monitor_cap.ID, "status")
    if current ~= overall then device:emit_event(monitor_cap.status(overall, { state_change = true })) end
  end
  if checked_cap then device:emit_event(checked_cap.lastChecked(kst_now())) end
end

local function tcp_check(ip, port, timeout)
  if ip == nil or ip == "" or port == nil then return false, "missing address" end
  local tcp = socket.tcp()
  tcp:settimeout(timeout)
  local ok, err = tcp:connect(ip, port)
  pcall(function() tcp:close() end)
  return ok ~= nil and ok ~= false, err
end

local function run_monitor_cycle(device, generation)
  local did = device.id
  if generations[did] ~= generation then return end

  local timeout = tonumber(pref(device, "connectTimeout", 2)) or 2
  local threshold = tonumber(pref(device, "failThreshold", 3)) or 3
  local success_threshold = tonumber(pref(device, "successThreshold", 3)) or 3
  local interval = math.max(5, tonumber(pref(device, "checkInterval", 10)) or 10)

  for slot = 1, MAX_TARGETS do
    if generations[did] ~= generation then return end

    local cfg = target_config(device, slot)
    if not cfg.enabled then
      failures[did][slot] = 0
      successes[did][slot] = 0
      emit_slot_status(device, slot, "disabled", false)
    else
      if (states[did][slot] == nil) or states[did][slot] == "disabled" then
        emit_slot_status(device, slot, "checking", true)
      end

      log.info(string.format("Checking target %d: %s %s:%d", slot, cfg.name, cfg.ip, cfg.port))
      local ok, err = tcp_check(cfg.ip, cfg.port, timeout)

      if ok then
        failures[did][slot] = 0
        successes[did][slot] = (successes[did][slot] or 0) + 1
        local current = states[did][slot]
        -- Do not bounce offline -> online on a single successful probe.
        -- Require consecutive successes after an outage. Initial checking can
        -- become online immediately so startup does not take unnecessarily long.
        if current == "offline" then
          log.info(string.format("Target %d recovery success (%d/%d): %s:%d",
            slot, successes[did][slot], success_threshold, cfg.ip, cfg.port))
          if successes[did][slot] >= success_threshold then
            emit_slot_status(device, slot, "online", false)
          end
        else
          emit_slot_status(device, slot, "online", false)
        end
        log.info(string.format("Target %d OK: %s:%d", slot, cfg.ip, cfg.port))
      else
        successes[did][slot] = 0
        failures[did][slot] = (failures[did][slot] or 0) + 1
        log.warn(string.format("Target %d %s %s:%d failed (%d/%d): %s",
          slot, cfg.name, cfg.ip, cfg.port, failures[did][slot], threshold, tostring(err)))
        if failures[did][slot] >= threshold then
          emit_slot_status(device, slot, "offline", false)
        end
      end
    end
  end

  recalc_overall(device)

  if generations[did] == generation then
    device.thread:call_with_delay(interval, function()
      run_monitor_cycle(device, generation)
    end, "network-monitor-cycle")
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
  failures[did] = {}
  successes[did] = {}
  summary_cache[did] = summary_cache[did] or {}

  for i = 1, MAX_TARGETS do
    failures[did][i] = 0
    successes[did][i] = 0
    local cfg = target_config(device, i)

    if not cfg.enabled then
      emit_slot_status(device, i, "disabled", states[did][i] == nil)
    elseif states[did][i] == nil or states[did][i] == "disabled" then
      emit_slot_status(device, i, "checking", true)
    else
      -- Manual refresh / preference debounce must not force online devices
      -- through a synthetic checking -> online transition.
      emit_slot_summary(device, i, states[did][i], false)
    end
  end
  recalc_overall(device)

  -- IMPORTANT: run one finite cycle and return.  The older implementation
  -- started one endless callback per target; target 1 occupied the device
  -- thread, so target 2+ could remain permanently at "checking" and
  -- preference changes could be delayed.  A finite recurring cycle keeps
  -- the device thread free between checks.
  device.thread:call_with_delay(0.2, function()
    run_monitor_cycle(device, generation)
  end, "network-monitor-cycle")
end

local function activate_device(driver, device)
  device:try_update_metadata({ profile = DEVICE_PROFILE })
  emit_info(device)
  start_workers(device)
end

local function added(driver, device)
  activate_device(driver, device)
end

local function init(driver, device)
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
  failures[device.id] = nil
  successes[device.id] = nil
  pref_restart_seq[device.id] = nil
  summary_cache[device.id] = nil
end

local function refresh_handler(driver, device, command)
  log.info("Manual refresh requested")
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
