; ============================================================
; BBFS - Bare Bones File System for 6502 + CF card
; For use with EhBASIC on a homebrew 6502 system
;
; Filesystem layout:
;   Sector 0        : directory (16 entries x 32 bytes = 512 bytes)
;   Sectors 1-16    : reserved
;   Sectors 17+     : data (contiguous runs, one run per file)
;
; Directory entry (32 bytes):
;   $00-$0F  filename, null-padded, null-terminated (16 bytes)
;   $10      flags: $FF=active, $00=deleted/empty
;   $11-$12  start sector (16-bit, little-endian)
;   $13-$14  data length in bytes (16-bit, little-endian)
;   $15-$16  load address (16-bit, little-endian)  [saved but not used by EhBASIC hook]
;   $17-$1F  reserved
;
; EhBASIC integration:
;   LOAD vector calls FS_LOAD
;   SAVE vector calls FS_SAVE
;   Both prompt for a filename via the ACIA/VDP output routines.
;
; Calling conventions (EhBASIC):
;   On SAVE: BASIC program is in RAM from PROG_START to PROG_END (zero page)
;   On LOAD: we read back to PROG_START, patch PROG_END to match
;
; Depends on:
;   CF card routines:  CFREAD(sector in LBAD0-LBAD3, buf at SECTOR_BUF)
;                      CFWRITE(sector in LBAD0-LBAD3, buf at SECTOR_BUF)
;   V_OUTP / V_INPT   (already in your monitor)
;   LAB_CRLF          (already in EhBASIC)
;   SECTOR_BUF        512-byte scratch buffer in RAM
;
; Zero page usage (choose free locations for your build):
;   FS_ZP_PTR   = $E0  (2 bytes) general pointer
;   FS_ZP_CNT   = $E2  (2 bytes) byte counter
;   FS_ZP_SEC   = $E4  (2 bytes) current sector number
;   FS_ZP_TMP   = $E6  (1 byte)  scratch
;   FS_ZP_ENT   = $E7  (1 byte)  current dir entry index (0-15)
; ============================================================

; ---- Adjust these to match your build ----------------------

FS_ZP_PTR   = $E0
FS_ZP_CNT   = $E2
FS_ZP_SEC   = $E4
FS_ZP_TMP   = $E6
FS_ZP_ENT   = $E7

; EhBASIC zero page: start and end of BASIC program
; From basic.asm: Smeml=$79 (start of BASIC), Svarl=$7B (end of BASIC = start of vars)
PROG_START_L = $79          ; Smeml - start of BASIC program low byte
PROG_START_H = $7A          ; Smemh - start of BASIC program high byte
PROG_END_L   = $7B          ; Svarl - end of BASIC program low byte  
PROG_END_H   = $7C          ; Svarh - end of BASIC program high byte

; 512-byte buffer in RAM - must match BLKDAT in your main build
; BLKDAT = $0400 in basic.asm, CFREAD/CFWRITE use BLKIND pointing to BLKDAT
SECTOR_BUF  = $0400     ; must match BLKDAT

; First data sector (sectors 0-16 reserved for dir + future use)
FS_DATA_START = 17

; Directory is always at sector 0
FS_DIR_SECTOR = 0

; Number of directory entries
FS_MAX_ENTRIES = 16
FS_ENTRY_SIZE  = 32     ; bytes per entry

; Entry field offsets
FS_OFF_NAME    = $00    ; 16 bytes
FS_OFF_FLAGS   = $10    ; 1 byte  ($FF = active, $00 = free)
FS_OFF_STARTH  = $11    ; 2 bytes start sector (lo, hi)
FS_OFF_LEN     = $13    ; 2 bytes length in bytes (lo, hi)
FS_OFF_LOADLO  = $15    ; 2 bytes original load address (lo, hi)

FS_FLAG_ACTIVE = $FF
FS_FLAG_FREE   = $00

; ---- Input buffer for filenames ----------------------------
FS_NAMEBUF  = $0300     ; 17 bytes in RAM (16 chars + null)

; ============================================================
; FS_SAVE  -  EhBASIC SAVE hook
;
; Called by EhBASIC SAVE token. Bpntrl/Bpntrh points to
; the character after "SAVE" on the BASIC line.
; Usage:  SAVE "filename"
; Parses the quoted filename then saves the BASIC program.
; ============================================================
FS_SAVE
    ; Entry diagnostic - print S so we know we got here
    LDA #'S'
    JSR V_OUTP
    JSR FS_PARSE_FNAME      ; parse "filename" from BASIC line
    BCC FS_SAVE_GONAME
    JMP FS_SAVE_ABORT       ; no valid filename
FS_SAVE_GONAME

    ; Load directory sector
    JSR FS_LOAD_DIR
    BCC FS_SAVE_DIROK
    JMP FS_IO_ERR
FS_SAVE_DIROK

    ; Search for existing entry with same name (for overwrite)
    JSR FS_FIND_NAME        ; returns entry index in FS_ZP_ENT, C=0 if found
    BCC FS_SAVE_FOUND_SLOT

    ; Not found - find a free slot
    JSR FS_FIND_FREE        ; returns entry index in FS_ZP_ENT, C=0 if found
    BCC FS_SAVE_FOUND_SLOT
    JMP FS_SAVE_FULL        ; directory full

FS_SAVE_FOUND_SLOT
    ; Calculate BASIC program length: Svarl - Smeml
    ; Svarl/Svarh = end of program (start of variables)
    ; Smeml/Smemh = start of program
    SEC
    LDA PROG_END_L
    SBC PROG_START_L
    STA FS_ZP_CNT
    LDA PROG_END_H
    SBC PROG_START_H
    STA FS_ZP_CNT+1

    ; Find the next free sector (scan dir entries for highest end sector)
    JSR FS_NEXT_FREE_SECTOR ; result in FS_ZP_SEC (16-bit)

    ; Set FS_ZP_PTR = SECTOR_BUF + (FS_ZP_ENT * 32)
    LDA FS_ZP_ENT
    ASL                 ; * 2
    ASL                 ; * 4
    ASL                 ; * 8
    ASL                 ; * 16
    ASL                 ; * 32
    CLC
    ADC #<SECTOR_BUF
    STA FS_ZP_PTR
    LDA #>SECTOR_BUF
    ADC #$00
    STA FS_ZP_PTR+1

    ; Write filename (null-padded to 16 bytes)
    LDY #$00
FS_SAVE_NAME2
    LDA FS_NAMEBUF,Y
    STA (FS_ZP_PTR),Y
    INY
    CPY #16
    BNE FS_SAVE_NAME2

    ; Write flags = $FF (active)
    LDA #FS_FLAG_ACTIVE
    LDY #FS_OFF_FLAGS
    STA (FS_ZP_PTR),Y

    ; Write start sector (lo, hi)
    LDA FS_ZP_SEC
    LDY #FS_OFF_STARTH
    STA (FS_ZP_PTR),Y
    LDA FS_ZP_SEC+1
    INY
    STA (FS_ZP_PTR),Y

    ; Write length (lo, hi)
    LDA FS_ZP_CNT
    LDY #FS_OFF_LEN
    STA (FS_ZP_PTR),Y
    LDA FS_ZP_CNT+1
    INY
    STA (FS_ZP_PTR),Y

    ; Write load address = Smeml (actual start of program in RAM)
    LDA PROG_START_L
    LDY #FS_OFF_LOADLO
    STA (FS_ZP_PTR),Y
    LDA PROG_START_H
    INY
    STA (FS_ZP_PTR),Y

    ; Zero out reserved bytes ($17-$1F)
    LDA #$00
    LDY #$17
FS_SAVE_ZERO
    STA (FS_ZP_PTR),Y
    INY
    CPY #FS_ENTRY_SIZE
    BNE FS_SAVE_ZERO

    ; Write directory sector back
    JSR FS_SAVE_DIR
    BCC FS_SAVE_DIRSAVED
    JMP FS_IO_ERR
FS_SAVE_DIRSAVED

    ; Now write data sectors
    ; Source pointer = Smeml (actual start of BASIC program)
    LDA PROG_START_L
    STA FS_ZP_PTR
    LDA PROG_START_H
    STA FS_ZP_PTR+1

    ; Bytes remaining in FS_ZP_CNT
    ; Current sector in FS_ZP_SEC

FS_SAVE_LOOP
    ; Any bytes left?
    LDA FS_ZP_CNT
    ORA FS_ZP_CNT+1
    BEQ FS_SAVE_DONE

    ; Fill SECTOR_BUF from (FS_ZP_PTR), up to 512 bytes
    JSR FS_FILL_SECTOR_BUF

    ; Write sector to CF
    JSR FS_SET_LBA          ; set LBA from FS_ZP_SEC
    JSR CFWRITE
    BCC FS_SAVE_SECOK
    JMP FS_IO_ERR
FS_SAVE_SECOK

    ; Advance sector
    INC FS_ZP_SEC
    BNE FS_SAVE_LOOP
    INC FS_ZP_SEC+1
    JMP FS_SAVE_LOOP

FS_SAVE_DONE
    JSR LAB_CRLF
    LDA #<FS_MSG_OK
    LDY #>FS_MSG_OK
    JSR FS_PRINT_STR
    CLC
    RTS

FS_SAVE_ABORT
    CLC
    RTS

FS_SAVE_FULL
    LDA #<FS_MSG_FULL
    LDY #>FS_MSG_FULL
    JSR FS_PRINT_STR
    SEC
    RTS

FS_IO_ERR
    LDA #<FS_MSG_IOERR
    LDY #>FS_MSG_IOERR
    JSR FS_PRINT_STR
    SEC
    RTS

; ============================================================
; FS_LOAD  -  EhBASIC LOAD hook
;
; Called by EhBASIC LOAD token. Bpntrl/Bpntrh points to
; the character after "LOAD" on the BASIC line.
; Usage:  LOAD "filename"
; Parses the quoted filename then loads the file.
; ============================================================
FS_LOAD
    ; Entry diagnostic - print L so we know we got here
    LDA #'L'
    JSR V_OUTP
    JSR FS_PARSE_FNAME      ; parse "filename" from BASIC line
    BCC FS_LOAD_GONAME
    JMP FS_LOAD_ABORT
FS_LOAD_GONAME

    ; Load directory
    JSR FS_LOAD_DIR
    BCC FS_LOAD_DIROK
    JMP FS_IO_ERR
FS_LOAD_DIROK

    ; Search for filename
    JSR FS_FIND_NAME
    BCC FS_LOAD_FOUND
    JMP FS_NOT_FOUND
FS_LOAD_FOUND

    ; Point FS_ZP_PTR at entry
    LDA FS_ZP_ENT
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC #<SECTOR_BUF
    STA FS_ZP_PTR
    LDA #>SECTOR_BUF
    ADC #$00
    STA FS_ZP_PTR+1

    ; Read start sector
    LDY #FS_OFF_STARTH
    LDA (FS_ZP_PTR),Y
    STA FS_ZP_SEC
    INY
    LDA (FS_ZP_PTR),Y
    STA FS_ZP_SEC+1

    ; Read length into FS_ZP_CNT
    LDY #FS_OFF_LEN
    LDA (FS_ZP_PTR),Y
    STA FS_ZP_CNT
    INY
    LDA (FS_ZP_PTR),Y
    STA FS_ZP_CNT+1

    ; Destination pointer = Smeml (actual start of BASIC program)
    LDA PROG_START_L
    STA FS_ZP_PTR
    LDA PROG_START_H
    STA FS_ZP_PTR+1

FS_LOAD_LOOP
    LDA FS_ZP_CNT
    ORA FS_ZP_CNT+1
    BEQ FS_LOAD_DONE

    ; Read sector from CF into SECTOR_BUF
    JSR FS_SET_LBA
    JSR CFREAD
    BCC FS_LOAD_SECOK
    JMP FS_IO_ERR
FS_LOAD_SECOK

    ; Copy SECTOR_BUF -> (FS_ZP_PTR), up to 512 bytes or remaining count
    JSR FS_DRAIN_SECTOR_BUF

    ; Next sector
    INC FS_ZP_SEC
    BNE FS_LOAD_LOOP
    INC FS_ZP_SEC+1
    JMP FS_LOAD_LOOP

FS_LOAD_DONE
    ; Update Svarl/Svarh = Smeml + loaded length
    ; This tells EhBASIC where variables start (= end of program)
    CLC
    LDA PROG_START_L
    ADC FS_ZP_CNT
    STA PROG_END_L
    LDA PROG_START_H
    ADC FS_ZP_CNT+1
    STA PROG_END_H

    JSR LAB_CRLF
    LDA #<FS_MSG_OK
    LDY #>FS_MSG_OK
    JSR FS_PRINT_STR
    CLC
    RTS

FS_LOAD_ABORT
    CLC
    RTS

FS_NOT_FOUND
    LDA #<FS_MSG_NOTFOUND
    LDY #>FS_MSG_NOTFOUND
    JSR FS_PRINT_STR
    SEC
    RTS

; ============================================================
; FS_DIR  -  List all files (call from BASIC via USR or
;            just wire it to a keyword if you extend EhBASIC)
; ============================================================
FS_DIR
    JSR FS_LOAD_DIR
    BCC FS_DIR_OK
    JMP FS_IO_ERR
FS_DIR_OK

    JSR LAB_CRLF
    LDA #<FS_MSG_DIRTITLE
    LDY #>FS_MSG_DIRTITLE
    JSR FS_PRINT_STR
    JSR LAB_CRLF

    LDA #$00
    STA FS_ZP_ENT           ; entry index

FS_DIR_LOOP
    LDA FS_ZP_ENT
    CMP #FS_MAX_ENTRIES
    BEQ FS_DIR_DONE

    ; Point FS_ZP_PTR at entry
    LDA FS_ZP_ENT
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC #<SECTOR_BUF
    STA FS_ZP_PTR
    LDA #>SECTOR_BUF
    ADC #$00
    STA FS_ZP_PTR+1

    ; Check flags
    LDY #FS_OFF_FLAGS
    LDA (FS_ZP_PTR),Y
    CMP #FS_FLAG_ACTIVE
    BNE FS_DIR_SKIP

    ; Print filename
    LDY #$00
FS_DIR_PRNAME
    LDA (FS_ZP_PTR),Y
    BEQ FS_DIR_PADNAME
    JSR V_OUTP
    INY
    CPY #16
    BNE FS_DIR_PRNAME
    JMP FS_DIR_PRINTSIZE

FS_DIR_PADNAME
    ; Pad with spaces to column 16
    LDA #' '
    JSR V_OUTP
    INY
    CPY #16
    BNE FS_DIR_PADNAME

FS_DIR_PRINTSIZE
    ; Print "  " then size in decimal
    LDA #' '
    JSR V_OUTP
    JSR V_OUTP

    LDY #FS_OFF_LEN
    LDA (FS_ZP_PTR),Y
    STA FS_ZP_CNT
    INY
    LDA (FS_ZP_PTR),Y
    STA FS_ZP_CNT+1

    ; Print 16-bit decimal (FS_ZP_CNT)
    JSR FS_PRINT_DEC

    LDA #' '
    JSR V_OUTP
    LDA #'B'
    JSR V_OUTP
    JSR LAB_CRLF

FS_DIR_SKIP
    INC FS_ZP_ENT
    JMP FS_DIR_LOOP

FS_DIR_DONE
    RTS

; ============================================================
; FS_DELETE  -  Mark a file as deleted
; Usage: CALL FS_DELETE address with "filename" in BASIC line
; or wire to a keyword. Parses quoted filename from Bpntrl.
; ============================================================
FS_DELETE
    JSR FS_PARSE_FNAME
    BCC FS_DEL_GONAME
    RTS
FS_DEL_GONAME

    JSR FS_LOAD_DIR
    BCC FS_DEL_DIROK
    JMP FS_IO_ERR
FS_DEL_DIROK

    JSR FS_FIND_NAME
    BCC FS_DEL_FOUND
    JMP FS_NOT_FOUND
FS_DEL_FOUND

    ; Set flags byte to $00
    LDA FS_ZP_ENT
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC #<SECTOR_BUF
    STA FS_ZP_PTR
    LDA #>SECTOR_BUF
    ADC #$00
    STA FS_ZP_PTR+1

    LDA #FS_FLAG_FREE
    LDY #FS_OFF_FLAGS
    STA (FS_ZP_PTR),Y

    JSR FS_SAVE_DIR
    BCC FS_DEL_SAVEOK
    JMP FS_IO_ERR
FS_DEL_SAVEOK

    LDA #<FS_MSG_DELETED
    LDY #>FS_MSG_DELETED
    JSR FS_PRINT_STR
    CLC
    RTS

FS_DEL_ABORT
    CLC
    RTS

; ============================================================
; FS_PARSE_FNAME
;
; Parse a quoted filename from the current BASIC execute
; pointer (Bpntrl/Bpntrh). Called when EhBASIC has just
; processed SAVE/LOAD/etc and Bpntrl points to the next
; character on the line, which should be a space then quote.
;
; Skips leading spaces, expects '"', copies chars up to
; closing '"' or end of line into FS_NAMEBUF (null-padded
; to 16 bytes).
;
; Returns C=0 if a valid name was found, C=1 if not.
; Advances Bpntrl/Bpntrh past the closing quote.
; ============================================================
FS_PARSE_FNAME
    LDY #$00                ; index into BASIC line

; skip spaces
FS_PF_SKIP
    LDA (Bpntrl),Y
    CMP #' '
    BNE FS_PF_QUOTE
    INY
    BNE FS_PF_SKIP
    ; Y wrapped - extremely long space run, give up
    SEC
    RTS

FS_PF_QUOTE
    CMP #$22                ; expecting open quote "
    BEQ FS_PF_OPEN
    SEC                     ; not a quote - syntax error
    RTS

FS_PF_OPEN
    INY                     ; move past opening quote
    LDX #$00                ; index into FS_NAMEBUF

FS_PF_COPY
    LDA (Bpntrl),Y
    BEQ FS_PF_NOCLOSE       ; hit EOL without closing quote - still ok, use what we have
    CMP #$22                ; closing quote?
    BEQ FS_PF_CLOSE
    CPX #15                 ; max 15 chars (+ null)
    BEQ FS_PF_SKIP2         ; silently drop chars beyond limit
    STA FS_NAMEBUF,X
    INX
FS_PF_SKIP2
    INY
    BNE FS_PF_COPY
    ; Y wrapped (line > 255 chars) - shouldn't happen in BASIC

FS_PF_CLOSE
    INY                     ; advance past closing quote

FS_PF_NOCLOSE
    ; Check we got at least one character
    CPX #$00
    BEQ FS_PF_EMPTY         ; empty filename

    ; Null-pad FS_NAMEBUF to 16 bytes
    LDA #$00
FS_PF_PAD
    STA FS_NAMEBUF,X
    INX
    CPX #16
    BNE FS_PF_PAD

    ; Advance BASIC execute pointer past what we consumed (Y bytes)
    TYA
    CLC
    ADC Bpntrl
    STA Bpntrl
    BCC FS_PF_OK
    INC Bpntrh

FS_PF_OK
    ; DEBUG: print the filename we parsed so we can verify it
    JSR LAB_CRLF
    LDA #<FS_MSG_PARSED
    LDY #>FS_MSG_PARSED
    JSR FS_PRINT_STR
    LDX #$00
FS_PF_DBLOOP
    LDA FS_NAMEBUF,X
    BEQ FS_PF_DBDONE
    JSR V_OUTP
    INX
    CPX #16
    BNE FS_PF_DBLOOP
FS_PF_DBDONE
    JSR LAB_CRLF
    CLC
    RTS

FS_PF_EMPTY
    SEC
    RTS

; ============================================================
; INTERNAL HELPERS
; ============================================================

; FS_LOAD_DIR  -  read sector 0 into SECTOR_BUF
FS_LOAD_DIR
    LDA #FS_DIR_SECTOR
    STA FS_ZP_SEC
    LDA #$00
    STA FS_ZP_SEC+1
    JSR FS_SET_LBA
    JMP CFREAD              ; tail-call; returns C=0 ok, C=1 error

; FS_SAVE_DIR  -  write SECTOR_BUF back to sector 0
FS_SAVE_DIR
    LDA #FS_DIR_SECTOR
    STA FS_ZP_SEC
    LDA #$00
    STA FS_ZP_SEC+1
    JSR FS_SET_LBA
    JMP CFWRITE             ; tail-call

; FS_SET_LBA  -  load FS_ZP_SEC (16-bit) into CF LBA registers
; Assumes LBA bits 16-27 = 0, CFREG6 = $E0 (master, LBA mode)
FS_SET_LBA
    LDA #$01
    STA CFREG2          ; sector count = 1
    LDA FS_ZP_SEC       ; LBA bits 0-7
    STA CFREG3
    LDA FS_ZP_SEC+1     ; LBA bits 8-15
    STA CFREG4
    LDA #$00            ; LBA bits 16-23 = 0
    STA CFREG5
    LDA #$E0            ; LBA bits 24-27 = 0, master, LBA mode
    STA CFREG6
    RTS

; FS_FIND_NAME  -  search SECTOR_BUF directory for FS_NAMEBUF
; Returns C=0, FS_ZP_ENT = entry index   if found
; Returns C=1                             if not found
FS_FIND_NAME
    LDA #$00
    STA FS_ZP_ENT

FS_FN_LOOP
    LDA FS_ZP_ENT
    CMP #FS_MAX_ENTRIES
    BEQ FS_FN_NOTFOUND

    ; Point FS_ZP_PTR at this entry
    LDA FS_ZP_ENT
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC #<SECTOR_BUF
    STA FS_ZP_PTR
    LDA #>SECTOR_BUF
    ADC #$00
    STA FS_ZP_PTR+1

    ; Check if active
    LDY #FS_OFF_FLAGS
    LDA (FS_ZP_PTR),Y
    CMP #FS_FLAG_ACTIVE
    BNE FS_FN_NEXT

    ; Compare name
    LDY #$00
FS_FN_CMP
    LDA (FS_ZP_PTR),Y
    CMP FS_NAMEBUF,Y
    BNE FS_FN_NEXT
    INY
    LDA FS_NAMEBUF,Y
    BEQ FS_FN_FOUND         ; both strings ended at same place = match
    CPY #16
    BNE FS_FN_CMP
    ; Fell off the end without mismatch - found
FS_FN_FOUND
    CLC
    RTS

FS_FN_NEXT
    INC FS_ZP_ENT
    JMP FS_FN_LOOP

FS_FN_NOTFOUND
    SEC
    RTS

; FS_FIND_FREE  -  find first directory entry with flags=$00 or unwritten ($FF unused)
; Returns C=0, FS_ZP_ENT = entry index   if found
; Returns C=1                             if directory full
FS_FIND_FREE
    LDA #$00
    STA FS_ZP_ENT
FS_FF_LOOP
    LDA FS_ZP_ENT
    CMP #FS_MAX_ENTRIES
    BEQ FS_FF_FULL

    LDA FS_ZP_ENT
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC #<SECTOR_BUF
    STA FS_ZP_PTR
    LDA #>SECTOR_BUF
    ADC #$00
    STA FS_ZP_PTR+1

    LDY #FS_OFF_FLAGS
    LDA (FS_ZP_PTR),Y
    CMP #FS_FLAG_ACTIVE
    BNE FS_FF_FOUND         ; not active = free (either $00 or uninitialised)
    INC FS_ZP_ENT
    JMP FS_FF_LOOP
FS_FF_FOUND
    CLC
    RTS
FS_FF_FULL
    SEC
    RTS

; FS_NEXT_FREE_SECTOR
; Scans all active directory entries, finds the highest
; (start_sector + ceil(length/512)), returns that in FS_ZP_SEC.
; If no files exist, returns FS_DATA_START.
FS_NEXT_FREE_SECTOR
    LDA #<FS_DATA_START
    STA FS_ZP_SEC
    LDA #>FS_DATA_START
    STA FS_ZP_SEC+1

    LDA #$00
    STA FS_ZP_ENT

FS_NFS_LOOP
    LDA FS_ZP_ENT
    CMP #FS_MAX_ENTRIES
    BEQ FS_NFS_DONE

    LDA FS_ZP_ENT
    ASL
    ASL
    ASL
    ASL
    ASL
    CLC
    ADC #<SECTOR_BUF
    STA FS_ZP_PTR
    LDA #>SECTOR_BUF
    ADC #$00
    STA FS_ZP_PTR+1

    ; Skip if not active
    LDY #FS_OFF_FLAGS
    LDA (FS_ZP_PTR),Y
    CMP #FS_FLAG_ACTIVE
    BNE FS_NFS_SKIP

    ; end_sector = start + ceil(len / 512)
    ; len_hi = len >> 8 roughly (since 512 = $0200, divide by 512
    ; means take the hi byte and add 1 if lo byte != 0)
    LDY #FS_OFF_LEN
    LDA (FS_ZP_PTR),Y       ; length lo
    STA FS_ZP_TMP
    INY
    LDA (FS_ZP_PTR),Y       ; length hi

    ; A:FS_ZP_TMP is 16-bit length.
    ; Sectors used = (length + 511) / 512
    ;              = (length_hi + (1 if length_lo != 0)) + start
    ; More precisely:  (length + 511) >> 9
    ; We only have 16-bit length so length can span at most 128 sectors.
    ; Simple: sectors = length_hi + (1 if length_lo non-zero) + 1(round up)
    ; Actually (len + 511) / 512:
    ;   temp16 = len + 511
    ;   result = temp16 >> 9  (= temp16_hi >> 1 ... but easier below)
    ; For a 6502 with 16-bit len < 32768: sectors_used = (len_hi) + (1 if len_lo!=0) + possible carry
    ; Simpler safe formula: add len_lo to $01FF, sectors = result_hi+start_hi ... 
    ; Let's just do it properly:

    ; FS_ZP_CNT = length (already stored), let's use it
    ; But FS_ZP_CNT is being used elsewhere. Use temp approach:
    ; Store start sector in ZP temporarily
    LDY #FS_OFF_STARTH
    LDA (FS_ZP_PTR),Y
    PHA                     ; start lo
    INY
    LDA (FS_ZP_PTR),Y
    PHA                     ; start hi

    ; Compute ceil(length / 512):
    ; = (len_hi) if len_lo==0, else (len_hi + 1)
    LDY #FS_OFF_LEN
    LDA (FS_ZP_PTR),Y       ; len lo
    PHA
    INY
    LDA (FS_ZP_PTR),Y       ; len hi = sectors (approx)
    TAX                     ; X = len_hi (= number of full 512-byte sectors if lo=0)
    PLA                     ; restore len lo
    BEQ FS_NFS_NOINC
    INX                     ; partial sector needs one more
FS_NFS_NOINC
    ; end_sector = start + X
    PLA                     ; start hi
    TAY
    PLA                     ; start lo
    CLC
    ADC #$00                ; just need to set C for multi-byte
    ; Actually add X to start (16-bit):
    TXA                     ; sectors to add
    PHA
    PLA                     ; restore to A
    ; start lo was just pulled (in A at "PLA" above for start lo)
    ; This is getting awkward - redo cleanly:
    ; We have start lo in A, start hi in Y, sectors in X
    ; end_sec_lo = start_lo + X (16-bit)
    ; Since X < 256 and start_lo < 256:
    PHA                     ; save start lo
    TXA
    STA FS_ZP_TMP           ; sectors to add
    PLA                     ; restore start lo
    CLC
    ADC FS_ZP_TMP
    TAX                     ; end_sec_lo in X
    TYA                     ; start_hi
    ADC #$00                ; add carry
    TAY                     ; end_sec_hi in Y

    ; Compare X:Y with FS_ZP_SEC (lo:hi), keep the larger
    CPY FS_ZP_SEC+1
    BCC FS_NFS_SKIP         ; Y < ZP_SEC+1: no update
    BNE FS_NFS_UPDATE       ; Y > ZP_SEC+1: update
    ; equal hi bytes - compare lo
    TXA
    CMP FS_ZP_SEC
    BCC FS_NFS_SKIP         ; X < ZP_SEC: no update
FS_NFS_UPDATE
    STX FS_ZP_SEC
    STY FS_ZP_SEC+1

FS_NFS_SKIP
    INC FS_ZP_ENT
    JMP FS_NFS_LOOP

FS_NFS_DONE
    RTS

; FS_FILL_SECTOR_BUF
; Copies up to 512 bytes from (FS_ZP_PTR) into SECTOR_BUF,
; consuming from FS_ZP_CNT (16-bit remaining byte count).
; Advances FS_ZP_PTR.  Fills remainder of sector with $00.
FS_FILL_SECTOR_BUF
    LDY #$00
    ; Inner counter: X counts bytes written (0..255 x 2 passes for 512)
    ; We write 512 bytes maximum: two passes of 256
    LDX #$00                ; buffer index lo byte
FS_FILL_OUTER
FS_FILL_INNER
    ; Check if bytes remaining
    LDA FS_ZP_CNT
    ORA FS_ZP_CNT+1
    BEQ FS_FILL_ZERO        ; no more data, pad with zero

    LDA (FS_ZP_PTR),Y
    STA SECTOR_BUF,X        ; NOTE: won't work if SECTOR_BUF+X > page - see note below

    ; Decrement remaining count
    LDA FS_ZP_CNT
    BNE FS_FSB_NOLO
    DEC FS_ZP_CNT+1
FS_FSB_NOLO
    DEC FS_ZP_CNT

    ; Advance source pointer
    INC FS_ZP_PTR
    BNE FS_FSB_NOPHI
    INC FS_ZP_PTR+1
FS_FSB_NOPHI
    INX
    BNE FS_FILL_INNER
    ; Crossed 256-byte boundary - need Y to track high byte
    INY                     ; Y tracks which 256-byte half of SECTOR_BUF
    CPY #$02
    BNE FS_FILL_INNER
    RTS

FS_FILL_ZERO
    LDA #$00
    STA SECTOR_BUF,X        ; pad rest of sector with zeros
    INX
    BNE FS_FILL_ZERO
    INY
    CPY #$02
    BNE FS_FILL_ZERO
    RTS

; NOTE on SECTOR_BUF,X above:
; This only works if SECTOR_BUF is at a 256-byte boundary and we use Y
; for the page offset. For non-page-aligned SECTOR_BUF you need indirect
; indexed via a pointer.  The above code uses X and Y together as a
; "256-byte half" index - it works correctly only if SECTOR_BUF is
; 256-byte aligned ($0200, $0300, $0400, etc).
; If not page-aligned, replace with pointer-based copy (see FS_DRAIN below).

; FS_DRAIN_SECTOR_BUF
; Copies up to 512 bytes from SECTOR_BUF into (FS_ZP_PTR),
; consuming FS_ZP_CNT. Advances FS_ZP_PTR.
FS_DRAIN_SECTOR_BUF
    LDY #$00
    LDX #$00
FS_DRAIN_OUTER
FS_DRAIN_INNER
    LDA FS_ZP_CNT
    ORA FS_ZP_CNT+1
    BEQ FS_DRAIN_DONE

    LDA SECTOR_BUF,X
    STA (FS_ZP_PTR),Y       ; store to destination

    ; Advance dest pointer
    INC FS_ZP_PTR
    BNE FS_DRN_NOPHI
    INC FS_ZP_PTR+1
FS_DRN_NOPHI

    ; Decrement remaining count
    LDA FS_ZP_CNT
    BNE FS_DRN_NOLO
    DEC FS_ZP_CNT+1
FS_DRN_NOLO
    DEC FS_ZP_CNT

    INX
    BNE FS_DRAIN_INNER
    INY
    CPY #$02
    BNE FS_DRAIN_INNER

FS_DRAIN_DONE
    RTS

; FS_GETNAME  -  read a filename from the user into FS_NAMEBUF
; Returns C=0 if a name was entered, C=1 if ESC or empty
; Echoes characters, handles backspace.
; Maximum 15 chars + null terminator.
FS_GETNAME
    LDX #$00                ; name buffer index
FS_GN_LOOP
    JSR V_INPT
    BCC FS_GN_LOOP          ; wait for keypress

    CMP #$1B                ; ESC
    BEQ FS_GN_ESC

    CMP #$0D                ; CR = end of input
    BEQ FS_GN_DONE

    CMP #$08                ; backspace
    BEQ FS_GN_BACK
    CMP #$7F                ; DEL (also backspace on some terminals)
    BEQ FS_GN_BACK

    ; Ignore if full (15 chars max - leave room for null)
    CPX #15
    BEQ FS_GN_LOOP

    ; Store char and echo
    STA FS_NAMEBUF,X
    JSR V_OUTP
    INX
    JMP FS_GN_LOOP

FS_GN_BACK
    CPX #$00
    BEQ FS_GN_LOOP          ; nothing to delete
    DEX
    LDA #$08
    JSR V_OUTP              ; backspace
    LDA #' '
    JSR V_OUTP              ; erase
    LDA #$08
    JSR V_OUTP              ; backspace again
    JMP FS_GN_LOOP

FS_GN_DONE
    CPX #$00
    BEQ FS_GN_ESC           ; empty name = abort

    ; Null-pad the rest of the buffer
    LDA #$00
FS_GN_PAD
    STA FS_NAMEBUF,X
    INX
    CPX #16
    BNE FS_GN_PAD
    CLC
    RTS

FS_GN_ESC
    SEC
    RTS

; FS_PRINT_STR  -  print null-terminated string
; A = lo address, Y = hi address
FS_PRINT_STR
    STA FS_ZP_PTR
    STY FS_ZP_PTR+1
    LDY #$00
FS_PS_LOOP
    LDA (FS_ZP_PTR),Y
    BEQ FS_PS_DONE
    JSR V_OUTP
    INY
    BNE FS_PS_LOOP
    INC FS_ZP_PTR+1
    JMP FS_PS_LOOP
FS_PS_DONE
    RTS

; FS_PRINT_DEC  -  print 16-bit value in FS_ZP_CNT as decimal
; Simple repeated subtraction for powers of 10
FS_PRINT_DEC
    LDX #$04                ; index into powers-of-10 table
    LDA #$00
    STA FS_ZP_TMP           ; leading zero flag
FS_PD_OUTER
    LDA FS_PD_POW10_HI,X
    PHA
    LDA FS_PD_POW10_LO,X
    PHA
    ; Digit = FS_ZP_CNT / current power
    LDY #$00
FS_PD_DIV
    ; Subtract power from FS_ZP_CNT
    SEC
    LDA FS_ZP_CNT
    SBC FS_PD_POW10_LO,X    ; This needs X still valid - use another approach
    ; ... pull and use a second temp

    ; Simpler: inline the subtraction
    PLA
    STA FS_ZP_PTR           ; power lo
    PLA
    STA FS_ZP_PTR+1         ; power hi (was pushed hi first)

    LDY #$00
FS_PD_COUNT
    LDA FS_ZP_CNT
    SEC
    SBC FS_ZP_PTR           ; lo
    STA FS_ZP_CNT
    LDA FS_ZP_CNT+1
    SBC FS_ZP_PTR+1         ; hi
    BCC FS_PD_EMIT          ; went negative: undo and emit digit
    STA FS_ZP_CNT+1
    INY
    JMP FS_PD_COUNT

FS_PD_EMIT
    ; Undo last subtraction
    LDA FS_ZP_CNT
    CLC
    ADC FS_ZP_PTR
    STA FS_ZP_CNT
    LDA FS_ZP_CNT+1
    ADC FS_ZP_PTR+1
    STA FS_ZP_CNT+1

    ; Y = digit
    CPY #$00
    BNE FS_PD_PRINT
    LDA FS_ZP_TMP
    BEQ FS_PD_SKIP          ; suppress leading zero (unless last digit)
    CPX #$00
    BEQ FS_PD_PRINT         ; always print the units digit

FS_PD_SKIP
    DEX
    BMI FS_PD_DONE
    JMP FS_PD_OUTER

FS_PD_PRINT
    LDA #$01
    STA FS_ZP_TMP           ; leading zero suppression off
    TYA
    CLC
    ADC #'0'
    JSR V_OUTP
    DEX
    BMI FS_PD_DONE
    JMP FS_PD_OUTER

FS_PD_DONE
    RTS

; Powers of 10 table (lo byte, hi byte)
FS_PD_POW10_LO
    !byte <1, <10, <100, <1000, <10000
FS_PD_POW10_HI
    !byte >1, >10, >100, >1000, >10000

; ============================================================
; MESSAGES
; ============================================================
FS_MSG_SAVEPROMPT
    !raw "Save as: ",$00
FS_MSG_LOADPROMPT
    !raw "Load file: ",$00
FS_MSG_DELPROMPT
    !raw "Delete file: ",$00
FS_MSG_PARSED
    !raw "File: ",$00
FS_MSG_OK
    !raw "OK",$0D,$0A,$00
FS_MSG_FULL
    !raw "Directory full",$0D,$0A,$00
FS_MSG_IOERR
    !raw "I/O error",$0D,$0A,$00
FS_MSG_NOTFOUND
    !raw "File not found",$0D,$0A,$00
FS_MSG_DELETED
    !raw "Deleted",$0D,$0A,$00
FS_MSG_DIRTITLE
    !raw "Filename        Bytes",$0D,$0A,"--------------------",$0D,$0A,$00
