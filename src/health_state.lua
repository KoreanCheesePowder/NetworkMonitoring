-- Pure, deterministic TCP service health classification.
-- A failed TCP connect is not proof of a disconnected Wi-Fi/LAN device.
-- Leave the prior confirmed state intact until a persistent failure is observed.
local M = {}
M.MIN_FAILURE_SECONDS = 90
M.MIN_RECOVERY_SECONDS = 20

local function valid_status(s)
  return s == "online" or s == "offline" or s == "checking" or s == "disabled"
end

function M.new(previous)
  return {
    status = valid_status(previous) and previous or "checking",
    fail_count = 0,
    success_count = 0,
    fail_since = nil,
    success_since = nil,
    last_error = nil,
    last_success_at = nil,
    last_failure_at = nil,
  }
end

function M.reset(previous)
  return M.new(previous)
end

function M.observe(s, ok, now, fail_threshold, success_threshold)
  local old = s.status
  fail_threshold = math.max(1, tonumber(fail_threshold) or 3)
  success_threshold = math.max(1, tonumber(success_threshold) or 3)
  if ok then
    if s.success_count == 0 then s.success_since = now end
    s.success_count = s.success_count + 1
    s.fail_count = 0
    s.fail_since = nil
    s.last_error = nil
    s.last_success_at = now
    if s.status == "offline" then
      if s.success_count >= success_threshold and now - (s.success_since or now) >= M.MIN_RECOVERY_SECONDS then
        s.status = "online"
      end
    elseif s.status == "checking" then
      -- Initial successful connection establishes baseline without a 'recovered' alert.
      s.status = "online"
    end
  else
    if s.fail_count == 0 then s.fail_since = now end
    s.fail_count = s.fail_count + 1
    s.success_count = 0
    s.success_since = nil
    s.last_failure_at = now
    if s.status ~= "offline" and s.status ~= "disabled" and
       s.fail_count >= fail_threshold and now - (s.fail_since or now) >= M.MIN_FAILURE_SECONDS then
      s.status = "offline"
    end
  end
  local changed = old ~= s.status
  -- Newly established ONLINE is not a recovery; only confirmed failures and
  -- recovery from confirmed OFFLINE should trigger user routines.
  local event = changed and (
    (s.status == "offline" and (old == "online" or old == "checking")) or
    (s.status == "online" and old == "offline")
  )
  return changed, event
end

return M
