local sha = require("sha2")

local username = "Nimfus" 
local key = "NimfusKaizen1"
local base = "https://server.duinocoin.com/legacy_job"
local miner = "CC-Tweaked-" .. os.getComputerID()

local accepted = 0
local rejected = 0

local function enc(v)
    return textutils.urlEncode(tostring(v or ""))
end

local function yield()
    os.queueEvent("duco_yield")
    os.pullEvent("duco_yield")
end

local function req(method, url)
    local r, err
    if method == "POST" then
        r, err = http.post(url, "")
    else
        r, err = http.get(url)
    end

    if not r then
        return nil, err
    end

    local body = r.readAll()
    r.close()
    return body
end

term.clear()
term.setCursorPos(1, 1)
term.setTextColor(colors.lightBlue)
print("DUINO-COIN CC MINER")
term.setTextColor(colors.white)

while true do
    local job_url = base ..
        "?u=" .. enc(username) ..
        "&i=" .. enc(miner) ..
        "&nocache=" .. os.epoch("utc")

    local job, err = req("GET", job_url)

    if not job then
        term.setTextColor(colors.red)
        print("GET failed: " .. tostring(err))
        term.setTextColor(colors.white)
        os.sleep(5)
    else
        local last_hash, expected_hash, diff = job:match("^([^,]+),([^,]+),([^,]+)")

        if not last_hash then
            term.setTextColor(colors.red)
            print(job)
            term.setTextColor(colors.white)
            os.sleep(10)
        else
            diff = tonumber(diff) or 1

            local start = os.epoch("utc")
            local result = 0
            local limit = diff * 100

            for nonce = 0, limit do
                result = nonce

                if sha.sha1(last_hash .. nonce) == expected_hash then
                    break
                end

                if nonce % 250 == 0 then
                    yield()
                end
            end

            local seconds = math.max((os.epoch("utc") - start) / 1000, 0.001)
            local hashrate = math.floor(result / seconds)

            local submit_url = base ..
                "?u=" .. enc(username) ..
                "&r=" .. enc(result) ..
                "&k=" .. enc(key) ..
                "&s=" .. enc("CC Tweaked Miner 1.0") ..
                "&j=" .. enc(expected_hash) ..
                "&i=" .. enc(miner) ..
                "&h=" .. enc(hashrate) ..
                "&b=" .. enc(seconds) ..
                "&nocache=" .. os.epoch("utc")

            local feedback = req("POST", submit_url) or "NO RESPONSE"

            if feedback:find("GOOD") or feedback:find("BLOCK") then
                accepted = accepted + 1
                term.setTextColor(colors.lime)
            else
                rejected = rejected + 1
                term.setTextColor(colors.red)
            end

            print(feedback .. " | " .. hashrate .. " H/s | " .. accepted .. "/" .. rejected)
            term.setTextColor(colors.white)

            os.sleep(0.5)
        end
    end
end
