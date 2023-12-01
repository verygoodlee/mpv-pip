# mpv Picture-in-Picture
实现mpv播放器画中画功能，仅限于Windows平台，因为是基于 [AutoHotkey](https://www.autohotkey.com/) 实现的。

![mpv-pip.gif](https://github.com/verygoodlee/mpv-pip/blob/master/mpv-pip.gif)

## 安装
- 需要把`pip-tool.ahk`编译为`pip-tool.exe`，文档：[把脚本转换成 EXE(Ahk2Exe)](https://wyagd001.github.io/v2/docs/Scripts.htm#ahk2exe) ，\
  或者可以直接从 [Release](https://github.com/verygoodlee/mpv-pip/releases) 页下载。
- `pip.lua`放在`~~/scripts`目录，`pip.conf`放在`~~/scripts-opts`目录，`pip-tool.exe`放在mpv根目录，通常如下图所示：
    ```
    .../mpv/
       │  mpv.exe 
       │  pip-tool.exe
       │  ...
       └─ /portable_config/
          ├─ /scripts/
          │    pip.lua
          ├─ /script-opts/
          │    pip.conf
    ```
## 使用
`pip.conf`中可修改 快捷键（默认`c`开启/关闭画中画），窗口大小，窗口对齐方式。\
如果你使用了 [--no-input-default-bindings](https://mpv.io/manual/stable/#options-no-input-default-bindings) 配置，则需要自己在`input.conf`中自定义快捷键
```
KEY script-binding pip/toggle
```

## 在其他脚本中调用
```lua
-- 开启
mp.commandv('script-message-to', 'pip', 'on')
-- 关闭
mp.commandv('script-message-to', 'pip', 'off')
-- 开启/关闭
mp.commandv('script-message-to', 'pip', 'toggle')
```

