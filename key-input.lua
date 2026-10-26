-- Single press/release detection. No Hammerspoon API or persistent key log.
local K = {}
local modifiers = {
    [54] = "cmd", [55] = "cmd", [56] = "shift", [60] = "shift",
    [58] = "alt", [61] = "alt", [59] = "ctrl", [62] = "ctrl", [63] = "fn",
}

local function otherFlags(flags, except)
    for _, name in ipairs({"cmd", "alt", "ctrl", "shift", "fn"}) do
        if name ~= except and flags[name] then return true end
    end
    return false
end

function K.valid(spec)
    return type(spec) == "table" and type(spec.code) == "number"
        and spec.code >= 0 and spec.code <= 255 and spec.code % 1 == 0
        and ((spec.kind == "key" and spec.modifier == nil)
            or (spec.kind == "modifier" and modifiers[spec.code] ~= nil
                and spec.modifier == modifiers[spec.code]))
end

function K.same(a, b)
    return K.valid(a) and K.valid(b) and a.code == b.code
        and a.kind == b.kind and a.modifier == b.modifier
end

function K.capture()
    local C = {}
    -- Events have type "down", "up", or "flags", a code, flags, and repeatKey.
    -- Returns a completed candidate and whether an ordinary key event was used.
    function C:feed(e)
        local p = self.pending
        local flags = e.flags or {}
        local used = p and p.kind == "key" and p.code == e.code
            and (e.type == "down" or e.type == "up") or false
        if not p then
            if e.type == "down" and not e.repeatKey and not otherFlags(flags) then
                p = {kind = "key", code = e.code}
                used = true
            elseif e.type == "flags" then
                local name = modifiers[e.code]
                if name and flags[name] and not otherFlags(flags, name) then
                    p = {kind = "modifier", code = e.code, modifier = name}
                end
            end
            self.pending = p
            return nil, used
        end
        if e.type == "down" and (p.kind ~= "key" or p.code ~= e.code) then
            self.dirty = true
        elseif e.type == "flags" and (otherFlags(flags, p.modifier)
            or (modifiers[e.code] and e.code ~= p.code and flags[modifiers[e.code]])) then
            self.dirty = true
        end
        local released = p.kind == "key" and e.type == "up" and p.code == e.code
            or p.kind == "modifier" and e.type == "flags" and p.code == e.code
                and not flags[p.modifier]
        if released then
            local clean = not self.dirty and not otherFlags(flags)
            self.pending, self.dirty = nil, nil
            if clean then return p, used end
        end
        return nil, used
    end
    return C
end

function K.matcher(spec)
    local capture = K.capture()
    return function(e)
        if not capture.pending and e.code ~= spec.code then return false, false end
        local candidate, used = capture:feed(e)
        return K.same(spec, candidate), used
    end
end

return K
