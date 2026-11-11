/* draw_icons.inc: the toolbar icon programs run by d_icon in draw.S.
 * Every coordinate is a float, written as its bit pattern.
 * Op: .byte kind, n, width, alpha. kind 1 polyline of n points, 2 convex polygon,
 * 3 ellipse (center, then radii in grid units), 0 end. width 0 sw, 1 sw*1.15,
 * 2 sw*1.1, 3 5*u. alpha 0 = 255, 1 = 110. Points are grid units (0..20). */
.Lic_rect:
        .byte 1, 5, 0, 0
        .long 0x40400000, 0x40900000
        .long 0x41880000, 0x40900000
        .long 0x41880000, 0x41780000
        .long 0x40400000, 0x41780000
        .long 0x40400000, 0x40900000
        .byte 0, 0, 0, 0
.Lic_ellipse:
        .byte 3, 0, 0, 0
        .long 0x41200000, 0x41200000, 0x40E00000, 0x40B00000
        .byte 0, 0, 0, 0
.Lic_line:
        .byte 1, 2, 0, 0
        .long 0x40900000, 0x41780000
        .long 0x41780000, 0x40900000
        .byte 0, 0, 0, 0
.Lic_arrow:
        .byte 1, 2, 0, 0
        .long 0x40900000, 0x41780000
        .long 0x41480000, 0x40F00000
        .byte 2, 3, 0, 0
        .long 0x41840000, 0x40600000
        .long 0x411CCCCD, 0x40B9999A
        .long 0x41633333, 0x41233333
        .byte 0, 0, 0, 0
.Lic_pen:
        .byte 1, 8, 0, 0
        .long 0x40400000, 0x41500000
        .long 0x40A00000, 0x41280000
        .long 0x40E00000, 0x4119999A
        .long 0x41100000, 0x41300000
        .long 0x41300000, 0x41500000
        .long 0x41500000, 0x4149999A
        .long 0x41700000, 0x4119999A
        .long 0x41880000, 0x40E00000
        .byte 0, 0, 0, 0
.Lic_marker:
        .byte 1, 2, 3, 1
        .long 0x40B00000, 0x41580000
        .long 0x41680000, 0x40900000
        .byte 1, 2, 0, 0
        .long 0x40400000, 0x4189999A
        .long 0x41880000, 0x4189999A
        .byte 0, 0, 0, 0
.Lic_text:
        .byte 1, 2, 1, 0
        .long 0x40900000, 0x40866666
        .long 0x41780000, 0x40866666
        .byte 1, 2, 1, 0
        .long 0x41200000, 0x40866666
        .long 0x41200000, 0x41840000
        .byte 0, 0, 0, 0
.Lic_number:
        .byte 3, 0, 0, 0
        .long 0x41200000, 0x41200000, 0x40ECCCCD, 0x40ECCCCD
        .byte 1, 3, 0, 0
        .long 0x41033333, 0x40F33333
        .long 0x4129999A, 0x40BCCCCD
        .long 0x4129999A, 0x4164CCCD
        .byte 0, 0, 0, 0
.Lic_undo:
        .byte 1, 11, 0, 0
        .long 0x40D00000, 0x40E00000
        .long 0x41400000, 0x40E00000
        .long 0x415A05C1, 0x40EA5A36
        .long 0x41701551, 0x4103EAB0
        .long 0x417ED2E5, 0x4119FA40
        .long 0x41820000, 0x41340001
        .long 0x417ED2E5, 0x414E05C2
        .long 0x41701550, 0x41641551
        .long 0x415A05C0, 0x4172D2E6
        .long 0x413FFFFF, 0x41780000
        .long 0x40E00000, 0x41780000
        .byte 2, 3, 0, 0
        .long 0x40400000, 0x40E00000
        .long 0x40E00000, 0x40666666
        .long 0x40E00000, 0x41266666
        .byte 0, 0, 0, 0
.Lic_redo:
        .byte 1, 11, 0, 0
        .long 0x41580000, 0x40E00000
        .long 0x41000000, 0x40E00000
        .long 0x40CBF47E, 0x40EA5A36
        .long 0x409FD55E, 0x4103EAB0
        .long 0x40825A36, 0x4119FA40
        .long 0x40700000, 0x41340001
        .long 0x40825A36, 0x414E05C2
        .long 0x409FD560, 0x41641551
        .long 0x40CBF480, 0x4172D2E6
        .long 0x41000001, 0x41780000
        .long 0x41500000, 0x41780000
        .byte 2, 3, 0, 0
        .long 0x41880000, 0x40E00000
        .long 0x41500000, 0x40666666
        .long 0x41500000, 0x41266666
        .byte 0, 0, 0, 0
.Lic_pin:
        .byte 2, 4, 0, 0
        .long 0x40E00000, 0x40200000
        .long 0x41500000, 0x40200000
        .long 0x41500000, 0x40933333
        .long 0x40E00000, 0x40933333
        .byte 2, 4, 0, 0
        .long 0x41033333, 0x40933333
        .long 0x413CCCCD, 0x40933333
        .long 0x414CCCCD, 0x4129999A
        .long 0x40E66666, 0x4129999A
        .byte 2, 4, 0, 0
        .long 0x40900000, 0x4129999A
        .long 0x41780000, 0x4129999A
        .long 0x41780000, 0x41466666
        .long 0x40900000, 0x41466666
        .byte 1, 2, 0, 0
        .long 0x41200000, 0x41466666
        .long 0x41200000, 0x418E6666
        .byte 0, 0, 0, 0
.Lic_save:
        .byte 1, 6, 0, 0
        .long 0x40600000, 0x40600000
        .long 0x41580000, 0x40600000
        .long 0x41840000, 0x40D00000
        .long 0x41840000, 0x41840000
        .long 0x40600000, 0x41840000
        .long 0x40600000, 0x40600000
        .byte 1, 4, 0, 0
        .long 0x40D00000, 0x40600000
        .long 0x40D00000, 0x40F00000
        .long 0x41480000, 0x40F00000
        .long 0x41480000, 0x40600000
        .byte 1, 4, 0, 0
        .long 0x40C00000, 0x41840000
        .long 0x40C00000, 0x41380000
        .long 0x41600000, 0x41380000
        .long 0x41600000, 0x41840000
        .byte 0, 0, 0, 0
.Lic_close:
        .byte 1, 2, 0, 0
        .long 0x40B00000, 0x40B00000
        .long 0x41680000, 0x41680000
        .byte 1, 2, 0, 0
        .long 0x41680000, 0x40B00000
        .long 0x40B00000, 0x41680000
        .byte 0, 0, 0, 0
.Lic_ok:
        .byte 1, 3, 2, 0
        .long 0x40800000, 0x41280000
        .long 0x41033333, 0x416B3333
        .long 0x41800000, 0x40B9999A
        .byte 0, 0, 0, 0
/* the mosaic icon's grid lines, (float)(3 + 3.5 * i) */
.Lic_mosaic_grid: .long 0x40400000, 0x40D00000, 0x41200000, 0x41580000, 0x41880000
