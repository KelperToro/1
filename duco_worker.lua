local sha_url="https://raw.githubusercontent.com/Egor-Skriptunoff/pure_lua_SHA/master/sha2.lua"
local worker_url="https://raw.githubusercontent.com/KelperToro/1/main/duco_worker.lua"
local worker_file="duco_worker.lua"
local startup_file="startup.lua"
local yield_each=5000
local report_interval=3000
local draw_interval=15000

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
local last_draw=0

local function pause()
    os.queueEvent("duco_yield")
    os.pullEvent("duco_yield")
end

local function draw()
    last_draw=os.epoch("utc")
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
    print("Yield: "..yield_each)
end

local function maybe_draw(force)
    local now=os.epoch("utc")
    if force or now-last_draw>=draw_interval then draw() end
end

local function ready(to)
    local msg={proto="duco_ready",id=id,rate=rate,jobs=jobs,status=status}
    if to then rednet.send(to,msg,"duco") else rednet.broadcast(msg,"duco") end
end

local function install_startup()
    local f=fs.open(startup_file,"w")
    f.write("shell.run(\""..worker_file.."\")\n")
    f.close()
end

local function download(url,path)
    local sep=url:find("?",1,true) and "&" or "?"
    local r,e=http.get(url..sep.."nocache="..os.epoch("utc"))
    if not r then return false,tostring(e) end
    local body=r.readAll()
    r.close()
    if not body or #body<1000 then return false,"short download" end
    local tmp=path..".new"
    local f=fs.open(tmp,"w")
    f.write(body)
    f.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp,path)
    return true
end

local function update_self(to,msg)
    status="updating"
    maybe_draw(true)
    local url=(type(msg)=="table" and msg.url) or worker_url
    local ok,err=download(url,worker_file)
    if ok then
        install_startup()
        rednet.send(to,{proto="duco_update_ack",id=id,ok=true,rate=rate,jobs=jobs,status="rebooting"},"duco")
        sleep(0.5)
        os.reboot()
    else
        status="update failed"
        rednet.send(to,{proto="duco_update_ack",id=id,ok=false,err=err,status=status},"duco")
        maybe_draw(true)
    end
end

local function check_control()
    while true do
        local sender,msg,protocol=rednet.receive("duco",0)
        if not sender then break end
        if type(msg)=="table" and msg.proto=="duco_update" then
            update_self(sender,msg)
        elseif type(msg)=="table" and msg.proto=="duco_ping" then
            ready(sender)
        end
    end
end

local function progress(to,msg,hashes,started)
    local ms=math.max(os.epoch("utc")-started,1)
    rate=math.floor(hashes/(ms/1000))
    rednet.send(to,{proto="duco_progress",id=id,job=msg.job,task=msg.task,first=msg.first,lastn=msg.lastn,rate=rate,jobs=jobs,status=status,hashes=hashes},"duco")
end

local function work(sender,msg)
    master=sender
    jobs=jobs+1
    status="work "..msg.first.."-"..msg.lastn
    maybe_draw(false)

    local started=os.epoch("utc")
    local next_report=started+report_interval
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
        if hashes%yield_each==0 then
            pause()
            local now=os.epoch("utc")
            if now>=next_report then
                check_control()
                status="work "..n.."/"..msg.lastn
                progress(sender,msg,hashes,started)
                maybe_draw(false)
                next_report=now+report_interval
            end
        end
    end

    local ms=math.max(os.epoch("utc")-started,1)
    rate=math.floor(hashes/(ms/1000))
    status=found and ("found "..nonce) or "done"
    rednet.send(sender,{proto="duco_result",id=id,job=msg.job,task=msg.task,first=msg.first,lastn=msg.lastn,found=found,nonce=nonce,hashes=hashes,ms=ms,rate=rate,jobs=jobs,status=status},"duco")
    ready(sender)
    maybe_draw(false)
end

draw()
ready()

while true do
    local sender,msg,protocol=rednet.receive("duco",5)
    if not sender then
        ready()
    elseif type(msg)=="table" and msg.proto=="duco_ping" then
        ready(sender)
    elseif type(msg)=="table" and msg.proto=="duco_update" then
        update_self(sender,msg)
    elseif type(msg)=="table" and msg.proto=="duco_work" then
        work(sender,msg)
    end
end
