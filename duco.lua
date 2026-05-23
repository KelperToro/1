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

local miner="CC-Tweaked-"..os.getComputerID()
local mon=peripheral.find("monitor")
if mon then mon.setTextScale(0.5) end

local accepted=0
local rejected=0
local last="starting"
local rate=0
local avg=0
local shares=0
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

local function write_line(t,y,s,c)
    t.setCursorPos(1,y)
    t.clearLine()
    if t.setTextColor then t.setTextColor(c or colors.white) end
    t.write(s)
end

local function draw(t)
    if not t then return end
    t.clear()
    write_line(t,1,"DUINO-COIN CC MINER",colors.lightBlue)
    write_line(t,2,"User: "..cfg.username,colors.white)
    write_line(t,3,"Miner: "..miner,colors.gray)
    write_line(t,5,"Last: "..last, last:find("GOOD") or last:find("BLOCK") and colors.lime or colors.red)
    write_line(t,6,"Rate: "..rate.." H/s",colors.lime)
    write_line(t,7,"Avg:  "..avg.." H/s",colors.green)
    write_line(t,8,"OK/BAD: "..accepted.."/"..rejected,colors.yellow)
    write_line(t,9,"Shares: "..shares,colors.white)
    write_line(t,10,"Uptime: "..math.floor((os.epoch("utc")-started)/1000).."s",colors.lightGray)
    if t.setTextColor then t.setTextColor(colors.white) end
end

draw(term)
draw(mon)

while true do
    local job_url=base.."?u="..enc(cfg.username).."&i="..enc(miner).."&nocache="..os.epoch("utc")
    local job,err=req("GET",job_url)

    if not job then
        last="GET failed: "..tostring(err)
        draw(term)
        draw(mon)
        os.sleep(5)
    else
        local last_hash,expected_hash,diff=job:match("^([^,]+),([^,]+),([^,]+)")

        if not last_hash then
            last=job
            draw(term)
            draw(mon)
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
            avg=math.floor((shares*result)/math.max((os.epoch("utc")-started)/1000,0.001))

            local submit_url=base.."?u="..enc(cfg.username).."&r="..enc(result).."&k="..enc(cfg.key).."&s="..enc("CC Tweaked Miner 1.2").."&j="..enc(expected_hash).."&i="..enc(miner).."&h="..enc(rate).."&b="..enc(seconds).."&nocache="..os.epoch("utc")
            local feedback=req("POST",submit_url) or "NO RESPONSE"
            last=feedback

            if feedback:find("GOOD") or feedback:find("BLOCK") then
                accepted=accepted+1
            else
                rejected=rejected+1
            end

            draw(term)
            draw(mon)
            os.sleep(0.5)
        end
    end
end
