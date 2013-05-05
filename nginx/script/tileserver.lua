--
-- Lua script for providing osm tile server
--
--
-- Copyright (C) 2013, Hiroshi Miura
--
--    This program is free software: you can redistribute it and/or modify
--    it under the terms of the GNU Affero General Public License as published by
--    the Free Software Foundation, either version 3 of the License, or
--    any later version.
--
--    This program is distributed in the hope that it will be useful,
--    but WITHOUT ANY WARRANTY; without even the implied warranty of
--    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--    GNU Affero General Public License for more details.
--
--    You should have received a copy of the GNU Affero General Public License
--    along with this program.  If not, see <http://www.gnu.org/licenses/>.
--

-- required module
local bit = require 'bit'

-- constants
--
local metatile = 8

-- ------------------------------------
-- module(...) -- SyncThread
-- ------------------------------------
-- Syncronize thread functions
--
--   thread(1)
--       get_handle(key)
--       do work
--       store work result somewhere
--       send_signal(key)
--       return result
--
--   thread(2)
--       get_handle(key) fails then
--       wait_singal(key)
--       return result what thread(1) done
--
--   to syncronize amoung nginx threads
--   we use ngx.shared.DICT interface.
--   
--   Here we use ngx.shared.stats
--   you need to set /etc/conf.d/lua.conf
--      ngx_shared_dict stats 10m; 
--
--   if these functions returns 'nil'
--   status is undefined
--   something wrong
--
--   status definitions
--    key is not exist:    neutral
--    key is exist: someone got work token
--       val = 0:     now working
--       val > 0:     work is finished
--
--    key will be expired in timeout sec
--    we can use same key after timeout passed
--
-- ------------------------------------
local stats = ngx.shared.stats

--
--  if key exist, it returns false
--  else it returns true
--
function get_handle(key,timeout, flag)
    return stats:safe_add(key, 0, timeout, flag)
end

-- returns new value (maybe 1)
function send_signal(key)
    return stats:incr(key, 1)
end

-- return nil if timeout in wait
--
function wait_signal(key,timeout)
    local interval = 1
    local timeout = tonumber(timeout)
    for i=0, timeout do
        local val, id = stats:get(key)
        if val then
            if val > 0 then
                return id
            end
            ngx.sleep(interval)
        else
            return nil
        end
    end
    return nil
end

-- ---------------------------------------------------------------
-- Tirex Interface
-- module(...) -- tirex
--
-- ---------------------------------------------------------------
local tirexsock = 'unix:/var/run/tirex/master.sock'
local tirextile = "/var/lib/tirex/tiles/"
local tirex_sync_duration = 240 -- should be in sec
local tirex_cmd_max_size = 512
local tirex_resp_timeout = 30000

-- ========================================================
-- protocol definition
--
-- command
--   char[]
--       'id=id, type = xxx, x = x, y=y, z=z, map=map,prio=prio'
-- interface master.sock(datagram)
--
local tirex_results =       {'ok',
                              'error',
                              'error_illegal_prio',
                              'error_ellegal_metatile'}

local tirex_command_types = {'metatile_enqueue_request',
                              'metatile_remove_request',
                              'ping',
                              'reset_max_queue_size',
                              'quit',
                              'debug',
                              'nodebug',
                              'stop_rendering_bucket',
                              'continue_rendering_bucket',
                              'reload_config',
                              'shutdown'}

-- ========================================================
-- serialize/deserialize
-- bet table <-> string 

-- function: serialize_msg
-- argument: table msg
--     hash table {key1=val1, key2=val2,....}
-- return: string
--     should be 'key1=val1\nkey2=val2\n....\n'
--
function serialize_msg (msg)
    local str = ''
    for k,v in pairs(msg) do
        str = str .. k .. '=' .. tostring(v) .. '\n'
    end
    return str
end

-- function: deserialize_msg
-- arguments: string str: recieved message from tirex
--     should be 'key1=val1\nkey2=val2\n....\n'
-- return: table
--     hash table {key1=val1, key2=val2,....}
function deserialize_msg (str) 
    local msg = {}
    for line in string.gmatch(str, "[^\n]+") do
        m,_,k,v = string.find(line,"([^=]+)=(.+)")
        if  k ~= '' then
            msg[k]=v
        end
    end
    return msg
end

-- function: tirex_command
--  send command to tirex server thru unix domain socket datagram
--
function tirex_command(req)
    -- send request to Tirex master socket
    local udpsock = ngx.socket.udp()
    local socketpath = tirexsock
    udpsock:setitimeout(tirex_resp_timeout)
    local ok, err = udpsock:setpeername(socketpath)
    if not ok then
        ngx.log(ngx.ERR, "udpsock setpeername error")
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end
    udpsock:send(req)
    local data, err = udpsock:receive(tirex_cmd_max_size)
    udpsock:close()
    if not data then
        ngx.log(ngx.ERR, "timeout ", mx, " ", my, " ", mz, err)
        return nil
    end
    -- check result
    local msg = deserialize_msg(tostring(data))
    if next(msg) == nil then -- something wrong
        return nil
    end
    if msg["result"] ~= "ok" then
        ngx.log(ngx.ERR, "Tirex fails by ", msg["result"], " id: ", msg["id"])
        return nil
    end
    return ngx.OK
end

-- ========================================================
-- function: request_tirex_render
--  enqueue request to tirex server
--
function request_tirex_render(map, mx, my, mz, id)
    -- Create request command
    local priority = 8
    local req = serialize_msg({
        ["id"]   = tostring(id);
        ["type"] = 'metatile_enqueue_request';
        ["prio"] = priority;
        ["map"]  = map;
        ["x"]    = mx;
        ["y"]    = my;
        ["z"]    = mz})
     return tirex_command(req)
end

-- function request_tirex_debug
--   debug request to tirex server
function request_tirex_debug()
    local req = serialize_msg({
        ["id"]=tostoring(ngx.time());
        ["type"]="debug"
    })
    return tirex_command(req)
end

-- ========================================================
-- funtion: send_tirex_request
-- argument: map, x, y, z
-- return:   if ok ngx.OK, if not ok then nil
--
function send_tirex_request (map, x, y, z)
    local mx = x - x % 8
    local my = y - y % 8
    local mz = z
    local id = ngx.time()
    local index = string.format("%s:%d:%d:%d",map, mx, my, mz)

    local ok, err = get_handle(index, tirex_sync_duration, id)
    if not ok then
        -- someone have already start Tirex session
        -- wait other side(*), sync..
        return wait_signal(index, 30)
    end

    -- Start Tirex session
    local ok = request_tirex_render(map, mx, my, mz, id)
    if not ok then
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    -- We got new metatile. signal to who waiting above(*)
    local ok,err = send_signal(index)
    if not ok then
        return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end

    return ngx.OK
end
-- ---------------------------------------------------------------
-- End of Tirex Interface
--
-- ---------------------------------------------------------------

-- ---------------------------------------------------------------
-- Renderd Interface
-- module(...) -- renderd
-- ---------------------------------------------------------------
local renderdsock = 'unix:/var/lib/tirex/modtile.sock'
local renderdtile = "/var/lib/tirex/tiles/"
local renderd_resp_timeout = 30000
local renderd_cmd_max_size = 61

-- ========================================================
-- protocol definitions
--
-- ========================================================
--
-- renderd/mod_tile
--
-- command/response
--        int32 ver
--        int32 cmd
--        int32 x
--        int32 y
--        int32 z
--        char[] map
--
-- interface /tmp/osm-renderd (stream)
--
local renderd_cmd = {['cmdIgnore'] = 0;
                      ['cmdRender'] = 1;
                      ['cmdDirty']  = 2;
                      ['cmdDone']   = 3;
                      ['cmdNotDone']= 4;
                      ['cmdRenderPrio'] = 5;
                      ['cmdRenderBulk'] = 6
                     }

local renderd_protocol_ver = 2
local renderd_map_length = 41

-- function: get_long
-- argument  string buffer
--           number offset
-- return    long value
--
function get_long (buffer, offset)
    return ((buffer:byte(offset+4) * 256 + buffer:byte(offset+3)) * 256 + buffer:byte(offset+2)) * 256 + buffer:byte(offset+1)
end

-- function: add_long
-- argument  string buffer
--           number val
-- return    string buffer
--
function form_long (val)
    return string.char(val%256, bit.rshift(val,8)%256, bit.rshift(val, 16)%256, bit.rshift(val, 24)%256)
end

-- fucntion: pack_msg(msg)
-- argument table msg
--     hash table {key1=val1, key2=val2,....}
-- return: binary data
--     int32* + char*
--     char length = 41
function pack_msg(msg)
    local map = tostring(msg['map'])
    local data = form_long(renderd_protocol_ver) ..
                  form_long(tonumber(msg['cmd'])) ..
                  form_long(tonumber(msg['x'])) ..
                  form_long(tonumber(msg['y'])) ..
                  form_long(data, 16, tonumber(msg['z'])) ..
                  map ..
                  rep("\000", renderd_map_length - map:len())
    return data
end

-- fucntion: unpack_msg(data)
-- argument binary data
--     int32* + char*
-- return table msg
--     hash table {key1=val1, key2=val2,....}
function unpack_msg(data)
    local msg = {}
    msg['ver'] = get_long(data,0)
    msg['cmd'] = get_long(data,4)
    msg['x']   = get_long(data,8)
    msg['y']   = get_long(data,12)
    msg['z']   = get_long(data,16)
    pad = data:find("\000",21)
    msg['map'] = data:sub(21,pad)
end

-- ========================================================
-- function: renderd_command
-- send tirex command thru unix domain datagram socket
--
function renderd_command(req)
    -- send request to Tirex master socket
    local tcpsock = ngx.socket.tcp()
    local socketpath = renderdsock
    tcpsock:setitimeout(renderd_resp_timeout)
    local ok, err = tcpsock:setpeername(socketpath)
    if not ok then
        ngx.log(ngx.ERR, "renderd: setpeername error")
        return ngx.exit(ngx.HTTP_SERVICE_UNAVAILABLE)
    end
    tcpsock:send(req)
    local data, err = tcpsock:receive(renderd_cmd_max_size)
    tcpsock:close()
    if not data then
        ngx.log(ngx.ERR, "timeout ", err)
        return nil
    end
    -- check result
    local msg = unpack_msg(data)
    if next(msg) == nil then -- something wrong
        return nil
    end
    if msg["cmd"] ~= renderd_cmd["cmdDone"] then
        ngx.log(ngx.ERR, "Renderd fails")
        return nil
    end
    return ngx.OK
end

-- ========================================================
-- funtion: send_renderd_request
-- argument: map, x, y, z
-- return:   if ok ngx.OK, if not ok then nil
--
function send_renderd_request (map, x, y, z)
    local req = pack_msg({["cmd"] = renderd_cmd["cmdRender"];
                           ["x"] = tonumber(x);
                           ["y"] = tonumber(y);
                           ["z"] = tonumber(z);
                           ["map"] = tostring(map)
                         })
    return renderd_command(req)
end

-- ---------------------------------------------------------------
-- End of Renderd Interface
--
-- ---------------------------------------------------------------

-- ---------------------------------------------------------------
-- Metatile routines
--
-- ---------------------------------------------------------------

-- function: xyz_to_filename
-- arguments: int x, y, z
-- return: filename of metatile
--
function xyz_to_filename (x, y, z) 
    local res=''
    local v = 0
    local mx = x - x % 8
    local my = y - y % 8
    for i=0, 4 do
        v = bit.band(mx, 0x0f)
        v = bit.lshift(v, 4)
        v = bit.bor(v, bit.band(my, 0x0f))
        mx = bit.rshift(mx, 4)
        my = bit.rshift(my, 4)
        res = '/'..tostring(v)..res
    end
    return tostring(z)..res..'.meta'
end

-- get offset value from buffer
-- buffer should be string
-- offset is from 0-
-- s:byte(o) is counting from 1-
function get_offset (buffer, offset)
    return ((buffer:byte(offset+4) * 256 + buffer:byte(offset+3)) * 256 + buffer:byte(offset+2)) * 256 + buffer:byte(offset+1)
end

-- function: get_imgfilename
-- arguments: string map
--            number x, y, z
-- return string filename
--
function get_imgfilename (map, x, y, z)
    local imgfile = tirextile
    if map == nil or map == "" then
        imgfile = imgfile..xyz_to_filename(x, y, z)
    else
        imgfile = imgfile..map.."/"..xyz_to_filename(x, y, z)
    end
    return imgfile
end

-- function send_tile
-- arguments map, x, y, z
-- return ngx.OK or nil
-- 
--  send back tile to client from metatile
--
function send_tile(map, x, y, z)
    local imgfile = get_imgfilename(map, x, y, z)
    local fd, err = io.open(imgfile,"rb")
    if fd == nil then
        return nil
    end
    local metatile_header_size = 532 -- XXX: 20 + 8 * 64
    local header, err = fd:read(metatile_header_size)
    if header == nil then
        fd:close()
        ngx.log(ngx.ERR, "File read error: ",err)
        return nil
    end
    -- offset: lookup table in header
    local pib = 20 + ((y % 8) * 8) + ((x % 8) * 8 * 8 )
    local offset = get_offset(header, pib)
    local size = get_offset(header, pib+4)
    fd:seek("set", offset)
    local png, err = fd:read(size)
    if png == nil then
        fd:close()
        ngx.log(ngx.ERR, "File read error: ", err)
        return nil
    end
    ngx.header.content_type = 'image/png'
    ngx.print(png)
    fd:close()
    return ngx.OK
end

-- ---------------------------------------------------------------
-- End of Metatile routines
--
-- ---------------------------------------------------------------

-- ---------------------------------------------------------------
-- The main routine
--
-- ---------------------------------------------------------------
-- main routine
-- vals from nginx conf
--
local map = ngx.var.map
local x = tonumber(ngx.var.x)
local y = tonumber(ngx.var.y)
local z = tonumber(ngx.var.z)
local debug = nil

-- try renderd file.
local ok = send_tile(map, x, y, z)
if ok then
    return ngx.OK
end

if debug then
    request_tirex_debug()
end

-- ask tirex to render it
local ok = send_tirex_request(map, x, y, z)
if not ok then
   return ngx.exit(ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local ok = send_tile(map, x, y, z)
if not ok then
    return ngx.exit(ngx.HTTP_NOT_FOUND)
end

return ngx.OK

-- vi:nosi:sw=4:ts=4
-- EOF --
