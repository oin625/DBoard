-- DBoard — Hammerspoon 菜单栏 D板看板
-- 读取 ~/.claude/demand-center-cache.md，菜单栏图标 + 弹出 webview

local M = {}
local cachePath = os.getenv("HOME") .. "/.claude/demand-center-cache.md"
local menubar = nil
local webview = nil
local watcher = nil
local isVisible = false

-- ── 解析 Markdown ──

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function parseCache()
    local content = readFile(cachePath)
    if not content then return {items={}, todos={}, syncTime=nil} end

    local items = {}
    local todos = {}
    local syncTime = nil
    local curPrio = nil
    local curItem = nil
    local inTodo = false

    local prioMap = {
        ["## 🔴"] = "p0",
        ["## 🟡"] = "p1",
        ["## 🟠"] = "p2",
        ["## 🟢"] = "p3",
    }

    for line in content:gmatch("[^\n]*") do
        local s = line:match("^%s*(.-)%s*$")

        -- 同步时间
        local st = s:match("<!%-%- synced:%s*(.-)%s*%-%->")
        if st then syncTime = st end

        -- 优先级区块
        local hitPrio = false
        for prefix, p in pairs(prioMap) do
            if s:sub(1, #prefix) == prefix then
                if curItem and curPrio then
                    curItem.priority = curPrio
                    table.insert(items, curItem)
                end
                curItem = nil
                curPrio = p
                inTodo = false
                hitPrio = true
                break
            end
        end
        if hitPrio then goto continue end

        -- 零碎区块
        if s:sub(1, 5) == "## 📝" then
            if curItem and curPrio then
                curItem.priority = curPrio
                table.insert(items, curItem)
            end
            curItem = nil
            inTodo = true
            curPrio = nil
            goto continue
        end

        -- Todo
        if inTodo and (s:match("^- %[[ xX]%]")) then
            local done = s:match("^- %[[xX]%]") ~= nil
            local text = s:gsub("^- %[[ xX]%]%s*", "")
            local linked = text:match("`→%s*(D%d%d%d)`")
            text = text:gsub("%s*`→%s*D%d%d%d`%s*", ""):match("^%s*(.-)%s*$")
            table.insert(todos, {text=text, done=done, linked=linked})
            goto continue
        end

        -- D 条目标题
        if curPrio and s:match("^### D%d%d%d") then
            if curItem then
                curItem.priority = curPrio
                table.insert(items, curItem)
            end
            local did = s:match("(D%d%d%d)")
            local project = s:match("【(.-)】") or ""
            local status = "待开始"
            for _, tag in ipairs({"#进行中","#已完成","#挂起","#待开始"}) do
                if s:find(tag, 1, true) then status = tag:sub(2); break end
            end
            local deadline = s:match("🎯(%d+%.%d+)")
            curItem = {did=did, project=project, status=status, deadline=deadline, title=nil}
            goto continue
        end

        -- 描述字段
        if curItem and s:match("^%- %*%*描述%*%*") then
            curItem.title = s:gsub("^%- %*%*描述%*%*[：:]%s*", "")
        end

        ::continue::
    end

    if curItem and curPrio then
        curItem.priority = curPrio
        table.insert(items, curItem)
    end

    return {items=items, todos=todos, syncTime=syncTime}
end

-- ── 计算剩余天数 ──
local function daysLeft(deadline)
    if not deadline then return nil end
    local m, d = deadline:match("(%d+)%.(%d+)")
    if not m then return nil end
    m, d = tonumber(m), tonumber(d)
    local now = os.time()
    local year = tonumber(os.date("%Y"))
    local target = os.time({year=year, month=m, day=d, hour=0})
    local diff = math.floor((target - now) / 86400)
    return math.max(0, diff)
end

-- ── HTML 转义 ──
local function esc(s)
    if not s then return "" end
    return s:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;"):gsub('"',"&quot;")
end

-- ── 生成 HTML ──
local function buildHtml(data)
    local urgentCount = 0
    for _, it in ipairs(data.items) do
        local dl = daysLeft(it.deadline)
        if dl and dl <= 3 then urgentCount = urgentCount + 1 end
    end
    local doneCount = 0
    for _, td in ipairs(data.todos) do
        if td.done then doneCount = doneCount + 1 end
    end
    local totalTodos = #data.todos
    local ratio = totalTodos > 0 and (doneCount / totalTodos * 100) or 0

    local prioOrder = {"p0","p1","p2","p3"}
    local prioInfo = {
        p0={dot="#ff3b30", label="重要且紧急"},
        p1={dot="#e6a700", label="重要不紧急"},
        p2={dot="#ff9500", label="紧急不重要"},
        p3={dot="#34c759", label="不紧急不重要"},
    }
    local statusColor = {
        ["进行中"]="#007aff", ["待开始"]="#aeaeb2",
        ["已完成"]="#34c759", ["挂起"]="#ff9500",
    }

    local h = {}
    local function w(s) h[#h+1] = s end

    w([[<!DOCTYPE html><html><head><meta charset="utf-8"><style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,"PingFang SC","SF Pro Text",sans-serif;background:#f5f5f7;color:#1d1d1f;-webkit-user-select:none;cursor:default}
::-webkit-scrollbar{width:5px}
::-webkit-scrollbar-thumb{background:#c0c0c0;border-radius:3px}
.header{position:sticky;top:0;z-index:10;background:rgba(255,255,255,.88);-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px);padding:14px 18px;border-bottom:.5px solid #d2d2d7;display:flex;align-items:center;justify-content:space-between}
.header h1{font-size:17px;font-weight:700}
.header-right{font-size:12px;color:#6e6e73;display:flex;gap:8px;align-items:center}
.badge-urgent{background:#fff0f0;color:#ff3b30;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600}
.content{padding:4px 0 20px}
.sec{padding:12px 18px 4px;font-size:11px;font-weight:600;display:flex;align-items:center;gap:5px;letter-spacing:.3px}
.dot{width:8px;height:8px;border-radius:50%;display:inline-block}
.card{margin:3px 12px;padding:10px 14px;background:#fff;border-radius:10px;display:flex;justify-content:space-between;align-items:flex-start;border:.5px solid #e8e8ed;transition:all .15s}
.card:hover{background:#f0f2f5;border-color:#d0d0d5}
.card.urgent{background:#fffafa;border-color:#ffd4d4}
.card-l{flex:1;min-width:0}
.card-top{display:flex;align-items:baseline;gap:8px}
.did{font-family:Menlo,monospace;font-size:13px;font-weight:700}
.proj{font-size:11px;color:#6e6e73;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.desc{font-size:11px;color:#aeaeb2;margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card-r{text-align:right;margin-left:12px;flex-shrink:0}
.st{font-size:10px;font-weight:500}
.dl{font-size:11px;margin-top:2px}
.dl.u{color:#ff3b30;font-weight:700}
.dl.n{color:#aeaeb2}
.divider{height:.5px;background:#d2d2d7;margin:10px 18px}
.th{padding:8px 18px 0;display:flex;justify-content:space-between;align-items:center}
.th h2{font-size:14px;font-weight:700}
.tc{font-family:Menlo,monospace;font-size:11px;color:#aeaeb2}
.bar{margin:8px 18px 4px;height:3px;background:#e5e5ea;border-radius:2px;overflow:hidden}
.fill{height:100%;background:#34c759;border-radius:2px;transition:width .3s}
.ti{padding:7px 18px;display:flex;align-items:center;gap:10px;cursor:pointer;transition:background .1s;border-radius:6px;margin:0 8px}
.ti:hover{background:#ececf0}
.ck{width:20px;height:20px;border-radius:50%;border:1.5px solid #d1d1d6;display:flex;align-items:center;justify-content:center;flex-shrink:0;font-size:11px;color:transparent;transition:all .15s}
.ti.done .ck{background:#34c759;border-color:#34c759;color:#fff}
.tt{font-size:12px;flex:1}
.ti.done .tt{color:#aeaeb2;text-decoration:line-through}
.lk{font-family:Menlo,monospace;font-size:9px;color:#007aff;background:#f0f4ff;padding:1px 6px;border-radius:4px}
.footer{position:sticky;bottom:0;background:rgba(255,255,255,.88);-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px);padding:8px 18px;border-top:.5px solid #d2d2d7;display:flex;justify-content:space-between;font-size:11px;color:#aeaeb2}
.rb{color:#007aff;cursor:pointer;font-weight:500}
.rb:hover{text-decoration:underline}
</style></head><body>]])

    -- Header
    w('<div class="header"><h1>📋 D板</h1><div class="header-right">')
    if urgentCount > 0 then
        w('<span class="badge-urgent">⚠ '..urgentCount..'项紧急</span>')
    end
    w('<span>今日 '..totalTodos..' 项</span></div></div>')
    w('<div class="content">')

    -- 条目
    for _, pk in ipairs(prioOrder) do
        local group = {}
        for _, it in ipairs(data.items) do
            if it.priority == pk then group[#group+1] = it end
        end
        if #group > 0 then
            local pi = prioInfo[pk]
            w('<div class="sec"><span class="dot" style="background:'..pi.dot..'"></span>'..pi.label..'</div>')
            for _, it in ipairs(group) do
                local dl = daysLeft(it.deadline)
                local isU = dl and dl <= 3
                w('<div class="card'..(isU and ' urgent' or '')..'">')
                w('<div class="card-l"><div class="card-top"><span class="did">'..esc(it.did)..'</span><span class="proj">'..esc(it.project)..'</span></div>')
                if it.title and it.title ~= "" then
                    w('<div class="desc">'..esc(it.title)..'</div>')
                end
                w('</div><div class="card-r">')
                local sc = statusColor[it.status] or "#aeaeb2"
                w('<div class="st" style="color:'..sc..'">'..esc(it.status)..'</div>')
                if dl then
                    if isU then w('<div class="dl u">⚠ '..dl..'天</div>')
                    else w('<div class="dl n">'..dl..'天</div>') end
                end
                w('</div></div>')
            end
        end
    end

    w('<div class="divider"></div>')

    -- 今日零碎
    w('<div class="th"><h2>📝 今日零碎</h2><span class="tc">'..doneCount..'/'..totalTodos..'</span></div>')
    w('<div class="bar"><div class="fill" style="width:'..string.format("%.0f",ratio)..'%"></div></div>')

    for i, td in ipairs(data.todos) do
        local cls = td.done and "ti done" or "ti"
        w('<div class="'..cls..'" onclick="toggle('..i..')">')
        w('<div class="ck">'..(td.done and "✓" or "")..'</div>')
        w('<span class="tt">'..esc(td.text)..'</span>')
        if td.linked then w('<span class="lk">'..esc(td.linked)..'</span>') end
        w('</div>')
    end

    w('</div>') -- content

    -- Footer
    w('<div class="footer">')
    if data.syncTime then
        local t = data.syncTime:match("T(%d+:%d+)") or data.syncTime
        w('<span>同步 '..t..'</span>')
    else w('<span></span>') end
    w('<span class="rb" onclick="doRefresh()">↻ 刷新</span></div>')

    w([[<script>
function toggle(i){try{webkit.messageHandlers.dboard.postMessage("toggle:"+i)}catch(e){}}
function doRefresh(){try{webkit.messageHandlers.dboard.postMessage("refresh")}catch(e){}}
</script></body></html>]])

    return table.concat(h, "\n")
end

-- ── Webview ──

local function createWebview()
    if webview then return end
    local screen = hs.screen.mainScreen():frame()
    local w, hi = 400, 600
    local x = screen.x + screen.w - w - 20
    local y = screen.y + 32

    webview = hs.webview.new({x=x, y=y, w=w, h=hi}, {developerExtrasEnabled=false})
    webview:windowStyle({"titled","closable","resizable","utility"})
    webview:windowTitle("D板")
    webview:allowTextEntry(false)
    webview:allowGestures(true)
    webview:level(hs.drawing.windowLevels.floating)
    webview:shadow(true)

    -- JS → Lua callback
    local uc = hs.webview.usercontent.new("dboard")
    uc:setCallback(function(msg)
        local body = msg.body or ""
        if body == "refresh" then
            M.refresh()
        elseif body:sub(1,7) == "toggle:" then
            local idx = tonumber(body:sub(8))
            if idx then M.toggleTodo(idx) end
        end
    end)

    -- 重建 webview 带 usercontent
    webview:delete()
    webview = hs.webview.new({x=x, y=y, w=w, h=hi}, {developerExtrasEnabled=false}, uc)
    webview:windowStyle({"titled","closable","resizable","utility"})
    webview:windowTitle("D板")
    webview:allowTextEntry(false)
    webview:allowGestures(true)
    webview:level(hs.drawing.windowLevels.floating)
    webview:shadow(true)
end

function M.refresh()
    if not webview then return end
    local data = parseCache()
    local html = buildHtml(data)
    webview:html(html)

    -- 更新菜单栏
    if menubar then
        local uc = 0
        for _, it in ipairs(data.items) do
            local dl = daysLeft(it.deadline)
            if dl and dl <= 3 then uc = uc + 1 end
        end
        menubar:setTitle(uc > 0 and ("📋"..uc) or "📋")
    end
end

function M.toggleTodo(idx)
    local content = readFile(cachePath)
    if not content then return end
    local lines = {}
    for line in (content.."\n"):gmatch("(.-)\n") do lines[#lines+1] = line end

    local inTodo = false
    local todoIdx = 0
    for i, line in ipairs(lines) do
        if line:match("^## 📝") then inTodo = true end
        if inTodo and line:match("^%s*%- %[[ xX]%]") then
            todoIdx = todoIdx + 1
            if todoIdx == idx then
                if line:match("%- %[ %]") then
                    lines[i] = line:gsub("%- %[ %]", "- [x]", 1)
                else
                    lines[i] = line:gsub("%- %[[xX]%]", "- [ ]", 1)
                end
                break
            end
        end
    end

    local f = io.open(cachePath, "w")
    if f then f:write(table.concat(lines, "\n")); f:close() end
    M.refresh()
end

function M.toggle()
    if not webview then
        createWebview()
        M.refresh()
    end
    if isVisible then
        webview:hide()
        isVisible = false
    else
        webview:show()
        webview:bringToFront()
        M.refresh()
        isVisible = true
    end
end

-- ── 初始化 ──
function M.init()
    menubar = hs.menubar.new()
    menubar:setTitle("📋")
    menubar:setTooltip("D板 — 个人工作看板")
    menubar:setClickCallback(function() M.toggle() end)

    watcher = hs.pathwatcher.new(cachePath, function()
        if isVisible then M.refresh() end
    end)
    watcher:start()

    hs.hotkey.bind({"ctrl"}, "D", function() M.toggle() end)
end

function M.cleanup()
    if watcher then watcher:stop() end
    if webview then webview:delete(); webview = nil end
    if menubar then menubar:delete(); menubar = nil end
end

return M
