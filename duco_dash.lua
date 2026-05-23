local cfg_path="duco.cfg"
local sha_url="https://raw.githubusercontent.com/Egor-Skriptunoff/pure_lua_SHA/master/sha2.lua"
local base="https://server.duinocoin.com/legacy_job"

if not fs.exists("sha2.lua") then
    print("Downloading sha2.lua")
    local r,e=http.get(sha_url)
    if not r then error("sha2 download failed: "..tostring(e)) end
    local f=fs.open("sha2.lua","w")
    f.write(r.readAll())
    f.close()
    r.close()
end

local sha=require("sha2")
local ser=textutils.serialize or textutils.serialise
local unser=textutils.unserialize or textutils.unserialise
local cfg={}

if fs.exists(cfg_path) then
    local f=fs.open(cfg_path,"r")
    cfg=unser(f.readAll()) or {}
    f.close()
end

if not cfg.username or cfg.username=="" then
    write("DUCO username: ")
    cfg.username=read()
end

if not cfg.key or cfg.key=="" then
    write("Mining key: ")
    cfg.key=read("*")
end

local f=fs.open(cfg_path,"w")
f.write(ser(cfg))
f.close()

local modem=nil
for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then
        modem=name
        rednet.open(name)
        break
    end
end

if not modem then error("No modem found") end

local screen=peripheral.find("monitor") or term
if screen.setTextScale then screen.setTextScale(0.5) end

local miners={}
local stale_ms=20000
local accepted=0
local rejected=0
local total_rate=0
local last="starting"
local current="idle"
local job_no=0
local diff=0

local function enc(v)
    return textutils.urlEncode(tostring(v or ""))
end

local function pause()
    os.queueEvent("duco_yield")
    os.pullEvent("duco_yield")
end

local function req(method,url)
    local r,e
    if method=="POST" then r,e=http.post(url,"") else r,e=http.get(url) end
    if not r then return nil,e end
    local b=r.readAll()
    r.close()
    return b
end

local function color(c)
    if screen.setTextColor then screen.setTextColor(c) end
end

local function line(y,text,c)
    screen.setCursorPos(1,y)
    screen.clearLine()
    color(c or colors.white)
    screen.write(text)
end

local function ids(t)
    local out={}
    for id,_ in pairs(t) do table.insert(out,id) end
    table.sort(out)
    return out
end

local function touch(id,msg)
    miners[id]=miners[id] or {}
    local m=miners[id]
    m.seen=os.epoch("utc")
    if msg.rate then m.rate=msg.rate end
    if msg.jobs then m.jobs=msg.jobs end
    if msg.status then m.status=msg.status end
    if msg.found~=nil then m.status=msg.found and "found" or "done" end
end

local function active_ids()
    local out={}
    local now=os.epoch("utc")
    for id,m in pairs(miners) do
        if now-(m.seen or 0)<=stale_ms then table.insert(out,id) end
    end
    table.sort(out)
    return out
end

local function draw()
    local active=active_ids()
    total_rate=0
    for _,id in ipairs(active) do total_rate=total_rate+(miners[id].rate or 0) end

    screen.clear()
    line(1,"DUCO FARM MASTER",colors.lightBlue)
    line(2,"Active: "..#active.." | Total: "..total_rate.." H/s",colors.lime)
    line(3,"OK/BAD: "..accepted.."/"..rejected,colors.yellow)
    line(4,"Job: "..job_no.." diff "..diff,colors.gray)
    line(5,"State: "..current,colors.white)
    line(6,"Last: "..last,(last:find("GOOD") or last:find("BLOCK")) and colors.lime or colors.red)
    line(7,"Modem: "..modem,colors.gray)

    local y=9
    for _,id in ipairs(ids(miners)) do
        local m=miners[id]
        local fresh=os.epoch("utc")-(m.seen or 0)<=stale_ms
        local c=fresh and colors.white or colors.gray
        line(y,"#"..id.." "..(m.rate or 0).." H/s "..(m.status or "?") ,c)
        y=y+1
        if y>18 then break end
    end
    color(colors.white)
end

local function handle_message(sender,msg,chunks,job_id)
    if type(msg)~="table" then return false,nil end
    if msg.proto=="duco_ready" then
        touch(sender,msg)
        return false,nil
    end
    if msg.proto=="duco_result" then
        touch(sender,msg)
        if chunks and msg.job==job_id and chunks[sender] and not chunks[sender].done then
            chunks[sender].done=true
            chunks[sender].hashes=msg.hashes or 0
            chunks[sender].rate=msg.rate or 0
            return true,msg
        end
    end
    return false,nil
end

local function discover(seconds)
    current="discover"
    draw()
    rednet.broadcast({proto="duco_ping"},"duco")
    local timer=os.startTimer(seconds or 1)
    while true do
        local ev,a,b,c=os.pullEvent()
        if ev=="rednet_message" and c=="duco" then
            handle_message(a,b,nil,nil)
        elseif ev=="timer" and a==timer then
            break
        end
    end
end

local function mine_range(last_hash,target,from,to)
    local started=os.epoch("utc")
    local hashes=0
    for n=from,to do
        hashes=hashes+1
        if sha.sha1(last_hash..tostring(n))==target then
            local ms=math.max(os.epoch("utc")-started,1)
            return true,n,hashes,ms,math.floor(hashes/(ms/1000))
        end
        if hashes%250==0 then pause() end
    end
    local ms=math.max(os.epoch("utc")-started,1)
    return false,nil,hashes,ms,math.floor(hashes/(ms/1000))
end

local function get_job()
    local url=base.."?u="..enc(cfg.username).."&i="..enc("CC-Farm-Master-"..os.getComputerID()).."&nocache="..os.epoch("utc")
    local job,err=req("GET",url)
    if not job then return nil,err end
    local a,h,d=job:match("^([^,]+),([^,]+),([^,]+)")
    if not a then return nil,job end
    return {last=a,target=h,diff=tonumber(d) or 1}
end

local function submit(nonce,target,rate,seconds)
    local url=base.."?u="..enc(cfg.username).."&r="..enc(nonce).."&k="..enc(cfg.key).."&s="..enc("CC Farm Master 1.0").."&j="..enc(target).."&i="..enc("CC-Farm-Master-"..os.getComputerID()).."&h="..enc(rate).."&b="..enc(seconds).."&nocache="..os.epoch("utc")
    return req("POST",url) or "NO RESPONSE"
end

draw()

while true do
    discover(1)
    local active=active_ids()

    current="get job"
    draw()
    local job,err=get_job()
    if not job then
        last="GET "..tostring(err)
        draw()
        os.sleep(5)
    else
        job_no=job_no+1
        diff=job.diff
        local limit=diff*100
        local found=false
        local nonce=nil
        local hashes=0
        local started=os.epoch("utc")
        local job_id=tostring(started)..":"..job_no

        if #active==0 then
            current="local mine"
            draw()
            local ok,n,h=mine_range(job.last,job.target,0,limit)
            found=ok
            nonce=n
            hashes=hashes+h
        else
            current="send work"
            draw()
            local chunks={}
            local total=limit+1
            local size=math.ceil(total/#active)
            local sent=0

            for i,id in ipairs(active) do
                local from=(i-1)*size
                local to=math.min(limit,from+size-1)
                if from<=limit then
                    chunks[id]={from=from,to=to,done=false}
                    miners[id].status="sent"
                    rednet.send(id,{proto="duco_work",job=job_id,last=job.last,target=job.target,from=from,to=to},"duco")
                    sent=sent+1
                end
            end

            local done=0
            local timer=os.startTimer(45)
            current="wait "..done.."/"..sent
            draw()

            while done<sent do
                local ev,a,b,c=os.pullEvent()
                if ev=="rednet_message" and c=="duco" then
                    local counted,msg=handle_message(a,b,chunks,job_id)
                    if counted then
                        done=done+1
                        hashes=hashes+(msg.hashes or 0)
                        if msg.found and not found then
                            found=true
                            nonce=msg.nonce
                        end
                        current="wait "..done.."/"..sent
                        draw()
                    end
                elseif ev=="timer" and a==timer then
                    break
                end
            end

            for id,ch in pairs(chunks) do
                if not ch.done then
                    current="fallback #"..id
                    draw()
                    local ok,n,h=mine_range(job.last,job.target,ch.from,ch.to)
                    ch.done=true
                    hashes=hashes+h
                    miners[id].status="timeout"
                    if ok and not found then
                        found=true
                        nonce=n
                    end
                end
            end
        end

        local seconds=math.max((os.epoch("utc")-started)/1000,0.001)
        local submit_rate=math.floor(hashes/seconds)

        if found then
            current="submit"
            draw()
            last=submit(nonce,job.target,submit_rate,seconds)
            if last:find("GOOD") or last:find("BLOCK") then accepted=accepted+1 else rejected=rejected+1 end
        else
            last="NO NONCE"
            rejected=rejected+1
        end

        current="idle"
        draw()
        os.sleep(0.5)
    end
end
