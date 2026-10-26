-- Explicit two-press registration UI. Saved mapping changes only on a match.
return function(M, K, commit)
    local R = {active = false}

    local function clearCapture()
        if R.deadline then R.deadline:stop(); R.deadline = nil end
        if R.armTimer then R.armTimer:stop(); R.armTimer = nil end
        if R.banner then hs.alert.closeSpecific(R.banner); R.banner = nil end
        R.capture = nil
    end

    local function finish(message)
        clearCapture()
        R.active, R.stage, R.first = false, nil, nil
        -- Drop partial presses from before registration/cancellation.
        M.setMapping(M.mapping)
        if M.menu then M.menu:setTitle("한/영") end
        if message then hs.alert.show(message, 3) end
    end

    local function dialog(title, text, accept, callback)
        clearCapture()
        R.stage = "dialog"
        if M.menu then M.menu:setTitle("한/영") end
        -- Defer UI creation until the event tap has returned.
        R.dialogTimer = hs.timer.doAfter(0.05, function()
            local f = hs.screen.mainScreen():frame()
            hs.dialog.alert(f.x + f.w / 2 - 240, f.y + f.h / 2 - 150, function(button)
                if not R.active then return end
                if button == accept then callback() else finish("키 등록 취소 · 기존 매핑 유지") end
            end, title, text, accept, "취소", "informational")
        end)
    end

    local function label(spec)
        local name = hs.keycodes.map[spec.code] or "unknown"
        if spec.code == 104 then name = "Lang1 / kana" end
        return string.format("%s · 코드 %d%s", name, spec.code,
            spec.kind == "modifier" and " · 단독 보조키" or "")
    end

    local arm
    local function received(spec)
        if not R.first then
            R.first = spec
            dialog("첫 번째 입력을 확인해 주세요", label(spec)
                .. "\n방금 원격 키보드의 한/영키를 누르셨나요?\n확인 후 같은 키를 한 번 더 눌러 주세요.",
                "확인 후 재입력", function() arm(2) end)
        elseif K.same(R.first, spec) then
            local ok, err = pcall(commit, spec)
            if ok then
                finish("한/영키 등록 완료\n" .. label(spec))
            else
                print("[CRD Hangul] Unable to save mapping: " .. tostring(err))
                finish("저장하지 못했습니다. 기존 매핑을 유지합니다.")
            end
        else
            dialog("두 입력이 다릅니다", "첫 입력: " .. label(R.first)
                .. "\n두 번째: " .. label(spec) .. "\n저장하지 않았습니다. 같은 한/영키로 다시 등록해 주세요.",
                "처음부터 다시", function() R.first = nil; arm(1) end)
        end
    end

    arm = function(step)
        clearCapture()
        R.stage = "arming"
        -- A held Enter/Option used to dismiss the dialog is never a fresh press.
        R.armTimer = hs.timer.doAfter(0.5, function()
            R.stage = "capture"
            R.capture = K.capture()
            if M.menu then M.menu:setTitle("등록 취소") end
            R.banner = hs.alert.show(string.format("한/영키 등록 %d/2\n원격 화면에서 한/영키를 한 번 눌렀다 떼세요.\nEsc 또는 메뉴의 ‘등록 취소’ · 60초", step), 60)
            R.deadline = hs.timer.doAfter(60, function()
                finish("입력 시간이 지났습니다. 기존 매핑을 유지합니다.")
            end)
        end)
    end

    function R:start()
        if self.active then return end
        if not hs.accessibilityState() or not M.tap:isEnabled() then
            hs.alert.show("손쉬운 사용에서 Hammerspoon을 허용하고 앱을 다시 실행해 주세요.", 5)
            return
        end
        if hs.eventtap.isSecureInputEnabled() then
            hs.alert.show("암호 입력창을 닫고 일반 화면에서 키 등록을 다시 시작해 주세요.", 5)
            return
        end
        self.active, self.first = true, nil
        dialog("원격 한/영키 등록", "원격으로 사용할 물리 키보드에서 진행해 주세요.\n입력 시작 → 한/영키 1회 → 감지한 키 확인 → 같은 키 1회\n두 입력이 일치할 때만 저장합니다.\n입력 중에는 다른 키를 함께 누르지 마세요.",
            "입력 시작", function() arm(1) end)
    end

    function R:cancelCapture()
        if self.stage == "capture" or self.stage == "arming" then
            finish("키 등록 취소 · 기존 매핑 유지")
        end
    end

    function R:feed(e)
        if self.stage ~= "capture" then return false end
        if e.type == "down" and e.code == 53 then
            finish("키 등록 취소 · 기존 매핑 유지")
            return true
        end
        local spec = self.capture:feed(e)
        if spec then received(spec) end
        -- Candidate keystrokes must not type into the currently focused app.
        return e.type == "down" or e.type == "up"
    end

    return R
end
