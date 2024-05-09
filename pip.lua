-- mpv Picture-in-Picture on Windows
-- https://github.com/verygoodlee/mpv-pip

local ffi_ok, ffi = pcall(require, 'ffi')
if not ffi_ok then return end -- mpv builds without luajit

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

require('mp.options').read_options(options, mp.get_script_name(), function() end)

ffi.cdef[[
    typedef void*           HWND;
    typedef int             BOOL;
    typedef unsigned int    DWORD;
    typedef unsigned int    LPDWORD[1];
    typedef int             LPARAM;
    typedef long            LONG;
    typedef unsigned int    UINT;
    typedef void*           PVOID;
    typedef BOOL            (*WNDENUMPROC)(HWND, LPARAM);
    typedef struct tagRECT {
        LONG left;
        LONG top;
        LONG right;
        LONG bottom;                       
    }                       RECT;

    HWND    GetForegroundWindow();
    BOOL    EnumWindows(WNDENUMPROC lpEnumFunc, LPARAM lParam);
    DWORD   GetWindowThreadProcessId(HWND hwnd, LPDWORD lpdwProcessId);
    BOOL    SystemParametersInfoA(UINT uiAction, UINT uiParam, PVOID pvParam, UINT fWinIni);
    BOOL    ShowWindow(HWND hwnd, int nCmdShow);
    BOOL    MoveWindow(HWND hwnd, int X, int Y, int nWidth, int nHeight, BOOL bRepaint);
]]

local user32 = ffi.load('user32')

local mpv_pid = require('mp.utils').getpid()
local mpv_hwnd = nil
local work_area = {
    ['left']   = 0,
    ['top']    = 0,
    ['right']  = mp.get_property_number('display-width', 0),
    ['bottom'] = mp.get_property_number('display-height', 0),
}


function init()
    if mpv_hwnd then return true end
    local foreground_hwnd = user32.GetForegroundWindow()
    if is_mpv_window(foreground_hwnd) then
        mpv_hwnd = foreground_hwnd
    else
        user32.EnumWindows(function(each_hwnd, _)
            if is_mpv_window(each_hwnd) then
                mpv_hwnd = each_hwnd
                return false
            end
            return true
        end, 0)
    end
    local rect = ffi.new("RECT[1]")
    if user32.SystemParametersInfoA(0x0030, 0, rect, 0) ~= 0 then
        work_area.left   = rect[0].left
        work_area.top    = rect[0].top
        work_area.right  = rect[0].right
        work_area.bottom = rect[0].bottom
    end
    if not mpv_hwnd then mp.msg.warn('init failed') end
    return mpv_hwnd ~= nil
end

function is_mpv_window(hwnd)
    if not hwnd then return false end
    local lpdwProcessId = ffi.new('LPDWORD')
    user32.GetWindowThreadProcessId(hwnd, lpdwProcessId)
    return lpdwProcessId[0] == mpv_pid
end

function move_window(w, h, align_x, align_y)
    if not init() then return false end
    if w <= 0 or h <= 0 then
        mp.msg.warn('window size error')
        return false
    end
    local x, y
    if align_x == 'left' then
        x = work_area.left
    elseif align_x == 'right' then
        x = work_area.right - w
    else
        x = (work_area.left+work_area.right)/2 - w/2
    end
    if align_y == 'top' then 
        y = work_area.top
    elseif align_y == 'bottom' then
        y = work_area.bottom - h
    else 
        y = (work_area.top+work_area.bottom)/2 - h/2
    end
    return user32.MoveWindow(mpv_hwnd, x, y, w, h, 0) ~= 0
end

function restore_window()
    if not init() then return end
    return user32.ShowWindow(mpv_hwnd, 9)
end

local pip_on = false

-- these properties will be set when pip is on
local pip_props = {
    ['fullscreen'] = false,
    ['window-minimized'] = false,
    ['window-maximized'] = false,
    ['auto-window-resize'] = false,
    ['keepaspect-window'] = true,
    ['ontop'] = true,
    ['border'] = false,
-- toggle show-in-taskbar causes the mpv window to disappear for a very short time
-- https://github.com/mpv-player/mpv/issues/13928#issuecomment-2080382056
--    ['show-in-taskbar'] = false,
}

-- original properties before pip is on, pip window back to normal window will restore these properties
local original_props = {
    ['auto-window-resize'] = true,
    ['keepaspect-window'] = true,
    ['ontop'] = false,
    ['border'] = true,
--    ['show-in-taskbar'] = true,
}

function round(num)
    if num >= 0 then return math.floor(num + 0.5)
    else return math.ceil(num - 0.5)
    end
end

function is_rotated()
    return mp.get_property_number('vid')
        and mp.get_property_number('video-rotate', 0) % 180 == 90
end

function parse_autofit(atf)
    local w, h = 0, 0
    if atf:match('^%d+%%?x%d+%%?$') then
        w, h = atf:match('^(%d+)%%?x(%d+)%%?$')
        w, h = tonumber(w), tonumber(h)
        local w_percent, h_percent = atf:match('^%d+(%%?)x%d+(%%?)$')
        if w_percent ~= nil and w_percent ~= '' then
            w = round((work_area.right - work_area.left) * w / 100)
        end
        if h_percent ~= nil and h_percent ~= '' then
            h = round((work_area.bottom - work_area.top) * h / 100)
        end
    elseif atf:match('^%d+%%?$') then
        w = tonumber(atf:match('^(%d+)%%?$'))
        local w_percent = atf:match('^%d+(%%?)$')
        if w_percent ~= nil and w_percent ~= '' then
            w = round((work_area.right - work_area.left) * w / 100)
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
    local aspect = mp.get_property_number('video-params/aspect', 16 / 9)
    if is_rotated() then aspect = 1 / aspect end
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
    local w, h = mp.get_property_number('video-params/dw', 960),
                 mp.get_property_number('video-params/dh', 540)
    if is_rotated() then w, h = h, w end
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
    if not init() then return end
    local w, h = caculate_pip_window_size()
    for name, _ in pairs(original_props) do
        original_props[name] = mp.get_property_native(name)
    end
    for name, val in pairs(pip_props) do
        mp.set_property_native(name, val)
    end
    observe_props()
    mp.add_timeout(0.025, function()
        local success = move_window(w, h, options.align_x, options.align_y)
        if not success then
            unobserve_props()
            for name, val in pairs(original_props) do
                mp.set_property_native(name, val)
            end
            return
        end
        mp.msg.info('Picture-in-Picture: on')
        pip_on = true
        mp.set_property_bool('user-data/pip/on', true)
    end)
end

-- pip off
function off()
    if not pip_on then return end
    local w, h = caculate_normal_window_size()
    local success = move_window(w, h, 'center', 'center')
    if not success then return end
    mp.msg.info('Picture-in-Picture: off')
    unobserve_props()
    for name, val in pairs(original_props) do
        mp.set_property_native(name, val)
    end
    pip_on = false
    mp.set_property_bool('user-data/pip/on', false)
end

-- pip toggle
function toggle()
    if pip_on then off() else on() end
end

function on_prop_change(name, val)
    if not pip_on then return end
    -- resize pip window after video rotate and aspect ratio change
    if name == 'video-rotate' or name == 'video-params/aspect' then
        if not val then return end
        local w, h = caculate_pip_window_size()
        move_window(w, h, options.align_x, options.align_y)
        return
    end
    -- reset props on change
    if val == pip_props[name] then return end
    if name == 'window-minimized' then
        restore_window()
        return
    end
    mp.set_property_native(name, pip_props[name])
end

function observe_props()
    for name, _ in pairs(pip_props) do
        mp.observe_property(name, 'native', on_prop_change)
    end
    mp.observe_property('video-rotate', 'native', on_prop_change)
    mp.observe_property('video-params/aspect', 'native', on_prop_change)
end

function unobserve_props()
    mp.unobserve_property(on_prop_change)
end


-- keybinding
mp.add_key_binding(options.key, 'toggle', toggle)

-- script_message
mp.register_script_message('toggle', toggle)
mp.register_script_message('on', on)
mp.register_script_message('off', off)
