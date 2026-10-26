-- Chrome Remote Desktop: registered key -> Korean 2-Set / ABC.
-- init.lua only needs: dofile(hs.configdir .. "/lang1-korean.lua")
if crdLang1Korean then return end
crdLang1Korean = {}
local M = crdLang1Korean
local K = dofile(hs.configdir .. "/key-input.lua")
local types = hs.eventtap.event.types
local props = hs.eventtap.event.properties
local english = "com.apple.keylayout.ABC"
local korean = "com.apple.inputmethod.Korean.2SetKorean"
local settingKey = "crdHangulRegisteredKeyV1"
local requestPath = hs.configdir .. "/.crd-register-key"

function M.toggle()
    local target = hs.keycodes.currentSourceID() == korean and english or korean
    if hs.keycodes.currentSourceID(target) then
        hs.alert.show(target == korean and "한글" or "ABC", 0.6)
    else
        hs.alert.show("입력 소스에 한국어 두벌식과 ABC를 추가해 주세요.")
    end
end

function M.setMapping(spec)
    assert(K.valid(spec), "Invalid registered key")
    M.mapping = spec
    M.match = K.matcher(spec)
end
local saved = hs.settings.get(settingKey)
M.setMapping(K.valid(saved) and saved or {kind = "key", code = 104})

M.registration = dofile(hs.configdir .. "/key-registration.lua")(M, K, function(spec)
    hs.settings.set(settingKey, spec)
    M.setMapping(spec)
end)
M.register = function() M.registration:start() end

M.tap = hs.eventtap.new({types.keyDown, types.keyUp, types.flagsChanged}, function(event)
    local eventType = event:getType()
    local e = {
        type = eventType == types.keyDown and "down" or eventType == types.keyUp and "up" or "flags",
        code = event:getKeyCode(), flags = event:getFlags(),
        repeatKey = eventType == types.keyDown and event:getProperty(props.keyboardEventAutorepeat) ~= 0,
    }
    if M.registration.active then return M.registration:feed(e) end
    local toggle, swallow = M.match(e)
    if toggle then M.toggle() end
    return swallow
end):start()

M.menu = hs.menubar.new()
if M.menu then
    M.menu:setTitle("한/영")
    M.menu:setTooltip("클릭: 한/영 전환 · Option+클릭: 키 다시 등록")
    M.menu:setClickCallback(function(flags)
        if M.registration.active then
            M.registration:cancelCapture()
        elseif flags and flags.alt then
            M.register()
        else
            M.toggle()
        end
    end)
end

if not M.tap:isEnabled() then
    hs.alert.show("Hammerspoon 손쉬운 사용 권한을 켜고 앱을 다시 실행해 주세요.")
end

-- The installer leaves a request across the first permission grant/relaunch.
if hs.fs.attributes(requestPath, "mode") == "file" then
    M.startupTimer = hs.timer.doAfter(2, function()
        if hs.accessibilityState() and M.tap:isEnabled() then
            M.register()
            if M.registration.active then os.remove(requestPath) end
        end
    end)
end
