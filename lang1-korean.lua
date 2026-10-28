-- Chrome Remote Desktop: registered key -> native macOS input-source shortcut.
-- init.lua only needs: dofile(hs.configdir .. "/lang1-korean.lua")
if crdLang1Korean then return end
crdLang1Korean = {}
local M = crdLang1Korean
local K = dofile(hs.configdir .. "/key-input.lua")
local types = hs.eventtap.event.types
local props = hs.eventtap.event.properties
local english = "com.apple.keylayout.ABC"
local korean = "com.apple.inputmethod.Korean.2SetKorean"
local injectedMarker = 0x4B4F5245
local settingKey = "crdHangulRegisteredKeyV1"
local requestPath = hs.configdir .. "/.crd-register-key"

local function nativeShortcut()
    -- A native shortcut cycles input sources. Keep the original explicit
    -- ABC/Korean selection when other layouts or input methods are enabled.
    local seen = {}
    for _, sources in ipairs({hs.keycodes.layouts(true), hs.keycodes.methods(true)}) do
        for _, source in ipairs(sources) do
            if source ~= english and source ~= korean then return nil end
            seen[source] = true
        end
    end
    if not seen[english] or not seen[korean] then return nil end

    -- Read the user's existing shortcuts; do not require F19 or change settings.
    -- Absent entries use macOS defaults: next=Ctrl+Option+Space, previous=Ctrl+Space.
    local preferences = hs.plist.read(os.getenv("HOME")
        .. "/Library/Preferences/com.apple.symbolichotkeys.plist") or {}
    local shortcuts = preferences.AppleSymbolicHotKeys or {}
    local modifiers = {
        {"ctrl", 0x40000}, {"alt", 0x80000}, {"shift", 0x20000},
        {"cmd", 0x100000}, {"fn", 0x800000},
    }
    local supportedMask = 0x9E0000
    for _, item in ipairs({{"61", 0xC0000}, {"60", 0x40000}}) do
        local setting = shortcuts[item[1]] or shortcuts[tonumber(item[1])]
        if setting == nil then
            setting = {enabled = true, value = {type = "standard",
                parameters = {65535, 49, item[2]}}}
        end
        local value = setting.value or {}
        local parameters = value.parameters or {}
        local code, mask = parameters[2], parameters[3]
        if (setting.enabled == true or setting.enabled == 1) and value.type == "standard"
            and type(code) == "number" and code % 1 == 0 and code >= 0 and code <= 255
            and type(mask) == "number" and mask % 1 == 0 and mask >= 0
            and (mask & ~supportedMask) == 0 then
            local flags = {}
            for _, modifier in ipairs(modifiers) do
                if (mask & modifier[2]) ~= 0 then flags[#flags + 1] = modifier[1] end
            end
            return {code = code, flags = flags}
        end
    end
    return nil
end
local shortcut = nativeShortcut() -- Reload Config after changing system shortcuts.

function M.toggle()
    if not shortcut then
        -- Preserve compatibility when system switching shortcuts are disabled or
        -- additional input sources are installed.
        local target = hs.keycodes.currentSourceID() == korean and english or korean
        if not hs.keycodes.currentSourceID(target) then
            hs.alert.show("입력 소스에 한국어 두벌식과 ABC를 추가해 주세요.")
        end
        return
    end
    -- Use macOS's input-source action instead of selecting a TIS source directly.
    -- Post a complete press/release immediately; never wait for the remote key
    -- to be released. The marker prevents recursion if the shortcut is registered.
    for _, down in ipairs({true, false}) do
        hs.eventtap.event.newKeyEvent(shortcut.flags, shortcut.code, down)
            :setProperty(props.eventSourceUserData, injectedMarker):post()
    end
end

function M.setMapping(spec)
    assert(K.valid(spec), "Invalid registered key")
    M.mapping = spec
    M.match = K.matcher(spec)
    M.keyHeld = false
end
local saved = hs.settings.get(settingKey)
M.setMapping(K.valid(saved) and saved or {kind = "key", code = 104})

M.registration = dofile(hs.configdir .. "/key-registration.lua")(M, K, function(spec)
    hs.settings.set(settingKey, spec)
    M.setMapping(spec)
end)
M.register = function() M.registration:start() end

M.tap = hs.eventtap.new({types.keyDown, types.keyUp, types.flagsChanged}, function(event)
    if event:getProperty(props.eventSourceUserData) == injectedMarker then return false end
    local eventType = event:getType()
    local e = {
        type = eventType == types.keyDown and "down" or eventType == types.keyUp and "up" or "flags",
        code = event:getKeyCode(), flags = event:getFlags(),
        repeatKey = eventType == types.keyDown and event:getProperty(props.keyboardEventAutorepeat) ~= 0,
    }
    if M.registration.active then return M.registration:feed(e) end
    if M.mapping.kind == "key" then
        if e.code ~= M.mapping.code then return false end
        if e.type == "up" then
            local handled = M.keyHeld
            M.keyHeld = false
            return handled
        end
        if e.type ~= "down" then return false end
        if M.keyHeld then return true end
        if e.repeatKey then return false end
        if e.flags.cmd or e.flags.ctrl or e.flags.alt or e.flags.shift then return false end
        M.keyHeld = true
        M.toggle()
        return true
    end
    -- A registered Command/Option/etc. remains a solo tap on release so normal
    -- shortcuts with that modifier keep working.
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
