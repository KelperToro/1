local modem_side=nil
for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then
        modem_side=name
        rednet.open(name)
        break
    end
end

if not modem_side then error("No modem found") end

local screen=peripheral.find("monitor") or term
if screen.setTextScale then screen.setTextScale(0.5) end

local miners={}
local stale_ms=15000

local function color(c)
    if screen.setTextColor then screen.setTextColor(c) end
end

local function line(y,text,c)
    screen.setCursorPos(1,y)
    screen.clearLine()
    color(c or colors.white)
    screen.write(text)
end

local function keys(t)
    local k={}
    for id,_ in pairs(t) do table.insert(k,id) end
    table.sort(k)
    return k
end

local function draw()
    local now=os.epoch("utc")
    local total=0
    local avg=0
    local ok=0
    local bad=0
    local active=0

    for _,m in pairs(miners) do
        if now-(m.seen or 0)<=stale_ms then
            active=active+1
            total=total+(m.rate or 0)
            avg=avg+(m.avg or 0)
            ok=ok+(m.accepted or 0)
            bad=bad+(m.rejected or 0)
        end
    end

    screen.clear()
    line(1,"DUCO FARM DASHBOARD",colors.lightBlue)
    line(2,"Active: "..active.." | Total: "..total.." H/s",colors.lime)
    line(3,"Avg sum: "..avg.." H/s",colors.green)
    line(4,"OK/BAD: "..ok.."/"..bad,colors.yellow)
    line(5,"Modem: "..modem_side,colors.gray)

    local y=7
    for _,id in ipairs(keys(miners)) do
        local m=miners[id]
        local fresh=now-(m.seen or 0)<=stale_ms
        local c=fresh and colors.white or colors.gray
        local status=m.last or "?"
        if #status>18 then status=status:sub(1,18) end
        line(y,"#"..id.." "..(m.rate or 0).." H/s "..(m.accepted or 0).."/"..(m.rejected or 0).." "..status,c)
        y=y+1
        if y>18 then break end
    end

    color(colors.white)
end

draw()
local timer=os.startTimer(1)

while true do
    local ev,p1,p2,p3=os.pullEvent()
    if ev=="rednet_message" and p3=="duco" and type(p2)=="table" and p2.proto=="duco_stat" then
        p2.seen=os.epoch("utc")
        miners[p2.id or p1]=p2
        draw()
    elseif ev=="timer" and p1==timer then
        draw()
        timer=os.startTimer(1)
    end
end
