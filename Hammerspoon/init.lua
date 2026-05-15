local appNameNeedle = "subway"

local directions = {
  w = { 0, -18 },
  up = { 0, -18 },
  s = { 0, 18 },
  down = { 0, 18 },
  a = { -18, 0 },
  left = { -18, 0 },
  d = { 18, 0 },
  right = { 18, 0 },
}

local function subwayIsFrontmost()
  local app = hs.application.frontmostApplication()
  if not app then
    return false
  end

  local name = string.lower(app:name() or "")
  local bundleID = string.lower(app:bundleID() or "")
  return string.find(name, appNameNeedle, 1, true) ~= nil
    or string.find(bundleID, appNameNeedle, 1, true) ~= nil
end

local function postSwipe(delta)
  for _ = 1, 5 do
    hs.eventtap.scrollWheel(delta, {}, "pixel"):post()
    hs.timer.usleep(4500)
  end
end

for key, delta in pairs(directions) do
  hs.hotkey.bind({}, key, nil, function()
    if subwayIsFrontmost() then
      postSwipe(delta)
    else
      hs.eventtap.keyStroke({}, key, 0)
    end
  end)
end

hs.alert.show("SwipeKeys loaded")
