        GET     hdr.include
        GET     ARMLib:hdr.list
        GET     ARMLib:hdr.flags

        AREA    |Module$$CODE|, CODE, READONLY, PIC

        EXPORT  init_device
        EXPORT  fini_device


;----------------------------------------------------------------------------
; init_device
;
; => ws => Module's workspace
; <= r0-r7, CZNV corrupted, On error r0 => Error block, else r0 = 0.
;
; Registers with DeviceFS, unless module not present, in which case no action
; is taken (as DeviceFS will announce itself when it initialises, at which
; time any modules may register devices).

init_device
        stmfd   sp!,{r4-r7,lr}
        mov     r0,#0                           ; Flags (Single duplex, char)
        adr     r1,devices                      ; => List of devices
        adr     r2,device_driver                ; => Device driver code
        mov     r3,#0                           ; Passed to driver r8
        mov     r4,ws                           ; Passed to driver r12
        mov     r5,#0                           ; Special spec (custom)
        mov     r7,#&7f000000                   ; Unlimited TX
        mov     r6,#0                           ; No RX.
        swi     XDeviceFS_Register
        strvc   r0,[ws,#ws_devicefs_id]
        movvc   r1,#1
        strvcb  r1,[ws,#ws_device_registered]   ; Mark as registered
        movvc   r0,#0
        ldmvcfd sp!,{r4-r7,pc}

        ldr     r1,[r0]                         ; Error code
        mov     r2,#400                         ; r2 = 486 (SWI Not Known)
        add     r2,r2,#86                       ; error code. Just exit
        teq     r1,r2                           ; cleanly if no DeviceFS.
        moveq   r0,#0                           ; Will be initialised
        ldmfd   sp!,{r4-r7,pc}                  ; when DeviceFS is started..

;----------------------------------------------------------------------------
; devicefs_deregister
;
; => r12 => Module's workspace
;
; <= r0-r7, CZNV corrupted, On error r0 => Error block; else r0 = 0

fini_device
        ldrb    r0,[ws,#ws_device_registered]   ; If not active, don't bother
        teq     r0,#0
        moveq   pc,lr

        ldr     r0,[ws,#ws_streams]             ; Error if there are still
        teq     r0,#0                           ; open streams.
        adrnel  r0,e_module_in_use
        movne   pc,lr

        mov     r1,r14
        ldr     r0,[ws,#ws_devicefs_id]
        swi     XDeviceFS_Deregister            ; Deregister and mark as
        movvc   r0,#0                           ; unregistered if all went
        strvcb  r0,[ws,#ws_device_registered]   ; well
        mov     pc,r1

e_module_in_use
    Err     ErrModuleInUse, "Module in use (streams open)"

;----------------------------------------------------------------------------
; device info

devices
        DCD     device_name - devices           ; Offset to device name
        DCD     2                               ; Flags (~Buffered, path)
        DCD     0                               ; Default RX buffer flags
        DCD     0                               ; Default RX buffer size
        DCD     0                               ; Default TX buffer flags
        DCD     0                               ; Default TX buffer size
        DCD     0                               ; Reserved, 0
        DCD     0                               ; End of devices list

device_name
        DCB     "SysLog",0
        ALIGN

;----------------------------------------------------------------------------
; Device driver entry point
;
; => r0  =  reason code, r1-r7 depend on r0
;    r8  => Private word (as passed to register call)
;    r12 => workdpace pointer (as passed to register call)
;
; <=  r0 preserved, or V set and r0=>Error block to return error
;     r1 preserved.
;     All named registers preserved.

device_driver
        cmp     r0,#(jump_table_end-jump_table_start)/4
        addlo   pc,pc,r0,lsl #2
        mov     pc,lr

jump_table_start
        b       dev_open                        ; 0  - Open device
        b       dev_close                       ; 1  - Close device
        b       dev_wakeup_for_tx               ; 2  - Wakeup for TX
        mov     pc,lr                           ; 3  - Wakeup for RX
        mov     pc,lr                           ; 4  - Sleep for RX
        mov     pc,lr                           ; 5  - Enumerate directory
        mov     pc,lr                   ; 6  - Create TX buffer
        mov     pc,lr                           ; 7  - Create RX buffer
        mov     pc,lr                           ; 8  - Halt buffer filling
        mov     pc,lr                           ; 9  - Resume, after halt
        mov     pc,lr                       ; 10 - Check for EOF
        mov     pc,lr                           ; 11 - Stream created
jump_table_end

;----------------------------------------------------------------------------
; Initialise device driver
; => r0  =  0
;    r2  =  DeviceFS stream handle for this stream
;    r3  =  Flags: b0=0 => RX, b0=1 => TX
;    r6  => Special field control blk, ptr remains valid until stream closed
;    r8  => Private word (as passed to register)
;    r12 => workspace pointer (as passed to register)
;
; <= r2  =  My stream handle, not zero.

dev_open
        stmfd   sp!,{r1,r3,r4,lr}

        mov     r4,r2                           ; r4 = DeviceFS stream handle
        mov     r0,#6
        mov     r3,#sb_size
        swi     XOS_Module
        movvs   r2,r4
        bvs     dev_open_exit

        mov     sb,r2                           ; sb => Stream block
        str     r4,[r2,#sb_devicefs_id]         ; DeviceFS stream handle

        mov     r0,#64                          ; Default priority
        str     r0,[sb,#sb_priority]
        mov     r0,#0
        strb    r0,[sb,#sb_logname]             ; Empty name.
        str     r0,[sb,#sb_logline_size]        ; No bytes in line buffer

        bl      dev_open_read_args              ; Read logname and return
        ldrb    r0,[sb,#sb_logname]             ; error if it was not
        teq     r0,#0                           ; set.
        adreql  r0,e_bad_parameters
        beq     dev_open_error

        ldrne   r0,[sb,#sb_priority]            ; Clip prioity to 255.
        cmp     r0,#255
        movhi   r0,#255
        strhi   r0,[sb,#sb_priority]

        LInsert ws,ws_streams,sb,r3,r4          ; Insert into streams list

        mov     r0,#0                           ; Preserve r0.
        mov     r2,sb
dev_open_exit
        ldmfd   sp!,{r1,r3,r4,pc}

dev_open_error
        mov     r4,r0                           ; r4 => Error block
        mov     r0,#7
        mov     r2,sb
        swi     XOS_Module
        mov     r0,r4
        SetErr
        b       dev_open_exit

e_bad_parameters
    Err     ErrBadParams, "Special field invalid: need log=<name>"

;----------------------------------------------------------------------------
; dev_open_read_args
;
; => r6 => Special field/0 if none.
;
; <= r0-r3, vcnz undefined (no errors are returned).
;    Fills in sb_priority and sb_logname if present in special field.
;
; DeviceFS does not yet support the /G special field argument type, so need
; custom code to parse the special field. Looks for log=<logname> and
; priority=<number>. Must skip over stuff we don't understand as DeviceFS
; interprets some for itself.
dev_open_read_args
        stmfd   sp!,{r6,lr}
        teq     r6,#0
        ldmeqfd     sp!,{r6,pc}
dev_open_read_args_arg_start                    ; r6 => Start of name
        adr     r1,arg_log
        bl      dev_open_read_args_arg_compare
        teq     r0,#0
        bne     dev_open_read_args_log
        adr     r1,arg_priority
        bl      dev_open_read_args_arg_compare
        teq     r0,#0
        bne     dev_open_read_args_priority
dev_open_read_args_find_next_arg
        ldrb    r14,[r6],#1                     ; Find next ';', ':'
        teq     r14,#':'                        ; or 0-31 control
        cmpne   r14,#31                         ; character. Exit if
        ldmlsfd sp!,{r6,pc}                     ; not a ';'.
        teq     r14,#';'
        bne     dev_open_read_args_find_next_arg
        b       dev_open_read_args_arg_start

; => r1 => LC keyword, r6 => Bit of special field to compare
; <= r0 = 0 if no match, else to => value (in special field)
dev_open_read_args_arg_compare
        mov     r0,r6                           ; r0 => Special field pos
dev_open_read_args_arg_compare_loop
        ldrb    r2,[r0],#1                      ; r2 = Char from special
        cmp     r2,#'A'                         ; field, Converted into
        addhs   r2,r2,#32                       ; lower case.
        cmphs   r2,#'z'+1
        subhs   r2,r2,#32
        ldrb    r3,[r1],#1                      ; r3 = Char to compare with
        teq     r2,r3
        movne   r0,#0
        movne   pc,lr
        teq     r3,#'='
        bne     dev_open_read_args_arg_compare_loop
        mov     pc,lr

arg_log
        DCB     "log="
arg_priority
        DCB     "priority="
        ALIGN

; => r0 => Priority no as string
dev_open_read_args_priority
        mov     r1,r0                           ; r1 => String to convert
        mov     r0,#10                          ; Default to base 10
        swi     XOS_ReadUnsigned
        strvc   r2,[sb,#sb_priority]
        movvc   r6,r1                           ; r6 => Terminating char
        b       dev_open_read_args_find_next_arg

; => r0 => Logname string
dev_open_read_args_log
        add     r1,sb,#sb_logname               ; r1 => Buffer for string
        add     r2,sb,#sb_logname_end           ; r2 => End of buffer
dev_open_read_args_copy_log
        cmp     r1,r2
        bhs     dev_open_read_args_find_next_arg
        ldrb    r3,[r0],#1
        teq     r3,#':'
        teqne   r3,#';'
        cmpne   r3,#32
        movlss  r3,#0                           ; EQ <=> At end of string.
        strb    r3,[r1],#1
        bne     dev_open_read_args_copy_log
        sub     r6,r0,#1                        ; r6 => Terminator
        b       dev_open_read_args_find_next_arg

;----------------------------------------------------------------------------
; Finalise device driver
; => r0  =  1
;    r2  =  My stream handle for this stream or 0 for all streams

dev_close
        teq     r2,#0
        beq     dev_close_all
dev_close2
        stmfd   sp!,{r0-r2,lr}
        mov     sb,r2

        LRemove ws,ws_streams,r2,r0,r14         ; Remove from streams list

        add     r1,sb,#sb_logline
        ldr     r2,[sb,#sb_logline_size]
        teq     r2,#0
        movne   r14,#0
        strneb  r14,[r1,r2]
        ldrne   r2,[sb,#sb_priority]
        addne   r0,sb,#sb_logname
        swine   XSysLog_LogMessage

        add     r0,sb,#sb_logname               ; Flush log
        swi     XSysLog_FlushLog

        mov     r0,#7                           ; Free memory
        mov     r2,sb
        swi     XOS_Module

        ClrErr
        ldmfd   sp!,{r0-r2,pc}

dev_close_all
        stmfd   sp!,{r2,lr}
dev_close_all_loop
        ldr     r2,[ws,#ws_streams]
        teq     r2,#0
        beq     dev_close_all_exit
        bl      dev_close2
        b       dev_close_all_loop
dev_close_all_exit
        ldmfd   sp!,{r2,pc}

;----------------------------------------------------------------------------
; Wakeup for TX
;
; => r0  =  2
;    r2  =  My stream handle for this stream or 0 for all streams
;
; <= r0  =  0 To remain dormant, 2 if ready to if ready to transmit.
dev_wakeup_for_tx
        stmfd   sp!,{r0-r2,lr}
        mov     sb,r2
        ldr     r1,[sb,#sb_devicefs_id]
        swi     XDeviceFS_TransmitCharacter         ; r0 = Byte to write
        bvs     dev_wakeup_for_tx_exit
        bcs     dev_wakeup_for_tx_exit

        add     r1,sb,#sb_logline                   ; r1 => Start of buffer
        ldr     r2,[sb,#sb_logline_size]            ; r2 = Bytes buffered.

        cmp     r0,#31
        movles  r0,#0                               ; EQ => End of line
        teqeq   r2,#0
        beq     dev_wakeup_for_tx_exit              ; Filter empty lines.

        strb    r0,[r1,r2]
        add     r2,r2,#1
        teq     r2,#sb_logline_end - sb_logline
        teqne   r0,#0
        strne   r2,[sb,#sb_logline_size]
        bne     dev_wakeup_for_tx_exit

        mov     r0,#0
        strb    r0,[r1,r2]                          ; Terminate string
        str     r0,[sb,#sb_logline_size]            ; Flush buffer

        add     r0,sb,#sb_logname                   ; Write string
        ldr     r2,[sb,#sb_priority]
        swi     XSysLog_LogMessage
        ClrErr

dev_wakeup_for_tx_exit
        ldmfd   sp!,{r0-r2,pc}

;----------------------------------------------------------------------------
        END
