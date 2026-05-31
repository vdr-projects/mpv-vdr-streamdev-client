--
--   VDR Streamdev Client
--
--   A script which turns mpv into a client for VDR with the Streamdev-Plugin
--
--   Copyright 2017 Martin Wache
--   VDR Streamdev Client is free software; you can redistribute it and/or
--   modify it under the terms of the GNU General Public License as published 
--   by the Free Software Foundation Version 2 of the License.
--   You can obtain a copy of the License from 
--   https://www.gnu.org/licenses/gpl2.html
--   
--   Short instructions:
--   1. Enable the streamdev-server-plugin in vdr
--   2. Modify streamdevhosts.conf to contain the clients IP
--   3. If you want to have channel names and epg info,
--      modify svdrphosts.conf to contain the clients IP.
--      Also netcat ('nc') needs to be installed and in the path.
--   4. Place this file in one of mpvs script folders 
--     ( ~/.config/mpv/scripts/) or call mpv with the --script
--     command line option
--   5. start mpv
--     mpv  vdrstream://[vdr-host][:streamdev-port]
--
--   When mpv is running in Streamdev client mode, you can use
--   the keys UP,DOWN, 0-9 to select channels.
--   ENTER will bring up the channel info display.
--   The key 'i' will show the epg info for the current runing
--   event.
--

local options = {
    host="192.168.55.4",
    svdrp_port="6419",
    streamdev_port="3000",
    previous_channel_time=10,
    epg_update_time=300,
}
require 'mp.options'
read_options(options,'vdr-streamdev-client')

local channels = { }
local startup = 1
local vdruri
local utils = require 'mp.utils'
local channel_idx=1
local next_channel=0
local last_channel=1
local epgnow = {}
local epgnext = {}
local epg_timer -- refreshes the epg info regulary

local osd_state="off"

function toArray(i)
    local array={}
    for v in i do
        array[#array+1]=v
    end
    return array
end

local function send_svdrp(command)
    ret = utils.subprocess({
        args= {'/bin/bash', '-c', 'echo "'..command
               ..'" |nc '..options.host..' '..options.svdrp_port},
--        args= {'/bin/bash', '-c', 'echo "'..command
--               ..'" >/dev/tcp/'..options.host..'/'..options.svdrp_port},
        cancellable=false,
    })
    return ret.stdout
end

local function parse_lstc(stdout)
    mp.log("info","Getting channel list")
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code = i:sub(1,4)
        if (code ~= "250-") then
            mp.log("info","Unknown code '"..code.."'")
        else
            local channel_end=i:find(";")
            if (channel_end ~=nil) then
                local channel=i:sub(5,channel_end-1)
                local sp=channel:find(" ")
                if (sp ~= nil) then
                    local c =channel:sub(0,sp-1)
                    if (channels[c] == nil) then
                        channels[c]={}
                    end
                    channels[c]['name']=channel:sub(sp+1)
-- S19.2E-1-1079-28011 ZDFinfo (S19.2E)
-- ZDFinfo;ZDFvision:11953:HC34M2S0:S19.2E:27500:610=2:620=deu@3,621=mis@3,622=mul@3;625=deu@106:630;631=deu:0:28011:1:1079:0
                    local para=toArray(i:sub(channel_end+1):gmatch("[^:]+"))
                    if (#para>12) then
                        local cid=para[4].."-"..para[11].."-"..para[12].."-"..para[10]
                        --mp.log("info",cid)
                        channels[c]['id']=cid
                    end
                end
            end
        end
    end
end

local function get_channels()
    parse_lstc(send_svdrp('LSTC'))
end

local function parse_lste(stdout)
    local epginfo={}
    local cid 
    mp.log("info","Updating epg")
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code = i:sub(1,5)
        if (code == "215-C") then
            cid=i:sub(7)
            cid=cid:sub(1,cid:find(" ")-1)
            -- mp.log("info","Channel '"..cid.."'")
            if (epginfo[cid] == nil) then
                epginfo[cid] = {}
            end
        elseif (code == "215-T") then
            --mp.log("info","cid '"..cid.."' Titel '"..i:sub(7).."'")
            if (cid ~= nil) then
                epginfo[cid]['title']=i:sub(7)
            end 
        elseif (code == "215-E") then
            if (cid ~= nil) then
                local p=toArray(i:sub(7):gmatch("[^ ]+"))
                epginfo[cid]['start']=p[2]
                epginfo[cid]['duration']=p[3]
            end 
        elseif (code == "215-S") then
            if (cid ~= nil) then
                epginfo[cid]['subtitle']=i:sub(7)
            end 
        elseif (code == "215-D") then
            if (cid ~= nil) then
                epginfo[cid]['description']=i:sub(7)
            end 
        elseif (code =="215-c") then
            cid = nil
        end
    end
    return epginfo
end

local function get_epg_now()
    epgnow=parse_lste(send_svdrp("LSTE now"))
end

local function get_epg_next()
    epgnext=parse_lste(send_svdrp("LSTE next"))
end



local function print_time(t)
    if (t == nil) then
        return "    "
    end
    return os.date('%H:%M',t)
end


local function format_epg(epg_info)
    local msg=print_time(epg_info['start'])
    if (epg_info['title'] ~= nil) then
        msg = msg.." "..epg_info['title']
    end
    return msg
end

local function show_description()
    local cinfo=channels[tostring(channel_idx)]
    local msg=""
    local cid=cinfo['id']
    local einfo=epgnow[cid]
    if (cinfo and einfo) then
        msg = msg .. format_epg(einfo)
        if (einfo['subtitle'] ~= nil) then
            msg = msg .."\n\n" .. einfo['subtitle']
        end
        msg = msg .."\n\n" .. einfo['description']:gsub("|","\n")
    end
    mp.osd_message( msg, 30)
end

local function format_progress(part,length)
    mp.log("info","part "..part.." length "..length)
    ret = ""
    for i = 1,length do
        if (i/length>part) then
            ret = ret .. "--"
        else
            ret = ret .. "+"
        end
    end
    return ret
end

local function show_channel_info()
    msg=os.date('%H:%M').."               "..channel_idx
    local cinfo=channels[tostring(channel_idx)]
    if (cinfo) then
        local cid=cinfo['id']
        msg=msg.." "..cinfo['name'].."\n"
        if (epgnow[cid] ~= nil) then
            local einfo=epgnow[cid]
            if (einfo['start'] ~= nil and einfo['duration'] ~= nil) then
                local part = (os.time()-tonumber(epgnow[cid]['start']))
                            /tonumber(epgnow[cid]['duration'])
                msg = msg .. "\n" .. format_progress(part,30)
            end
            msg = msg .. "\n" .. format_epg(epgnow[cid])
        end
        if (epgnext[cid] ~= nil) then
            msg = msg .. "\n" ..format_epg(epgnext[cid])
        end
    end
    mp.osd_message(msg,5)
end

local function switch_channel(no) 
    mp.log("info","switch_channel "..no)
    local sav_channel=channel_idx
    mp.add_timeout(options.previous_channel_time,function()
        last_channel=sav_channel
    end)
    channel_idx=no
    mp.commandv("loadfile",vdruri .. channel_idx)
    show_channel_info()
    next_channel=0
end

local function channel_next()
    mp.log("info","next channel called " .. channel_idx .. " len channels " .. #channels)
    channel_idx = channel_idx + 1
    --#if (channel_idx > #channels) then
    --#    channel_idx = 1
    --#end
    --mp.commandv("loadfile",channels[channel_idx])
    --mp.commandv("loadfile",vdruri .. channel_idx)
    switch_channel(channel_idx);
    -- mp.set_property("stream-open-filename",channels[channel_idx])
end
local function channel_prev()
    mp.log("info","next channel called " .. channel_idx .. " len channels " .. #channels)
    channel_idx = channel_idx - 1
    --#if (channel_idx > #channels) then
    --#    channel_idx = 1
    --#end
    --mp.commandv("loadfile",channels[channel_idx])
    switch_channel(channel_idx);
    -- mp.set_property("stream-open-filename",channels[channel_idx])
end
local channel_timer=mp.add_periodic_timer(2,function() 
    if ( next_channel ~= 0 ) then
        switch_channel(next_channel)
        next_channel = 0
    end
    if ( channel_timer ~= nil ) then
        channel_timer:kill()
    end
end)
local function key(key)
    if (key == 0 and next_channel == 0) then
        -- immediatly update last_channel
        local sav_channel=channel_idx
        switch_channel(last_channel);
        last_channel=sav_channel
        return
    end
    next_channel=next_channel*10+key
    mp.osd_message(next_channel)
    channel_timer:resume()
end

local function keypress(k)
    return function()
        key(k)
    end
end

local function on_start()
    local url = mp.get_property("stream-open-filename")
    mp.log("info","channels length "..#channels)

    if (url:find("vdrstream://") == 1) then
        if ( startup == 1) then
            local host_port = url:sub(13)
            if (host_port:len()>0) then
                local has_port=host_port:find(":")
                if (has_port) then
                    options.host = host_port:sub(1,has_port-1)
                    options.streamdev_port=host_port:sub(has_port+1)
                else
                    options.host = host_port
                end
            end
            mp.log("info","VDR host:"..options.host)
            mp.log("info","VDR svdrp port:"..options.svdrp_port)
            mp.log("info","VDR streamdev port:"..options.streamdev_port)
            vdruri="http://"..options.host..":"..options.streamdev_port.."/TS/"

            -- set parameters to optimize channel switch time
            mp.set_property("cache-secs",1)
            mp.set_property("demuxer-lavf-analyzeduration",1)
            mp.set_property("ytdl","no")

            get_channels()
            -- load epg in background
            mp.add_timeout(1,function()
                get_epg_now()
                get_epg_next()
                mp.log("info","finished epg")
            end)
            -- periodically update epg
            epg_timer = mp.add_periodic_timer(options.epg_update_time,function() 
                get_epg_now()
                get_epg_next()
            end)

            startup = 0
        end
        -- mp.set_property("stream-open-filename",channels[channel_idx])
        mp.set_property("cache-size",1024)
        switch_channel(1)
    end
    mp.log("info","Lua version " .. _VERSION)
end

mp.add_forced_key_binding("UP",'next_channel',channel_next)
mp.add_forced_key_binding("DOWN",'prev_channel',channel_prev)
mp.add_forced_key_binding("0",'key0',keypress(0))
mp.add_forced_key_binding("1",'key1',keypress(1))
mp.add_forced_key_binding("2",'key2',keypress(2))
mp.add_forced_key_binding("3",'key3',keypress(3))
mp.add_forced_key_binding("4",'key4',keypress(4))
mp.add_forced_key_binding("5",'key5',keypress(5))
mp.add_forced_key_binding("6",'key6',keypress(6))
mp.add_forced_key_binding("7",'key7',keypress(7))
mp.add_forced_key_binding("8",'key8',keypress(8))
mp.add_forced_key_binding("9",'key9',keypress(9))
mp.add_forced_key_binding("ENTER",'show_channel_info',show_channel_info)
mp.add_forced_key_binding("i",'show_description',show_description)
mp.add_hook("on_load", 50, on_start)
