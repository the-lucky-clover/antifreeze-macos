// AntiFreeze-Bridging-Header.h
//
// Exposes C-only system headers to Swift.
//
// libproc.h (proc_listpids / proc_pidinfo, used by ProcessCollector) is not
// part of Swift's Darwin module, so without this header Xcode fails with
// "use of unresolved identifier 'proc_pidinfo'". sys/sysctl.h backs the
// swap-usage read in MemoryCollector.
//
// Set in Xcode under: target → Build Settings → "Objective-C Bridging Header"
// → AntiFreeze/AntiFreeze-Bridging-Header.h (see BUILD_GUIDE.md Step 6).

#ifndef AntiFreeze_Bridging_Header_h
#define AntiFreeze_Bridging_Header_h

#include <libproc.h>
#include <sys/sysctl.h>

#endif /* AntiFreeze_Bridging_Header_h */
