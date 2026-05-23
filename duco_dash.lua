local cfg_path="duco.cfg"
local sha_url="https://raw.githubusercontent.com/Egor-Skriptunoff/pure_lua_SHA/master/sha2.lua"
local base="https://server.duinocoin.com/legacy_job"
local chunk_size=100000
local stale_ms=20000
local timeout_ms=90000

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
local accepted=0
local rejected=0
local last="starting"
local state="idle"
local job_no=0
local diff=0
local progress="0/0"
local total_rate=0

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

local function line(y,text,c)
    screen.setCursorPos(1,y)
    screen.clearLine()
    if screen.setTextColor then screen.setTextColor(c or colors.white) end
    screen.write(text)
end

local function sorted_ids(t)
    local out={}
    for id,_ in pairs(t) do table.insert(out,id) end
    table.sort(out)
    return out
end

local function touch(id,msg)
    miners[id]=miners[id] or {rate=0,status="seen",jobs=0}
    local m=miners[id]
    m.seen=os.epoch("utc")
    if msg.rate~=nil then m.rate=msg.rate end
    if msg.jobs~=nil then m.jobs=msg.jobs end
    if msg.status then m.status=msg.status end
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
    line(4,"Job: "..job_no.." diff "..diff.." "..progress,colors.gray)
    line(5,"State: "..state,colors.white)
    line(6,"Last: "..last,(last:find("GOOD") or last:find("BLOCK")) and colors.lime or colors.red)
    line(7,"Chunk: "..chunk_size.." | Modem: "..modem,colors.gray)

    local y=9
    for _,id in ipairs(sorted_ids(miners)) do
        local m=miners[id]
        local fresh=os.epoch("utc")-(m.seen or 0)<=stale_ms
        local c=fresh and colors.white or colors.gray
        line(y,"#"..id.." "..(m.rate or 0).." H/s "..(m.status or "?"),c)
        y=y+1
        if y>18 then break end
    end
    if screen.setTextColor then screen.setTextColor(colors.white) end
end

local function mine_range(seed,target,first,lastn)
    local started=os.epoch("utc")
    local hashes=0
    for n=first,lastn do
        hashes=hashes+1
        if sha.sha1(seed..tostring(n))==target then
            local ms=math.max(os.epoch("utc")-started,1)
            return true,n,hashes,ms,math.floor(hashes/(ms/1000))
        end
        if hashes%250==0 then pause() end
    end
    local ms=math.max(os.epoch("utc")-started,1)
    return false,nil,hashes,ms,math.floor(hashes/(ms/1000))
end

local function discover(seconds)
    state="discover"
    draw()
    rednet.broadcast({proto="duco_ping"},"duco")
    local timer=os.startTimer(seconds or 1)
    while true do
        local ev,a,b,c=os.pullEvent()
        if ev=="rednet_message" and c=="duco" and type(b)=="table" and b.proto=="duco_ready" then
            touch(a,b)
            draw()
        elseif ev=="timer" and a==timer then
            break
        end
    end
end

local function get_job()
    local name="CC-Farm-Master-"..os.getComputerID()
    local url=base.."?u="..enc(cfg.username).."&i="..enc(name).."&nocache="..os.epoch("utc")
    local job,err=req("GET",url)
    if not job then return nil,err end
    local seed,target,d=job:match("^([^,]+),([^,]+),([^,]+)")
    if not seed then return nil,job end
    return {seed=seed,target=target,diff=tonumber(d) or 1}
end

local function submit(nonce,target,rate,seconds)
    local name="CC-Farm-Master-"..os.getComputerID()
    local url=base.."?u="..enc(cfg.username).."&r="..enc(nonce).."&k="..enc(cfg.key).."&s="..enc("CC Farm Master Turbo").."&j="..enc(target).."&i="..enc(name).."&h="..enc(rate).."&b="..enc(seconds).."&nocache="..os.epoch("utc")
    return req("POST",url) or "NO RESPONSE"
end

local function run_job(job)
    job_no=job_no+1
    diff=job.diff
    local limit=diff*100
    local job_id=tostring(os.epoch("utc"))..":"..job_no
    local active=active_ids()
    local inflight={}
    local next_nonce=0
    local done_hashes=0
    local found=false
    local nonce=nil
    local started=os.epoch("utc")

    local function remaining_inflight()
        local n=0
        for _,_ in pairs(inflight) do n=n+1 end
        return n
    end

    local function send_chunk(id)
        if next_nonce>limit then return false end
        local first=next_nonce
        local lastn=math.min(limit,first+chunk_size-1)
        next_nonce=lastn+1
        inflight[id]={first=first,lastn=lastn,sent=os.epoch("utc")}
        miners[id]=miners[id] or {}
        miners[id].status="sent "..first.."-"..lastn
        rednet.send(id,{proto="duco_work",job=job_id,seed=job.seed,target=job.target,first=first,lastn=lastn},"duco")
        return true
    end

    if #active==0 then
        state="local mine"
        progress="0/"..limit
        draw()
        local ok,n,h=mine_range(job.seed,job.target,0,limit)
        found=ok
        nonce=n
        done_hashes=h
    else
        state="send chunks"
        for _,id in ipairs(active) do send_chunk(id) end
        draw()

        local tick=os.startTimer(1)
        while not found and (next_nonce<=limit or remaining_inflight()>0) do
            progress=math.min(next_nonce,limit+1).."/"..(limit+1)
            state="work "..remaining_inflight().." active"
            draw()

            local ev,a,b,c=os.pullEvent()
            if ev=="rednet_message" and c=="duco" and type(b)=="table" then
                if b.proto=="duco_ready" then
                    touch(a,b)
                elseif b.proto=="duco_result" and b.job==job_id and inflight[a] then
                    touch(a,{rate=b.rate or 0,jobs=miners[a] and miners[a].jobs or 0,status=b.found and "found" or "done"})
                    done_hashes=done_hashes+(b.hashes or 0)
                    inflight[a]=nil
                    if b.found then
                        found=true
                        nonce=b.nonce
                    else
                        send_chunk(a)
                    end
                end
            elseif ev=="timer" and a==tick then
                local now=os.epoch("utc")
                for id,ch in pairs(inflight) do
                    if now-(ch.sent or 0)>timeout_ms then
                        miners[id].status="timeout"
                        state="fallback #"..id
                        draw()
                        local ok,n,h=mine_range(job.seed,job.target,ch.first,ch.lastn)
                        done_hashes=done_hashes+h
                        inflight[id]=nil
                        if ok then
                            found=true
                            nonce=n
                        elseif not found then
                            send_chunk(id)
                        end
                    end
                end
                tick=os.startTimer(1)
            end
        end
    end

    local seconds=math.max((os.epoch("utc")-started)/1000,0.001)
    local rate=math.floor(done_hashes/seconds)

    if found then
        state="submit"
        draw()
        last=submit(nonce,job.target,rate,seconds)
        if last:find("GOOD") or last:find("BLOCK") then accepted=accepted+1 else rejected=rejected+1 end
    else
        last="NO NONCE"
        rejected=rejected+1
    end
    state="idle"
    draw()
end

draw()

while true do
    discover(1)
    state="get job"
    draw()
    local job,err=get_job()
    if not job then
        last="GET "..tostring(err)
        draw()
        os.sleep(5)
    else
        run_job(job)
        os.sleep(0.2)
    end
end
