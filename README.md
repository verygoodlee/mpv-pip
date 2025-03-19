# mpv Picture-in-Picture

## Language
[English](README.md)

[简体中文](README_zh.md)

## About
mpv lua script implements Picture-in-Picture, only for Windows System，it is implemented based on luajit call win32api.

![mpv-pip.gif](mpv-pip.gif)

## Install
- Note: mpv builds with luajit is required, [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake/releases) and [zhongfly/mpv-winbuild](https://github.com/zhongfly/mpv-winbuild/releases) is recommended.
- put `pip.lua` into `~~/scripts`, put `pip.conf` into `~~/scripts-opts`, like this: 
    ```
    .../mpv/
       │  ...
       └─ /portable_config/
          ├─ /scripts/
          │    pip.lua
          ├─ /script-opts/
          │    pip.conf
    ```
## Use
You can customize the keybinding, window size and window alignment in `pip.conf`.\
If you use the [--input-default-bindings=no](https://mpv.io/manual/stable/#options-input-default-bindings) option, you need to customize your keybinding in `input.conf`: 
```
KEY script-binding pip/toggle
```

## Integrate with other scripts
```lua
-- get whether the Picture-in-Picture is on
local pip_is_on = mp.get_property_bool('user-data/pip/on', false)
-- turn on, turn off and toggle opertions
mp.commandv('script-message-to', 'pip', 'on')
mp.commandv('script-message-to', 'pip', 'off')
mp.commandv('script-binding', 'pip/toggle')
```

