#SingleInstance force
#NoTrayIcon

pid := A_Args[1]
opt :=  A_Args[2]

win_title := 'ahk_pid ' pid

move(w, h, align_x, align_y) {
    MonitorGetWorkArea(, &Left, &Top, &Right, &Bottom)
    if (align_x== 'left') {
        x := Left
    } else if (align_x == 'right') {
        x := Right - w
    } else {
        x := ((Left+Right)/2)-(w/2)
    }
    if (align_y == 'top') {
        y := Top
    } else if (align_y == 'bottom') {
        y := Bottom - h
    } else {
        y := ((Top+Bottom)/2)-(h/2)
    }
    WinMove x, y, w, h, win_title
}

restore() {
    WinRestore win_title
}

if (opt == 'move') {
    move(A_Args[3], A_Args[4], A_Args[5], A_Args[6])
} else if (opt == 'restore') {
    restore()
}

