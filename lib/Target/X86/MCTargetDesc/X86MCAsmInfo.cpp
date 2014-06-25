//===-- X86MCAsmInfo.cpp - X86 asm properties -----------------------------===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This file contains the declarations of the X86MCAsmInfo properties.
//
//===----------------------------------------------------------------------===//

#include "X86MCAsmInfo.h"
#include "llvm/ADT/Triple.h"
#include "llvm/MC/MCContext.h"
#include "llvm/MC/MCExpr.h"
#include "llvm/MC/MCSectionELF.h"
#include "llvm/MC/MCStreamer.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/ELF.h"
using namespace llvm;

enum AsmWriterFlavorTy {
  // Note: This numbering has to match the GCC assembler dialects for inline
  // asm alternatives to work right.
  ATT = 0, Intel = 1
};

static cl::opt<AsmWriterFlavorTy>
AsmWriterFlavor("x86-asm-syntax", cl::init(ATT),
  cl::desc("Choose style of code to emit from X86 backend:"),
  cl::values(clEnumValN(ATT,   "att",   "Emit AT&T-style assembly"),
             clEnumValN(Intel, "intel", "Emit Intel-style assembly"),
             clEnumValEnd));

static cl::opt<bool>
MarkedJTDataRegions("mark-data-regions", cl::init(false),
  cl::desc("Mark code section jump table data regions."),
  cl::Hidden);

void X86MCAsmInfoDarwin::anchor() { }

X86MCAsmInfoDarwin::X86MCAsmInfoDarwin(const Triple &T) {
  bool is64Bit = T.getArch() == Triple::x86_64;
  if (is64Bit)
    PointerSize = CalleeSaveStackSlotSize = 8;

  AssemblerDialect = AsmWriterFlavor;

  TextAlignFillValue = 0x90;

  if (!is64Bit)
    Data64bitsDirective = nullptr;       // we can't emit a 64-bit unit

  // Use ## as a comment string so that .s files generated by llvm can go
  // through the GCC preprocessor without causing an error.  This is needed
  // because "clang foo.s" runs the C preprocessor, which is usually reserved
  // for .S files on other systems.  Perhaps this is because the file system
  // wasn't always case preserving or something.
  CommentString = "##";

  SupportsDebugInformation = true;
  UseDataRegionDirectives = MarkedJTDataRegions;

  // Exceptions handling
  ExceptionsType = ExceptionHandling::DwarfCFI;

  // old assembler lacks some directives
  // FIXME: this should really be a check on the assembler characteristics
  // rather than OS version
  if (T.isMacOSX() && T.isMacOSXVersionLT(10, 6))
    HasWeakDefCanBeHiddenDirective = false;

  // FIXME: this should not depend on the target OS version, but on the ld64
  // version in use.  From at least >= ld64-97.17 (Xcode 3.2.6) the abs-ified
  // FDE relocs may be used. We also use them for the ios simulator.
  DwarfFDESymbolsUseAbsDiff = (T.isMacOSX() && !T.isMacOSXVersionLT(10, 6))
    || T.isiOS();

  UseIntegratedAssembler = true;
}

X86_64MCAsmInfoDarwin::X86_64MCAsmInfoDarwin(const Triple &Triple)
  : X86MCAsmInfoDarwin(Triple) {
}

void X86ELFMCAsmInfo::anchor() { }

X86ELFMCAsmInfo::X86ELFMCAsmInfo(const Triple &T) {
  bool is64Bit = T.getArch() == Triple::x86_64;
  bool isX32 = T.getEnvironment() == Triple::GNUX32;

  // For ELF, x86-64 pointer size depends on the ABI.
  // For x86-64 without the x32 ABI, pointer size is 8. For x86 and for x86-64
  // with the x32 ABI, pointer size remains the default 4.
  PointerSize = (is64Bit && !isX32) ? 8 : 4;

  // OTOH, stack slot size is always 8 for x86-64, even with the x32 ABI.
  CalleeSaveStackSlotSize = is64Bit ? 8 : 4;

  AssemblerDialect = AsmWriterFlavor;

  TextAlignFillValue = 0x90;

  // Set up DWARF directives
  HasLEB128 = true;  // Target asm supports leb128 directives (little-endian)

  // Debug Information
  SupportsDebugInformation = true;

  // Exceptions handling
  ExceptionsType = ExceptionHandling::DwarfCFI;

  // OpenBSD and Bitrig have buggy support for .quad in 32-bit mode, just split
  // into two .words.
  if ((T.getOS() == Triple::OpenBSD || T.getOS() == Triple::Bitrig) &&
       T.getArch() == Triple::x86)
    Data64bitsDirective = nullptr;

  // Always enable the integrated assembler by default.
  // Clang also enabled it when the OS is Solaris but that is redundant here.
  UseIntegratedAssembler = true;
}

const MCExpr *
X86_64MCAsmInfoDarwin::getExprForPersonalitySymbol(const MCSymbol *Sym,
                                                   unsigned Encoding,
                                                   MCStreamer &Streamer) const {
  MCContext &Context = Streamer.getContext();
  const MCExpr *Res =
    MCSymbolRefExpr::Create(Sym, MCSymbolRefExpr::VK_GOTPCREL, Context);
  const MCExpr *Four = MCConstantExpr::Create(4, Context);
  return MCBinaryExpr::CreateAdd(Res, Four, Context);
}

const MCSection *X86ELFMCAsmInfo::
getNonexecutableStackSection(MCContext &Ctx) const {
  return Ctx.getELFSection(".note.GNU-stack", ELF::SHT_PROGBITS,
                           0, SectionKind::getMetadata());
}

void X86MCAsmInfoMicrosoft::anchor() { }

X86MCAsmInfoMicrosoft::X86MCAsmInfoMicrosoft(const Triple &Triple) {
  if (Triple.getArch() == Triple::x86_64) {
    PrivateGlobalPrefix = ".L";
    PointerSize = 8;
    ExceptionsType = ExceptionHandling::Win64;
  }

  AssemblerDialect = AsmWriterFlavor;

  TextAlignFillValue = 0x90;

  AllowAtInName = true;

  UseIntegratedAssembler = true;
}

void X86MCAsmInfoGNUCOFF::anchor() { }

X86MCAsmInfoGNUCOFF::X86MCAsmInfoGNUCOFF(const Triple &Triple) {
  assert(Triple.isOSWindows() && "Windows is the only supported COFF target");
  if (Triple.getArch() == Triple::x86_64) {
    PrivateGlobalPrefix = ".L";
    PointerSize = 8;
    ExceptionsType = ExceptionHandling::Win64;
  } else {
    ExceptionsType = ExceptionHandling::DwarfCFI;
  }

  AssemblerDialect = AsmWriterFlavor;

  TextAlignFillValue = 0x90;

  UseIntegratedAssembler = true;
}
