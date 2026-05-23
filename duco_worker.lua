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

local modem_side=nil
for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then
        modem_side=name
        rednet.open(name)
        break
    end
end

local miner="CC-Tweaked-"..os.getComputerID()
local accepted=0
local rejected=0
local last="starting"
local rate=0
local avg=0
local shares=0
local hashes=0
local started=os.epoch("utc")

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

local function stat()
    local msg={
        proto="duco_stat",
        id=os.getComputerID(),
        miner=miner,
        user=cfg.username,
        rate=rate,
        avg=avg,
        accepted=accepted,
        rejected=rejected,
        shares=shares,
        last=last,
        uptime=math.floor((os.epoch("utc")-started)/1000),
        ts=os.epoch("utc")
    }
    if modem_side then rednet.broadcast(msg,"duco") end
end

local function draw()
    term.clear()
    term.setCursorPos(1,1)
    term.setTextColor(colors.lightBlue)
    print("DUCO WORKER #"..os.getComputerID())
    term.setTextColor(colors.white)
    print("User: "..cfg.username)
    print("Modem: "..tostring(modem_side or "none"))
    print("Last: "..last)
    print("Rate: "..rate.." H/s")
    print("Avg: "..avg.." H/s")
    print("OK/BAD: "..accepted.."/"..rejected)
end

draw()
stat()

while true do
    local job_url=base.."?u="..enc(cfg.username).."&i="..enc(miner).."&nocache="..os.epoch("utc")
    local job,err=req("GET",job_url)

    if not job then
        last="GET failed: "..tostring(err)
        draw()
        stat()
        os.sleep(5)
    else
        local last_hash,expected_hash,diff=job:match("^([^,]+),([^,]+),([^,]+)")

        if not last_hash then
            last=job
            draw()
            stat()
            os.sleep(10)
        else
            diff=tonumber(diff) or 1
            local start=os.epoch("utc")
            local result=0
            local limit=diff*100

            for nonce=0,limit do
                result=nonce
                if sha.sha1(last_hash..tostring(nonce))==expected_hash then break end
                if nonce%250==0 then pause() end
            end

            local seconds=math.max((os.epoch("utc")-start)/1000,0.001)
            rate=math.floor(result/seconds)
            shares=shares+1
            hashes=hashes+result
            avg=math.floor(hashes/math.max((os.epoch("utc")-started)/1000,0.001))

            local submit_url=base.."?u="..enc(cfg.username).."&r="..enc(result).."&k="..enc(cfg.key).."&s="..enc("CC Multi Worker 1.0").."&j="..enc(expected_hash).."&i="..enc(miner).."&h="..enc(rate).."&b="..enc(seconds).."&nocache="..os.epoch("utc")
            local feedback=req("POST",submit_url) or "NO RESPONSE"
            last=feedback

            if feedback:find("GOOD") or feedback:find("BLOCK") then
                accepted=accepted+1
            else
                rejected=rejected+1
            end

            draw()
            stat()
            os.sleep(0.5)
        end
    end
end
