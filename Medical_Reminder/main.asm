     LIST    P=16F877A, R=DEC
        #include <p16f877a.inc>
        __CONFIG H'3F31'  


LCD_RS  equ     0                       ; RC0 -> LCD RS
LCD_E   equ     1                       ; RC1 -> LCD E
LED1    equ     0                       ; RB0 -> Medicine 1 LED
LED2    equ     1                       ; RB1 -> Medicine 2 LED
LED3    equ     2                       ; RB2 -> Medicine 3 LED
BUZZER  equ     3                       ; RB3 -> buzzer
ACK_BTN equ     4                       ; RB4 -> acknowledgment button, active LOW

; Timer0 settings for 4 MHz
TMR0_PRELOAD      equ     6                    ; Timer0 overflows every 8 ms with this + 1:32 prescale
TICKS_PER_SECOND  equ     125                   ; Timer0 overflows per real second (1000ms/8ms)
SIM_SPEED         equ     60                    ; sim seconds banked per tick: 60 = 1 real s = 1 sim min
BLINK_TICKS       equ     31            ; about 250 ms with an 8 ms Timer0 overflow
MISS_SECONDS      equ     8             ; real seconds -> Dose Missed (independent of SIM_SPEED)
CLOCK_TICK        equ     0             ; clock_flag bit: set by the ISR each time a minute changes
MISSED_BIT        equ     1             ; clock_flag bit: set by the ISR when the 20 s Ack window ends
ACK_READY_BIT     equ     0             ; ack_ready bit: 1 once the button has been seen released

; Bank 0 RAM
        cblock  0x20
        dly_ms                          ; DelayMs: milliseconds remaining
        dly_lo                          ; DelayMs: inner loop counter
        dly50                           ; Delay50us: loop counter
        wait_cnt                        ; Delay250xN: number of 250 ms chunks left
        lcd_rs                          ; current RS level to send (0=cmd, 1=char)
        lcd_tmp                         ; LCD_WriteByte: byte being sent
        msg_ptr                         ; LCD_PrintMsg: index into the message table
        pb_val                          ; LCD_PrintBin2: remainder after removing tens
        pb_tens                         ; LCD_PrintBin2: tens digit being counted
        pt_h                            ; LCD_PrintTime: hour to print
        pt_m                            ; LCD_PrintTime: minute to print
        hour                            ; live clock: 0-23
        minutes                         ; live clock: 0-59
        remh:3                          ; the 3 medicines' reminder hour
        remm:3                          ; the 3 medicines' reminder minute
        idx                             ; (currently unused)
        val_h                           ; Enter_HHMM result: validated hour
        val_m                           ; Enter_HHMM result: validated minute
        ent:4                           ; the 4 digits being typed (H H M M), as ASCII
        ndig                            ; how many of the 4 digits have been entered
        prompt_id                       ; which Enter_HHMM screen: 0=clock, 1..3=medicine
        key                             ; last key returned by Keypad_GetKey
        tA                              ; AsciiPair: first digit in/out
        tB                              ; AsciiPair: second digit in/out
        tmp                             ; general scratch (AsciiPair, Buzz_Tone)
        tmp2                            ; general scratch (AsciiPair, Buzz_Tone)
        kpat                            ; Keypad_Scan: which row is currently driven low
        krow                            ; Keypad_Scan: row being tested (0-3)
        kcol                            ; Keypad_Scan: column bits read back
        kc                              ; Keypad_Scan: column index (0-2)
        kraw                            ; Keypad_GetKey: raw scan result being debounced
        kidx                            ; Keypad_Scan: row*4+col result (0-255=none)
        ktmp                            ; Keypad_GetKey: release-wait scratch
        lcd_n                           ; LCD_Nibble: the 4-bit value being sent
        ptmp                            ; Rows_Write: new PORTD row bits
        krel_cnt                        ; Keypad_GetKey: release-wait timeout counter
        clock_acc                      ; Timer0 phase accumulator for simulated seconds
        sim_seconds                    ; simulated seconds 0..59
        reminder_acc                   ; timeout phase accumulator, starts at reminder activation
        reminder_elapsed               ; simulated seconds since the active reminder started
        clock_flag                      ; bit0=CLOCK_TICK, bit1=MISSED_BIT (set by the ISR)
        portb_out                      ; shadow for RB0-RB3 outputs
        pending_flags                  ; bits 0..2 = medicines waiting to be serviced
        done_flags                     ; bits 0..2 = medicines already reminded today
        reminder_active                ; 0 = none, 1..3 = active medicine
        blink_count                     ; ISR: counts ticks up to BLINK_TICKS to time the LED blink
        ack_ready                      ; bit 0: ACK was released after reminder started
        msg_sel                        ; message shown by Finish_Reminder
        now_h                           ; Snapshot_Time: hour at the moment of the snapshot
        now_m                           ; Snapshot_Time: minute at the moment of the snapshot
        now_done                       ; snapshot of done_flags for a consistent LCD update
        next_h                          ; Find_Next_Reminder result: hour to show
        next_m                          ; Find_Next_Reminder result: minute to show
        next_med                        ; Find_Next_Reminder result: medicine number (0=none found yet)
        cand_h                          ; Find_Next_Reminder: candidate hour being considered
        cand_m                          ; Find_Next_Reminder: candidate minute being considered
        cand_med                        ; Find_Next_Reminder: candidate medicine number
        endc

; Common RAM for interrupt context
        cblock  0x70
        w_temp
        status_temp
        pclath_temp
        endc

; Reset vector
        org     0x0000
        goto    Main

; Interrupt vector
        org     0x0004
; ISR: fires every ~8 ms; advances the clock, blinks the LED, times the Ack window
ISR:
        movwf   w_temp
        swapf   STATUS,w                ; SWAPF doesn't touch STATUS, so this is safe
        movwf   status_temp
        movf    PCLATH,w
        movwf   pclath_temp
        clrf    PCLATH                  ; PCLATH=0 so the ISR's own CALLs stay in page 0

        bcf     STATUS,RP0
        bcf     STATUS,RP1

        btfss   INTCON,T0IF
        goto    ISR_Done

        movlw   TMR0_PRELOAD
        movwf   TMR0
        bcf     INTCON,T0IF

        ; No CALL used here - keeps the hardware stack safe from the ISR
        movf    reminder_active,f
        btfsc   STATUS,Z
        goto    ISR_Clock               ; no reminder active - skip straight to the clock
        incf    blink_count,f
        movlw   BLINK_TICKS
        xorwf   blink_count,w
        btfss   STATUS,Z                ; only every BLINK_TICKS-th tick (~250 ms) toggles the LED
        goto    ISR_ReminderTime
        clrf    blink_count

        ; pick which LED bit to flip based on which medicine is active
        movf    reminder_active,w
        xorlw   1
        btfsc   STATUS,Z
        goto    ISR_Blink1
        movf    reminder_active,w
        xorlw   2
        btfsc   STATUS,Z
        goto    ISR_Blink2
        movlw   b'00000100'             ; medicine 3 -> LED3 bit
        goto    ISR_DoBlink
ISR_Blink1:
        movlw   b'00000001'             ; medicine 1 -> LED1 bit
        goto    ISR_DoBlink
ISR_Blink2:
        movlw   b'00000010'             ; medicine 2 -> LED2 bit
ISR_DoBlink:
        xorwf   portb_out,f             ; flip just that LED bit in the shadow register...
        movf    portb_out,w
        movwf   PORTB                   ; ...then write the whole shadow out to the real port

        ; reminder_acc: +1 per tick, "overflows" every TICKS_PER_SECOND -> 1 real second
ISR_ReminderTime: 
        btfsc   clock_flag,MISSED_BIT
        goto    ISR_Clock
        movlw   1
        addwf   reminder_acc,f
        movlw   TICKS_PER_SECOND
        subwf   reminder_acc,w
        btfss   STATUS,C
        goto    ISR_Clock
        movwf   reminder_acc
        incf    reminder_elapsed,f
        movlw   MISS_SECONDS
        xorwf   reminder_elapsed,w
        btfsc   STATUS,Z
        bsf     clock_flag,MISSED_BIT

        ; clock_acc: +SIM_SPEED per tick -> "simulated second" scales with SIM_SPEED
ISR_Clock:
        movlw   SIM_SPEED
        addwf   clock_acc,f
        movlw   TICKS_PER_SECOND
        subwf   clock_acc,w
        btfss   STATUS,C
        goto    ISR_Done                ; not a full simulated second yet
        movwf   clock_acc

        incf    sim_seconds,f
        movlw   60
        xorwf   sim_seconds,w
        btfss   STATUS,Z
        goto    ISR_Done                ; not a full simulated minute yet

        ; One simulated minute has passed. The clock itself is updated in the ISR.
        clrf    sim_seconds
        incf    minutes,f
        movlw   60
        xorwf   minutes,w
        btfss   STATUS,Z
        goto    ISR_MinuteChanged       ; no hour rollover this time

        clrf    minutes
        incf    hour,f
        movlw   24
        xorwf   hour,w
        btfss   STATUS,Z
        goto    ISR_MinuteChanged       ; no day rollover this time

        ; New day. Clear daily completion before checking the 00:00 reminders.
        clrf    hour
        clrf    done_flags 

ISR_MinuteChanged:
        bsf     clock_flag,CLOCK_TICK   ; tells the main loop "redraw the idle screen"

        ; queues any medicine matching hour:minutes; done_flags stops repeats
        btfsc   done_flags,0
        goto    ISR_CR_Med2
        movf    remh,w
        xorwf   hour,w
        btfss   STATUS,Z
        goto    ISR_CR_Med2
        movf    remm,w
        xorwf   minutes,w
        btfss   STATUS,Z
        goto    ISR_CR_Med2
        bsf     pending_flags,0
        bsf     done_flags,0

ISR_CR_Med2:
        btfsc   done_flags,1
        goto    ISR_CR_Med3
        movf    remh+1,w
        xorwf   hour,w
        btfss   STATUS,Z
        goto    ISR_CR_Med3
        movf    remm+1,w
        xorwf   minutes,w
        btfss   STATUS,Z
        goto    ISR_CR_Med3
        bsf     pending_flags,1
        bsf     done_flags,1

ISR_CR_Med3:
        btfsc   done_flags,2
        goto    ISR_Done
        movf    remh+2,w
        xorwf   hour,w
        btfss   STATUS,Z
        goto    ISR_Done
        movf    remm+2,w
        xorwf   minutes,w
        btfss   STATUS,Z
        goto    ISR_Done
        bsf     pending_flags,2
        bsf     done_flags,2

ISR_Done:
        movf    pclath_temp,w
        movwf   PCLATH
        swapf   status_temp,w
        movwf   STATUS
        swapf   w_temp,f
        swapf   w_temp,w
        retfie

; Check_Reminders: set pending bits for all medicines matching hour:minutes.
; A medicine is marked done when it is reminded (not when it is acknowledged),
; so a 23:59 reminder answered after midnight is still active for the new day.
Check_Reminders:
        btfsc   done_flags,0
        goto    CR_Med2
        movf    remh,w
        xorwf   hour,w
        btfss   STATUS,Z
        goto    CR_Med2
        movf    remm,w
        xorwf   minutes,w
        btfss   STATUS,Z
        goto    CR_Med2
        bsf     pending_flags,0
        bsf     done_flags,0

CR_Med2:
        btfsc   done_flags,1
        goto    CR_Med3
        movf    remh+1,w
        xorwf   hour,w
        btfss   STATUS,Z
        goto    CR_Med3
        movf    remm+1,w
        xorwf   minutes,w
        btfss   STATUS,Z
        goto    CR_Med3
        bsf     pending_flags,1
        bsf     done_flags,1

CR_Med3:
        btfsc   done_flags,2
        return
        movf    remh+2,w
        xorwf   hour,w
        btfss   STATUS,Z
        return
        movf    remm+2,w
        xorwf   minutes,w
        btfss   STATUS,Z
        return
        bsf     pending_flags,2
        bsf     done_flags,2
        return

; LED control subroutines
LED_Active_On:
        bcf     portb_out,LED1
        bcf     portb_out,LED2
        bcf     portb_out,LED3

        movf    reminder_active,w
        xorlw   1
        btfsc   STATUS,Z
        bsf     portb_out,LED1
        movf    reminder_active,w
        xorlw   2
        btfsc   STATUS,Z
        bsf     portb_out,LED2
        movf    reminder_active,w
        xorlw   3
        btfsc   STATUS,Z
        bsf     portb_out,LED3

        movf    portb_out,w
        movwf   PORTB
        return

LEDs_Off:
        bcf     portb_out,LED1
        bcf     portb_out,LED2
        bcf     portb_out,LED3
        movf    portb_out,w
        movwf   PORTB
        return

; Buzzer control subroutines
Buzzer_On:                              ; steady ON (used only for a moment - Buzz_Tone drives it after)
        bsf     portb_out,BUZZER
        movf    portb_out,w
        movwf   PORTB
        return

Buzzer_Off:
        bcf     portb_out,BUZZER
        movf    portb_out,w
        movwf   PORTB
        return

; Buzz_Tone: called each pass of Loop_Active; toggles the buzzer to make an
; actual tone. Pulse length depends on reminder_active -> different pitch per medicine
Buzz_Tone:
        movf    reminder_active,w
        xorlw   1
        btfsc   STATUS,Z
        goto    BT_Med1
        movf    reminder_active,w
        xorlw   2
        btfsc   STATUS,Z
        goto    BT_Med2
        goto    BT_Med3
BT_Med1:
        movlw   12                      ; ~12 x 50us half-period -> lower pitch
        goto    BT_Run
BT_Med2:
        movlw   9
        goto    BT_Run
BT_Med3:
        movlw   6                       ; shortest half-period -> highest pitch
BT_Run:
        movwf   tmp                     ; tmp = half-period length, in Delay50us units
        bsf     portb_out,BUZZER
        movf    portb_out,w
        movwf   PORTB
        call    BT_Wait
        bcf     portb_out,BUZZER
        movf    portb_out,w
        movwf   PORTB
        call    BT_Wait
        return
BT_Wait:                                ; waits tmp x ~50us
        movf    tmp,w
        movwf   tmp2
BT_WaitLoop:
        call    Delay50us
        decfsz  tmp2,f
        goto    BT_WaitLoop
        return

; Main program
Main:
        ; PORTB: RB0-RB2 LEDs, RB3 buzzer, RB4 ACK button
        ; PORTC: RC0-RC1 LCD control, RC2-RC4 keypad columns
        ; PORTD: RD0-RD3 LCD data, RD4-RD7 keypad rows

        bsf     STATUS,RP0
        movlw   0x06
        movwf   ADCON1                  ; all pins digital

        clrf    TRISD                   ; LCD data + keypad rows are outputs

        movlw   b'11110000'
        movwf   TRISB                   ; RB0-RB3 outputs, RB4-RB7 inputs

        movlw   b'00011100'
        movwf   TRISC                   ; RC0-RC1 outputs, RC2-RC4 inputs

        movlw   b'01111111'
        movwf   OPTION_REG              ; Timer_Init changes Timer0 settings later

        bcf     STATUS,RP0

        clrf    portb_out
        clrf    PORTB                   ; LEDs and buzzer OFF
        clrf    PORTC
        movlw   0xFF
        movwf   PORTD                   ; keypad rows released

        
        call    LCD_Init
        movlw   MsgWelcome-MsgBase
        call    LCD_PrintMsg
        call    LCD_Line2
        movlw   MsgMedRem-MsgBase
        call    LCD_PrintMsg
        movlw   8
        call    Delay250xN              ; 2 seconds

        
        clrf    prompt_id                ; 0 = "Set Current Time" screen
        call    Enter_HHMM
        movf    val_h,w
        movwf   hour
        movf    val_m,w
        movwf   minutes

        ; Ask for each medicine's reminder time in turn (prompt_id 1, 2, 3).
        ; remh/remm are indexed via FSR so this one loop fills all 3 slots:
        ; prompt_id 1 -> remh[0]/remm[0], prompt_id 2 -> remh[1]/remm[1], etc.
        movlw   1
        movwf   prompt_id
SetLoop:
        call    Enter_HHMM
        movlw   remh-1
        addwf   prompt_id,w
        movwf   FSR
        movf    val_h,w
        movwf   INDF
        movlw   remm-1
        addwf   prompt_id,w
        movwf   FSR
        movf    val_m,w
        movwf   INDF
        incf    prompt_id,f
        movlw   4
        xorwf   prompt_id,w
        btfss   STATUS,Z
        goto    SetLoop

        ; Runtime state
        clrf    pending_flags
        clrf    done_flags
        clrf    reminder_active
        clrf    blink_count
        clrf    ack_ready
        clrf    clock_flag
        clrf    clock_acc
        clrf    sim_seconds
        clrf    reminder_acc
        clrf    reminder_elapsed

        ; Catch a reminder equal to the initial current time.
        call    Check_Reminders

        
        call    Timer_Init

       
        call    Start_Next_Reminder
        movf    reminder_active,f
        btfss   STATUS,Z
        goto    Loop

       
        call    Clear_Clock_Flag
        call    Show_Normal

; Loop: idle state - reminder_active picks between this and Loop_Active
Loop:
        ; if a reminder is active, only the ACK path is handled here
        movf    reminder_active,f
        btfss   STATUS,Z
        goto    Loop_Active

        ; a pending reminder may have been queued by the ISR
        call    Start_Next_Reminder
        movf    reminder_active,f
        btfss   STATUS,Z
        goto    Loop

        ; refresh the display when a minute changes (atomic test-and-clear)
        call    Take_Clock_Flag
        btfss   STATUS,C
        goto    Loop
        call    Refresh_Normal
        goto    Loop

; Loop_Active: a medicine is being reminded - sound the buzzer, watch for Ack/timeout
Loop_Active:
        call    Buzz_Tone

        btfss   clock_flag,MISSED_BIT
        goto    LA_Ack
        call    Handle_Missed
        goto    Loop

LA_Ack:
        
        call    Ack_Check
        btfss   STATUS,C
        goto    Loop

        ; If the 20-second timeout happened during the debounce delay,
        ; timeout has priority over the late button press.
        btfsc   clock_flag,MISSED_BIT
        goto    LA_MissedAfterDebounce
        call    Handle_Ack
        goto    Loop

LA_MissedAfterDebounce:
        call    Handle_Missed
        goto    Loop

; Timer0: configures the ~8 ms tick and starts the interrupt running - this
; is deliberately done only after the current time and all 3 reminders
; have been entered, so the clock starts from a known value.
Timer_Init:
        bcf     INTCON,GIE
        bcf     INTCON,T0IE
        bcf     INTCON,T0IF

        bsf     STATUS,RP0
        bcf     STATUS,RP1
        movlw   b'00000100'             ; internal clock, prescaler 1:32, RB pull-ups ON
        movwf   OPTION_REG

        bcf     STATUS,RP0
        movlw   TMR0_PRELOAD
        movwf   TMR0
        clrf    clock_acc
        clrf    sim_seconds
        clrf    reminder_acc
        clrf    reminder_elapsed
        clrf    clock_flag
        bcf     INTCON,T0IF
        bsf     INTCON,T0IE
        bsf     INTCON,GIE
        return

; Clear_Clock_Flag: used once, right before the first normal-mode screen is
; drawn, so a tick that happened during setup doesn't cause an instant
; extra redraw.
Clear_Clock_Flag:
        bcf     INTCON,GIE
        bcf     clock_flag,CLOCK_TICK
        bsf     INTCON,GIE
        return

; Atomically consume CLOCK_TICK. Carry = 1 if a refresh was pending.
Take_Clock_Flag:
        bcf     INTCON,GIE
        bcf     STATUS,C
        btfss   clock_flag,CLOCK_TICK
        goto    TCF_Done
        bcf     clock_flag,CLOCK_TICK
        bsf     STATUS,C
TCF_Done:
        bsf     INTCON,GIE
        return

; Copy the time and daily state without allowing a rollover between the values.
Snapshot_Time:
        bcf     INTCON,GIE
        movf    hour,w
        movwf   now_h
        movf    minutes,w
        movwf   now_m
        movf    done_flags,w
        movwf   now_done 
        bsf     INTCON,GIE
        return


; Show_Normal clears the previous screen when entering normal mode.
; Refresh_Normal rewrites the two lines without clearing, so the fast demo does not flicker.
Show_Normal:
        call    LCD_Clear
        goto    Refresh_Normal

Refresh_Normal:
        call    Snapshot_Time
        call    Find_Next_Reminder

        call    LCD_Line1
        movf    now_h,w
        movwf   pt_h
        movf    now_m,w
        movwf   pt_m
        call    LCD_PrintTime

        call    LCD_Line2
        movlw   MsgMedShort-MsgBase
        call    LCD_PrintMsg
        movf    next_med,w
        addlw   '0'
        call    LCD_Char
        movlw   ' '
        call    LCD_Char
        movf    next_h,w
        movwf   pt_h
        movf    next_m,w
        movwf   pt_m 
        goto    LCD_PrintTime

; Find_Next_Reminder: picks the soonest not-yet-done medicine for line 2 of
; the idle screen; falls back to tomorrow's earliest if all 3 are done today
Find_Next_Reminder:
        clrf    next_med

        btfsc   now_done,0
        goto    FNR_Future2
        movf    remh,w
        movwf   cand_h
        movf    remm,w
        movwf   cand_m
        movlw   1
        movwf   cand_med
        call    Consider_Future

FNR_Future2:
        btfsc   now_done,1
        goto    FNR_Future3
        movf    remh+1,w
        movwf   cand_h
        movf    remm+1,w
        movwf   cand_m
        movlw   2
        movwf   cand_med
        call    Consider_Future

FNR_Future3:
        btfsc   now_done,2
        goto    FNR_CheckFound
        movf    remh+2,w
        movwf   cand_h
        movf    remm+2,w
        movwf   cand_m
        movlw   3
        movwf   cand_med
        call    Consider_Future

FNR_CheckFound:
        movf    next_med,f
        btfss   STATUS,Z
        return                          ; a future reminder today was found - done

        ; No remaining future reminder today: choose the earliest one for tomorrow.
        ; (Consider_Earliest is used here for ALL 3 medicines, including ones
        ; already done today, since done_flags gets cleared again at midnight.)
        movf    remh,w
        movwf   cand_h
        movf    remm,w
        movwf   cand_m
        movlw   1
        movwf   cand_med
        call    Consider_Earliest

        movf    remh+1,w
        movwf   cand_h
        movf    remm+1,w
        movwf   cand_m
        movlw   2
        movwf   cand_med
        call    Consider_Earliest

        movf    remh+2,w
        movwf   cand_h
        movf    remm+2,w
        movwf   cand_m
        movlw   3
        movwf   cand_med
        goto    Consider_Earliest

; Add the candidate only if cand_h:cand_m >= now_h:now_m.
Consider_Future:
        movf    now_h,w
        subwf   cand_h,w                ; cand_h - now_h
        btfss   STATUS,C
        return                          ; candidate hour is earlier

        movf    cand_h,w
        xorwf   now_h,w
        btfss   STATUS,Z
        goto    Consider_Earliest       ; candidate hour is later

        movf    now_m,w
        subwf   cand_m,w                ; cand_m - now_m
        btfss   STATUS,C
        return                          ; same hour, candidate minute is earlier
        goto    Consider_Earliest

; Keep the earliest candidate. Equal times keep the lower medicine number
; because medicines are considered in the order 1, 2, 3.
Consider_Earliest:
        movf    next_med,f
        btfsc   STATUS,Z
        goto    CE_Store

        movf    next_h,w
        subwf   cand_h,w                ; cand_h - next_h
        btfss   STATUS,C
        goto    CE_Store                ; candidate hour is smaller

        movf    cand_h,w
        xorwf   next_h,w
        btfss   STATUS,Z
        return                          ; candidate hour is larger

        movf    next_m,w
        subwf   cand_m,w                ; cand_m - next_m
        btfss   STATUS,C
        goto    CE_Store
        return

CE_Store:
        movf    cand_h,w
        movwf   next_h
        movf    cand_m,w
        movwf   next_m
        movf    cand_med,w
        movwf   next_med
        return


; Start_Next_Reminder: picks the lowest pending medicine and starts it (LED+buzzer+message)
Start_Next_Reminder:
        bcf     INTCON,GIE

        movf    reminder_active,f
        btfss   STATUS,Z
        goto    SNR_Exit

        btfsc   pending_flags,0
        goto    SNR_Med1
        btfsc   pending_flags,1
        goto    SNR_Med2
        btfsc   pending_flags,2
        goto    SNR_Med3
        goto    SNR_Exit

SNR_Med1:
        bcf     pending_flags,0
        movlw   1
        movwf   reminder_active
        goto    SNR_Start
SNR_Med2:
        bcf     pending_flags,1
        movlw   2
        movwf   reminder_active
        goto    SNR_Start
SNR_Med3:
        bcf     pending_flags,2
        movlw   3
        movwf   reminder_active

SNR_Start:
        clrf    blink_count
        clrf    ack_ready 
        clrf    reminder_acc
        clrf    reminder_elapsed
        bcf     clock_flag,MISSED_BIT

        ; Only one medicine LED is turned on, and the buzzer is enabled.
        ; GIE is still off here, so these calls cannot collide with the blink ISR.
        call    LED_Active_On
        call    Buzzer_On

        ; If ACK is already held down, it must be released before it can count.
        btfsc   PORTB,ACK_BTN
        bsf     ack_ready,ACK_READY_BIT

        bsf     INTCON,GIE
        goto    Show_Take_Medicine      ; tail call keeps the runtime stack bounded

SNR_Exit:
        bsf     INTCON,GIE
        return

Show_Take_Medicine:
        call    LCD_Clear
        movlw   MsgTake-MsgBase
        call    LCD_PrintMsg
        movf    reminder_active,w
        addlw   '0'
        goto    LCD_Char


; Ack_Check: non-blocking poll; returns C=1 on a confirmed new press.
; ack_ready guards a press already happening when the reminder started.
Ack_Check:
        bcf     STATUS,C

        btfsc   ack_ready,ACK_READY_BIT
        goto    AC_Armed

        ; Not armed yet: wait until the button is released stably.
        btfss   PORTB,ACK_BTN
        return
        movlw   20
        call    DelayMs
        btfss   PORTB,ACK_BTN
        return
        bsf     ack_ready,ACK_READY_BIT
        return

AC_Armed:
        btfss   PORTB,ACK_BTN            ; active LOW
        goto    AC_Pressed
        return

AC_Pressed:
        movlw   20
        call    DelayMs
        btfsc   PORTB,ACK_BTN            ; high again -> bounce
        return
        bsf     STATUS,C                 ; valid press; release is handled by ack_ready
        return


; Handle_Ack/Handle_Missed pick the message, then fall into Finish_Reminder
Handle_Ack:
        movlw   MsgDoseTaken-MsgBase
        goto    Finish_Reminder

Handle_Missed:
        movlw   MsgDoseMissed-MsgBase

Finish_Reminder:
        movwf   msg_sel

        ; Update state and outputs atomically with respect to LED blinking.
        bcf     INTCON,GIE
        clrf    reminder_active
        clrf    blink_count
        clrf    ack_ready
        clrf    reminder_acc
        clrf    reminder_elapsed
        bcf     clock_flag,MISSED_BIT
        call    LEDs_Off
        call    Buzzer_Off
        bsf     INTCON,GIE

        call    LCD_Clear
        movf    msg_sel,w
        call    LCD_PrintMsg
        movlw   8
        call    Delay250xN              ; "Dose Taken" / "Dose Missed" for 2 seconds

        ; A reminder that became pending meanwhile (or at the same time) starts now.
        call    Start_Next_Reminder
        movf    reminder_active,f
        btfss   STATUS,Z
        return

        call    Clear_Clock_Flag
        goto    Show_Normal

; Keypad

; Keypad_Scan: drives one row low at a time (kpat rotates the 0 bit), reads
; the 3 columns back. Index = row*4+column. Returns W=255 if nothing pressed.
Keypad_Scan:
        movlw   b'11111110'             ; row 0 low, rows 1-3 (and unused bits) high
        movwf   kpat
        clrf    krow
KS_row:
        call    Rows_Write
        call    Delay50us                ; let the row settle before reading columns
        movf    PORTC,w                 ; columns RC2..RC4
        andlw   b'00011100'
        xorlw   b'00011100'              ; all 3 columns still high (pulled up) = no key here
        btfss   STATUS,Z
        goto    KS_found
        bsf     STATUS,C
        rlf     kpat,f                   ; rotate the low row bit to the next row
        incf    krow,f
        movlw   4
        xorwf   krow,w
        btfss   STATUS,Z
        goto    KS_row                   ; try the next row
        call    Rows_Release
        retlw   255                      ; all 4 rows checked, nothing pressed
KS_found:
        movwf   kcol                     ; kcol bits 2-4 = which column(s) read low
        bcf     STATUS,C
        rrf     kcol,f                   ; shift the column bits down so column 0 is bit 0...
        bcf     STATUS,C
        rrf     kcol,f
        clrf    kc
KS_col:
        btfsc   kcol,0                   ; ...then just walk bit 0 up until it's the low one
        goto    KS_idx
        bcf     STATUS,C
        rrf     kcol,f
        incf    kc,f
        goto    KS_col
KS_idx:
        bcf     STATUS,C
        rlf     krow,w                   ; kidx = krow*4 ...
        movwf   kidx
        bcf     STATUS,C
        rlf     kidx,f
        movf    kc,w
        addwf   kidx,f                   ; ... + kc, giving the row*4+col table index
        call    Rows_Release
        movf    kidx,w
        return

; Rows_Write: sets PORTD's row nibble from kpat, keeps the LCD data nibble untouched
Rows_Write:
        swapf   kpat,w
        andlw   b'11110000'
        movwf   ptmp
        movf    PORTD,w
        andlw   b'00001111'
        iorwf   ptmp,w
        movwf   PORTD
        return

Rows_Release:                           ; all rows high = idle, nothing selected
        movlw   b'00001111'
        movwf   kpat
        goto    Rows_Write

; Keypad_GetKey: waits for a key (debounced), waits for release (max ~2s), returns W=ASCII
Keypad_GetKey:
KG_wait:
        call    Keypad_Scan
        movwf   kraw                    ; kraw = the key we're debouncing
        incf    kraw,w                  ; 255+1 wraps to 0 -> W=0 means "no key"
        btfsc   STATUS,Z
        goto    KG_wait
        movlw   20
        call    DelayMs                 ; debounce delay
        call    Keypad_Scan
        xorwf   kraw,w                  ; still the same key?
        btfss   STATUS,Z
        goto    KG_wait                 ; no - it was noise, start over
KG_rel:
        movlw   100
        movwf   krel_cnt
KG_rel_loop:
        call    Keypad_Scan
        movwf   ktmp
        incf    ktmp,w
        btfsc   STATUS,Z
        goto    KG_rel_done             ; released
        movlw   20
        call    DelayMs
        decfsz  krel_cnt,f
        goto    KG_rel_loop             ; still held - keep waiting (up to the timeout)
KG_rel_done:
        movlw   20
        call    DelayMs                 ; release debounce
        movlw   HIGH KeyTable
        movwf   PCLATH
        movf    kraw,w
        call    KeyTable                ; kraw (0-15 index) -> ASCII character
        return

; Time entry
; Enter_HHMM: shared time-entry screen (prompt_id picks the label). '*'=clear,
; '#'=confirm once 4 valid digits are typed. Output: val_h, val_m.
Enter_HHMM:
EH_start:
        call    ClearEntry
        call    DrawPrompt
EH_key:
        call    Keypad_GetKey
        movwf   key
        movlw   '*'
        xorwf   key,w
        btfsc   STATUS,Z
        goto    EH_clear                ; '*' -> restart this entry
        movlw   '#'
        xorwf   key,w
        btfsc   STATUS,Z
        goto    EH_confirm              ; '#' -> try to accept the 4 digits
        movlw   '0'
        subwf   key,w
        btfss   STATUS,C
        goto    EH_key                  ; key < '0' -> not a digit, ignore
        movlw   '9'+1
        subwf   key,w
        btfsc   STATUS,C
        goto    EH_key                  ; key > '9' -> not a digit, ignore
        movlw   4
        subwf   ndig,w
        btfsc   STATUS,C
        goto    EH_key                  ; already have 4 digits, ignore extras
        movlw   ent
        addwf   ndig,w
        movwf   FSR
        movf    key,w
        movwf   INDF                    ; ent[ndig] = key
        incf    ndig,f
        call    DrawEntry
        goto    EH_key
EH_clear:
        call    ClearEntry
        call    DrawEntry
        goto    EH_key
EH_confirm:
        movlw   4
        xorwf   ndig,w
        btfss   STATUS,Z
        goto    EH_invalid              ; not enough digits yet - ignore '#'
        movf    ent,w                   ; combine digits 0,1 into val_h (0-99)
        movwf   tA
        movf    ent+1,w
        movwf   tB
        call    AsciiPair
        movwf   val_h
        movf    ent+2,w                 ; combine digits 2,3 into val_m (0-99)
        movwf   tA
        movf    ent+3,w
        movwf   tB
        call    AsciiPair
        movwf   val_m
        movlw   24
        subwf   val_h,w                 ; C=1 if val_h >= 24 -> invalid hour
        btfsc   STATUS,C
        goto    EH_invalid
        movlw   60
        subwf   val_m,w                 ; C=1 if val_m >= 60 -> invalid minute
        btfsc   STATUS,C
        goto    EH_invalid
        return
EH_invalid:
        call    LCD_Clear
        movlw   MsgInvalid-MsgBase
        call    LCD_PrintMsg
        movlw   4
        call    Delay250xN
        goto    EH_start                ; start this entry over from scratch

ClearEntry:
        movlw   '_'
        movwf   ent
        movwf   ent+1
        movwf   ent+2
        movwf   ent+3
        clrf    ndig
        return

; DrawPrompt: line 1 label + line 2 entry/hint. prompt_id=0 -> clock, 1..3 -> medicine n
DrawPrompt:
        call    LCD_Clear
        movf    prompt_id,f
        btfss   STATUS,Z
        goto    DP_med
        movlw   MsgSetTime-MsgBase
        call    LCD_PrintMsg
        goto    DP_line2
DP_med:
        movlw   MsgSetMed-MsgBase
        call    LCD_PrintMsg
        movf    prompt_id,w
        addlw   '0'
        call    LCD_Char
DP_line2:
        call    DrawEntry
        movlw   MsgHint-MsgBase
        goto    LCD_PrintMsg

; DrawEntry: redraws line 2 as "HH:MM" from ent[] (0xC0 = cursor to line 2)
DrawEntry:
        movlw   0xC0
        call    LCD_Cmd
        movf    ent,w
        call    LCD_Char
        movf    ent+1,w
        call    LCD_Char
        movlw   ':'
        call    LCD_Char
        movf    ent+2,w
        call    LCD_Char
        movf    ent+3,w
        goto    LCD_Char

; AsciiPair: tA,tB (ASCII digits) -> one 0-99 value = tA*10+tB (x10 = x8+x2, no multiply on PIC)
AsciiPair:
        movlw   '0'
        subwf   tA,f                    ; tA, tB: ASCII '0'-'9' -> binary 0-9
        subwf   tB,f
        movf    tA,w
        movwf   tmp
        bcf     STATUS,C
        rlf     tmp,f                   ; tmp = tA*2
        movf    tmp,w
        movwf   tmp2
        bcf     STATUS,C
        rlf     tmp2,f                  ; tmp2 = tA*4
        bcf     STATUS,C
        rlf     tmp2,f                  ; tmp2 = tA*8
        movf    tmp2,w
        addwf   tmp,w                   ; W = tA*8 + tA*2 = tA*10
        addwf   tB,w                    ; W = tA*10 + tB
        return

; Delay subroutines (4 MHz). Only used for short fixed hardware timing -
; never for the clock itself, which runs entirely off the Timer0 ISR.
Delay50us:                              ; ~50 microseconds
        movlw   15
        movwf   dly50
D50_loop:
        decfsz  dly50,f
        goto    D50_loop
        return

DelayMs:                                ; W = milliseconds to wait
        movwf   dly_ms
DMs_1:
        movlw   249
        movwf   dly_lo
DMs_2:
        nop
        decfsz  dly_lo,f
        goto    DMs_2
        decfsz  dly_ms,f
        goto    DMs_1
        return

Delay250xN:                             ; W = number of 250 ms chunks to wait
        movwf   wait_cnt
D250_lp:
        movlw   250
        call    DelayMs
        decfsz  wait_cnt,f
        goto    D250_lp
        return

; LCD subroutines
; LCD_Nibble: sends a 4-bit nibble to D4-D7 (PORTD low nibble, shared with keypad rows) + pulses E
LCD_Nibble:
        movwf   lcd_n
        swapf   lcd_n,w
        andlw   b'00001111'
        movwf   lcd_n
        movf    PORTD,w
        andlw   b'11110000'             ; keep the keypad row bits untouched
        iorwf   lcd_n,w
        movwf   PORTD
        bcf     PORTC,LCD_RS
        btfsc   lcd_rs,LCD_RS
        bsf     PORTC,LCD_RS
        bsf     PORTC,LCD_E             ; E pulse: high...
        nop
        bcf     PORTC,LCD_E             ; ...then low latches the nibble
        return

; LCD_WriteByte: sends high nibble then low nibble (standard 4-bit protocol)
LCD_WriteByte:
        movwf   lcd_tmp
        call    LCD_Nibble
        swapf   lcd_tmp,w
        call    LCD_Nibble
        goto    Delay50us

LCD_Cmd:                                ; W = command byte (RS=0)
        bcf     lcd_rs,LCD_RS
        goto    LCD_WriteByte

LCD_Char:                               ; W = character to print (RS=1)
        bsf     lcd_rs,LCD_RS
        goto    LCD_WriteByte

; LCD_Init: standard HD44780 4-bit wake-up (0x3 x3, then 0x2), then function set/display/clear
LCD_Init:
        clrf    lcd_rs
        movlw   30
        call    DelayMs

        movlw   0x30
        call    LCD_Nibble
        movlw   5
        call    DelayMs
        movlw   0x30
        call    LCD_Nibble
        movlw   1
        call    DelayMs
        movlw   0x30
        call    LCD_Nibble
        movlw   1
        call    DelayMs

        movlw   0x20                    ; now switch to 4-bit mode
        call    LCD_Nibble
        movlw   1
        call    DelayMs

        movlw   0x28                    ; function set: 4-bit, 2 lines, 5x8 font
        call    LCD_Cmd
        movlw   0x0C                    ; display on, cursor off, blink off
        call    LCD_Cmd
        movlw   0x06                    ; entry mode: increment, no shift
        call    LCD_Cmd
        goto    LCD_Clear

LCD_Clear:
        movlw   0x01
        call    LCD_Cmd
        movlw   2
        goto    DelayMs                 ; clear needs a bit longer to finish

LCD_Line1:                              ; move cursor to the start of line 1
        movlw   0x80
        goto    LCD_Cmd

LCD_Line2:                              ; move cursor to the start of line 2
        movlw   0xC0
        goto    LCD_Cmd

; LCD_PrintMsg: prints a 0-terminated string from MsgTable; W = MsgXxx-MsgBase offset
LCD_PrintMsg:
        movwf   msg_ptr
PM_lp:
        movlw   HIGH MsgTable
        movwf   PCLATH
        movf    msg_ptr,w
        call    MsgTable
        xorlw   0
        btfsc   STATUS,Z
        return                          ; 0 byte = end of string
        call    LCD_Char
        incf    msg_ptr,f
        goto    PM_lp

; LCD_PrintBin2: prints 0-99 as two decimal digits (repeated subtract-10 for the tens digit)
LCD_PrintBin2:
        movwf   pb_val
        clrf    pb_tens
PB_lp:
        movlw   10
        subwf   pb_val,w
        btfss   STATUS,C                ; C=0 once pb_val < 10 - done
        goto    PB_done
        movwf   pb_val
        incf    pb_tens,f
        goto    PB_lp
PB_done:
        movlw   '0'
        addwf   pb_tens,w
        call    LCD_Char
        movlw   '0'
        addwf   pb_val,w
        goto    LCD_Char

LCD_PrintTime:                          ; prints pt_h:pt_m as "HH:MM"
        movf    pt_h,w
        call    LCD_PrintBin2
        movlw   ':'
        call    LCD_Char
        movf    pt_m,w
        goto    LCD_PrintBin2

; Tables
; org 0x0700 keeps both tables in one 256-word block, needed for "addwf
; PCL,f" (jumps into the Nth `dt` byte below - a classic PIC lookup trick)
        org     0x0700

; KeyTable: keypad index (0-15) -> ASCII; only 12 slots reachable (3 columns), A-D unused
KeyTable:
        addwf   PCL,f
        dt      "123A456B789C*0#D"

; MsgTable: 0-terminated strings; LCD_PrintMsg takes (label-MsgBase) as the offset
MsgTable:
        addwf   PCL,f
MsgBase:
MsgWelcome:     dt "Welcome to",0
MsgMedRem:      dt "Med Reminder",0
MsgSetTime:     dt "Set Current Time",0
MsgSetMed:      dt "Set Medicine ",0
MsgHint:        dt " #OK *CLR",0
MsgInvalid:     dt "Invalid Time!",0
MsgMedShort:    dt "Med",0
MsgTake:        dt "Take Medicine ",0
MsgDoseTaken:   dt "Dose Taken",0
MsgDoseMissed:  dt "Dose Missed",0
        end
