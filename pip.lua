-- mpv Picture-in-Picture on Windows
-- https://github.com/verygoodlee/mpv-pip

local ffi_ok, ffi = pcall(require, 'ffi')
if not ffi_ok then return end -- mpv builds without luajit
local bit = require('bit')
local msg = require('mp.msg')
local utils = require('mp.utils')
local options = require('mp.options')

local user_opts = {
    -- key for PiP on/off
    key = 'c',

    -- PiP window size, the syntax is the same as https://mpv.io/manual/stable/#options-autofit
    -- e.g. 25%x25% 400x300
    autofit = '25%x25%',
    
    -- PiP window alignment, default right-bottom corner
    -- <left|center|right>
    align_x = 'right',
    -- <top|center|bottom>
    align_y = 'bottom',

    -- add thin-line border to PiP window, works only on Windows11
    thin_border = false,
}

function validate_user_opts()
    if not (user_opts.autofit:match('^%d+%%?x%d+%%?$') or user_opts.autofit:match('^%d+%%?$')) then
        msg.warn('autofit option is invalid')
        user_opts.autofit = '25%x25%'
    end
    if not (user_opts.align_x == 'left' or user_opts.align_x == 'center' or user_opts.align_x == 'right') then
        msg.warn('align_x option is invalid')
        user_opts.align_x = 'right'
    end
    if not (user_opts.align_y == 'top' or user_opts.align_y == 'center' or user_opts.align_y == 'bottom') then
        msg.warn('align_y option is invalid')
        user_opts.align_y = 'bottom'
    end
    user_opts.thin_border = user_opts.thin_border and mp.get_property_native('title-bar') ~= nil
end

options.read_options(user_opts)
validate_user_opts()

---------- win32api start ----------
ffi.cdef[[
    typedef void*           HWND;
    typedef void*           HMONITOR;
    typedef int             BOOL;
    typedef unsigned int    DWORD;
    typedef unsigned int    LPDWORD[1];
    typedef int             LPARAM;
    typedef long            LONG;
    typedef long            LONG_PTR;
    typedef unsigned int    UINT;
    typedef void*           PVOID;
    typedef BOOL            (*WNDENUMPROC)(HWND, LPARAM);
    typedef struct tagRECT {
        LONG left;
        LONG top;
        LONG right;
        LONG bottom;                       
    }                       RECT, *PRECT, *NPRECT, *LPRECT;
    typedef struct tagMONITORINFO {
        DWORD cbSize;
        RECT  rcMonitor;
        RECT  rcWork;
        DWORD dwFlags;
    }                       MONITORINFO, *LPMONITORINFO;

    HWND    GetForegroundWindow();
    BOOL    EnumWindows(WNDENUMPROC lpEnumFunc, LPARAM lParam);
    DWORD   GetWindowThreadProcessId(HWND hwnd, LPDWORD lpdwProcessId);
    HMONITOR MonitorFromWindow(HWND hwnd, DWORD dwFlags);
    BOOL    GetMonitorInfoA(HMONITOR hMonitor, LPMONITORINFO lpmi);
    BOOL    SystemParametersInfoA(UINT uiAction, UINT uiParam, PVOID pvParam, UINT fWinIni);
    BOOL    ShowWindow(HWND hwnd, int nCmdShow);
    BOOL    MoveWindow(HWND hwnd, int X, int Y, int nWidth, int nHeight, BOOL bRepaint);
    LONG_PTR GetWindowLongPtrW(HWND hwnd, int nIndex);
    LONG_PTR SetWindowLongPtrW(HWND hwnd, int nIndex, LONG_PTR dwNewLong);
    BOOL    AdjustWindowRect(LPRECT lpRect, DWORD dwStyle, BOOL bMenu);
]]

local user32 = ffi.load('user32')

local mpv_hwnd = nil

function init()
    if mpv_hwnd then return true end
    -- find mpv window
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
    if not mpv_hwnd then msg.warn('mpv window not found') end
    return mpv_hwnd ~= nil
end

function is_mpv_window(hwnd)
    if not hwnd then return false end
    local lpdwProcessId = ffi.new('LPDWORD')
    user32.GetWindowThreadProcessId(hwnd, lpdwProcessId)
    return lpdwProcessId[0] == utils.getpid()
end

-- get work area of display monitor, is the portion not obscured by the system taskbar
function get_work_area()
    local work_area = {left = 0, top = 0, right = 0, bottom = 0}
    if not init() then return work_area end
    -- get display monitor that has the largest area of intersection with mpv window
    local MONITOR_DEFAULTTONEAREST = 0x00000002
    local hmonitor = user32.MonitorFromWindow(mpv_hwnd, MONITOR_DEFAULTTONEAREST)
    if hmonitor ~= nil then
        local monitor_info = ffi.new('MONITORINFO', {cbSize = ffi.sizeof('MONITORINFO')})
        if user32.GetMonitorInfoA(hmonitor, monitor_info) ~= 0 then
            work_area.left   = monitor_info.rcWork.left
            work_area.top    = monitor_info.rcWork.top
            work_area.right  = monitor_info.rcWork.right
            work_area.bottom = monitor_info.rcWork.bottom
            return work_area
        end
    end
    -- fallback: primary display monitor
    local rect = ffi.new('RECT')
    local SPI_GETWORKAREA = 0x0030
    if user32.SystemParametersInfoA(SPI_GETWORKAREA, 0, rect, 0) ~= 0 then
        work_area.left   = rect.left
        work_area.top    = rect.top
        work_area.right  = rect.right
        work_area.bottom = rect.bottom
        return work_area
    end
    msg.warn('failed to get work area of display monitor')
    return work_area
end

function move_window(w, h, align_x, align_y, taskbar)
    if not init() then return false end
    if w <= 0 or h <= 0 then
        msg.warn('window size error')
        return false
    end
    local invisible_borders_size = {left = 0, right = 0, top = 0, bottom = 0}
    if user_opts.thin_border then
        local thin_border_size = get_border_size()
        local rect = ffi.new('RECT')
        rect.left, rect.top, rect.right, rect.bottom = 0, 0, w, h
        local GWL_STYLE = -16
        user32.AdjustWindowRect(rect, user32.GetWindowLongPtrW(mpv_hwnd, GWL_STYLE), 0)
        local invisible_title_height = -rect.top - thin_border_size
        local w2, h2 = rect.right - rect.left, rect.bottom - rect.top - invisible_title_height
        invisible_borders_size.left = -rect.left - thin_border_size
        invisible_borders_size.right = w2 - w - invisible_borders_size.left - 2 * thin_border_size
        invisible_borders_size.bottom = h2 - h - 2 * thin_border_size
        w, h = w2, h2
    end
    local x, y
    local work_area = get_work_area()
    if align_x == 'left' then
        x = work_area.left - invisible_borders_size.left
    elseif align_x == 'right' then
        x = work_area.right - w + invisible_borders_size.right
    else
        x = (work_area.left+work_area.right)/2 - (w+invisible_borders_size.left-invisible_borders_size.right)/2
    end
    if align_y == 'top' then 
        y = work_area.top - invisible_borders_size.top
    elseif align_y == 'bottom' then
        y = work_area.bottom - h + invisible_borders_size.bottom
    else
        y = (work_area.top+work_area.bottom)/2 - (h+invisible_borders_size.top-invisible_borders_size.bottom)/2
    end
    show_window(false)
    local success = user32.MoveWindow(mpv_hwnd, x, y, w, h, 0) ~= 0
    if success then show_in_taskbar(taskbar) end
    show_window(true)
    return success
end

function show_window(show)
    if not init() then return end
    local SW_HIDE, SW_SHOW = 0, 5
    user32.ShowWindow(mpv_hwnd, show and SW_SHOW or SW_HIDE)
end

function show_in_taskbar(show)
    if not init() then return end
    if mp.get_property_bool('show-in-taskbar') ~= nil then
        mp.set_property_bool('show-in-taskbar', show)
        return
    end
    local GWL_EXSTYLE, WS_EX_TOOLWINDOW = -20, 0x00000080
    local exstyle = user32.GetWindowLongPtrW(mpv_hwnd, GWL_EXSTYLE)
    exstyle = bit.band(exstyle, bit.bnot(WS_EX_TOOLWINDOW))
    if not show then exstyle = bit.bor(exstyle, WS_EX_TOOLWINDOW) end
    user32.SetWindowLongPtrW(mpv_hwnd, GWL_EXSTYLE, exstyle)
end
---------- win32api end ----------

---------- helper functions start ----------
function round(num)
    if num >= 0 then return math.floor(num + 0.5) end
    return math.ceil(num - 0.5)
end

function is_empty(o)
    if o == nil or o == '' then return true end
    if type(o) == 'table' then return next(o) == nil end
    return false
end

function get_border_size()
    return user_opts.thin_border and round(mp.get_property_number('display-hidpi-scale', 1)) or 0
end

local video_out_params = nil
function get_video_out_size()
    local w = video_out_params and video_out_params['dw'] or 960
    local h = video_out_params and video_out_params['dh'] or 540
    local rotate = video_out_params and video_out_params['rotate']  or 0
    if rotate % 180 == 90 then return h, w, h/w end
    return w, h, w/h
end

function parse_autofit(atf, larger)
    local w, h = 0, 0
    local work_area = get_work_area()
    if atf:match('^%d+%%?x%d+%%?$') then -- WxH
        w, h = atf:match('^(%d+)%%?x(%d+)%%?$')
        w, h = tonumber(w), tonumber(h)
        local w_percent, h_percent = atf:match('^%d+(%%?)x%d+(%%?)$')
        if not is_empty(w_percent) then
            w = round((work_area.right - work_area.left) * w / 100)
        end
        if not is_empty(h_percent) then
            h = round((work_area.bottom - work_area.top) * h / 100)
        end
    elseif atf:match('^%d+%%?$') then -- W
        w = tonumber(atf:match('^(%d+)%%?$'))
        local w_percent = atf:match('^%d+(%%?)$')
        if not is_empty(w_percent) then
            w = round((work_area.right - work_area.left) * w / 100)
        end
    else
        msg.warn('autofit value is invalid: ' .. atf)
    end
    if w > 0 and h == 0 then
        h = larger and (work_area.bottom - work_area.top) or 1
    elseif w == 0 and h > 0 then
        w = larger and (work_area.right - work_area.left) or 1
    end
    local border_size = get_border_size()
    w = math.max(math.min(w, work_area.right - work_area.left - 2 * border_size), 0)
    h = math.max(math.min(h, work_area.bottom - work_area.top - 2 * border_size), 0)
    if w > 0 and h > 0 then
        -- fit to the video aspect ratio
        local _, _, aspect = get_video_out_size()
        if aspect > w / h then
            if larger then h = round(w / aspect)
            else w = round(h * aspect)
            end
        elseif aspect < w / h then
            if larger then w = round(h * aspect)
            else h = round(w / aspect)
            end
        end
    end
    return w, h
end

function get_pip_window_size()
    return parse_autofit(user_opts.autofit, true)
end

function get_normal_window_size()
    local atf_larger = mp.get_property('autofit-larger')
    if is_empty(atf_larger) then atf_larger = '100%x100%' end
    local w_max, h_max = parse_autofit(atf_larger, true)
    local w_min, h_min = 0, 0
    local atf_smaller = mp.get_property('autofit-smaller')
    if not is_empty(atf_smaller) then
        w_min, h_min = parse_autofit(atf_smaller, false)
        if w_min > w_max then w_min, h_min = w_max, h_max end
    end
    local w, h = 0, 0
    local atf = mp.get_property('autofit')
    if is_empty(atf) then
        w, h = get_video_out_size()
        if mp.get_property_bool('hidpi-window-scale', false) then
            local hidpi_scale = mp.get_property_number('display-hidpi-scale', 1)
            w, h = round(w * hidpi_scale), round(h * hidpi_scale)
        end
    else
        w, h = parse_autofit(atf, true)
    end
    if w >= w_max then return w_max, h_max
    elseif w >= w_min then return w, h
    else return w_min, h_min
    end
end
---------- helper functions end ----------

local pip_on = false

-- these properties will be set when pip is on
local pip_props = {
    ['fullscreen'] = false,
    ['window-minimized'] = false,
    ['window-maximized'] = false,
    ['auto-window-resize'] = false,
    ['keepaspect-window'] = true,
    ['ontop'] = true,
    [user_opts.thin_border and 'title-bar' or 'border'] = false,
    ['border'] = user_opts.thin_border,
}
-- original properties before pip is on, pip window back to normal window will restore these properties
local original_props = {
    ['auto-window-resize'] = true,
    ['keepaspect-window'] = true,
    ['ontop'] = false,
    [user_opts.thin_border and 'title-bar' or 'border'] = true,
    ['border'] = true,
}

function set_pip_props()
    -- save original props before set
    for name, _ in pairs(original_props) do
        original_props[name] = mp.get_property_native(name)
    end
    for name, val in pairs(pip_props) do
        mp.set_property_native(name, val)
    end
end

function set_original_props()
    for name, val in pairs(original_props) do
        mp.set_property_native(name, val)
    end
end

local turn_on_timer = mp.add_timeout(0.05, function()
    video_out_params = mp.get_property_native('video-out-params')
    local w, h = get_pip_window_size()
    local success = move_window(w, h, user_opts.align_x, user_opts.align_y, false)
    if not success then
        unobserve_props()
        set_original_props()
        return
    end
    msg.info(string.format('Picture-in-Picture: on, Size: %dx%d', w, h))
    pip_on = true
    mp.set_property_bool('user-data/pip/on', true)
end, true)

-- pip on
function on()
    if pip_on or not init() or turn_on_timer:is_enabled() then return end
    set_pip_props()
    observe_props()
    turn_on_timer:resume()
end

-- pip off
function off()
    if not pip_on or not init() then return end
    local w, h = get_normal_window_size()
    local success = move_window(w, h, 'center', 'center', true)
    if not success then return end
    msg.info(string.format('Picture-in-Picture: off, Size: %dx%d', w, h))
    unobserve_props()
    set_original_props()
    pip_on = false
    mp.set_property_bool('user-data/pip/on', false)
end

-- pip toggle
function toggle()
    if pip_on then off() else on() end
end

function observe_props()
    for name, _ in pairs(pip_props) do
        mp.observe_property(name, 'native', on_pip_prop_change)
    end
    mp.register_event('video-reconfig', on_video_reconfig)
end

function unobserve_props()
    mp.unobserve_property(on_pip_prop_change)
    mp.unregister_event(on_video_reconfig)
end

function on_video_reconfig()
    if not pip_on then return end
    local w0, h0 = get_pip_window_size()
    video_out_params = mp.get_property_native('video-out-params')
    local w1, h1 = get_pip_window_size()
    if not (w0 == w1 and h0 == h1) then resize_pip_window(w1, h1) end
end

function on_pip_prop_change(name, val)
    if not pip_on then return end
    if val == pip_props[name] then return end
    mp.set_property_native(name, pip_props[name])
end

function resize_pip_window(w, h)
    if not pip_on then return false end
    if not w or not h then w, h = get_pip_window_size() end
    local resized = move_window(w, h, user_opts.align_x, user_opts.align_y, false)
    if resized then msg.info(string.format('Resize: %dx%d', w, h)) end
    return resized
end

-- IMPORTANT: reset mpv_hwnd on VO change
mp.observe_property('current-vo', 'string', function(_, val) if val then mpv_hwnd = nil end end)

mp.add_key_binding(user_opts.key, 'toggle', toggle)
mp.register_script_message('on', on)
mp.register_script_message('off', off)
