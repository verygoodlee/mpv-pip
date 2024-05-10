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

    -- PiP window size, the meaning is the same as --autofit in mpv.conf
    -- example 25%x25% 400x300, see https://mpv.io/manual/stable/#options-autofit
    autofit = '25%x25%',
    
    -- PiP window alignment, default right-bottom corner
    -- <left|center|right>
    align_x = 'right',
    -- <top|center|bottom>
    align_y = 'bottom',

    thin_border = true,
}
function validate_user_opts()
    if not (user_opts.autofit:match('^%d+%%?x%d+%%?$') or user_opts.autofit:match('^%d+%%?$')) then
        msg.warn('autofit option is invalid, restore to the default value')
        user_opts.autofit = '25%x25%'
    end
    if not (user_opts.align_x == 'left' or user_opts.align_x == 'center' or user_opts.align_x == 'right') then
        msg.warn('align_x option is invalid, restore to the default value')
        user_opts.align_x = 'right'
    end
    if not (user_opts.align_y == 'top' or user_opts.align_y == 'center' or user_opts.align_y == 'bottom') then
        msg.warn('align_y option is invalid, restore to the default value')
        user_opts.align_y = 'bottom'
    end
    thin_border = thin_border and mp.get_property_native('title-bar') ~= nil
end
options.read_options(user_opts, _, validate_user_opts)
validate_user_opts()

---------- win32api start ----------
ffi.cdef[[
    typedef void*           HWND;
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

    HWND    GetForegroundWindow();
    BOOL    EnumWindows(WNDENUMPROC lpEnumFunc, LPARAM lParam);
    DWORD   GetWindowThreadProcessId(HWND hwnd, LPDWORD lpdwProcessId);
    BOOL    SystemParametersInfoA(UINT uiAction, UINT uiParam, PVOID pvParam, UINT fWinIni);
    BOOL    ShowWindow(HWND hwnd, int nCmdShow);
    BOOL    MoveWindow(HWND hwnd, int X, int Y, int nWidth, int nHeight, BOOL bRepaint);
    LONG_PTR GetWindowLongPtrW(HWND hwnd, int nIndex);
    LONG_PTR SetWindowLongPtrW(HWND hwnd, int nIndex, LONG_PTR dwNewLong);
    BOOL    AdjustWindowRect(LPRECT lpRect, DWORD dwStyle, BOOL bMenu);
]]

local user32 = ffi.load('user32')

local mpv_hwnd = nil
local work_area = {
    ['left']   = 0,
    ['top']    = 0,
    ['right']  = mp.get_property_number('display-width', 0),
    ['bottom'] = mp.get_property_number('display-height', 0),
}

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
    -- get work area of screen, is the portion not obscured by the system taskbar
    local rect = ffi.new("RECT[1]")
    local SPI_GETWORKAREA = 0x0030
    if user32.SystemParametersInfoA(SPI_GETWORKAREA, 0, rect, 0) ~= 0 then
        work_area.left   = rect[0].left
        work_area.top    = rect[0].top
        work_area.right  = rect[0].right
        work_area.bottom = rect[0].bottom
    end
    if not mpv_hwnd then msg.warn('init failed') end
    return mpv_hwnd ~= nil
end

function is_mpv_window(hwnd)
    if not hwnd then return false end
    local lpdwProcessId = ffi.new('LPDWORD')
    user32.GetWindowThreadProcessId(hwnd, lpdwProcessId)
    return lpdwProcessId[0] == utils.getpid()
end

function move_window(w, h, align_x, align_y, taskbar)
    if not init() then return false end
    if w <= 0 or h <= 0 then
        msg.warn('window size error')
        return false
    end
    
    local invisible_borders_size = {
        ['left'] = 0,
        ['right'] = 0,
        ['top'] = 0,
        ['bottom'] = 0,
    }
    if user_opts.thin_border then
        local thin_border_size = 1
        local rect = ffi.new('RECT[1]')
        rect[0].left, rect[0].top, rect[0].right, rect[0].bottom = 0, 0, w, h
        local GWL_STYLE = -16
        user32.AdjustWindowRect(rect, user32.GetWindowLongPtrW(mpv_hwnd, GWL_STYLE), 0)
        local invisible_title_height = -rect[0].top - thin_border_size
        w2, h2 = rect[0].right - rect[0].left, rect[0].bottom - rect[0].top - invisible_title_height
        invisible_borders_size.left = -rect[0].left - thin_border_size
        invisible_borders_size.right = w2 - w - invisible_borders_size.left - 2 * thin_border_size
        invisible_borders_size.bottom = h2 - h - 2 * thin_border_size
        w, h = w2, h2
    end

    local x, y
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
    if type(o) == 'table' then
        local size = 0
        for _, _ in pairs(o) do size = size + 1 end
        return size == 0
    end
    return false
end

function get_video_out_size()
    local o = mp.get_property_native('video-out-params')
    if is_empty(o) then return 960, 540, 960/540 end
    local w, h = o['dw'], o['dh']
    if o['rotate'] % 180 == 90 then return h, w, h/w end
    return w, h, w/h
end

function parse_autofit(atf, larger)
    local w, h = 0, 0
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
    if w > 0 then
        -- fit to the video aspect ratio
        if h <= 0 then h = larger and 100000000 or 1 end
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
    local w_min, h_min= 0, 0
    local atf_smaller = mp.get_property('autofit-smaller')
    if not is_empty(atf_smaller) then
        w_min, h_min = parse_autofit(atf_smaller, false)
    end
    local w_max, h_max = 100000000, 100000000
    local atf_larger = mp.get_property('autofit-larger')
    if not is_empty(atf_larger) then
        w_max, h_max = parse_autofit(atf_larger, true)
    end
    local w, h = get_video_out_size()
    local atf = mp.get_property('autofit')
    if not is_empty(atf) then
        w, h = parse_autofit(atf, true)
    end
    if w >= w_max then return w_max, h_max
    elseif w >= w_min then return w, h
    else return w_min, h_min
    end
end
---------- helper functions end ----------

local pip_on = false
local pip_w, pip_h

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

-- pip on
function on()
    if pip_on or not init() then return end
    pip_w, pip_h = get_pip_window_size()
    set_pip_props()
    observe_props()
    mp.add_timeout(0.05, function()
        local success = move_window(pip_w, pip_h, user_opts.align_x, user_opts.align_y, false)
        if not success then
            unobserve_props()
            set_original_props()
            return
        end
        msg.info(string.format('Picture-in-Picture: on, Size: %dx%d', pip_w, pip_h))
        pip_on = true
        mp.set_property_bool('user-data/pip/on', true)
    end)
end

-- pip off
function off()
    if not pip_on then return end
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
    mp.observe_property('video-out-params', 'native', resize_pip_window_on_change)
    for name, _ in pairs(pip_props) do
        mp.observe_property(name, 'native', reset_pip_prop_on_change)
    end
end

function unobserve_props()
    mp.unobserve_property(resize_pip_window_on_change)
    mp.unobserve_property(reset_pip_prop_on_change)
end

function resize_pip_window_on_change()
    if not pip_on then return end
    local w, h = get_pip_window_size()
    if w == pip_w and h == pip_h then return end
    local success = move_window(w, h, user_opts.align_x, user_opts.align_y, false)
    if success then
        pip_w, pip_h = w, h
        msg.info(string.format('Resize: %dx%d', pip_w, pip_h))
    end
end

function reset_pip_prop_on_change(name, val)
    if not pip_on then return end
    if val == pip_props[name] then return end
    mp.set_property_native(name, pip_props[name])
    if name == 'fullscreen' or name == 'window-minimized' or name == 'window-maximized' then
        mp.add_timeout(0.1, function() show_in_taskbar(false)  end)
    end
end

-- keybinding
mp.add_key_binding(user_opts.key, 'toggle', toggle)

-- script message
mp.register_script_message('toggle', toggle)
mp.register_script_message('on', on)
mp.register_script_message('off', off)
