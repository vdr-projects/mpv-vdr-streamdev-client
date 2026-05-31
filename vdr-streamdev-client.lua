--   Copyright 2017 Martin Wache
--   VDR Streamdev Client is free software; you can redistribute it and/or
--   modify it under the terms of the GNU General Public License as published 
--   by the Free Software Foundation Version 2 of the License.
--   You can obtain a copy of the License from 
--   https://www.gnu.org/licenses/gpl2.html
--
--   VDR Streamdev Client
--   Version 0.3.3
--
--   A script which turns mpv into a client for VDR with the Streamdev-Plugin
--
--   Features:
--   * runs on Windows, Linux and Mac Os. (needs bash and netcat installed)
--   * easy channel switching a la vdr (no channel groups for now)
--   * show current and next epg event if available
--   * create timers from epg, disable/enable and remove timers
--   * watch recordings
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
--     mpv  vdrstream://[vdr-host][:streamdev-port][/channel] [--script vdr-streamdev-client.lua]
--
--   When mpv is running in Streamdev client mode, you can use
--   the keys UP,DOWN, 0-9 to select channels.
--   ENTER will bring up the channel info display.
--   The key 'm' will show the menu.
--
--   Many thanks to:
--   - wolfi.m@vdr-portal.de for fixing the dimensions of the time-box
--     in the channel-info, the progress bar position and pointing
--     out that I forgot to remove my startup channel.
--   - jrie@vdr-portal.de for fixing the bash path for windows
--

local config = {
    host="192.168.55.4",
    svdrp_port="6419",
    --svdrp_port="2004",
    streamdev_port="3000",
    -- default startup channel to show
    startup_channel=1,
    -- time after which the '0' key returns to this channel
    previous_channel_time=10,
    -- for how long to show playback/channel info
    show_info_timeout=7,
    -- timeout after which channel entry is assumed to be finished
    channel_switch_timeout=5,

    --media_dir="/Users/wache/Downloads/mps/", 
    media_dir="/Volumes/video", 
    -- all media extensions in upper case please!
    media_extensions={".AVI",".MPG",".OGG",".M4A",".M3U",".MP4",".WEBM",},

    -- if you don't want to use streamdev-streaming for recordings
    -- you can provide the path to VDRs video directory here (mounted locally)
    vdr_video_dir="",

    -- recording MB/minute to estimate remaining recording time
    mb_per_minute=25,

    -- how often the current/next epg events are loaded from the server.
    -- In seconds
    epg_nownext_update_time=300,
    -- time after which a schedule for a channel is considered out of date
    -- and updated from the server. In seconds.
    epg_channel_update_time=3600,
    -- how long after the event ended it is still shown. In seconds.
    epg_old_events_linger_time=120,

    -- how much time before an event the timer starts. In minutes.
    timer_margin_start=5,
    -- how much time after an event the timer stops. In minutes.
    timer_margin_stop=10,
    -- the default lifetime of a recording (see VDRs manual)
    timer_default_lifetime=99,
    -- the default priority of a recording (see VDRs manual)
    timer_default_priority=50,

    osd_font_pixel_per_char=8,

    -- osd colors
    osd_background_color="000000",
    osd_background_alpha="70",
    osd_header_color="000090",
    osd_header_alpha="70",
    osd_highlight_color="000090",
    osd_highlight_alpha="70",
    osd_progressbar_fg_color="00F000",
    osd_progressbar_fg_alpha="10",
    osd_progressbar_bg_color="000090",
    osd_progressbar_bg_alpha="10",
    osd_red="0000F0",
    osd_reda="70",
    osd_green="00F000",
    osd_greena="70",
    osd_yellow="00F0F0",
    osd_yellowa="70",
    osd_blue="F00000",
    osd_bluea="70",
    osd_message_color="007700",
    osd_message_alpha="10",
    osd_confirm_color="007777",
    osd_confirm_alpha="10",

    osd_top_menu=20,
    osd_left_menu=20,
    osd_width_menu=430,
    osd_height_menu=242,
    osd_menu_max_items=9,
    osd_menu_item_height=20,
    osd_max_rows = 14,

    osd_message_left=20,
    osd_message_top=230,
    osd_message_width=430,
    osd_message_height=20,

    osd_info_left=20,
    osd_info_top=180,
    osd_info_width=430,
    osd_info_height=80,
}
require 'mp.options'
read_options(config,'vdr-streamdev-client')
local assdraw = require "mp.assdraw"

local channels = { }
local chno_to_idx = {}
local chid_to_idx = {}
local startup = 1
local has_svdrp = 0
local vdruri
local utils = require 'mp.utils'
local channel_idx=1
local next_channel=0
local last_channel=1
local next_last_channel=1
local update_last_channel_timeout
local disk_space_available=nil
local disk_space_free=nil
local disk_space_percent=nil
local epginfo = {}
local epginfo_time = {}
local epg_timer -- refreshes the epg info regulary
local timerinfo = {}

local vw=495
local vh=275

-- ************************* misc ***********************

function ends_with(str,str_end)
    local str_len=str:len()
    return str:sub(1+str:len()-str_end:len(),str_len)==str_end
end

function strip_end(str,str_end)
    local str_len=str:len()
    return str:sub(1,str:len()-str_end:len()+1)
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

-- ************************* state machine stuff **********************
local state={}
local state_livetv
local state_playback
local state_channel_info
local main_menu_items

function update_state()
    local cstate=curr_state()
    if (cstate.update_state) then
        cstate:update_state()
    end
end

function update_osd()
    local cstate=curr_state()
    mp.log("info","update_osd "..cstate.name)
    local ass
    if (cstate.update_osd) then
        ass = cstate:update_osd()
    else
        ass = assdraw.ass_new()
    end
    if cstate.message ~= nil or cstate.confirm ~= nil then
        -- message box
        ass:new_event()
        ass:pos(config.osd_message_left, config.osd_message_top)
        if cstate.confirm ~= nil then
            ass_color(ass,config.osd_confirm_color)
            ass_alpha(ass,config.osd_confirm_alpha)
        else
            ass_color(ass,config.osd_message_color)
            ass_alpha(ass,config.osd_message_alpha)
        end
        ass:draw_start()
        ass:rect_ccw(0,0,config.osd_message_width,config.osd_message_height)
        ass:draw_stop()

        -- print message
        ass:new_event()
        ass:pos(config.osd_message_left, config.osd_message_top)
        if cstate.confirm ~= nil then
            ass:append(cstate.confirm)
        else
            ass:append(cstate.message)
        end
    end

    mp.set_osd_ass(0, 0, ass.text)
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
                                  function()
                                      update_state()
                                      update_osd()
                                  end)
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

function update_hide_osd_timeout()
    local cstate=curr_state()
    if cstate.hide_osd_timeout then
        if cstate.hide_osd_timer ~= nil then
            cstate.hide_osd_timer:kill()
        end
        cstate.hide_osd_timer=mp.add_timeout(cstate.hide_osd_timeout,
             function()
                 cstate.update_osd=nil
                 update_osd()
             end)
    end
    cstate.hide_osd_timeout=nil
end

function new_state(nstate)
    table.insert(state,nstate)
    mp.log("info","state_new "..nstate.name)
    state_update_timeout()
    update_state()
    update_hide_osd_timeout()
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
    update_state()
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

local function vdrtime2str(t)
    return t:sub(1,2)..":"..t:sub(3,5)
end

local function print_time(t)
    if (t == nil) then
        return "    "
    end
    return os.date('%H:%M',t)
end

local function print_date(t)
    if (t == nil) then
        return "    "
    end
    return os.date('%a %d.%m',t)
end

-- local fake time stamp
local function lts(options)
    if options.hour == nil then options.hour=0 end
    if options.min == nil then options.min=0 end
    return ((((options.year-1970)*366+options.month)*31+options.day)*24+
            options.hour)*60+options.min
end

local function to_lts(date, time)
    local year=tonumber(date:sub(1,4))
    local month=tonumber(date:sub(6,7))
    local day=tonumber(date:sub(9,10))
    local min=tonumber(time:sub(3,4))
    local hour=tonumber(time:sub(1,2))
    --return os.time{year=year,month=month,day=day,hour=hour,minute=min}
    return lts{year=year,month=month,day=day,
                               hour=hour,min=min}
end

local function format_epg(epg_info)
    if epg_info == nil then return "" end

    local msg
    msg=print_time(epg_info['start'])
    if (epg_info.timer_status =="T") then
        msg= msg.." REC: "
    end
    if (epg_info['title'] ~= nil) then
        msg = msg.." "..epg_info['title']
    end
    return msg
end

local function date_format_epg(epg_info)
    local msg=format_epg(epg_info)
    msg = print_date(epg_info.start) .. " " .. msg
    return msg
end

local function print_duration(t)
    if t==nil then
        return "xx:xx:xx"
    end
    local h=math.floor(t/3600)
    local m=math.floor(t%3600/60)
    local s=t%60
    return string.format("%02d:%02d:%02d",h,m,s)
end

function curr_channel_id()
    local cinfo = channels[channel_idx]
    return cinfo and cinfo['id'] or nil
end

function channel_id_to_idx(cid)
    return chid_to_idx[cid]
end

function draw_progressbar(ass,left,top, width, height, part)
    ass:new_event()
    ass:pos(left, top)
    ass_color(ass,config.osd_progressbar_bg_color)
    ass_alpha(ass,config.osd_progressbar_bg_alpha)
    ass_bdcolor(ass,config.osd_progressbar_bg_color)
    ass_bdalpha(ass,config.osd_progressbar_bg_alpha)
    ass:draw_start()
    ass:rect_ccw(0,0,width,height)
    ass:draw_stop()
    ass:new_event()

    if part <0 then return end
    ass:pos(left, top)
    ass_color(ass,config.osd_progressbar_fg_color)
    ass_alpha(ass,config.osd_progressbar_fg_alpha)
    ass_bdcolor(ass,config.osd_progressbar_fg_color)
    ass_bdalpha(ass,config.osd_progressbar_fg_alpha)
    ass:draw_start()
    ass:rect_ccw(0,0,part*width,height)
    ass:draw_stop()
    ass:new_event()
end

function show_playback_info(self)
    --local time_pos = mp.get_property_native("time-pos")
    local time_pos = mp.get_property_native("playback-time")
    local max_time = mp.get_property_native("duration")
    local ass = assdraw.ass_new()

    -- channel info box
    ass:new_event()
    ass:pos(config.osd_info_left, config.osd_info_top)
    ass_color(ass,config.osd_background_color)
    ass_alpha(ass,config.osd_background_alpha)
    ass:draw_start()
    ass:rect_ccw(0,0,config.osd_info_width,config.osd_info_height)
    ass:draw_stop()

    -- print current playback time
    ass:new_event()
    ass:pos(config.osd_info_left, config.osd_info_top)
    ass:append(print_duration(time_pos))

    -- print playback length
    ass:new_event()
    ass:pos(config.osd_info_width-80, config.osd_info_top)
    ass:append(print_duration(max_time))

    -- print recording name
    ass:new_event()
    ass:pos(config.osd_info_left+80, config.osd_info_top)
    ass_clip(ass,config.osd_info_left+80,config.osd_info_top,
                 config.osd_info_left+config.osd_info_width-100,config.osd_info_top+20)
    ass_scale_font(ass,80)
    ass:append(self.rinfo['name'])

    if time_pos~= nil and max_time~= nil then
        draw_progressbar(ass,config.osd_info_left+10,config.osd_info_top+30,
            config.osd_info_width-config.osd_info_left-10,20,time_pos/max_time)
    end

    return ass
end

function show_channel_info(self)
    local ass = assdraw.ass_new()
    local cidx = next_channel==0 and channel_idx or chno_to_idx[next_channel]
    local cinfo = cidx and channels[cidx] or nil
    local chno = cinfo and cinfo.no or cidx
    if next_channel ~= 0 then
        -- channel switching by entering a number
        chno = next_channel
        cidx = chno_to_idx[chno]
        cinfo = cidx and channels[cidx] or nil
    else
        cidx = channel_idx
        cinfo = channels[cidx]
        chno = cinfo and cinfo.no or cidx
    end

    -- channel info box
    ass:pos(config.osd_info_left, config.osd_info_top)
    ass_color(ass,config.osd_background_color)
    ass_alpha(ass,config.osd_background_alpha)
    ass:draw_start()
    ass:rect_ccw(0,0,config.osd_info_width,config.osd_info_height)
    ass:draw_stop()

    -- info time box
    ass:new_event()
    ass:pos(config.osd_info_left, config.osd_info_top)
    ass_color(ass,config.osd_header_color)
    ass_alpha(ass,config.osd_header_alpha)
    ass:draw_start()
    ass:rect_ccw(0,0,55,23)
    ass:draw_stop()

    -- print time
    ass:new_event()
    ass:pos(config.osd_info_left, config.osd_info_top)
    ass:append(os.date("%H:%M"))

    -- channel name
    ass:new_event()
    ass:pos(config.osd_info_left+70, config.osd_info_top)
    ass:append(chno)
    if next_channel~=0 then
        ass:append("_")
    end
    if cinfo then ass:append("  "..cinfo['name']) end
    ass:new_event()

    local cid = cinfo and cinfo['id'] or nil
    local einfo=get_epgnow(cid)
    if einfo then
        -- epg progress bar
        local dwidth=200
        local dheight=5
        if einfo['start'] ~= nil and einfo['duration'] ~= nil then
            local part = (os.time()-tonumber(einfo['start']))/
                          tonumber(einfo['duration'])
            draw_progressbar(ass,config.osd_info_left+1, config.osd_info_top+24,
                             dwidth,dheight,part)
        end

        -- epg now info
        ass:pos(config.osd_info_left+2, config.osd_info_top+35)
        ass_clip(ass,config.osd_info_left,config.osd_info_top+35,
                     config.osd_info_left+config.osd_info_width,
                     config.osd_info_top+55)
        ass_scale_font(ass,80)
        ass:append(format_epg(einfo))
        ass:new_event()
    end

    einfo = get_epgnext(cid)
    if einfo ~= nil then
        -- epg next info
        ass:pos(config.osd_info_left+2, config.osd_info_top+55)
        ass_clip(ass,config.osd_info_left,config.osd_info_top+55,
                     config.osd_info_left+config.osd_info_width,
                     config.osd_info_top+75)
        ass_scale_font(ass,80)
        ass:append(format_epg(einfo))
        ass:new_event()
    end

   return ass
end

function create_menu_base(options)
    local ass = assdraw.ass_new()
    local bg = config.osd_background_color
    local bga = config.osd_background_alpha
    local hd = config.osd_header_color
    local hda = config.osd_header_alpha
    local red = config.osd_red
    local reda = config.osd_reda
    local green = config.osd_green
    local greena = config.osd_greena
    local yellow = config.osd_yellow
    local yellowa = config.osd_yellowa
    local blue = config.osd_blue
    local bluea = config.osd_bluea

    -- menu  box
    ass:pos(config.osd_left_menu, config.osd_top_menu)
    ass_color(ass,bg)
    ass_alpha(ass,bga)
    ass:draw_start()
    ass:rect_ccw(0,0,config.osd_width_menu,config.osd_height_menu)
    ass:draw_stop()
    ass:new_event()

    -- header box
    ass:pos(config.osd_left_menu, config.osd_top_menu)
    ass_color(ass,hd)
    ass_alpha(ass,hda)
    ass:draw_start()
    ass:rect_ccw(0,0,config.osd_width_menu,20)
    ass:draw_stop()
    ass:new_event()

    -- header
    ass:pos(config.osd_left_menu, config.osd_top_menu)
    ass:append(os.date("%H:%M"))
    if options and options.name then ass:append("  "..options.name) end
    ass:new_event()

    -- footer
    ass:pos(config.osd_left_menu,config.osd_top_menu+config.osd_height_menu-20)
    ass_color(ass,red)
    ass_alpha(ass,reda)
    ass:draw_start()
    ass:rect_ccw(0,0,config.osd_width_menu/4,20)
    ass:draw_stop()
    ass:new_event()
    if options and options.red then
        ass:pos(config.osd_left_menu+2,config.osd_top_menu+config.osd_height_menu-20)
        ass_scale_font(ass,80)
        ass:append(options.red)
        ass:new_event()
    end

    ass:pos(config.osd_left_menu+config.osd_width_menu/4,config.osd_top_menu+config.osd_height_menu-20)
    ass_color(ass,green)
    ass_alpha(ass,greena)
    ass:draw_start()
    ass:rect_ccw(0,0,config.osd_width_menu/4,20)
    ass:draw_stop()
    ass:new_event()
    if options and options.green then
        ass:pos(config.osd_left_menu+config.osd_width_menu/4+2,config.osd_top_menu+config.osd_height_menu-20)
        ass_scale_font(ass,80)
        ass:append(options.green)
        ass:new_event()
    end

    ass:pos(config.osd_left_menu+config.osd_width_menu/4*2,config.osd_top_menu+config.osd_height_menu-20)
    ass_color(ass,yellow)
    ass_alpha(ass,yellowa)
    ass:draw_start()
    ass:rect_ccw(0,0,config.osd_width_menu/4,20)
    ass:draw_stop()
    ass:new_event()
    if options and options.yellow then
        ass:pos(config.osd_left_menu+config.osd_width_menu/4*2+2,config.osd_top_menu+config.osd_height_menu-20)
        ass_scale_font(ass,80)
        ass:append(options.yellow)
        ass:new_event()
    end

    ass:pos(config.osd_left_menu+config.osd_width_menu/4*3,config.osd_top_menu+config.osd_height_menu-20)
    ass_color(ass,blue)
    ass_alpha(ass,bluea)
    ass:draw_start()
    ass:rect_ccw(0,0,config.osd_width_menu/4,20)
    ass:draw_stop()
    ass:new_event()
    if options and options.blue then
        ass:pos(config.osd_left_menu+config.osd_width_menu/4*3+2,config.osd_top_menu+config.osd_height_menu-20)
        ass_scale_font(ass,80)
        ass:append(options.blue)
        ass:new_event()
    end

    return ass
end

function draw_scrollbar(ass,left,top,width,height,pos,max)
    local part=height/max
    local bheight=part
    if part<10 then bheight=10 end
    if pos<0 or max < 1 then return end
    part = (pos-1)*(height-bheight)/max
    ass:pos(left,top)
    ass_color(ass,config.osd_highlight_color)
    ass_alpha(ass,config.osd_highlight_alpha)
    ass:draw_start()
    ass:rect_ccw(0,part,width,part+bheight)
    ass:draw_stop()
    ass:new_event()
end

local item_w=config.osd_width_menu - 11
function show_menu(self)
    local ass = create_menu_base{name=self.header,
                                 red=self.red_name,green=self.green_name,
                                 yellow=self.yellow_name,blue=self.blue_name}
    if self.selected_item == nil then self.selected_item = 1 end
    if self.items == nil or #self.items == 0 then
        return ass
    end
    if self.start_pos == nil or self.start_pos < 1  then self.start_pos = 1 end
    if self.selected_item>self.start_pos+config.osd_menu_max_items then
        self.start_pos=self.selected_item - config.osd_menu_max_items
    end
    if self.selected_item<self.start_pos then
        self.start_pos=self.selected_item
    end
    local maxi = #self.items>self.start_pos+config.osd_menu_max_items 
                and self.start_pos+config.osd_menu_max_items or #self.items
    local draw_item=self.draw_item and self.draw_item or 
                        draw_column_item(nil,self.column_width)
    for i = self.start_pos,maxi do
        local v = self.items[i]
        local itop= config.osd_top_menu+1+(i-self.start_pos+1)*config.osd_menu_item_height
        if self.selected_item == i then
            ass:pos(config.osd_left_menu, itop)
            ass_color(ass,config.osd_highlight_color)
            ass_alpha(ass,config.osd_highlight_alpha)
            ass:draw_start()
            ass:rect_ccw(0,0,item_w,config.osd_menu_item_height)
            ass:draw_stop()
            ass:new_event()
        end
        if v.draw == nil then
            draw_item(v,ass,config.osd_left_menu+2,itop,item_w,config.osd_menu_item_height)
        else
            v:draw(ass,config.osd_left_menu+2,itop,item_w,config.osd_menu_item_height)
        end
        ass:new_event()
    end
    if #self.items>config.osd_menu_max_items then
        draw_scrollbar(ass,config.osd_left_menu+config.osd_width_menu-10,
                       config.osd_top_menu+21,9,config.osd_height_menu-42,
                       self.start_pos,#self.items-config.osd_menu_max_items)
    end

    return ass
end

function menu_handle_key(self,k)
    if k=="UP" then
        self.selected_item = self.selected_item - 1
    elseif k=="DOWN" then
        self.selected_item = self.selected_item + 1
    elseif k=="LEFT" then
        self.selected_item = self.selected_item - config.osd_menu_max_items
    elseif k=="RIGHT" then
        self.selected_item = self.selected_item + config.osd_menu_max_items
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

    if self.selected_item then
        if self.items ~= nil and self.selected_item > #self.items then 
            self.selected_item = #self.items
        end
        if self.selected_item < 1 then 
            self.selected_item = 1
        end
    end
    update_osd()
end

local margin=20
function split_text(max_len,text)
    local pos = 1
    return function()
        local npos = text:find("\n",pos)
        if npos == nil then npos=text:len()+1 end

        if npos-pos>max_len then
            -- find space to split the string
            npos=text:find("[ -.+]",pos+max_len-margin>0 and pos+max_len-margin or 0)
            if npos == nil then npos=text:len()+1 end
        end

        if pos>=text:len() then
            return nil
        end
        local ret = text:sub(pos,npos)
        pos = npos + 1
        return ret
    end
end

-- shows text in self.text
-- uses self.header, self.title, self.subtitle
function show_text(self)
    local ass = create_menu_base{name=self.header,
                                 red=self.red_name,green=self.green_name,
                                 yellow=self.yellow_name,blue=self.blue_name}
    local i = 0
    local t = config.osd_top_menu + 23
    local l = config.osd_left_menu + 2
    local max_rows=config.osd_max_rows
    local text = self.text and toArray(split_text(config.osd_width_menu/config.osd_font_pixel_per_char/0.8,self.text)) or {}


    if self.title then
        -- time, title
        ass:pos(l, t)
        ass_clip(ass,l,t,l+config.osd_width_menu-10,t+25)
        ass:append(tostring(self.title))
        ass:new_event()
        t = t + 25
        max_rows = max_rows - 2
    end
    -- subtitle
    if self.subtitle then
        ass:pos(l, t)
        ass_clip(ass,l,t,l+config.osd_width_menu-10,t+20)
        ass_scale_font(ass,80)
        ass:append(tostring(self.subtitle))
        ass:new_event()
        t = t + 20
        max_rows = max_rows - 2
    end
    if self.start_pos == nil then self.start_pos = 1 end
    if self.start_pos > #text-max_rows then self.start_pos = #text-max_rows end
    if self.start_pos < 1 then self.start_pos = 1 end
    local sp=self.start_pos
    if self.text then
        for j=0,max_rows  do
            local v = text[j+sp]
            if v then
                ass:pos(l, t + j*13)
                ass_scale_font(ass,70)
                ass:append(v)
                ass:new_event()
            end
        end
    end
    if #text > max_rows+1 then
        draw_scrollbar(ass,config.osd_left_menu+config.osd_width_menu-10,
                       config.osd_top_menu+21,9,config.osd_height_menu-42,
                       self.start_pos,#text-max_rows-1)
    end

    return ass
end

function key(k)
    return function()
        local cstate=curr_state()
        mp.log("info","state name "..cstate.name)
        mp.log("info","key "..k)
        if cstate.confirm ~= nil then
            local action=cstate.confirm_action
            cstate.confirm=nil
            cstate.confirm_action=nil
            if k=="ENTER" and action ~= nil then
                action(cstate)
            end
            update_osd()
            return
        end
        if cstate and cstate.handle_key then
            cstate:handle_key(k)
        end
    end
end

local function send_webrequest(path)
    ret = utils.subprocess({
        args= {'bash', '-c', '( printf "GET /'..path
               ..' HTTP/1.0\n\n"; sleep 1)|nc '..config.host..' '
               ..config.streamdev_port},
--        args= {'/bin/bash', '-c', 'echo "'..command
--               ..'" >/dev/tcp/'..config.host..'/'..config.svdrp_port},
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

local function get_info_svdrp(self)
    mp.log("info","get_info_svdrp "..tostring(self.name))
    local info=parse_lste(send_svdrp(string.format("LSTR %d",self.idx)))
    for i,v in pairs(info) do
        mp.log("info",tostring(i)..":"..tostring(v))
        for j,event in pairs(v) do
            mp.log("info",tostring(j)..":"..tostring(event))
            return event.description,format_epg(event),event.subtitle
        end
    end
end

local function parse_lstr(stdout)
    mp.log("info","Parsing lstr")
    local ret={}
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code = i:sub(1,3)
        if code == "250" then
            local c = i:sub(5,5)
            local line = i:sub(5)
            local idx,date,time,length,new,name = line:match("(%d+) (%d%d.%d%d.%d%d) (%d%d:%d%d) (%d?%d:%d%d)(%*?) +(.*)")
            local title={
                idx=idx,
                day=date,
                time=time,
                length=length,
                new=new,
                name=name,
                url=string.format("http://%s:%d/%d.rec.ts",config.host,config.streamdev_port,idx),
                info=get_info_svdrp,
            }
            table.insert(ret,title)
        else
            mp.log("info","parse_lstr unknown "..i)
        end
    end
    return ret
end

local function collect_directories(recordings)
    mp.log("info","collect recordings")
    local ret={}
    local cache_tree={
        entries={},
        child={},
    }
    for i,v in pairs(recordings) do
        local spath=toArray(string.gmatch(v['name'],"[^~]+"))
        local j=1
        local dir=ret
        local cache=cache_tree
        while (j~=#spath) do
            local name=spath[j]
            if cache.child[name] == nil then
                cache.child[name] = {
                   entries={},
                   child={},
               }
               cache.entries[name]={
                    name=name,
                    title=name,
                }
                table.insert(dir,cache.entries[name])
            end
            dir=cache.entries[name]
            cache=cache.child[name]
            j = j + 1
        end
        v.title=spath[#spath]
        table.insert(dir,v)
    end
    return ret
end

function send_svdrp(command)
    ret = utils.subprocess({
        args= {'bash', '-c', '(printf "'..command
               ..'\n" ; sleep 0.1)|nc '..config.host..' '..config.svdrp_port},
--        args= {'/bin/bash', '-c', 'echo "'..command
--               ..'" >/dev/tcp/'..config.host..'/'..config.svdrp_port},
        cancellable=false,
    })
    if ret.error=="init" then
        mp.log("warn","Could not contact VDR server. Do you have 'bash' and 'nc' (netcat) installed?")
    end
    if ret.status ~= 0 then
        mp.log("warn","Could not contact VDR server. Is the SVDRP port "..config.svdrp_port.." correct, is it open and the client's IP in svdrphosts.conf?")
    end
    return ret.stdout
end

function check_for_errors(stdout)
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code = i:sub(1,3)
        if code:sub(1,1) == "5" then
            return i:sub(5)
        end
    end
end

local function parse_lstc(stdout)
    mp.log("info","Getting channel list")
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code = i:sub(1,3)
        if (code ~= "250") then
            mp.log("info","Unknown code '"..i.."'")
        else
            local channel_end=i:find(";")
            if (channel_end ~=nil) then
                local channel=i:sub(5,channel_end-1)
                local sp=channel:find(" ")
                if (sp ~= nil) then
                    local c =tonumber(channel:sub(0,sp-1))
                    local cinfo={}
                    cinfo['no']=c
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
                    chno_to_idx[cinfo.no]=#channels
                    if cinfo.id then
                        chid_to_idx[cinfo.id]=#channels
                    else
                        mp.log("info","no channel id "..channel)
                    end
                end
            end
        end
    end
end

local function get_channels()
    parse_lstc(send_svdrp('LSTC'))
    if #channels==0 then
        mp.log("warn","Could not load channel list, only basic functionality will be available.")
        
    else
        has_svdrp=1
    end
end

local function parse_plug(stdout)
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code = i:sub(1,3)
        if code == "214" then
            local line = i:sub(5)
            if line == "Available plugins:" then
            elseif line == "End of plugin list" then
            else
                local plugin=line:sub(1,line:find(" ")-1)
                mp.log("info","found plugin "..tostring(plugin))
                if plugin == "svdrposd" then
                    table.insert( main_menu_items,#main_menu_items+1,{
                        text="Server OSD",
                        action = function() 
                            new_state( create_remote_osd_menu_state() )
                        end,
                    })
                end
            end
        end
    end
end

function check_for_plugins()
    parse_plug(send_svdrp("PLUG"))
end

-- ************************* epg stuff  ***********************

local function parse_stat(line)
    disk_space_available,disk_space_free,disk_space_percent=line:match("(%d+)MB (%d+)MB (%d+)%%")
end

function update_state_disk_header(self)
    if disk_space_available ~= nil then
        local free_m=math.floor(disk_space_free/config.mb_per_minute)
        self.header=string.format("Disk %d%% Free %02d:%02dh",
            disk_space_percent, math.floor(free_m/60), free_m%60)
    end
end

local function parse_event(event,line)
    --mp.log("info","prase_event "..tostring(line))
    if event==nil then event={} end
    local code = line:sub(1,2)
    local value = line:sub(3)
    if code == "C " then
        event.cid=value:sub(1,value:find(" ")-1)
    elseif code == "E " then
        local p=toArray(value:gmatch("[^ ]+"))
        event['start'] = tonumber(p[2])
        event['duration'] = tonumber(p[3])
        event['stop'] = event.start + event.duration
        event.start_date_str=print_date(event.start)
        event.start_time_str=print_time(event.start)
        event.start_lts=lts(os.date("*t",event.start))
        event.stop_lts=lts(os.date("*t",event.stop))
        event.cid=cid
    elseif code == "T " then
        event['title']=value
    elseif code == "S " then
        event['subtitle']=value
    elseif code == "D " then
        event['description']=value
    else
        --mp.log("info","Unknwon code "..tostring(code))
    end
    return event
end

function parse_lste(stdout)
    local epginfo={}
    local cid 
    local this_event = {}
    local this_channel
    mp.log("info","Updating epg")
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code = i:sub(1,3)
        if code == "215" then
            local c = i:sub(5,5)
            local line = i:sub(5)
            if c == "C" then
                -- new channel
                this_event=parse_event({},line)
                this_channel = {}
                cid = this_event.cid
                epginfo[cid]=this_channel
            elseif c =="e" then
                -- end of event
                this_event = {}
            elseif c =="c" then
                -- end of channel
                if #this_channel==0 then epginfo[cid]=nil end
                --mp.log("info","insert "..tostring(cid).." "..#this_channel)
            else
                this_event = parse_event(this_event,line)
                if this_channel[#this_channel]~=this_event and 
                           this_event.start then
                    this_event.cid = cid
                    table.insert(this_channel,this_event)
                end
            end
        elseif code == "250" then
            -- the reply to the stat command we send with update epg command
            local line = i:sub(5)
            parse_stat(line)
        end
    end
    return epginfo
end

local function merge_epg_channel(dst,src)
    local di=1
    local si=1
    while dst[1]~=nil and dst[1].start+dst[1].duration
             +config.epg_old_events_linger_time<os.time() do
        --mp.log("info","removing old epg event "..tostring(dst[1].title))
        table.remove(dst,1)
    end
    while si<=#src do
        if dst[di]== nil or dst[di].start > src[si].start then
            table.insert(dst,di,src[si])
            di = di + 1
            si = si + 1
        elseif dst[di].start == src[si].start then
            -- skip it it's already in
            di = di + 1
            si = si + 1
        else
            -- next destination item
            di = di + 1
        end
    end
end

local function merge_epg(dst,src)
    for cid,epg in pairs(src) do
        if dst[cid] ~= nil then
            merge_epg_channel(dst[cid],epg)
        else
            dst[cid]=epg
        end
    end
end

function get_epgnow(cid)
    if epginfo[cid] == nil or epginfo[cid][1] == nil then
        return nil
    end
    local dst=epginfo[cid]
    while dst[1] and dst[1].start+dst[1].duration
             +config.epg_old_events_linger_time<os.time() do
        --mp.log("info","removing old epg event "..tostring(dst[1].title))
        table.remove(dst,1)
    end
    return dst[1]
end

function get_epgnext(cid)
    return epginfo[cid] and (epginfo[cid][2] and epginfo[cid][2] or nil) or nil
end

local function load_epg_now()
    merge_epg(epginfo,parse_lste(send_svdrp("LSTE now")))
end

local function load_epg_next()
    merge_epg(epginfo,parse_lste(send_svdrp("LSTE next\n STAT disk")))
end

local function load_epg_channel(cid)
    mp.log("info","load_epg_channel "..tostring(cid))
    if epginfo_time[cid] == nil or
           epginfo_time[cid]+config.epg_channel_update_time < os.time() then
        merge_epg(epginfo, parse_lste(send_svdrp("LSTE "..cid)))
        epginfo_time[cid]=os.time()
    end
    match_timer_to_event(timerinfo[cid],epginfo[cid])
end

-- ************************* timer stuff  ***********************

local function parse_lstt(stdout)
    local timerinfo={}
    mp.log("info","Updating timers")
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code = i:sub(1,3)
        if (code == "250") then
            local timer={}
            local setting_pos=i:find(" ",5)
            timer.id=tonumber(i:sub(5,setting_pos-1))
            local t=toArray(i:sub(setting_pos+1):gmatch("[^:]+"))
            timer.enabled=tonumber(t[1])
            if timer.enabled==1 then
                timer.enabled_str=">"
            elseif timer.enabled==9 then
                timer.enabled_str="#"
            else
                timer.enabled_str=""
            end
            timer.cidx=tonumber(t[2])
            timer.cid=channels[timer.cidx].id
            timer.day=t[3]
            timer.day_str=timer.day:sub(9,10).."."..timer.day:sub(6,7)
            timer.start=t[4]
            timer.start_str=vdrtime2str(timer.start)
            timer.start_lts=to_lts(timer.day,timer.start)
            timer.stop=t[5]
            timer.stop_str=vdrtime2str(timer.stop)
            timer.stop_lts=to_lts(timer.day,timer.stop)
            if timer.stop_lts<timer.start_lts then 
                timer.stop_lts=timer.stop_lts+24*60
            end
            timer.priority=t[6]
            timer.lifetime=t[7]
            timer.name=t[8]
            timer.aux= t[9]~=nil and t[9] or ""
            table.insert(timerinfo,timer)
        end
    end
    return timerinfo
end

local function timer_from_event(event)
    local timer={}
    timer.id=nil
    timer.enabled=1
    timer.cidx=channel_id_to_idx(event.cid)
    timer.day=os.date("%Y-%m-%d",event.start-config.timer_margin_start*60)
    timer.start=os.date("%H%M",event.start-config.timer_margin_start*60)
    timer.stop=os.date("%H%M",event.start+event.duration+config.timer_margin_stop*60)
    timer.priority=config.timer_default_priority
    timer.lifetime=config.timer_default_lifetime
    if event.title ~= nil and string.len(event.title)>1 then
        timer.name=event.title
    else
        timer.name=os.date("Rec %Y-%M-%d %H:%m",event.start)
    end
    timer.aux=""
    return timer
end

local function toggle_timer_onoff(timer)
    if timer.enabled==0 then
        timer.enabled=1
    else
        timer.enabled=0
    end
end

local function send_update_timer(timer)
    local timer_str=""
    timer_str = timer_str..timer.enabled..":"
    timer_str = timer_str..timer.cidx..":"
    timer_str = timer_str..timer.day..":"
    timer_str = timer_str..timer.start..":"
    timer_str = timer_str..timer.stop..":"
    timer_str = timer_str..timer.priority..":"
    timer_str = timer_str..timer.lifetime..":"
    timer_str = timer_str..timer.name..":"
    timer_str = timer_str..timer.aux
    mp.log("info","send_update_timer: "..tostring(timer_str))
    local result
    if timer.id == nil then
        result =send_svdrp("UPDT "..timer_str)
    else
        timer_str= tostring(timer.id).." "..timer_str
        result =send_svdrp("MODT "..timer_str)
    end
    mp.log("info","send_update_timer: "..tostring(result))

    return check_for_errors(result)
end

local function send_delete_timer(timer)
    mp.log("info","send_delete_timer "..tostring(timer.id).." "..tostring(timer.name) )
    local result=send_svdrp("DELT "..tostring(timer.id))
    return check_for_errors(result)
end

function load_timers()
    local timers=parse_lstt(send_svdrp("LSTT "))
    timerinfo={}
    for i,t in pairs(timers) do
        if timerinfo[t.cid] == nil then
            timerinfo[t.cid] = {}
        end
        table.insert(timerinfo[t.cid],t)
    end
    for i,t in pairs(timerinfo) do
        table.sort(t,function(a,b) return a.start_lts<b.start_lts end )
    end
    table.sort(timers,function(a,b) return a.start_lts<b.start_lts end)
    return timers
end

function match_timer_to_event(timers,events, max_events)
    local ei=1
    if events == nil then events={} end 
    if max_events == nil then max_events=#events end
    if max_events > #events then max_events=#events end
    --mp.log("info","match_timer_to_event max_events "..max_events)
    while ei<=max_events do
        local ti=1
        local event=events[ei]

        event.timer_status=" "
        event.timer=nil
        --mp.log("info","event "..date_format_epg(event))
        --mp.log("info","event "..event.start_lts.." "..event.stop_lts)
        while timers and ti<=#timers and timers[ti].start_lts < event.stop_lts do
                --mp.log("info","timer s tls "..timers[ti].start_lts.." stop: "..timers[ti].stop_lts.." "..timers[ti].day.." "..timers[ti].start.." "..timers[ti].stop..tostring(timers[ti].name))
            if timers[ti].enabled == 0 then
                -- ignore disabled timers
            elseif timers[ti].stop_lts < event.start_lts then
                -- do nothing, timer stops before this event starts
                --mp.log("info","stops early "..timers[ti].stop_lts.." "..timers[ti].day.." "..timers[ti].start.." "..timers[ti].stop..tostring(timers[ti].name))
            elseif timers[ti].start_lts < event.start_lts then
                if timers[ti].stop_lts > event.stop_lts then
                    event.timer_status="T"
                    event.timer=timers[ti]
                    timers[ti].event=event
                    mp.log("info","found match "..tostring(event.title))
                else
                    -- partial recording, missing end
                    if event.timer_status == " " then
                        event.timer_status="t"
                        mp.log("info","found p match missing end "..tostring(event.title))
                        --mp.log("info","timer stop "..timers[ti].stop_lts.." "..timers[ti].day.." "..timers[ti].start.." "..timers[ti].stop..tostring(timers[ti].name))
                        --mp.log("info","event "..date_format_epg(event))
                        --mp.log("info","event "..event.start_lts.." "..event.stop_lts)
                    end
                end
            else
                if event.timer_status == " " then
                    -- partial recording, missing start
                    event.timer_status="t"
                    mp.log("info","found p match missing start "..tostring(event.title))
                    --mp.log("info","timer stop "..timers[ti].stop_lts.." "..timers[ti].day.." "..timers[ti].start.." "..timers[ti].stop..tostring(timers[ti].name))
                    --mp.log("info","event "..date_format_epg(event))
                    --mp.log("info","event "..event.start_lts.." "..event.stop_lts)
                end
            end
            ti = ti + 1
        end
        ei = ei +1
    end
end

local function match_nownext_timer_to_event()
    local cid,events 
    for cid,events in pairs(epginfo) do
        match_timer_to_event(timerinfo[cid],events,3)
    end
end

-- ************************* remote osd  ***********************

local function parse_svdrposd_lsto(stdout)
    local osdinfo={
        open=false,
        items={},
    }
    mp.log("info","Updating remote osd")
    for i in string.gmatch(stdout,"[^\r\n]+") do
        local code=i:sub(1,3)
        if code == "920" then
            osdinfo.open=true
            local t=i:sub(5,5)
            if t=="T" then
                osdinfo.title=i:sub(7)
            elseif t=="S" then
                table.insert(osdinfo.items, {text=i:sub(7)})
                osdinfo.selected=#osdinfo.items
            elseif t=="I" then
                table.insert(osdinfo.items, {text=i:sub(7)})
            elseif t=="X" then
                osdinfo.text=i:sub(7)
            elseif t=="R" then
                osdinfo.red=i:sub(7)
            elseif t=="G" then
                osdinfo.green=i:sub(7)
            elseif t=="Y" then
                osdinfo.yellow=i:sub(7)
            elseif t=="B" then
                osdinfo.blue=i:sub(7)
            else
                mp.log("info","unknown osd code "..tostring(i))
            end
        elseif code == "930" then
            osdinfo.open=false
        else
            mp.log("info","unknown osd code "..tostring(i))
        end
    end
    return osdinfo
end

local function switch_channel(no) 
    mp.log("info","switch_channel "..no)
    if tonumber(no) == nil then
        no = channel_id_to_idx(no)
    end
    local sav_channel=channel_idx
    if update_last_channel_timeout ~= nil then 
        update_last_channel_timeout:kill() 
    end
    update_last_channel_timeout=mp.add_timeout(config.previous_channel_time,
        function()
            mp.log("info","Updating last channel to "..tostring(sav_channel))
            mp.log("info","last_channel :"..tostring(last_channel).." next_lc "..tostring(next_last_channel))
	    last_channel=next_last_channel
	    next_last_channel=sav_channel
            mp.log("info","last_channel :"..tostring(last_channel).." next_lc "..tostring(next_last_channel))
       end)
    channel_idx=no
    mp.set_property("demuxer-lavf-format","mpegts")
    mp.set_property("keep-open","yes")
    local cinfo = channels[channel_idx]
    if cinfo then
        mp.commandv("loadfile",vdruri .. cinfo.id)
    else
        mp.commandv("loadfile",vdruri .. channel_idx)
    end
    if cinfo and cinfo.name then
        mp.set_property("force-media-title",cinfo.name)
    end
    mp.log("info","speed "..tostring(mp.get_property("speed")))
    mp.set_property("speed",0.9)
    if speed_timer~=nil then
	    speed_timer:kill()
    end
    speed_timer=mp.add_timeout(20,function()
	    mp.log("info","resetting speed "..tostring(mp.get_property("speed")))
            mp.set_property("speed",1)
	    mp.log("info","resetting speed "..tostring(mp.get_property("speed")))
    end)

    local state=curr_state()
    if state.name =="livetv" then
        state.update_osd = show_channel_info
        state.hide_osd_timeout=config.show_info_timeout
        update_hide_osd_timeout()
    end
    next_channel=0
    update_osd()
end

local function playback_recording(rinfo) 
    local url = rinfo['url']
    mp.log("info","play_rec "..tostring(url))
    mp.commandv("playlist-clear")
    --mp.commandv("playlist-remove","current")
    if type(url)=="table" then
        mp.log("info","loadfile "..tostring(url[1]))
        mp.commandv("loadfile",url[1])
        for i=2,#url do
            mp.log("info","loadfile "..tostring(url[i]))
            mp.commandv("loadfile",url[i],"append")
        end
    else
        mp.commandv("loadfile",url)
    end
    if rinfo and rinfo.title then
        mp.set_property("force-media-title",rinfo.title)
    end
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
    if (channel_idx < 1) then
        channel_idx =#channels > 0 and #channels or 1
    end
    switch_channel(channel_idx);
end

local channel_timer=mp.add_periodic_timer(config.channel_switch_timeout,
                                          function() 
    if ( next_channel ~= 0 ) then
        local ncid=chno_to_idx[next_channel]
        if ncid then
            switch_channel(ncid)
        else
            switch_channel(next_channel)
        end
        next_channel = 0
    end
    if ( channel_timer ~= nil ) then
        channel_timer:kill()
    end
end)

local function livetv_handle_key(self,key)
    mp.log("info","state name "..self.name)
    if key=="ENTER" then
        if next_channel ~= 0 then
            switch_channel(next_channel)
            next_channel = 0
        elseif self.update_osd == nil then
            self.update_osd = show_channel_info
            self.hide_osd_timeout = config.show_info_timeout
            update_hide_osd_timeout()
            update_osd()
        else
            self.update_osd = nil
            update_osd()
        end
    elseif key=="BS" then
        if self.name=="channel_info" then
            state_back()
        end
    elseif key=="m" then
        if has_svdrp==1 then
            -- no menu without svdrp connection
            state_main_menu.selected_item=1
            new_state(state_main_menu)
        end
    elseif key=="UP" then
        channel_next()
    elseif key=="DOWN" then
        channel_prev()
    elseif type(key) =="number" then
        if  key == 0 and next_channel == 0 then
            -- immediatly update last_channel
            mp.log("info","last_channel :"..tostring(last_channel).." next_lc "..tostring(next_last_channel))
            switch_channel(last_channel);
            local sav_channel=last_channel
            last_channel=next_last_channel
	    next_last_channel=sav_channel
            mp.log("info","last_channel :"..tostring(last_channel).." next_lc "..tostring(next_last_channel))
            return
        end
        next_channel=next_channel*10+key
        self.update_osd=show_channel_info
        update_osd()
        channel_timer:resume()
    end
end

local function on_start()
    local url = mp.get_property("stream-open-filename")

    if (url:find("vdrstream://") == 1) then
        if ( startup == 1) then
            do_startup(url)
            startup = 0
        end
        -- mp.set_property("stream-open-filename",channels[channel_idx])
        --mp.set_property("cache-size",1024)
        switch_channel(config.startup_channel)
        --rinfo= {
            --url="blah",
            --name="Diese Datei",
        --}
        --new_state(create_playback_state(rinfo))
    end
    mp.log("info","Lua version " .. _VERSION)
end

function new_show_epgs_state(epg_info,channel_info)
    epg_info = epg_info and epg_info or {description="No data"}
    channel_info = channel_info and channel_info or {}
    local state_show_epg = {
        name = "menu_epg",
        handle_key = function(self,k)
            if k=="ENTER" or k=="BS" then
                state_back()
            elseif k=="DOWN" then
                self.start_pos=self.start_pos+1
                update_osd()
            elseif k=="UP" then
                self.start_pos=self.start_pos-1
                update_osd()
            elseif k=="RED" and self.red_action then
                self:red_action()
            elseif k=="GREEN" and self.green_action then
                self:green_action()
            elseif k=="YELLOW" and self.yellow_action then
                self:yellow_action()
            elseif k=="BLUE" and self.blue_action then
                self:blue_action()
            elseif k=="m" then
                state_remove_including("main_menu")
            elseif k=="BLUE" then
                state_back_to("livetv")
                switch_channel(self.cinfo['idx'])
            end
        end,

        update_osd = show_text,
        text = epg_info.description and epg_info.description:gsub('|','\n') or nil,
        title = format_epg(epg_info),
        subtitle = epg_info['subtitle'],
        cinfo = channel_info,
        red_name = 'Record',
    }
    state_show_epg.red_action = function()
            action_record(state_show_epg,epg_info)
        end
    return state_show_epg
end

-- returns self[part1][part2]..[partn] for col_name 'part1.part2...partn'
function get_col(self,col_name)
    local p = col_name:find("%.")
    if p then
        return get_col(self[col_name:sub(1,p-1)],col_name:sub(p+1))
    end
    return self[col_name]
end

-- Returns a function to draw menu items
--
-- col_names should contain an array of names for get_col(), a function(self) returning
-- the text to show in to column, or be nil.
-- if col_names is nil self.text is split at tabulators (\t) and shown in columns
--
-- col_width should contain the width of the columns. If it is empty or missing values
-- the remaining space is equally divided between the remaining columns
function draw_column_item(col_names,col_width)
    return function(self,ass,left,top,width,height)
        local i
        local l=left
        local n=l
        local cols=col_names
        if cols == nil then
            cols = toArray(self.text:gmatch("[^\t]+"))
        end

        for i=1,#cols do
            local text
            if col_names == nil then
                text=cols[i]
            elseif type(col_names[i]) == "function" then
                text = col_names[i](self)
            else
                text=get_col(self,col_names[i])
            end
            if col_width and col_width[i] then
                n=l+col_width[i]
            else
                n=l+(left+width-l)/(#cols-i+1)
            end
            if text ~= nil then
                ass:pos(l,top)
                ass_clip(ass,l,top,n-2,top+height)
                ass_scale_font(ass,80)
                ass:append(tostring(text))
                ass:new_event()
            end
            l=n
        end
    end
end

function draw_tabbed_column_item(self,ass,left,top,width,height)
    mp.log("info","draw_tabbed_column_item")
    local cols = toArray(self.text:gmatch("[^\t]+"))
    local pos = 0
    local l = left
    local n
    local tabsize = 4
    for i=1,#cols do
        local text=cols[i]
        if text ~= nil then
            pos = (math.floor((pos + text:len())/tabsize)+1)*tabsize
            n = left + math.floor(pos*config.osd_font_pixel_per_char*0.8)
            ass:pos(l,top)
            ass_clip(ass,l,top,
                         (n>left+width and left+width or n)-2,top+height)
            ass_scale_font(ass,80)
            ass:append(tostring(text))
            ass:new_event()
        end
        l=n
    end
end

function action_record(nstate,event)
    local timer=event.timer
    local cid=event.cid
    if timer ~= nil then
        -- edit timer
        new_state(create_edit_timer_menu_state(timer))
    else
        -- new timer
        nstate.message="Creating timer..."
        update_osd()
        timer=timer_from_event(event)
        local ret = send_update_timer(timer)
        if ret then
            nstate.confirm="Error: "..tostring(ret)
            nstate.confirm_action=function() end
            nstate.message=nil
            update_osd()
        else
            nstate.message="Updating..."
            update_osd()
            mp.add_timeout(0.1,function()
                load_timers()
                match_timer_to_event(timerinfo[cid],epginfo[cid])
                nstate.message=nil
                update_osd()
            end)
        end
    end
end

function create_epg_channel_schedule_menu_state(channel_idx)
    local c=channels[channel_idx]
    local cid=c.id
    local items={}
    local nstate= new_menu_state("menu_schedule",items)
    local draw_item = draw_column_item(
         {'einfo.start_date_str','einfo.start_time_str','einfo.timer_status','einfo.title'},
         {85,50,15})

    local function update_items()
        local schedule=epginfo[cid]
        while #items>0 do
            table.remove(items)
        end
        if schedule ~= nil then
            for i,v in pairs(schedule) do
                table.insert(items,{
                    text=date_format_epg(v),
                    action = function()
                        new_state(new_show_epgs_state(v,c))
                    end,
                    draw = draw_item,
                    einfo = v,
                    cinfo = c,
                })
            end
        end
    end
    update_items()

    mp.add_timeout(0.1,function()
        load_epg_channel(cid)
        update_items()
        nstate.message=nil
        update_osd()
    end)
    nstate.header="Schedule "..c.name
    nstate.message="Loading..."
    nstate.red_name="Record"
    nstate.red_action=function(self)
        local event = self.items[self.selected_item].einfo
        action_record(nstate, event)
    end
    nstate.green_name="Now"
    nstate.green_action=function(self)
        state_back()
        new_state(create_epg_now_next_menu_state("epg_now", get_epgnow, channel_idx))
    end
    nstate.yellow_name="Next"
    nstate.yellow_action=function(self)
        state_back()
        new_state(create_epg_now_next_menu_state("epg_next", get_epgnext, channel_idx))
    end
    nstate.blue_name="Switch"
    nstate.blue_action=function(self)
        state_back_to("livetv")
        switch_channel(items[self.selected_item].cinfo.idx)
    end
    return nstate
end

function create_epg_now_next_menu_state(name,get_epg_fct, sel_cidx)
    local items={}
    local nstate= new_menu_state(name,items)
    if sel_cidx == nil then sel_cidx = channel_idx end
    local draw_item=draw_column_item(
        {'cinfo.name',function(self) return print_time(self.einfo.start) end,'einfo.title'},
        {100,55}
        )
    for i=1,#channels do
        local c = channels[i]
        if c['id'] and c['name'] then
            local e = get_epg_fct(c['id'])
            if e then
                table.insert(items,{
                    text=c['name']..format_epg(e),
                    action = function()
                        new_state(new_show_epgs_state(e,c))
                    end,
                    draw = draw_item,
                    einfo = e,
                    cinfo = c,
                })
                if sel_cidx == c.idx then
                    nstate.selected_item=#items
                end
            end
        end
    end
    nstate.blue_name="Switch"
    nstate.blue_action=function(self)
        state_back_to("livetv")
        switch_channel(items[self.selected_item].cinfo.idx)
    end
    nstate.yellow_name="Schedule"
    nstate.yellow_action=function(self)
        state_back()
        new_state(create_epg_channel_schedule_menu_state(
            items[self.selected_item].cinfo.idx))
    end
    if name=="epg_now" then
        nstate.green_name="Next"
        nstate.green_action=function(self)
            state_back()
            new_state(create_epg_now_next_menu_state("epg_next", get_epgnext,
              items[self.selected_item].cinfo.idx))
        end
    else
        nstate.green_name="Now"
        nstate.green_action=function(self)
            state_back()
            new_state(create_epg_now_next_menu_state("epg_now", get_epgnow,
              items[self.selected_item].cinfo.idx))
        end
    end
    return nstate
end

local function playback_handle_key(self,key)
    mp.log("info","state name "..self.name)
    local temporarily_show_info = function()
        mp.log("info","temp_show_info "..tostring(self.hide_osd_timeout))
        if self.hide_osd_timeout~=nil or self.update_osd==nil then
            self.hide_osd_timeout = config.show_info_timeout
            self.update_osd = show_playback_info
            update_hide_osd_timeout()
            update_osd()
        end
    end
    if key=="BLUE" then
        state_back_to("livetv")
        switch_channel(channel_idx)
    elseif key=="BS" then
        state_back()
        switch_channel(channel_idx)
    elseif key=="DOWN" or key=="UP" then
        mp.command("cycle pause")
        temporarily_show_info()
    elseif key=="YELLOW" then
        mp.command("no-osd seek +30")
        temporarily_show_info()
    elseif key=="m" then
        state_main_menu.selected_item=1
        new_state(state_main_menu)
    elseif key=="GREEN" then
        mp.command("no-osd seek -30")
        temporarily_show_info()
    elseif key=="ENTER" then
        if self.update_osd==nil then
            self.update_osd=show_playback_info
            self.hide_osd_timeout=nil
        else
            self.update_osd=nil
        end
        update_osd()
    end
end

function create_playback_state(rinfo)
   local state_playback = {
       name = "playback",
       handle_key = playback_handle_key,
       update_osd = nil,
       rinfo = rinfo,
       update_osd_timeout=1,
       hide_osd_timeout = config.show_info_timeout,
       update_osd = show_playback_info,
   }
   return state_playback
end

function read_info_file(self)
    local file = io.open(self.info_file,"r")
    if file then
        local lines=file:read("*a")
        local event={}
        for v in lines:gmatch("[^\r\n]+") do
            event = parse_event(event,v)
        end
        return event.description,format_epg(event),event.subtitle
    else
        mp.log("info","info file not found")
    end
end

function check_for_vdr_recording(dir,name)
    local rinfos={}
    local dirname=utils.join_path(dir,name)
    local dirs = utils.readdir(dirname,"dirs")
    if dirs == nil then dirs={} end
    for i,v in pairs(dirs) do
        if ends_with(v,".rec") then
            local rdir=utils.join_path(dirname,v)
            local files = utils.readdir(rdir,"files")
            local rinfo={url={},name=name}
            if files == nil then files={} end
            for j,w in pairs(files) do
                if ends_with(w,".ts") then
                    table.insert(rinfo.url,utils.join_path(rdir,w))
                elseif w:sub(1,1)=="0" and ends_with(w,".vdr") then
                    -- old recoding
                    table.insert(rinfo.url,utils.join_path(rdir,w))
                elseif w=="info" or w=="info.vdr" then
                    rinfo.info_file=utils.join_path(rdir,w)
                    rinfo.info=read_info_file
                end
            end
            if #rinfo.url>0 then
                table.sort(rinfo.url)
                table.insert(rinfos,rinfo)
            end
        end
    end
    return rinfos
end

local function show_info_action(self)
    local item=self.items[self.selected_item]
    local state={
        name="Media Info",
        update_osd=show_text,
        text="No info",
        message="Loading...",
        handle_key=function()
            state_back()
        end,
    }
    mp.add_timeout(0.1,function()
        if item==nil or item.rinfo==nil then
            -- error?
        elseif item.rinfo.info then
            state.text,state.title,state.subtitle = item.rinfo:info()
        elseif item.rinfo.url then
            local file =io.open(item.rinfo.url:sub(1,-1-item.rinfo.ext:len())..".txt","r")
            if file then
                state.text=file:read("*a")
            else
                mp.log("info","No filename.txt file found")
            end
        end
        state.message=nil
        if state.text==nil then state.text="No Info" end
        update_osd()
    end)
    new_state(state)
end

function create_show_media_state(dirname)
    local update_items=function()
        local items={}
        local dirs = utils.readdir(dirname,"dirs")
        if dirs == nil then dirs={} end
        for i,v in pairs(dirs) do
            local vpath=utils.join_path(dirname,v)
            local rinfos = check_for_vdr_recording(dirname,v)
            if #rinfos>0 then
                for j,w in pairs(rinfos) do
                    table.insert(items, {
                        text=tostring(w.name),
                        rinfo=w,
                        action=function()
                            playback_recording(w)
                            new_state(create_playback_state(w))
                        end
                    })
                end
            else
                table.insert(items,{
                    text=tostring(v),
                    action=function()
                        new_state( create_show_media_state(vpath))
                    end,
                })
            end
        end
        local files=utils.readdir(dirname,"files")
        if files == nil then files={} end
        for i,v in pairs(files) do
            V=v:upper()
            for j,w in pairs(config.media_extensions) do
                if ends_with(V,w) then
                    local rinfo={
                        name=tostring(v),
                        url=utils.join_path(dirname,v),
                        ext=w,
                    }
                    table.insert(items,{
                        text=tostring(v),
                        rinfo=rinfo,
                        action=function()
                            playback_recording(rinfo)
                            new_state(create_playback_state(rinfo))
                        end,
                    })
                end
            end
        end
        return items
    end
    local state=new_menu_state("Media",update_items)
    state.blue_name="Info"
    state.blue_action=show_info_action
    return state
end

function create_recordings_show_items(recordings)
    items={}
    for i,r in pairs(recordings) do
        if r['name'] ~= nil then
            local text=r['title']
            if r['time'] then text = r['time'].." "..text end
            if r['day'] then text = r['day'].." "..text end
            table.insert(items,{
                text = text,
                action = function(self)
                    if #self.rinfo >0 then
                        new_state( new_menu_state("Recordings",
                           create_recordings_show_items(self.rinfo)
                           ))
                    else
                        playback_recording(self.rinfo)
                        new_state(create_playback_state(self.rinfo))
                    end
                end,
                rinfo = r,
            })
        end
    end
    return items
end

function create_timers_show_items(timers)
    items={}
    local draw_item=draw_column_item(
       {'tinfo.enabled_str','tinfo.cidx','tinfo.day_str','tinfo.start_str','tinfo.stop_str','tinfo.name'},
       {20,30,70,50,50})
    for i,r in pairs(timers) do
        table.insert(items,{
            tinfo = r,
            draw = draw_item,
            action = function(self)
                  new_state(create_edit_timer_menu_state(self.tinfo))
                end,
            })
    end
    return items
end

-- ************************* Remote OSD  ***********************

local vdr_keys= {
    UP="Up", DOWN="Down", LEFT="Left", RIGHT="Right",
    BS="Back", RED="Red", GREEN="Green", YELLOW="Yellow", BLUE="Blue",
    ENTER="Ok", m="MENU",
}

function update_remote_osd(self)
    self.osdinfo=parse_svdrposd_lsto(send_svdrp("PLUG svdrposd LSTO"))
    self.items=self.osdinfo.items
    self.draw_item=draw_tabbed_column_item
    if self.osdinfo.text then
        self.text=self.osdinfo.text:gsub("|","\n")
    else
        self.text=""
    end
    self.selected_item=self.osdinfo.selected
    self.red_name=self.osdinfo.red
    self.green_name=self.osdinfo.green
    self.yellow_name=self.osdinfo.yellow
    self.blue_name=self.osdinfo.blue
    self.header="Remote OSD: "..tostring(self.osdinfo.title)
    mp.log("info","remote osd red: ".. tostring(self.red_name))

    if self.items and #self.items>0 then
        self.update_osd=show_menu
    else
        self.update_osd=show_text
    end

    self.message=nil
    update_osd()
end

function remote_osd_handle_key(self,k)
    mp.log("info","remote osd key "..k)
    mp.log("info","osdinfo "..tostring(self.osdinfo.open))
    if k=="BS" and self.osdinfo.open==false then
        state_back()
    elseif vdr_keys[k] ~= nil then
        mp.log("info","sending key")
        self.message="Updating..."
        update_osd()
        send_svdrp("HITK "..vdr_keys[k])
        update_remote_osd(self)
    end
end

function create_remote_osd_menu_state()
    local state_menu = {
        name = "remote_osd",
        handle_key = remote_osd_handle_key,
        update_osd = show_menu,
        items = {},
        osdinfo = {
            open = false,
        },
        message = "Loading..",
    }
    mp.add_timeout(0.1,function()
        update_remote_osd(state_menu)
    end)
    return state_menu
end

-- ************************* Menu Stuff  ***********************

function new_menu_state(name,items)
    local state_menu = {
        name = name,
        handle_key = menu_handle_key,
        update_osd = show_menu,
    }
    if type(items) == "function" then
        state_menu.message="Loading..."
        mp.add_timeout(0.1, function()
            state_menu.items=items()
            state_menu.message=nil
            update_osd()
        end)
    else
        state_menu.items=items
    end
    return state_menu
end

function create_edit_timer_menu_state(timer)
    local update_items=function()
        local items={
            { text="Active\t:  "..(timer.enabled==0 and "no" or "yes"), },
            { text="Channel\t:  "..tostring(timer.cidx).." "..tostring(channels[timer.cidx].name),},
            { text="Day\t:  "..timer.day},
            { text="Start\t:  "..timer.start:sub(1,2)..":"..timer.start:sub(3,4),},
            { text="Stop\t:  "..timer.stop:sub(1,2)..":"..timer.stop:sub(3,4),},
            { text="Priority\t:  "..timer.priority,},
            { text="Lifetime\t:  "..timer.lifetime,},
            { text="File\t:   "..timer.name,},
        }
        return items
    end

    local timer_menu_state=new_menu_state("Show Timer", update_items)
    timer_menu_state.column_width={80}
    timer_menu_state.red_name="On/Off"
    timer_menu_state.red_action=function(self)
        timer_menu_state.message="Updating timer..."
        update_osd()
        toggle_timer_onoff(timer)
        send_update_timer(timer)
        load_timers()
        match_timer_to_event(timerinfo[cid],epginfo[cid])
        self.items=update_items()
        timer_menu_state.message=nil
        update_osd()
    end
    return timer_menu_state
end

function confirm_action(msg,action) 
    return function(self)
        self.confirm=msg
        self.confirm_action=action
        update_osd()
    end
end

function create_timer_menu_state()
    local update_items= function()
           local timers=load_timers();
           return create_timers_show_items(timers)
       end
    local timer_menu_state=new_menu_state("Timers", update_items)

    timer_menu_state.red_name="On/Off"
    timer_menu_state.red_action=function(self)
        timer_menu_state.message="Updating timer..."
        update_osd()
        local timer=self.items[self.selected_item].tinfo
        toggle_timer_onoff(timer)
        local ret = send_update_timer(timer)
        if ret then
            timer_menu_state.confrim="Error: "..tostring(ret)
            timer_menu_state.confirm_action=function() end
        end
        self.items=update_items()
        timer_menu_state.message=nil
        update_osd()
    end
    timer_menu_state.yellow_name="Delete"
    timer_menu_state.yellow_action=confirm_action("Are you sure? Press OK to delete",function(self)
        timer_menu_state.message="Deleting timer..."
        update_osd()
        local ret=send_delete_timer(self.items[self.selected_item].tinfo)
        if ret then
            timer_menu_state.confrim="Error: "..tostring(ret)
            timer_menu_state.confirm_action=function() end
        end
        self.items=update_items()
        timer_menu_state.message=nil
        update_osd()
    end)
    timer_menu_state.blue_name="Info"
    timer_menu_state.blue_action=function(self)
        timer_menu_state.message="Loading..."
        update_osd()
        local timer=self.items[self.selected_item].tinfo
        load_epg_channel(timer.cid)
        mp.log("info","show info: "..tostring(timer.event).." "..tostring(channels[timer.cidx]))
        local state=new_show_epgs_state(timer.event,
                           channels[timer.cidx])
        timer_menu_state.message=nil
        new_state(state)
    end
    return timer_menu_state
end

function init_main_menu()
    main_menu_items=
    {
        { 
            text="Schedule",
            action = function() 
                local nstate=create_epg_channel_schedule_menu_state(channel_idx)
                new_state(nstate)
            end,
        },
        {
            text="Timers",
            action = function() 
                new_state(create_timer_menu_state())
            end,
        },
    }
    if config.vdr_video_dir:len()==0 then
        -- use streamdev for recordings
        table.insert( main_menu_items, #main_menu_items+1, {
            text="Recordings",
            action = function() 
                    local update_items=function(self)
                        --local recordings=parse_lstr(send_svdrp("lstr"))
                        local recordings=parse_ext3mu(send_webrequest("/recordings.m3u"))
                        recordings = collect_directories(recordings)
                        return create_recordings_show_items(recordings)
                    end
                    local state=new_menu_state("Recordings", update_items)
--                    state.blue_name="Info"
--                    state.blue_action=show_info_action
--                    state.yellow_name="Remove"
--                    state.yellow_action=confirm_action("Are you sure? Press OK to remove",
--                       function(self)
--                           local item=self.items[self.selected_item]
--                           self.message="Deleting recording..."
--                           update_osd()
--                           local error_msg=check_for_errors(send_svdrp(
--                                   string.format("DELR %d",item.rinfo.idx)))
--                           if error_msg then
--                               self.confirm="Error: "..error_msg
--                               self.confirm_action=function() end
--                           end
--                           self.items=update_items()
--                           self.message=nil
--                           self:update_state()
--                           update_osd()
--                       end)
                    state.update_state = update_state_disk_header
                    new_state(state)
                end,
        })
    else
        -- vdr video dir is locally mounted, read it directly
        table.insert( main_menu_items, #main_menu_items+1, {
            text="Recordings",
            action = function() 
                new_state( create_show_media_state(config.vdr_video_dir) )
            end
        })
    end

    if config.media_dir:len()>0 then
        table.insert( main_menu_items,#main_menu_items+1,{
            text="Media",
            action = function() 
                new_state( create_show_media_state(config.media_dir) )
            end,
        })
    end
    state_main_menu = new_menu_state("main_menu", main_menu_items)
    state_main_menu.update_state = update_state_disk_header

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
end

function do_startup(url)
    init_main_menu()

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
    mp.add_key_binding("UP",'vdrkeyUP',key("UP"),{repeatable=true})
    mp.add_key_binding("DOWN",'vdrkeyDOWN',key("DOWN"),{repeatable=true})
    mp.add_key_binding("LEFT",'vdrkeyLEFT',key("LEFT"),{repeatable=true})
    mp.add_key_binding("RIGHT",'vdrkeyRIGHT',key("RIGHT"),{repeatable=true})
    mp.add_key_binding("ENTER",'vdrkeyENTER',key("ENTER"))
    mp.add_key_binding("BS",'vdrkeyBS',key("BS"))
    mp.add_key_binding("m",'vdrkeym',key("m"))

    local host,port,channel=url:match("vdrstream://([^:/]*)(:?[%d]*)(/?.*)")
    if host and host:len()>0 then
        config.host=host
    end
    if port and port:len()>1 then
        config.streamdev_port=tonumber(port:sub(2))
    end
    if channel and channel:len()>1 then
        config.startup_channel=tonumber(channel:sub(2))
    end
    mp.log("info","VDR host:"..config.host)
    mp.log("info","VDR svdrp port:"..config.svdrp_port)
    mp.log("info","VDR streamdev port:"..config.streamdev_port)
    mp.log("info","startup channel:"..config.startup_channel)
    vdruri="http://"..config.host..":"..config.streamdev_port.."/TS/"

    -- set parameters to optimize channel switch time
    --mp.set_property("cache-secs",1)
    mp.set_property("demuxer-lavf-analyzeduration",1)
    mp.set_property("ytdl","no")
    mp.set_property("keep-open","yes")
    mp.set_property("idle","yes")
    mp.set_property("prefetch-playlist","yes")
    mp.set_property("force-window","yes")
    mp.log("info","demuxer "..tostring(mp.get_property("demuxer-lavf-format")))

    get_channels()
    -- load epg in background
    mp.add_timeout(1,function()
        load_timers()
        load_epg_now()
        load_epg_next()
        match_nownext_timer_to_event()
        mp.log("info","finished epg")
        update_osd()
        check_for_plugins()
    end)
    -- periodically update epg
    epg_timer = mp.add_periodic_timer(config.epg_nownext_update_time,function() 
        load_timers()
        -- only update "next" event, old "next" events become "now" events
        load_epg_next()
        match_nownext_timer_to_event()
    end)

    new_state( state_livetv )
end

mp.add_hook("on_load", 50, on_start)
