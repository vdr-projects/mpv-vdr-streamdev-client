--
--   VDR Streamdev Client
--   Version 0.2.0
--
--   A script which turns mpv into a client for VDR with the Streamdev-Plugin
--
--   Features:
--   * runs on Windows, Linux and Mac Os. (needs bash and netcat installed)
--   * easy channel switching a la vdr (no channel groups for now)
--   * show current and next epg event if available
--   * watch recordings
--
--
--   Short instructions:
--   1. Enable the streamdev-server-plugin in vdr
--   2. Modify streamdevhosts.conf to contain the clients IP
--   3. If you want to have channel names and epg info,
--      modify svdrphosts.conf to contain the clients IP.
--      Also netcat ('nc') and bash needs to be installed and in the path.
--   4. Place this file in one of mpvs script folders 
--     ( ~/.config/mpv/scripts/) or call mpv with the --script
--     command line option.
--     For now --script vdr-streamdev-client.lua is prefered.
--   5. start mpv
--     mpv  vdrstream://[vdr-host][:streamdev-port] [--script vdr-streamdev-client.lua]
--
--   When mpv is running in Streamdev client mode, you can use
--   the keys UP,DOWN, 0-9 to select channels.
--   ENTER will bring up the channel info display.
--   The key 'm' will show the menu.
--
--
--   Copyright 2017 Martin Wache
--   VDR Streamdev Client is free software; you can redistribute it and/or
--   modify it under the terms of the GNU General Public License as published 
--   by the Free Software Foundation Version 2 of the License.
--   You can obtain a copy of the License from 
--   https://www.gnu.org/licenses/gpl2.html
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
local assdraw = require "mp.assdraw"

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

local vw=495
local vh=275


-- ************************* state machine stuff **********************
local state={}
local state_livetv
local state_playback
local state_channel_info
local state_show_epg

function update_osd()
    local cstate=curr_state()
    mp.log("info","update_osd "..cstate.name)
    if (cstate.update_osd) then
        cstate:update_osd()
    else
        clear_osd()
    end
end

function state_update_timeout()
    local cstate=curr_state()
    if cstate.timeout then
        if cstate.timer == nil then
            cstate.timer=mp.add_timeout(cstate.timeout,state_back)
        else
            cstate.timer:kill()
            cstate.timer:resume()
        end
    end
    
    if cstate.update_osd_timeout then
        if cstate.osd_timer == nil then
            cstate.osd_timer=mp.add_periodic_timer(cstate.update_osd_timeout,
            update_osd)
        else
            cstate.osd_timer:kill()
            cstate.osd_timer:resume()
        end
    end
end

function state_remove_timeouts()
    local cstate=curr_state()
    if cstate.timer then
        cstate.timer:kill()
    end
    if cstate.osd_timer then
        cstate.osd_timer:kill()
    end
end

function new_state(nstate)
    table.insert(state,nstate)
    mp.log("info","state_new "..nstate.name)
    state_update_timeout()
    update_osd()
end

function state_remove_including(name)
    local cstate=curr_state()
    while #state>1 and name ~= cstate.name do
        state_back()
        cstate=curr_state()
    end
    -- remove the state the name
    state_back()
end

function state_back_to(name)
    local cstate=curr_state()
    while #state>1 and name ~= cstate.name do
        state_back()
        cstate=curr_state()
    end
end

function state_back()
    local cstate=curr_state()
    state_remove_timeouts()
    if #state>1 then
        table.remove(state)
    end
    cstate=curr_state()
    mp.log("info","state_back, new "..cstate.name)
    update_osd()
end

function curr_state()
    return state[#state]
end

-- *********************** OSD stuff *******************************

function ass_color(ass,bgr)
    ass:append("{\\1c&H"..bgr.."&}")
end
function ass_bdcolor(ass,bgr)
    ass:append("{\\3c&H"..bgr.."&}")
end
function ass_alpha(ass,alpha)
    ass:append("{\\1a&H"..alpha.."}")
end
function ass_bdalpha(ass,alpha)
    ass:append("{\\3a&H"..alpha.."}")
end
function ass_scale_font(ass,scale)
    ass:append("{\\fscx"..scale.."\\fscy"..scale.."}")
end
function ass_clip(ass,x1,y1,x2,y2)
    ass:append("{\\clip("..x1..","..y1..","..x2..","..y2.."}")
end

local function print_time(t)
    if (t == nil) then
        return "    "
    end
    return os.date('%H:%M',t)
end

local function format_epg(epg_info)
    if epg_info == nil then return "" end

    local msg=print_time(epg_info['start'])
    if (epg_info['title'] ~= nil) then
        msg = msg.." "..epg_info['title']
    end
    return msg
end

local function print_duration(t)
    local h=math.floor(t/3600)
    local m=math.floor(t%3600/60)
    local s=t%60
    return string.format("%02d:%02d:%02d",h,m,s)
end

function curr_channel_id()
    local cinfo = channels[channel_idx]
    return cinfo and cinfo['id'] or nil
end

function draw_progressbar(ass,left,top, width, height, part)
    ass:new_event()
    ass:pos(left, top)
    ass_color(ass,"007700")
    ass_alpha(ass,"10")
    ass_bdcolor(ass,"007700")
    ass_bdalpha(ass,"10")
    ass:draw_start()
    ass:rect_ccw(0,0,width,height)
    ass:draw_stop()
    ass:new_event()

    ass:pos(left, top)
    ass_color(ass,"000077")
    ass_alpha(ass,"10")
    ass_bdcolor(ass,"000077")
    ass_bdalpha(ass,"10")
    ass:draw_start()
    ass:rect_ccw(0,0,part*width,height)
    ass:draw_stop()
    ass:new_event()
end

function show_playback_info(self)
    local osd_w=480
    local osd_h=80
    local top=200
    local left=10
    local time_pos = mp.get_property_native("time-pos")
    local max_time = mp.get_property_native("duration")
    local ass = assdraw.ass_new()

    -- channel info box
    ass:new_event()
    ass:pos(left, top)
    ass_color(ass,"000000")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,0,osd_w,osd_h)
    ass:draw_stop()

    -- print current playback time
    ass:new_event()
    ass:pos(left, top)
    ass:append(print_duration(time_pos))

    -- print playback length
    ass:new_event()
    ass:pos(osd_w-80, top)
    ass:append(print_duration(max_time))

    -- print recording name
    ass:new_event()
    ass:pos(left+80, top)
    ass:append(self.rinfo['name'])

    draw_progressbar(ass,left+10,top+30,osd_w-left-10,20,time_pos/max_time)

    mp.set_osd_ass(0, 0, ass.text)
end

function show_channel_info(self)
    local osd_w=480
    local osd_h=80
    local top=200
    local left=10
    local cinfo=channels[channel_idx]
    local ass = assdraw.ass_new()

    -- channel info box
    ass:pos(left, top)
    ass_color(ass,"000000")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,0,osd_w,osd_h)
    ass:draw_stop()

    -- info time box
    ass:new_event()
    ass:pos(left, top)
    ass_color(ass,"000090")
    ass:draw_start()
    ass:rect_ccw(0,0,50,23)
    ass:draw_stop()

    -- print time
    ass:new_event()
    ass:pos(left, top)
    ass:append(os.date("%H:%M"))

    -- channel name
    ass:new_event()
    ass:pos(left+70, top)
    ass:append(channel_idx)
    if cinfo then ass:append("  "..cinfo['name']) end
    ass:new_event()

    local cid = cinfo and cinfo['id'] or nil
    local einfo=epgnow[cid] 
    if einfo then
        -- epg progress bar
        local dwidth=200
        local dheight=5
        if einfo['start'] ~= nil and einfo['duration'] ~= nil then
            local part = (os.time()-tonumber(einfo['start']))/
                          tonumber(einfo['duration'])
            draw_progressbar(ass,left, top+24,dwidth,dheight,part)
        end

        -- epg now info
        ass:pos(left, top+35)
        ass_scale_font(ass,80)
        ass:append(format_epg(einfo))
        ass:new_event()
    end

    einfo = epgnext[cid]
    if einfo ~= nil then
        -- epg next info
        ass:pos(left, top+55)
        ass_scale_font(ass,80)
        ass:append(format_epg(einfo))
        ass:new_event()
    end

    mp.set_osd_ass(0, 0, ass.text)
end

local osd_w=480
local osd_h=260
local top=20
local left=10
function create_menu_base(options)
    local ass = assdraw.ass_new()

    -- menu  box
    ass:pos(left, top)
    ass_color(ass,"000000")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,0,osd_w,osd_h)
    ass:draw_stop()
    ass:new_event()

    -- header box
    ass:pos(left, top)
    ass_color(ass,"000090")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,0,osd_w,20)
    ass:draw_stop()
    ass:new_event()

    -- header
    ass:pos(left, top)
    ass:append(os.date("%H:%M"))
    if options and options.name then ass:append("  "..options.name) end
    ass:new_event()

    -- footer
    ass:pos(left,top+osd_h-20)
    ass_color(ass,"0000F0")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,0,osd_w/4,20)
    ass:draw_stop()
    ass:new_event()
    if options and options.red then
        ass:pos(left,top+osd_h-20)
        ass:append(options.red)
        ass:new_event()
    end

    ass:pos(left+osd_w/4,top+osd_h-20)
    ass_color(ass,"00F000")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,0,osd_w/4,20)
    ass:draw_stop()
    ass:new_event()
    if options and options.green then
        ass:pos(left+osd_w/4,top+osd_h-20)
        ass:append(options.green)
        ass:new_event()
    end

    ass:pos(left+osd_w/4*2,top+osd_h-20)
    ass_color(ass,"00F0F0")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,0,osd_w/4,20)
    ass:draw_stop()
    ass:new_event()
    if options and options.yellow then
        ass:pos(left,top+osd_h-20)
        ass:append(options.yellow)
        ass:new_event()
    end

    ass:pos(left+osd_w/4*3,top+osd_h-20)
    ass_color(ass,"F00000")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,0,osd_w/4,20)
    ass:draw_stop()
    ass:new_event()
    if options and options.blue then
        ass:pos(left+osd_w/4*3,top+osd_h-20)
        ass:append(options.blue)
        ass:new_event()
    end

    return ass
end

function draw_scrollbar(ass,left,top,width,height,part)
    ass:pos(left,top)
    ass_color(ass,"000090")
    ass_alpha(ass,"70")
    ass:draw_start()
    ass:rect_ccw(0,part*height,width,part*height+10)
    ass:draw_stop()
    ass:new_event()
end

local max_items=10
local item_w=osd_w - 10
local item_h=20
function show_menu(self)
    local ass = create_menu_base{red=self.red_name,green=self.green_name,
                                 yellow=self.yellow_name,blue=self.blue_name}
    if self.selected_item == nil then self.selected_item = 1 end
    if self.start_pos == nil then self.start_pos = 1 end
    if self.selected_item>self.start_pos+max_items then
        self.start_pos=self.selected_item - max_items
    end
    if self.selected_item<self.start_pos then
        self.start_pos=self.selected_item
    end
    local maxi = #self.items>self.start_pos+max_items 
                and self.start_pos+max_items or #self.items
    for i = self.start_pos,maxi do
        v = self.items[i]
        local itop= top+(i-self.start_pos+1)*item_h
        if self.selected_item == i then
            ass:pos(left, itop)
            ass_color(ass,"000090")
            ass_alpha(ass,"70")
            ass:draw_start()
            ass:rect_ccw(0,0,item_w,item_h)
            ass:draw_stop()
            ass:new_event()
        end
        if v.draw == nil then
            ass:pos(left, itop)
            ass:append(v.text)
        else
            v:draw(ass,left,itop,item_w,item_h)
        end
        ass:new_event()
    end
    if #self.items>max_items then
        draw_scrollbar(ass,left+osd_w-10,top+20,10,osd_h-40,
                       self.start_pos/#self.items)
    end

    mp.set_osd_ass(0, 0, ass.text)
end

function menu_handle_key(self,k)
    if k=="UP" then
        self.selected_item = self.selected_item - 1
    elseif k=="DOWN" then
        self.selected_item = self.selected_item + 1
    elseif k=="LEFT" then
        self.selected_item = self.selected_item - max_items
    elseif k=="RIGHT" then
        self.selected_item = self.selected_item + max_items
    elseif k=="BS" then
        state_back()
    elseif k=="RED" and self.red_action then
        self:red_action()
    elseif k=="GREEN" and self.green_action then
        self:green_action()
    elseif k=="YELLOW" and self.yellow_action then
        self:yellow_action()
    elseif k=="BLUE" and self.blue_action then
        self:blue_action()
    elseif k=="ENTER" then
        local item = self.items[self.selected_item]
        if  item and item.action then
            item:action()
        end
    elseif k=="m" then
        state_remove_including("main_menu")
    elseif type(k) == "number" and  k>=0 and k<=9 then
        self.selected_item = k
    end

    if self.selected_item > #self.items then 
        self.selected_item = #self.items
    end
    if self.selected_item < 1 then 
        self.selected_item = 1
    end
    update_osd()
end

local margin=20
function split_text(max_len,text)
    local pos = 1
    return function()
        local npos = text:find("\n",pos)
        if npos == nil then npos=text:len() end

        if npos-pos>max_len then
            -- find space to split the string
            npos=text:find(" ",pos+max_len-margin>0 and pos+max_len-margin or 0)
            if npos == nil then npos=text:len() end
        end

        if pos>=text:len() then
            return nil
        end
        local ret = text:sub(pos,npos-1)
        pos = npos + 1
        return ret
    end
end

function show_epg(self)
    local ass = create_menu_base{blue="Switch"}
    local i = 0
    local einfo = self:epg()

    -- time, title
    ass:pos(left, top+23)
    ass:append(format_epg(einfo))
    ass:new_event()
    -- subtitle
    if einfo and einfo['subtitle'] then
        ass:pos(left, top+48)
        ass_scale_font(ass,80)
        ass:append(einfo['subtitle'])
        ass:new_event()
    end
    if einfo and einfo['description'] then
        for v in  split_text(85,einfo['description']:gsub("|","\n")) do
            i = i + 1
            ass:pos(left, top+53+i*13)
            ass_scale_font(ass,70)
            ass:append(v)
            ass:new_event()
        end
    end

    mp.set_osd_ass(0, 0, ass.text)
end

function clear_osd()
    mp.set_osd_ass(0, 0, "")
end

function key(k)
    return function()
        local cstate=curr_state()
        mp.log("info","state name "..cstate.name)
        mp.log("info","key "..k)
        if cstate and cstate.handle_key then
            cstate:handle_key(k)
        end
    end
end

function toArray(i)
    local array={}
    for v in i do
        array[#array+1]=v
    end
    return array
end

function slice(tbl,first,last)
    local s={}
    for i = first or 1, last or #tbl do
        s[#s+1] = tbl[i]
    end
    return s
end

local function send_webrequest(path)
    ret = utils.subprocess({
        args= {'/bin/bash', '-c', '( printf "GET /'..path
               ..' HTTP/1.0\n\n"; sleep 1)|nc '..options.host..' '
               ..options.streamdev_port},
--        args= {'/bin/bash', '-c', 'echo "'..command
--               ..'" >/dev/tcp/'..options.host..'/'..options.svdrp_port},
        cancellable=false,
    })
    return ret.stdout
end

local function parse_ext3mu(stdout)
    mp.log("info","Parsing ext3mu")
    local state='http_header'
    local ret={}
    local title={}
    for l in string.gmatch(stdout,"[^\r\n]+") do
        if state=='http_header' then
            if l~="HTTP/1.0 200 OK" then
                state="error_http_header"
                break
            end
            state="http_header_content"
        elseif state=="http_header_content" then
            if l~="Content-type: audio/x-mpegurl; charset=UTF-8" then
                state="error_http_content"
                break
            end
            state="content_header"
        elseif state=="content_header" then
            if l~="#EXTM3U" then
                state="error_content_header"
                break
            end
            state="content_line_header"
        elseif state=="content_line_header" then
            if l:sub(1,11)~="#EXTINF:-1," then
                state="error_content_line_header"
                mp.log("info","'"..l:sub(1,11).."'")
                break
            end
            local info=toArray(string.gmatch(l:sub(12),"[^ ]+"))
            title['idx']=info[1]
            title['day']=info[2]
            title['time']=info[3]
            title['name']=table.concat(slice(info,4)," ")
            state = "content_line"
        elseif state=="content_line" then
            title['url']=l
            table.insert(ret,title)
            title = {}
            state = "content_line_header"
        end
    end
    mp.log("info",state)
    return ret
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
                    local c =tonumber(channel:sub(0,sp-1))
                    local cinfo={}
                    cinfo['idx']=c
                    cinfo['name']=channel:sub(sp+1)
-- S19.2E-1-1079-28011 ZDFinfo (S19.2E)
-- ZDFinfo;ZDFvision:11953:HC34M2S0:S19.2E:27500:610=2:620=deu@3,621=mis@3,622=mul@3;625=deu@106:630;631=deu:0:28011:1:1079:0
                    local para=toArray(i:sub(channel_end+1):gmatch("[^:]+"))
                    if (#para>12) then
                        local cid=para[4].."-"..para[11].."-"..para[12].."-"..para[10]
                        --mp.log("info",cid)
                        cinfo['id']=cid
                    end
                    table.insert(channels,cinfo)
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

local function switch_channel(no) 
    mp.log("info","switch_channel "..no)
    local sav_channel=channel_idx
    mp.add_timeout(options.previous_channel_time,function()
        last_channel=sav_channel
    end)
    channel_idx=no
    mp.commandv("loadfile",vdruri .. channel_idx)
    if curr_state().name ~="channel_info" then
        new_state(state_channel_info)
    else 
        state_update_timeout()
    end
    next_channel=0
    update_osd()
end

local function playback_recording(url) 
    mp.log("info","play_rec "..url)
    local sav_channel=channel_idx
    mp.commandv("loadfile",url)
end

local function channel_next()
    mp.log("info","next channel called " .. channel_idx .. " len channels " .. #channels)
    channel_idx = channel_idx + 1
    if #channels>0 and channel_idx > #channels then
        channel_idx = 1
    end
    switch_channel(channel_idx);
end
local function channel_prev()
    mp.log("info","next channel called " .. channel_idx .. " len channels " .. #channels)
    channel_idx = channel_idx - 1
    if (channel_idx < 0) then
        channel_idx =#channels > 0 and #channels or 0
    end
    switch_channel(channel_idx);
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

local function playback_handle_key(self,key)
    mp.log("info","state name "..self.name)
    if key=="BLUE" then
        state_back_to("livetv")
        switch_channel(channel_idx)
    elseif key=="BS" then
        state_back()
        switch_channel(channel_idx)
    elseif key=="DOWN" or key=="UP" then
        mp.command("cycle pause")
    elseif key=="YELLOW" then
        mp.command("no-osd seek +30")
        update_osd()
    elseif key=="GREEN" then
        mp.command("no-osd seek -30")
        update_osd()
    elseif key=="ENTER" then
        if self.update_osd==nil then
            self.update_osd=show_playback_info
        else
            self.update_osd=nil
        end
        update_osd()
    end
end

local function livetv_handle_key(self,key)
    mp.log("info","state name "..self.name)
    if key=="ENTER" then
        if self.name=="channel_info" then
            state_back()
        else
            new_state(state_channel_info)
        end
    elseif key=="BS" then
        if self.name=="channel_info" then
            state_back()
        end
    elseif key=="m" then
        state_back()
        new_state(state_main_menu)
    elseif key=="UP" then
        channel_next()
    elseif key=="DOWN" then
        channel_prev()
    elseif type(key) =="number" then
        if  key == 0 and next_channel == 0 then
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
        --mp.set_property("cache-size",1024)
        switch_channel(1)
    end
    mp.log("info","Lua version " .. _VERSION)
end

function new_show_epgs_state(epg_info,channel_info)
    state_show_epg = {
        name = "menu_epg",
        handle_key = function(self,k)
            if k=="ENTER" or k=="BS" then
                state_back()
            elseif k=="m" then
                state_remove_including("main_menu")
            elseif k=="BLUE" then
                state_back_to("livetv")
                switch_channel(self.cinfo['idx'])
            end
        end,

        update_osd = show_epg,
        epg = function(self)
            return epg_info
        end,
        cinfo = channel_info,
    }
    return state_show_epg
end

function draw_epg_item(self,ass,left,top,width,height)
    ass:pos(left,top)
    ass_clip(ass,left,top,left+95,top+height)
    ass_scale_font(ass,80)
    ass:append(self.cinfo['name'])
    ass:new_event()

    ass:pos(left+100,top)
    ass_scale_font(ass,80)
    ass:append(print_time(self.einfo['start']))
    ass:new_event()

    if self.einfo['title'] then
        ass:pos(left+150,top)
        ass_clip(ass,left+150,top,left+width,top+height)
        ass_scale_font(ass,80)
        ass:append(self.einfo['title'])
        ass:new_event()
    end
end

function create_epg_show_menu_state(name,epglist)
    local items={}
    for i=1,#channels do
        local c = channels[i]
        if c['id'] and c['name'] then
            local e = epglist[c['id']]
            if e then
                table.insert(items,{
                    text=c['name']..format_epg(e),
                    action = function()
                        new_state(new_show_epgs_state(e,c))
                    end,
                    draw = draw_epg_item,
                    einfo = e,
                    cinfo = c,
                })
            end
        end
    end
    local nstate= new_menu_state(name,items)
    nstate.blue_name="Switch"
    nstate.blue_action=function(self)
        state_back_to("livetv")
        switch_channel(self.selected_item)
    end
    nstate.selected_item=channel_idx
    return nstate
end

function create_playback_state(rinfo)
   local state_playback = {
       name = "playback",
       handle_key = playback_handle_key,
       update_osd = nil,
       rinfo = rinfo,
       update_osd_timeout=1,
   }
   return state_playback
end

function create_recordings_show_items()
    items={}
    recordings=parse_ext3mu(send_webrequest("/recordings.m3u"))
    for i,r in pairs(recordings) do
        table.insert(items,{
            text=r['name'],
            action = function(self)
                playback_recording(self.rinfo['url'])
                new_state(create_playback_state(self.rinfo))
            end,
            rinfo = r,
        })
    end
    return items
end


function new_menu_state(name,items)
    local state_menu = {
        name = name,
        handle_key = menu_handle_key,
        update_osd = show_menu,
        items = items,
    }
    return state_menu
end

state_main_menu = new_menu_state("main_menu",
    {
        { 
            text="What's on now",
            action = function() 
                local nstate=create_epg_show_menu_state("epg_now",
                               epgnow)
                new_state(nstate)
            end,
        },
        {
            text="What's on next",
            action = function() 
                local nstate=create_epg_show_menu_state("epg_next",
                               epgnext)
                new_state(nstate)
            end,
        },
        {
            text="Recordings",
            action = function() 
                new_state( new_menu_state("Recordings",
                   create_recordings_show_items()
                   ))
            end,
        },
    })

state_epg_now = {
    name = "state_epg_now",
    handle_key = menu_handle_key,
    update_osd = show_menu,
}

state_livetv = {
    name = "livetv",
    handle_key = livetv_handle_key,
    update_osd = nil,
}


state_channel_info = {
    name = "channel_info",
    handle_key = livetv_handle_key,
    update_osd = show_channel_info,
    timeout = 5,
}

new_state( state_livetv )

mp.add_key_binding("F1",'vdrkeyRED',key("RED"))
mp.add_key_binding("F2",'vdrkeyGREEN',key("GREEN"))
mp.add_key_binding("F3",'vdrkeyYELLOW',key("YELLOW"))
mp.add_key_binding("F4",'vdrkeyBLUE',key("BLUE"))
mp.add_key_binding("0",'vdrkey0',key(0))
mp.add_key_binding("1",'vdrkey1',key(1))
mp.add_key_binding("2",'vdrkey2',key(2))
mp.add_key_binding("3",'vdrkey3',key(3))
mp.add_key_binding("4",'vdrkey4',key(4))
mp.add_key_binding("5",'vdrkey5',key(5))
mp.add_key_binding("6",'vdrkey6',key(6))
mp.add_key_binding("7",'vdrkey7',key(7))
mp.add_key_binding("8",'vdrkey8',key(8))
mp.add_key_binding("9",'vdrkey9',key(9))
mp.add_key_binding("UP",'vdrkeyUP',key("UP"))
mp.add_key_binding("DOWN",'vdrkeyDOWN',key("DOWN"))
mp.add_key_binding("LEFT",'vdrkeyLEFT',key("LEFT"))
mp.add_key_binding("RIGHT",'vdrkeyRIGHT',key("RIGHT"))
mp.add_key_binding("ENTER",'vdrkeyENTER',key("ENTER"))
mp.add_key_binding("BS",'vdrkeyBS',key("BS"))
mp.add_key_binding("m",'vdrkeym',key("m"))
mp.add_key_binding("i",'show_description',show_description)
mp.add_hook("on_load", 50, on_start)
