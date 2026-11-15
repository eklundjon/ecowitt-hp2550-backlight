@ Backlight-over-IP payload (v2) for HP2550 console (user.bin V2.0.4). Protocol: see
@ docs/PROTOCOL.md. The BL/BP/BS/DM command set with strict validation and a reject ack.
@ The notes below record how it differs from the earlier internal iterations.
@ Position-independent: all firmware calls go through ldr=abs + blx; all data
@ via ldr=abs. No writes to this (code) region. Mutable state lives only in data
@ RAM (0x1F0xxxx) plus a stack scratch buffer.
@
@ Entry bl_hook replaces the stolen `bl 0x43054` at 0x1ca0e (display loop).
@
@ Mechanics carried over unchanged from v2f: command IN = custom-server Station ID
@ (record +0x4B), status OUT = custom-server password (record +0x74) pushed with 0xAB
@ BEFORE the 0xAA refresh; nothing acted on until a 0xAA reply has landed (REC_VALID);
@ stand-down on screen 24 and on 15 with return-to 24; dedup = "#<seq>" parsed from the
@ RAM status; change-gated push; the status reports the SAVED level (or A under auto).
@
@ v2h changes (over v2g):
@   Strict seq: "#<digits>" must be directly after the first '#', value 1..255 (leading
@   zeros allowed, numeric value used), and end at the NUL. Anything else (#0, #256, #999,
@   "#", #12x, "#5 junk") is no valid seq: no action, status unchanged, no ack.
@   Valid seq + unknown verb / bad value / trailing junk: no action, status last token is
@   "!<seq>". Values are never clamped: BL 0..100 or A; BP, BS, DM exactly 0 or 1 (leading
@   zeros accepted: BL 040 = 40, BP 01 = 1). After the value only " #<seq>" may follow.
@   Dedup reads the status's trailing "#<seq>" or "!<seq>" (r4 bit 8 = rejected marker).
@   Status bytes come only from hardware state + the validated seq + the '#'/'!' marker.
@
@ v2g changes:
@   Commands (one per write, "<VERB> <VALUE> #<seq>"):
@     BL 0..100  saved level := n (clamped to 100), auto off. Power is NOT changed: if
@                the panel is on, brightness_set(n) applies it; if off, only the saved
@                level is stored (backlight_set(1) loads it at the next BP 1).
@     BL A       auto on. No power change, no firmware call.
@     BP 0 / 1   power off / on at the current level: backlight_set(0) / backlight_set(1),
@                the same calls the keypad power key makes. No-op when already in that
@                state (BL_ON_FLAG check).
@     BS 0 / 1   schedule enable.
@     DM 0 / 1   dark mode (1 = dark). CParam+0x6D is inverted (0 = dark): write value^1,
@                then set the home full-redraw flag 0x40038A only when the screen id is 0.
@                The settings-save countdown (0x1F19025) is not touched.
@     Unknown verb, or a known verb with a bad value (anything but digits / A for BL;
@     anything but 0/1 for BP, BS, DM): no action. The seq is still consumed and echoed.
@     BA is gone (unknown verb).
@   Status: "BP <on> BL <lvl|A> BS <sched> DM <dm> #<seq>" (max 26 chars).
@   st_seq accepts a status starting "BP" or "BL" (new or old v2c-v2f format), so an
@   old status already on the chip yields its seq on first boot.
        .syntax unified
        .cpu cortex-m4
        .thumb

        .equ APPLY,      0x43055      @ backlight_apply/PWM fade (thumb)
        .equ BL_SET,     0x43101      @ backlight_set(r0=0/1)    (thumb)
        .equ BRIGHT_SET, 0x430b1      @ brightness_set(r0=0..100)(thumb)
        .equ QUEUE_CMD,  0x4b139      @ queue_wifi_cmd(r0=code)  (thumb)

        .equ CMD_SLOT,   0x1f120cf    @ Station ID string (command in)   record+0x4B
        .equ STATUS_SLOT,0x1f120f8    @ password string (status out)     record+0x74
        .equ THROTTLE,   0x1f12089    @ record+5, free byte (poll countdown)
        .equ REC_VALID,  0x1f1d34c    @ set to 1 by the 0xAA RX handler (0x25bf8); 0 at boot
        .equ SCREEN_ID,  0x1f1145c    @ current screen id (byte); 0 = home
        .equ BL_ON_FLAG, 0x1f23057    @ backlight on flag (byte), written only by backlight_set
        .equ SAVED_LVL,  0x1f190a6    @ CParam+0x16: persistent backlight level
        .equ AUTO_EN,    0x1f190ec    @ CParam+0x5C: auto-brightness enable
        .equ SCHED_EN,   0x1f190eb    @ CParam+0x5B: backlight schedule enable
        .equ DARK_BYTE,  0x1f190fd    @ CParam+0x6D: 0 = dark, 1 = light (inverted)
        .equ REDRAW,     0x40038a     @ full-redraw / screen-init flag (byte)

        .equ SCREEN_CUSTOM, 24        @ Customized server screen id (skip)
        .equ SCREEN_TEXTEDIT, 15      @ shared text-entry screen
        .equ PREV_SCREEN, 0x1f11eb4   @ return-to screen id while on a text-entry screen
        .equ RELOAD,     100          @ poll throttle reload
        .equ REQ_RECORD, 0xaa         @ TX: request custom record from chip
        .equ PUSH_RECORD,0xab         @ TX: push custom record (status) to chip

        .equ V_BAD,      0x1000       @ parse_val: value not usable (decimals saturate at 1000)
        .equ V_AUTO,     0x2000       @ parse_val: value was the letter A
        .equ VERB_BL,    0x424c       @ 'B'<<8|'L'
        .equ VERB_BP,    0x4250
        .equ VERB_BS,    0x4253
        .equ VERB_DM,    0x444d
        .equ TAG_BP,     0x00205042   @ "BP " as a little-endian word
        .equ TAG_BL,     0x00204c42   @ "BL "
        .equ TAG_BS,     0x00205342   @ "BS "
        .equ TAG_DM,     0x00204d44   @ "DM "

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
        push    {r4, r5, r6, r7, lr}
        sub     sp, #32              @ status scratch buffer at sp[0..31]
        @ throttle
        ldr     r7, =THROTTLE
        ldrb    r5, [r7]
        cbz     r5, .Lfire
        subs    r5, #1
        strb    r5, [r7]
        b       .Lret
.Lfire:
        movs    r5, #RELOAD
        strb    r5, [r7]
        @ stand down on the Customized server screen (24) and on the text-entry
        @ screen (15) when it was opened from 24
        ldr     r5, =SCREEN_ID
        ldrb    r5, [r5]
        cmp     r5, #SCREEN_CUSTOM
        beq     .Lret
        cmp     r5, #SCREEN_TEXTEDIT
        bne     .Lgo
        ldr     r5, =PREV_SCREEN
        ldrb    r5, [r5]
        cmp     r5, #SCREEN_CUSTOM
        beq     .Lret
.Lgo:
        @ act only on a command/status pair that came from the chip (REC_VALID)
        ldr     r3, =REC_VALID
        ldrb    r0, [r3]
        cmp     r0, #0
        beq     .Lrefresh
        @ last-handled := "#<seq>" / "!<seq>" of the RAM status (password): r4 = seq,
        @ bit 8 = rejected ('!'); 0x200 if none
        ldr     r0, =STATUS_SLOT
        bl      st_seq
        mov     r4, r0
        @ command seq; the command needs "#<digits>" or it is not a command at all
        ldr     r6, =CMD_SLOT
        mov     r0, r6
        bl      seq_of               @ r0 = cmd seq 1..255, or 256 if no valid seq
        cmp     r0, #256
        bhs     .Lstatus             @ no valid seq: not a command, no ack
        uxtb    r1, r4
        cmp     r0, r1
        beq     .Lstatus             @ seq == last handled (# or !) -> already done, report
        mov     r4, r0               @ consume: acked '#' below, or '!' via .Lreject
        @ verb = two letters, value = parse_val (r5)
        ldrb    r7, [r6]
        ldrb    r0, [r6, #1]
        orr.w   r7, r0, r7, lsl #8
        bl      parse_val
        mov     r5, r0
        movw    r0, #VERB_BL
        cmp     r7, r0
        beq     .Lverb_bl
        movw    r0, #VERB_BP
        cmp     r7, r0
        beq     .Lverb_bp
        movw    r0, #VERB_BS
        cmp     r7, r0
        beq     .Lverb_bs
        movw    r0, #VERB_DM
        cmp     r7, r0
        beq     .Lverb_dm
        b       .Lreject             @ unknown verb (incl. BA) -> rejected

.Lverb_bl:
        cmp     r5, #V_AUTO
        beq     .Lbl_auto
        cmp     r5, #100
        bhi     .Lreject             @ >100 or bad value: rejected, never clamped
        movs    r0, #0
        ldr     r3, =AUTO_EN
        strb    r0, [r3]             @ an explicit level turns auto off
        ldr     r3, =SAVED_LVL
        strb    r5, [r3]             @ persistent level: holds vs the evaluator
        ldr     r3, =BL_ON_FLAG
        ldrb    r0, [r3]
        cbz     r0, .Lstatus         @ off: level stored only, NO backlight call
        mov     r0, r5
        ldr     r3, =BRIGHT_SET
        blx     r3                   @ on: apply now (runtime target := level)
        b       .Lstatus
.Lbl_auto:
        movs    r0, #1
        ldr     r3, =AUTO_EN
        strb    r0, [r3]
        b       .Lstatus

.Lverb_bp:
        cmp     r5, #1
        bhi     .Lreject             @ not 0/1 -> rejected
        ldr     r3, =BL_ON_FLAG
        ldrb    r0, [r3]
        cmp     r0, #0
        it      ne
        movne   r0, #1               @ on flag normalised to 0/1
        cmp     r0, r5
        beq     .Lstatus             @ already in the requested state: no-op
        mov     r0, r5
        ldr     r3, =BL_SET
        blx     r3                   @ backlight_set(0) off / (1) on at current level
        b       .Lstatus

.Lverb_bs:
        cmp     r5, #1
        bhi     .Lreject
        ldr     r3, =SCHED_EN
        strb    r5, [r3]
        b       .Lstatus

.Lverb_dm:
        cmp     r5, #1
        bhi     .Lreject
        eor     r0, r5, #1           @ DM 1 = dark = byte 0
        ldr     r3, =DARK_BYTE
        strb    r0, [r3]
        ldr     r3, =SCREEN_ID
        ldrb    r0, [r3]
        cbnz    r0, .Lstatus         @ not the home screen: byte only, no redraw flag
        movs    r0, #1
        ldr     r3, =REDRAW
        strb    r0, [r3]             @ full redraw (same flag the keypad sets)
        b       .Lstatus

.Lreject:
        orr     r4, r4, #0x100       @ ack marker '!' instead of '#'
.Lstatus:
        @ build "BP <on> BL <lvl|A> BS <sched> DM <dm> #<seq>" into the stack buffer
        mov     r6, sp
        ldr     r1, =TAG_BP
        str     r1, [r6]
        adds    r6, #3
        ldr     r3, =BL_ON_FLAG
        ldrb    r1, [r3]
        mov     r0, r6
        bl      fmt_uint
        mov     r6, r0
        movs    r0, #0x20
        strb    r0, [r6], #1
        ldr     r1, =TAG_BL
        str     r1, [r6]
        adds    r6, #3
        ldr     r3, =AUTO_EN         @ level field is 'A' under auto
        ldrb    r1, [r3]
        cbz     r1, .Lst_num
        movs    r0, #0x41            @ 'A'
        strb    r0, [r6], #1
        b       .Lst_lvl_done
.Lst_num:
        ldr     r3, =SAVED_LVL       @ saved level (stable), not the live fade value
        ldrb    r1, [r3]
        mov     r0, r6
        bl      fmt_uint
        mov     r6, r0
.Lst_lvl_done:
        movs    r0, #0x20
        strb    r0, [r6], #1
        ldr     r1, =TAG_BS
        str     r1, [r6]
        adds    r6, #3
        ldr     r3, =SCHED_EN
        ldrb    r1, [r3]
        mov     r0, r6
        bl      fmt_uint
        mov     r6, r0
        movs    r0, #0x20
        strb    r0, [r6], #1
        ldr     r1, =TAG_DM
        str     r1, [r6]
        adds    r6, #3
        ldr     r3, =DARK_BYTE       @ byte 0 = dark -> DM 1
        ldrb    r1, [r3]
        cmp     r1, #0
        ite     eq
        moveq   r1, #1
        movne   r1, #0
        mov     r0, r6
        bl      fmt_uint
        mov     r6, r0
        movs    r0, #0x20
        strb    r0, [r6], #1
        movs    r0, #0x23            @ '#' applied / nothing new
        tst     r4, #0x100
        it      ne
        movne   r0, #0x21            @ '!' rejected
        strb    r0, [r6], #1
        mov     r1, r4               @ seq (fmt_uint takes the low byte)
        mov     r0, r6
        bl      fmt_uint
        mov     r6, r0
        movs    r0, #0
        strb    r0, [r6]             @ null terminate
        @ change gate: compare buffer (sp) against the status slot (password)
        mov     r6, sp
        ldr     r7, =STATUS_SLOT
.Lcmp:
        ldrb    r0, [r6], #1
        ldrb    r1, [r7], #1
        cmp     r0, r1
        bne     .Lchanged
        cmp     r0, #0
        bne     .Lcmp
        b       .Lrefresh            @ identical -> no write, no push; refresh only
.Lchanged:
        @ guard (redundant with the REC_VALID check at .Lgo, kept as in v2e/v2f)
        ldr     r3, =REC_VALID
        ldrb    r0, [r3]
        cbz     r0, .Lrefresh
        @ copy buffer -> status slot (password), then push the record to the chip
        mov     r6, sp
        ldr     r7, =STATUS_SLOT
.Lcopy:
        ldrb    r0, [r6], #1
        strb    r0, [r7], #1
        cmp     r0, #0
        bne     .Lcopy
        movs    r0, #PUSH_RECORD
        ldr     r3, =QUEUE_CMD
        blx     r3                   @ push first ...
.Lrefresh:
        movs    r0, #REQ_RECORD      @ ... then refresh the record from the chip
        ldr     r3, =QUEUE_CMD
        blx     r3
.Lret:
        add     sp, #32
        pop     {r4, r5, r6, r7, pc}

@ ---------------------------------------------------------------------------
@ parse_val(r6=ptr to command) -> r0 = the value token after "<VERB> ", which must be
@ followed by exactly " #":
@   0..1000  decimal digits (leading zeros ok; larger numbers saturate at 1000)
@   V_AUTO   the single letter A
@   V_BAD    anything else (no space after the verb, no value, trailing junk)
@ Clobbers r0-r3; preserves r4+.
        .thumb_func
parse_val:
        push    {lr}
        ldrb    r1, [r6, #2]
        cmp     r1, #0x20
        bne     .Lpv_bad
        ldrb    r1, [r6, #3]
        cmp     r1, #0x41            @ 'A'
        beq     .Lpv_a
        subs    r2, r1, #0x30
        cmp     r2, #9
        bhi     .Lpv_bad
        adds    r0, r6, #3
        bl      parse_dec            @ r0 = value, r1 = ptr past the digits
        b       .Lpv_end
.Lpv_a:
        adds    r1, r6, #4
        mov.w   r0, #V_AUTO
.Lpv_end:
        ldrb    r2, [r1]
        cmp     r2, #0x20
        bne     .Lpv_bad
        ldrb    r2, [r1, #1]
        cmp     r2, #0x23            @ '#'
        bne     .Lpv_bad
        pop     {pc}
.Lpv_bad:
        movw    r0, #V_BAD
        pop     {pc}

@ ---------------------------------------------------------------------------
@ st_seq(r0=ptr to status) -> r0 = seq (0..255), plus 0x100 if the marker was '!';
@ 0x200 if the text does not start "BP" or "BL" (new / old status format) or has no
@ '#' / '!' followed by digits that fit 0..255. 0x200 has low byte 0, which never equals
@ a command seq (1..255), so "none" means act; fmt_uint prints it as 0. The first '#' or
@ '!' counts. Clobbers r0-r3; preserves r4+.
        .thumb_func
st_seq:
        push    {r4, lr}
        ldrb    r1, [r0]
        cmp     r1, #0x42            @ 'B'
        bne     .Lss_none
        ldrb    r1, [r0, #1]
        cmp     r1, #0x50            @ 'P' (BP: v2g/v2h)
        beq     .Lss_scan
        cmp     r1, #0x4c            @ 'L' (BL: v2c-v2f)
        bne     .Lss_none
.Lss_scan:
        ldrb    r1, [r0], #1
        cbz     r1, .Lss_none
        cmp     r1, #0x23            @ '#'
        beq     .Lss_got
        cmp     r1, #0x21            @ '!'
        bne     .Lss_scan
.Lss_got:
        mov     r4, r1               @ marker
        ldrb    r1, [r0]
        subs    r1, #0x30
        cmp     r1, #9
        bhi     .Lss_none            @ marker not followed by a digit
        bl      parse_dec
        cmp     r0, #255
        bhi     .Lss_none
        cmp     r4, #0x21
        it      eq
        orreq   r0, r0, #0x100       @ rejected
        pop     {r4, pc}
.Lss_none:
        mov.w   r0, #0x200
        pop     {r4, pc}

@ ---------------------------------------------------------------------------
@ seq_of(r0=ptr to command) -> r0 = the seq after the first '#': decimal digits directly
@ after it, value 1..255 (leading zeros ok), then the NUL. 256 otherwise (no '#', no
@ digit, #0, >255, trailing characters). Clobbers r1-r3; preserves r4+.
        .thumb_func
seq_of:
        push    {r4, lr}
        mov     r4, r0
.Lso:
        ldrb    r0, [r4], #1
        cbz     r0, .Lso_none
        cmp     r0, #0x23            @ '#'
        bne     .Lso
        ldrb    r0, [r4]
        subs    r0, #0x30
        cmp     r0, #9
        bhi     .Lso_none            @ '#' not followed by a digit
        mov     r0, r4
        bl      parse_dec
        ldrb    r2, [r1]
        cbnz    r2, .Lso_none        @ must end at the NUL
        cbz     r0, .Lso_none        @ #0
        cmp     r0, #255
        bhi     .Lso_none
        pop     {r4, pc}
.Lso_none:
        mov.w   r0, #256
        pop     {r4, pc}


@ ---------------------------------------------------------------------------
@ parse_dec(r0=ptr) -> r0=value saturating at 1000, r1=ptr past the digits. Leaf.
        .thumb_func
parse_dec:
        movs    r2, #0
.Lpd:
        ldrb    r3, [r0]
        subs    r3, #0x30
        cmp     r3, #9
        bhi     .Lpddone
        movs    r1, #10
        mul     r2, r2, r1
        add     r2, r2, r3
        cmp     r2, #1000
        it      hi
        movhi   r2, #1000
        adds    r0, #1
        b       .Lpd
.Lpddone:
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
