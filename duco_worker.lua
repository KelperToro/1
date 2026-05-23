local sha_url="https://raw.githubusercontent.com/Egor-Skriptunoff/pure_lua_SHA/master/sha2.lua"

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
local modem=nil
for _,name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name)=="modem" then
        modem=name
        rednet.open(name)
        break
    end
end
if not modem then error("No modem found") end

local id=os.getComputerID()
local rate=0
local jobs=0
local status="ready"
local master="none"

local function pause()
    os.queueEvent("duco_yield")
    os.pullEvent("duco_yield")
end

local function draw()
    term.clear()
    term.setCursorPos(1,1)
    term.setTextColor(colors.lightBlue)
    print("DUCO WORKER #"..id)
    term.setTextColor(colors.white)
    print("Modem: "..modem)
    print("Master: "..tostring(master))
    print("Status: "..status)
    print("Rate: "..rate.." H/s")
    print("Chunks: "..jobs)
end

local function ready(to)
    local msg={proto="duco_ready",id=id,rate=rate,jobs=jobs,status=status}
    if to then rednet.send(to,msg,"duco") else rednet.broadcast(msg,"duco") end
end

local function work(sender,msg)
    master=sender
    jobs=jobs+1
    status="work "..msg.first.."-"..msg.lastn
    draw()

    local started=os.epoch("utc")
    local hashes=0
    local found=false
    local nonce=nil

    for n=msg.first,msg.lastn do
        hashes=hashes+1
        if sha.sha1(msg.seed..tostring(n))==msg.target then
            found=true
            nonce=n
            break
        end
        if hashes%250==0 then pause() end
    end

    local ms=math.max(os.epoch("utc")-started,1)
    rate=math.floor(hashes/(ms/1000))
    status=found and ("found "..nonce) or "done"
    rednet.send(sender,{proto="duco_result",id=id,job=msg.job,found=found,nonce=nonce,hashes=hashes,ms=ms,rate=rate},"duco")
    ready(sender)
    draw()
end

draw()
ready()

while true do
    local sender,msg,protocol=rednet.receive("duco",5)
    if not sender then
        ready()
    elseif type(msg)=="table" and msg.proto=="duco_ping" then
        ready(sender)
    elseif type(msg)=="table" and msg.proto=="duco_work" then
        work(sender,msg)
    end
end
