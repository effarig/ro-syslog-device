    GET     hdr.include
    GET     armlib:hdr.flags
    GET     armlib:hdr.initlist

    AREA    |!!!Module$$Header|, CODE, READONLY, PIC

    IMPORT  |__RelocCode|
    IMPORT  init_device
    IMPORT  fini_device

    ENTRY

module_base
    DCD     0                               ; Start address
    DCD     module_init     - module_base   ; Initialise code
    DCD     module_die      - module_base   ; Finalise code
    DCD     module_service  - module_base   ; Service call handler
    DCD     module_title    - module_base   ; Title
    DCD     module_help_str - module_base   ; Infomation string
    DCD     0                               ; CLI command table
    DCD     0                               ; SWI base
    DCD     0                               ; SWI names table
    DCD     0                               ; SWI handler
    DCD     0                               ; SWI decoding code
    DCD     0                               ; Messages filename
    DCD     module_flags    - module_base   ; Module flags

module_title
    DCB     "SysLogDevice",0

module_help_str
    DCB     "SysLog Device",9
    DCB     "1.00 ($date) © James Peacock",0
    ALIGN

module_flags
    DCD     1               ; 32-bit compatible

;----------------------------------------------------------------------------
; Module initialisation/finalisation
;----------------------------------------------------------------------------

module_init
    stmfd   sp!,{r8,lr}
    bl      |__RelocCode|
    mov     r8,r12                      ; r8 => Module private word

    ldr     ws,[r8]
    teq     ws,#0
    ldmnefd sp!,{r8,pc}

    adr     r0,module_initlist
    bl      initlist_initialise         ; r0 = 0: No error
    teq     r0,#0                       ; r0 = 1: Error:
    bne     module_init_failed          ;   r1 = 0: Tidied up OK
    str     r1,[ws,#ws_init_count]      ;   r1 <>0: Couldn't clean up
    ClrErr
    ldmfd   sp!,{r8,pc}

module_init_failed
    teq     r1,#0                       ; If was unable to uninit
    bne     module_init_cant_die        ; cleanly, module can't die
    SetErr                              ; otherwise, make sure V is
    ldmfd   sp!,{r8,pc}                 ; set and return the error.

module_init_cant_die                    ; Module partially init'ed,
    str     r1,[ws,#ws_init_count]      ; but couldn't uninit'
    mov     r1,#1                       ; properly, so mark module
    strb    r1,[ws,#ws_module_broken]   ; as broken return no error.
    ClrErr
    ldmfd   sp!,{r8,pc}

module_die
    stmfd   sp!,{r8,lr}
    mov     r8,r12                      ; r8 => Module private word
    ldr     ws,[r12]                    ; If there is no workspace,
    teq     ws,#0                       ; just exit.
    ldmeqfd sp!,{r8,pc}

    mov     r0,#1                       ; Mark module as broken, as
    strb    r0,[ws,#ws_module_broken]   ; will exit or be broken.

    adr     r0,module_initlist          ; Attempt to uninitialise
    ldr     r1,[ws,#ws_init_count]      ; any remaining initialised
    bl      initlist_finalise           ; bits. If this wasn't
    teq     r0,#0                       ; possible mark as broken and
    bne     module_die_failed           ; return an error.

    ClrErr                              ; Otherwise tidied up OK, so
    ldmfd   sp!,{r8,pc}                 ; exit.

module_die_failed
    str     r1,[ws,#ws_init_count]
    SetErr
    ldmfd   sp!,{r8,pc}

module_initlist
    InitListStart
    InitListEntry   init_workspace,  fini_workspace
    InitListEntry   init_device,     fini_device
    InitListEnd

init_workspace
    stmfd   sp!,{lr}
    mov     r0,#6
    mov     r3,#ws_size
    swi     XOS_Module
    strvc   r2,[r8]
    movvc   ws,r2
    movvc   r0,#0
    strvcb  r0,[ws,#ws_module_broken]
    strvcb  r0,[ws,#ws_device_registered]
    strvc   r0,[ws,#ws_streams]
    ldmfd   sp!,{pc}

fini_workspace
    stmfd   sp!,{lr}
    mov     r0,#7
    mov     r2,ws
    swi     XOS_Module          ; Always ignore errors here
    mov     r0,#0               ; should never happen, but
    ldmfd   sp!,{pc}            ; causes no harm.

;----------------------------------------------------------------------------
; Service Call handler
;----------------------------------------------------------------------------
; =>  r1 =  Service number
;    r12 => Module private word
;    r13 => Stack
;
; <=  r1 =  0 To Claim service.
;    r12 May be corrupted
module_service
    teq     r1,#Service_DeviceFSStarting
    teqne   r1,#Service_DeviceFSDying
    movne   pc,lr

    ldr     ws,[r12]
    teq     ws,#0
    moveq   pc,lr

    teq     r1,#Service_DeviceFSDying
    beq     service_devicefs_dying

; DeviceFS module newly loaded/reinitialised and wants potential device
; drivers to register themselves...
service_devicefs_starting
    stmfd   sp!,{r0-r3,lr}
    ldrb    r0,[ws,#ws_module_broken]
    teq     r0,#0
    ldreqb  r0,[ws,#ws_device_registered]
    teqeq   r0,#0
    bleq    init_device
    ldmfd   sp!,{r0-r3,pc}

; DeviceFS is about to die. It has closed all open streams and deregistered
; any devices. Mark as inactive.
service_devicefs_dying
    stmfd   sp!,{lr}
    mov     lr,#0                           ; Mark as inactive
    strb    lr,[ws,#ws_device_registered]
    ldmfd   sp!,{pc}
;----------------------------------------------------------------------------

    END
