-- mpv Picture-in-Picture on Windows
-- https://github.com/verygoodlee/mpv-pip

local options = {
    -- key for PiP on/off
    key = 'c',

    -- initial PiP window size, the meaning is the same as --autofit in mpv.conf
    -- example 25%x25% 400x300, see https://mpv.io/manual/stable/#options-autofit
    autofit = '25%x25%',
    
    -- PiP window alignment, default right-bottom corner
    -- <left|center|right>
    align_x = 'right',
    -- <top|center|bottom>
    align_y = 'bottom',
}

mp.options = require 'mp.options'
mp.options.read_options(options, mp.get_script_name(), function() end)

local pip_on = false

-- old properties before pip is on, pip window back to normal window will reset these properties
local auto_window_resize = nil
local keepaspect_window = nil
local ontop = nil
local border = nil

-- call pip-tool.exe
function call_pip_tool(args)
    table.insert(args, 1, mp.get_property('pid'))
    table.insert(args, 1, 'pip-tool.exe')
    -- mp.msg.info(table.concat(args, ' '))
    mp.command_native({
        name = 'subprocess',
        playback_only = false,
        capture_stdout = false,
        args = args
    })
end

function round(num)
    if num >= 0 then return math.floor(num + 0.5)
    else return math.ceil(num - 0.5)
    end
end

function parse_autofit(atf)
    local w, h = 0, 0
    if atf:match('^%d+%%?x%d+%%?$') then
        w, h = atf:match('^(%d+)%%?x(%d+)%%?$')
        w, h = tonumber(w), tonumber(h)
        local w_percent, h_percent = atf:match('^%d+(%%?)x%d+(%%?)$')
        if w_percent ~= nil and w_percent ~= '' then
            w = round(mp.get_property_number('display-width', 0) * w / 100)
        end
        if h_percent ~= nil and h_percent ~= '' then
            h = round(mp.get_property_number('display-height', 0) * h / 100)
        end
    elseif atf:match('^%d+%%?$') then
        w = tonumber(atf:match('^(%d+)%%?$'))
        local w_percent = atf:match('^%d+(%%?)$')
        if w_percent ~= nil and w_percent ~= '' then
            w = round(mp.get_property_number('display-width', 0) * w / 100)
        end
    else
        mp.msg.warn('autofit value is invalid: ' .. atf)
    end
    return w, h
end

function size_fit_aspect(w, h, is_larger)
    if w <= 0 then return w, h end
    is_larger = is_larger == nil or is_larger
    if h == 0 then
        if is_larger then h = 1000000
        else h = 1
        end
    end
    local aspect = mp.get_property_number('width', 16) / mp.get_property_number('height', 9)
    if mp.get_property_number('video-rotate', 0) % 180 == 90 then aspect = 1 / aspect end
    if aspect > w / h then
        if is_larger then h = round(w / aspect)
        else w = round(h * aspect)
        end
    elseif aspect < w / h then
        if is_larger then w = round(h * aspect)
        else h = round(w / aspect)
        end
    end
    return w, h
end

function caculate_pip_window_size()
    return size_fit_aspect(parse_autofit(options.autofit))
end

function caculate_normal_window_size()
    local w_min, h_min= 0, 0
    local atf_smaller = mp.get_property('autofit-smaller')
    if atf_smaller ~= nil and atf_smaller ~= '' then
        w_min, h_min = parse_autofit(atf_smaller)
        w_min, h_min = size_fit_aspect(w_min, h_min, false)
    end
    
    local w_max, h_max = 1000000, 1000000
    local atf_larger = mp.get_property('autofit-larger')
    if atf_larger ~= nil and atf_larger ~= '' then
        w_max, h_max = size_fit_aspect(parse_autofit(atf_larger))
    end
    
    local w, h = mp.get_property_number('width', 0), mp.get_property_number('height', 0)
    if mp.get_property_number('video-rotate', 0) % 180 == 90 then w, h = h, w end
    local atf = mp.get_property('autofit')
    if atf ~= nil and atf ~= '' then
        w, h = size_fit_aspect(parse_autofit(atf))
    end
    if w == 0 or h == 0 then
        w, h = caculate_pip_window_size()
    end
    
    if w >= w_max then return w_max, h_max
    elseif w >= w_min then return w, h
    else return w_min, h_min
    end
end

-- pip on
function on()
    if pip_on then return end
    local w, h = caculate_pip_window_size()
    if w <= 0 or h <= 0 then
        mp.msg.warn('window size error')
        return
    end
    mp.msg.info('Picture-in-Picture: on')
    mp.set_property_bool('fs', false)
    mp.set_property_bool('window-maximized', false)
    auto_window_resize =  mp.get_property_bool('auto-window-resize')
    keepaspect_window = mp.get_property_bool('keepaspect-window')
    ontop = mp.get_property_bool('ontop')
    border = mp.get_property_bool('border')
    mp.set_property_bool('auto-window-resize', false)
    mp.set_property_bool('keepaspect-window', true)
    mp.set_property_bool('ontop', true)
    mp.set_property_bool('border', false)
    if not border then
        call_pip_tool({'move', tostring(w), tostring(h), options.align_x, options.align_y})
    else
        -- mp.set_property_bool('border', false) doesn't make the border disappear immediately
        -- waiting for border to disappear, resizing window with border will result in incorrect resolution
        mp.add_timeout(0.05, function()
            call_pip_tool({'move', tostring(w), tostring(h), options.align_x, options.align_y})
        end)
    end
    pip_on = true
end

-- pip off
function off()
    if not pip_on then return end
    local w, h = caculate_normal_window_size()
    if w <= 0 or h <= 0 then
        mp.msg.warn('window size error')
        return
    end
    mp.msg.info('Picture-in-Picture: off')
    mp.set_property_bool('fs', false)
    mp.set_property_bool('window-maximized', false)
    call_pip_tool({'move', tostring(w), tostring(h), 'center', 'center'})
    mp.set_property_bool('auto-window-resize', auto_window_resize)
    mp.set_property_bool('keepaspect-window', keepaspect_window)
    mp.set_property_bool('ontop', ontop)
    mp.set_property_bool('border', border)
    pip_on = false
end

-- pip toggle
function toggle()
    if pip_on then off() else on() end
end

-- if pip is on, never minimize the window
mp.observe_property('window-minimized', 'bool', function(name, val) 
    if not pip_on or not val then return end
    call_pip_tool({'restore'})
end)
-- if pip is on, always stay ontop
mp.observe_property('ontop', 'bool', function(name, val) 
    if not pip_on or val then return end
    mp.set_property_bool('ontop', true)
end)

function resize_pip_window()
    if not pip_on then return end
    local w, h = caculate_pip_window_size()
    if w <= 0 or h <= 0 then
        mp.msg.warn('window size error')
        return
    end
    mp.set_property_bool('fs', false)
    mp.set_property_bool('window-maximized', false)
    call_pip_tool({'move', tostring(w), tostring(h), options.align_x, options.align_y})
end

mp.observe_property('video-rotate', 'number', resize_pip_window)

-- resize pip window after loading file
mp.register_event('file-loaded', resize_pip_window)

-- keybinding
mp.add_key_binding(options.key, 'toggle', toggle)

-- script_message
mp.register_script_message('toggle', toggle)
mp.register_script_message('on', on)
mp.register_script_message('off', off)
