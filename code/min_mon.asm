
; minimal monitor for EhBASIC and 6502 simulator V1.05

; To run EhBASIC on the simulator load and assemble [F7] this file, start the simulator
; running [F6] then start the code with the RESET [CTRL][SHIFT]R. Just selecting RUN
; will do nothing, you'll still have to do a reset to run the code.

    !cpu    6502

	* = $C000

	!src "basic.asm"

; put the IRQ and MNI code in RAM so that it can be changed

IRQ_vec	= VEC_SV+2		; IRQ code vector
NMI_vec	= IRQ_vec+$0A	; NMI code vector

CTRLREG = $BC00

PA_8255 = $A200
PB_8255	= $A201
PC_8255	= $A202
CONF_8255 = $A203

ACIA_RXD = $A000 ; ACIA receive data port
ACIA_TXD = $A000 ; ACIA transmit data port
ACIA_STS = $A001 ; ACIA status port
ACIA_RES = $A001 ; ACIA reset port
ACIA_CMD = $A002 ; ACIA command port
ACIA_CTL = $A003 ; ACIA control port

RTC_1_SEC_REG = $A180
RTC_10_SEC_REG = $A181
RTC_1_MIN_REG = $A182
RTC_10_MIN_REG = $A183
RTC_1_HOUR_REG = $A184
RTC_10_HOUR_REG = $A185
RTC_1_DAY_REG = $A186
RTC_10_DAY_REG = $A187
RTC_1_MON_REG = $A188
RTC_10_MON_REG = $A189
RTC_1_YEAR_REG = $A18A
RTC_10_YEAR_REG = $A18B
RTC_WEEK_REG = $A18C
RTC_CTRLD_REG = $A18D
RTC_CTRLE_REG = $A18E
RTC_CTRLF_REG = $A18F

; now the code. all this does is set up the vectors and interrupt code
; and wait for the user to select [C]old or [W]arm start. nothing else
; fits in less than 128 bytes

;.ORG	$C000			; pretend this is in a 1/8K ROM

; reset vector points here

RES_vec
	CLD				; clear decimal mode
	LDX	#$FF			; empty stack
	TXS				; set the stack

; initialise 6551 ACIA
 
    STA ACIA_RES       	; soft reset (value not important)
    LDA #$0B        	; set specific modes and functions
						; no parity, no echo, no Tx interrupt
						; no Rx interrupt, enable Tx/Rx
    STA ACIA_CMD       	; save to command register
						; all the following 8-N-1 with the baud rate
						; generator selected. uncomment the line with
						; the required baud rate.
;   LDA #$1A        	; 8-N-1, 2400 baud
;   LDA #$1C        	; 8-N-1, 4800 baud
    LDA #$1E        	; 8-N-1, 9600 baud
;   LDA #$1F        	; 8-N-1, 19200 baud
    STA ACIA_CTL       	; set control register

; set up vectors and interrupt code, copy them to page 2

	LDY	#END_CODE-LAB_vec	; set index/count
LAB_stlp
	LDA	LAB_vec-1,Y		; get byte from interrupt code
	STA	VEC_IN-1,Y		; save to RAM
	DEY				; decrement index/count
	BNE	LAB_stlp		; loop if more to do
    
 ;Initialize M6442B RTC
    LDA  #$04                  ;30 AJD = 0, IRQ FLAG = 1 (required), BUSY = 0(?), HOLD = 0
    STA  RTC_CTRLD_REG
    LDA #$06                   ;Innterrupt mode, STD.P enabled, 1 s.
    STA  RTC_CTRLE_REG
    LDA #$04                   ;TEST = 0, 24h mode, STOP = 0, RESET = 0
    STA  RTC_CTRLF_REG    

; Initialize CF card
    JSR CFINIT
    
;EXPERIMENTAL BLOCK - INIT KEYBIARD
;    JSR	LAB_CRLF		;print CR/LF
;	LDA	#<LAB_KBMSG		;point to memory size message (low addr)
;	LDY	#>LAB_KBMSG		;point to memory size message (high addr)
;	JSR	LAB_18C3	   	;print null terminated string from memory
;INIT_KB:
;	JSR KBDINIT
;	TXA				    ;transfer error code to A
;	CMP #$00
;	BNE INIT_KB
INIT_VDP:
	JSR VDPINIT
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	NOP
	LDA #<CRTMSG
	STA BLKIND
	LDA #>CRTMSG
	STA BLKIND+1
	LDX #$00
	LDY #$08
	LDA #$B3			;179 data len
	STA BLKLEN
	LDA #$00
	STA BLKLEN + 1
	JSR VDPWVRAM

;	LDA	#<LAB_OKMSG		;point to memory size message (low addr)
;	LDY	#>LAB_OKMSG		;point to memory size message (high addr)
;	JSR	LAB_18C3	   	;print null terminated string from memory
;	JMP LAB_prepsignon
;LAB_printfail
;	LDA	#<LAB_FAILMSG	;point to memory size message (low addr)
;	LDY	#>LAB_FAILMSG	;point to memory size message (high addr)
;	JSR	LAB_18C3	   	;print null terminated string from memory
LAB_prepsignon			
	LDY #$00
;END OF EXPERIMENTAL BLOCK    	

; now do the signon message, Y = $00 here

LAB_signon
	LDA	LAB_mess,Y		; get byte from sign on message
	BEQ	LAB_nokey		; exit loop if done

	JSR	V_OUTP		; output character
	INY				; increment index
	BNE	LAB_signon		; loop, branch always

LAB_nokey
	JSR	V_INPT		; call scan input device
	BCC	LAB_nokey		; loop if no key

	AND	#$DF			; mask xx0x xxxx, ensure upper case
	CMP	#'W'			; compare with [W]arm start
	BEQ	LAB_dowarm		; branch if [W]arm start

	CMP	#'C'			; compare with [C]old start
	BNE	RES_vec		; loop if not [C]old start

	JMP	LAB_COLD		; do EhBASIC cold start

LAB_dowarm
	JMP	LAB_WARM		; do EhBASIC warm start

; byte out to UART

ACIAout
	PHA						; save A
ACIAout_wait
	LDA	ACIA_STS			; get status byte
	AND #$10				; mask transmit buffer status flag
	BEQ ACIAout_wait		; loop if tx buffer full
	PLA         			; restore A
	STA ACIA_TXD       		; save byte to ACIA data port
	RTS

; byte in from UART

ACIAin
	LDA ACIA_STS       		; get ACIA status
	AND #$08        		; mask rx buffer status flag
	BEQ	LAB_nobyw			; branch if no byte waiting
;	BEQ	KBDin				; branch if no byte waiting
	LDA ACIA_RXD       		; get byte from ACIA data port
	AND #$7F				; mask MSB OFF
	SEC						; flag byte received
	RTS
;KBDin
;	JSR KBDRCV
;	CMP #$00
;	BEQ LAB_nobyw
;	SEC
;	RTS

LAB_nobyw
	CLC				; flag no byte received
	RTS
no_load
	RTS				; empty load vector for EhBASIC
no_save				; empty save vector for EhBASIC
	RTS 	

; vector tables

LAB_vec
	!16	ACIAin		; byte in from simulated ACIA
	!16	ACIAout		; byte out to simulated ACIA
	!16	no_load		; null load vector for EhBASIC
	!16	no_save		; null save vector for EhBASIC

; EhBASIC IRQ support

IRQ_CODE
	PHA				; save A
	LDA	IrqBase		; get the IRQ flag byte
	LSR				; shift the set b7 to b6, and on down ...
	ORA	IrqBase		; OR the original back in
	STA	IrqBase		; save the new IRQ flag byte
	PLA				; restore A
	RTI

; EhBASIC NMI support

NMI_CODE
	PHA				; save A
	LDA	NmiBase		; get the NMI flag byte
	LSR				; shift the set b7 to b6, and on down ...
	ORA	NmiBase		; OR the original back in
	STA	NmiBase		; save the new NMI flag byte
	PLA				; restore A
	RTI

END_CODE

LAB_mess
	!raw	$0D,$0A,"6502 EhBASIC [C]old/[W]arm ?",$00
					; sign on string
LAB_KBMSG
    !raw    $0D,$0A,"Keyboard initialization: ",$00
    
LAB_OKMSG
    !raw    "OK",$00
    
LAB_FAILMSG
    !raw    "Failed!",$00    

; system vectors

    * =	$FFFA

	!16	    NMI_vec		; NMI vector
	!16	    RES_vec		; RESET vector
	!16	    IRQ_vec		; IRQ vector

