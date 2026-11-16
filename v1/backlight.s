@ Backlight-over-IP payload for HP2550 console (user.bin V2.0.4)
@ Position-independent: all firmware calls go through ldr=abs + blx; all data
@ via ldr=abs. No writes to this (code) region -> safe whether it runs from
@ PSRAM or XIP. Mutable state lives only in data RAM (0x1F0xxxx):
@   - poll throttle: 1 byte at 0x1f12089 (custom-record+5, never touched by fw)
@   - last acted seq: parsed back out of the status slot (path2) string
@
@ Entry bl_hook replaces the stolen `bl 0x43054` at 0x1ca0e (display loop).
        .syntax unified
        .cpu cortex-m4
        .thumb

        .equ APPLY,      0x43055      @ backlight_apply/PWM fade (thumb)
        .equ BL_SET,     0x43101      @ backlight_set(r0=0/1)    (thumb)
        .equ BRIGHT_SET, 0x430b1      @ brightness_set(r0=0..100)(thumb)
        .equ QUEUE_CMD,  0x4b139      @ queue_wifi_cmd(r0=code)  (thumb)

        .equ CMD_SLOT,   0x1f120cf    @ Station ID string (command in)
        .equ STATUS_SLOT,0x1f12162    @ path2 string (status out / last seq)
        .equ THROTTLE,   0x1f12089    @ record+5, free byte (poll countdown)
        .equ SCREEN_ID,  0x1f1145c    @ current screen id (byte)
        .equ BL_ON_FLAG, 0x1f23057    @ backlight on flag (byte)
        .equ BL_LEVEL,   0x1f23056    @ backlight target level (byte)

        .equ SCREEN_CUSTOM, 5         @ Customized setup screen id (skip)
        .equ RELOAD,     100          @ poll throttle reload (tune 1..255)
        .equ REQ_RECORD, 0xaa         @ TX: request custom record from chip
        .equ PUSH_PATHS, 0xd2         @ TX: push paths (status) to chip

@ ---------------------------------------------------------------------------
        .global bl_hook
        .thumb_func
bl_hook:                             @ replaces: bl 0x43054
        push    {r3, lr}
        ldr     r3, =APPLY
        blx     r3                   @ original backlight apply (unchanged)
        bl      bl_poll
        pop     {r3, pc}

@ ---------------------------------------------------------------------------
        .thumb_func
bl_poll:
        push    {r3, r4, r5, r6, r7, lr}
        @ throttle
        ldr     r7, =THROTTLE
        ldrb    r5, [r7]
        cbz     r5, .Lfire
        subs    r5, #1
        strb    r5, [r7]
        b       .Ldone
.Lfire:
        movs    r5, #RELOAD
        strb    r5, [r7]
        @ skip while user is on the Customized settings screen
        ldr     r5, =SCREEN_ID
        ldrb    r5, [r5]
        cmp     r5, #SCREEN_CUSTOM
        beq     .Ldone
        @ ask the chip to refresh the record (async; read reflects prior cycle)
        movs    r0, #REQ_RECORD
        ldr     r3, =QUEUE_CMD
        blx     r3
        @ command slot must start with "BL "
        ldr     r6, =CMD_SLOT
        ldrb    r0, [r6]
        cmp     r0, #0x42            @ 'B'
        bne     .Ldone
        ldrb    r0, [r6, #1]
        cmp     r0, #0x4c            @ 'L'
        bne     .Ldone
        ldrb    r0, [r6, #2]
        cmp     r0, #0x20            @ ' '
        bne     .Ldone
        @ parse value
        adds    r0, r6, #3
        bl      parse_uint           @ r0=value, r1=endptr
        mov     r5, r0               @ v
        mov     r6, r1
.Lhash:
        ldrb    r0, [r6]
        cmp     r0, #0
        beq     .Ldone               @ no '#'
        adds    r6, #1
        cmp     r0, #0x23            @ '#'
        bne     .Lhash
        @ parse sequence number (8-bit)
        mov     r0, r6
        bl      parse_uint
        uxtb    r0, r0
        mov     r4, r0               @ cmd seq
        @ last acted seq := '#' number currently in the status slot
        ldr     r6, =STATUS_SLOT
.Lph:
        ldrb    r0, [r6]
        cmp     r0, #0
        beq     .Lnew                @ empty status -> treat as new
        adds    r6, #1
        cmp     r0, #0x23
        bne     .Lph
        mov     r0, r6
        bl      parse_uint
        uxtb    r0, r0
        cmp     r0, r4
        beq     .Ldone               @ already acted on this seq
.Lnew:
        @ act on value
        cmp     r5, #0
        bne     .Lnotoff
        movs    r0, #0
        ldr     r3, =BL_SET
        blx     r3                   @ backlight_set(0)
        b       .Lstatus
.Lnotoff:
        cmp     r5, #1
        bne     .Llevel
        movs    r0, #1
        ldr     r3, =BL_SET
        blx     r3                   @ backlight_set(1)
        b       .Lstatus
.Llevel:
        movs    r0, #1
        ldr     r3, =BL_SET
        blx     r3                   @ ensure on
        mov     r0, r5
        cmp     r0, #100
        bls     .Llok
        movs    r0, #100
.Llok:
        ldr     r3, =BRIGHT_SET
        blx     r3                   @ brightness_set(v)
.Lstatus:
        @ write "BL <on> <lvl> #<seq>" into the status slot
        ldr     r6, =STATUS_SLOT
        movs    r0, #0x42
        strb    r0, [r6], #1
        movs    r0, #0x4c
        strb    r0, [r6], #1
        movs    r0, #0x20
        strb    r0, [r6], #1
        ldr     r3, =BL_ON_FLAG
        ldrb    r0, [r3]
        cmp     r0, #0
        bne     .Lon1
        movs    r0, #0x30            @ '0'
        b       .Lonw
.Lon1:
        movs    r0, #0x31            @ '1'
.Lonw:
        strb    r0, [r6], #1
        movs    r0, #0x20
        strb    r0, [r6], #1
        ldr     r3, =BL_LEVEL
        ldrb    r1, [r3]
        mov     r0, r6
        bl      fmt_uint             @ level
        mov     r6, r0
        movs    r0, #0x20
        strb    r0, [r6], #1
        movs    r0, #0x23            @ '#'
        strb    r0, [r6], #1
        mov     r1, r4               @ seq
        mov     r0, r6
        bl      fmt_uint
        mov     r6, r0
        movs    r0, #0
        strb    r0, [r6]             @ null terminate
        @ push paths (status) to the chip so the port-45000 API can read it
        movs    r0, #PUSH_PATHS
        ldr     r3, =QUEUE_CMD
        blx     r3
.Ldone:
        pop     {r3, r4, r5, r6, r7, pc}

@ ---------------------------------------------------------------------------
@ parse_uint(r0=ptr) -> r0=value (<=65535), r1=ptr past the digits. Leaf.
        .thumb_func
parse_uint:
        movs    r2, #0
.Lpu:
        ldrb    r3, [r0]
        subs    r3, #0x30
        cmp     r3, #9
        bhi     .Lpudone
        movs    r1, #10
        mul     r2, r2, r1
        add     r2, r2, r3
        adds    r0, #1
        b       .Lpu
.Lpudone:
        mov     r1, r0
        mov     r0, r2
        bx      lr

@ ---------------------------------------------------------------------------
@ fmt_uint(r0=dest, r1=value 0..255) -> r0=dest past the digits. Decimal,
@ no leading zeros, always at least one digit.
        .thumb_func
fmt_uint:
        push    {r4, r5, r6, lr}
        mov     r4, r0               @ dest
        uxtb    r5, r1               @ val
        movs    r6, #0               @ started
        movs    r2, #100
        udiv    r3, r5, r2
        mul     r1, r3, r2
        subs    r5, r5, r1           @ val %= 100
        cbz     r3, .Lf_t
        adds    r0, r3, #0x30
        strb    r0, [r4], #1
        movs    r6, #1
.Lf_t:
        movs    r2, #10
        udiv    r3, r5, r2
        mul     r1, r3, r2
        subs    r5, r5, r1           @ r5 = units
        cmp     r6, #0
        bne     .Lf_tp
        cbz     r3, .Lf_u
.Lf_tp:
        adds    r0, r3, #0x30
        strb    r0, [r4], #1
.Lf_u:
        adds    r0, r5, #0x30
        strb    r0, [r4], #1
        mov     r0, r4
        pop     {r4, r5, r6, pc}

        .ltorg
