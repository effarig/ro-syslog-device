DATE    = $(Sys$Date) $(Sys$Year)
ASFLAGS = -PreDefine "BUILDDATE SETS \"$(DATE)\"" -IArmLib: -throwback
AS      = objasm $(ASFLAGS) -o $@ $*.s
LINK    = link -rmf -o $@ $<

OBJS    = \
    header.o \
    driver.o

LIBS = ArmLib:o.armlib

GLOBAL_DEPS = \
    ARMLib:hdr.list \
    hdr.include \
    Makefile

MODNAME = SysLogDevice
MODFILE = SysLogDev
TGT     = rm.$(MODFILE)
DIST    = !System !ReadMe LICENSE
ZIPDIST = syslogdev/zip
MODDIST = !System.310.Modules.$(MODFILE)

all: $(TGT)

$(OBJS): dirs

dirs:
    @cdir o
    @cdir rm

dist: $(TGT)
    @echo Removing previous distribution archive...
    @-wipe $(ZIPDIST) F~VR~C
    @echo Copying $(TGT) to $(MODDIST)
    @copy $(TGT) $(MODDIST) A~CF~L~N~P~QR~S~T~V
    @echo Zipping as $(ZIPDIST)...
    @zip -9 -r $(ZIPDIST) $(DIST)
    @echo Done.

clean:
    @-wipe o RF~C~V
    @-wipe rm RF~C~V
    @-wipe $(TGT) $(ZIPDIST) RF~C~V

init: $(TGT)
    @echo Reinitialising driver
    @-RMKill $(MODNAME)
    @RMLoad $(TGT)

$(OBJS): $(GLOBAL_DEPS)

$(TGT): $(OBJS)
    @echo Linking $*...
    @$(LINK) $(OBJS) $(LIBS)

.SUFFIXES: .o .s

.s.o:
    @echo Assembling $*...
    @$(AS)
