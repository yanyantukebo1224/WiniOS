import shutil
import re

print("Patching FEX CMakeLists.txt...")
with open("FEX/CMakeLists.txt", "r", encoding="utf-8", errors="ignore") as f:
    s = f.read()
s = s.replace("string(TOLOWER ${CMAKE_SYSTEM_PROCESSOR} processor)", "set(CMAKE_SYSTEM_PROCESSOR \"arm64\")\nstring(TOLOWER \"${CMAKE_SYSTEM_PROCESSOR}\" processor)")
with open("FEX/CMakeLists.txt", "w", encoding="utf-8") as f:
    f.write(s)

print("Patching AtomicRefPolyfill...")
shutil.copyfile("app/Madeira/AtomicRefPolyfill.h", "FEX/FEXCore/include/FEXCore/Utils/AtomicRefPolyfill.h")
for p in ["FEX/FEXCore/include/FEXCore/Utils/SpinWaitLock.h", "FEX/FEXCore/include/FEXCore/Utils/WritePriorityMutex.h", "FEX/FEXCore/include/FEXCore/Utils/SHMStats.h"]:
    with open(p, "r", encoding="utf-8", errors="ignore") as f:
        c = f.read()
    if "AtomicRefPolyfill.h" not in c:
        c = "#include <FEXCore/Utils/AtomicRefPolyfill.h>\n" + c
        with open(p, "w", encoding="utf-8") as f:
            f.write(c)

print("Patching Core.cpp...")
core_cpp = "FEX/FEXCore/Source/Interface/Core/Core.cpp"
with open(core_cpp, "r", encoding="utf-8", errors="ignore") as f:
    cc = f.read()
old_block = "  /* iOS-Madeira ml316: report ExitToX64 FFS bypasses"
if old_block in cc and "#ifdef FEX_IOS_HOST\n  /* iOS-Madeira ml316" not in cc:
    cc = cc.replace(old_block, "#ifdef FEX_IOS_HOST\n" + old_block)
    close_block = "IosCbEntryLog[4], IosCbEntryLog[5], IosCbEntryLog[7]);\n    }\n  }"
    cc = cc.replace(close_block, close_block + "\n#endif")
    with open(core_cpp, "w", encoding="utf-8") as f:
        f.write(cc)

print("Patching Arm64.cpp...")
arm64_cpp = "FEX/FEXCore/Source/Utils/ArchHelpers/Arm64.cpp"
with open(arm64_cpp, "r", encoding="utf-8", errors="ignore") as f:
    ac = f.read()
if "VirtualQuery" in ac:
    pat = r"static void IosLogUnimplementedCASPAL\([^{]*\{[\s\S]*?\n\}"
    rep = (
        "static void IosLogUnimplementedCASPAL(uint32_t Size, uint32_t AddressReg, const uint64_t* GPRs) {\n"
        "  static uint32_t reports = 0;\n"
        "  if (Size == 0 || (GPRs[AddressReg] & 15) == 0 || reports >= 8) {\n"
        "    return;\n"
        "  }\n"
        "  reports++;\n"
        "  LogMan::Msg::EFmt(\"[caspal128] MISALIGNED-UNSUPPORTED Size={} addrReg=x{} addr={:#x} misalign={} crosses16B={}\",\n"
        "                    Size, AddressReg, GPRs[AddressReg], GPRs[AddressReg] & 15,\n"
        "                    (GPRs[AddressReg] & 15) ? \"yes\" : \"no\");\n"
        "}"
    )
    ac = re.sub(pat, rep, ac)
    with open(arm64_cpp, "w", encoding="utf-8") as f:
        f.write(ac)

print("FEX patching complete!")
