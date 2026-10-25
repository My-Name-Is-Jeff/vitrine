// A crash's stack for FLEX builds, where iOS writes none: on a jailbroken iPhone 11 the kernel answered every crash
// with "Corpse failure, too many 6" and no report reached the phone (2026-10-23). On SIGSEGV, SIGBUS, SIGILL, SIGTRAP
// and SIGABRT the faulting thread's frames are walked from its registers by their frame pointers and written to a file
// in Caches, each as image + offset; the next launch logs the file and removes it. The handler runs on a stack of its
// own for the main thread, so a stack overflow (a recursion) is caught too, and hands the signal on to the handler
// that was there before (Spotify's Crashlytics) or to the default.
//
// Threading: installed on the main thread. The handler only writes to a descriptor and reads tables filled before
// it runs (the images, the main thread's stack), as nothing that takes a lock may run in it.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <sys/ucontext.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <pthread.h>
#import <stdatomic.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif
#import "Core/SGCore.h"

#if SG_DRIVER

static char sg_path[1024];
static const int kSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT};
enum { kSignalCount = sizeof kSignals / sizeof *kSignals, kMaxFrames = 96 };
static struct sigaction sg_previous[kSignalCount];

// Every image's code as dyld reports it loading, for the handler: dladdr takes dyld's lock, which the crashed thread
// may hold. The name is copied, so an image closed since leaves nothing freed behind.
typedef struct {
    uintptr_t base, start, end;
    char name[64];
} Image;
enum { kMaxImages = 2048 };
static Image sg_images[kMaxImages];
static atomic_int sg_imageCount;

static void addImage(const struct mach_header *header, intptr_t slide) {
    int count = atomic_load(&sg_imageCount);
    Dl_info info;
    unsigned long size = 0;
    uint8_t *text = getsegmentdata((const struct mach_header_64 *)header, SEG_TEXT, &size);
    if (count >= kMaxImages || !text || !dladdr(header, &info) || !info.dli_fname) return;
    const char *slash = info.dli_fname;
    for (const char *c = info.dli_fname; *c; c++) if (*c == '/') slash = c + 1;
    sg_images[count] = (Image){(uintptr_t)header, (uintptr_t)text, (uintptr_t)text + size, {0}};
    strlcpy(sg_images[count].name, slash, sizeof sg_images[count].name);
    atomic_store(&sg_imageCount, count + 1);
}

// The main thread's stack, read when the handler is installed, so a frame pointer is followed only inside its stack.
static pthread_t sg_mainThread;
static uintptr_t sg_mainBottom, sg_mainTop;

static void put(int fd, const char *text) {
    size_t length = 0;
    while (text[length]) length++;
    if (length) (void)write(fd, text, length);
}

static void putHex(int fd, uintptr_t value) {
    char digits[19] = "0x";
    int n = 0;
    char reversed[16];
    do {
        reversed[n++] = "0123456789abcdef"[value & 15];
        value >>= 4;
    } while (value && n < 16);
    for (int i = 0; i < n; i++) digits[2 + i] = reversed[n - 1 - i];
    digits[2 + n] = 0;
    put(fd, digits);
}

static uintptr_t strip(uintptr_t address) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_return_address);
#else
    return address;
#endif
}

static void putFrame(int fd, uintptr_t address) {
    put(fd, "  ");
    putHex(fd, address);
    int count = atomic_load(&sg_imageCount);
    for (int i = 0; i < count; i++) {
        if (address < sg_images[i].start || address >= sg_images[i].end) continue;
        put(fd, " ");
        put(fd, sg_images[i].name);
        put(fd, " +");
        putHex(fd, address - sg_images[i].base);
        break;
    }
    put(fd, "\n");
}

static volatile sig_atomic_t sg_inHandler;

static void writeTrace(siginfo_t *info, void *context, int signal) {
    int fd = open(sg_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    put(fd, "signal ");
    putHex(fd, (uintptr_t)signal);
    put(fd, " at ");
    putHex(fd, (uintptr_t)(info ? info->si_addr : 0));
    put(fd, "\n");
    ucontext_t *uc = context;
    if (uc && uc->uc_mcontext) {
        uintptr_t pc = strip((uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss));
        uintptr_t lr = strip((uintptr_t)arm_thread_state64_get_lr(uc->uc_mcontext->__ss));
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
        // A frame is followed only inside the crashed thread's stack: a frame pointer out of it faults again. The
        // main thread's was read when armed; another thread's is read from its pthread, a field read with no lock.
        pthread_t self = pthread_self();
        BOOL onMain = pthread_equal(self, sg_mainThread);
        uintptr_t top = onMain ? sg_mainTop : (uintptr_t)pthread_get_stackaddr_np(self);
        uintptr_t bottom = onMain ? sg_mainBottom : top - pthread_get_stacksize_np(self);
        #define SG_IN_STACK(p) ((p) >= bottom && (p) + 16 <= top && !((p) & 7))
        putFrame(fd, pc);
        // lr is the caller only in a function that has not saved it in a frame yet; otherwise the walk prints it.
        if (!SG_IN_STACK(fp) || lr != strip(((uintptr_t *)fp)[1])) putFrame(fd, lr);
        // A recursion repeats one frame thousands of times: the first kMaxFrames say which.
        for (int i = 0; i < kMaxFrames && SG_IN_STACK(fp); i++) {
            uintptr_t *frame = (uintptr_t *)fp;
            uintptr_t next = frame[0], ret = strip(frame[1]);
            if (!ret) break;
            putFrame(fd, ret);
            if (next <= fp) break;
            fp = next;
        }
        #undef SG_IN_STACK
    }
    close(fd);
}

static void handler(int signal, siginfo_t *info, void *context) {
    if (!sg_inHandler) {
        sg_inHandler = 1;
        writeTrace(info, context, signal);
    }
    // A handler installed in front of this one called it as the one before it (Spotify's crash reporter after it took
    // the signal back): that one carries on from here. Handing on again would run it twice.
    struct sigaction current;
    if (sigaction(signal, NULL, &current) != 0 || !(current.sa_flags & SA_SIGINFO) || current.sa_sigaction != handler) return;
    // The handler that was there before, or the default, which ends the process with this signal.
    for (int i = 0; i < kSignalCount; i++) {
        if (kSignals[i] != signal) continue;
        struct sigaction previous = sg_previous[i];
        // Back from it, the signal was one it got over: the next one is written again.
        if ((previous.sa_flags & SA_SIGINFO) && previous.sa_sigaction) {
            sigaction(signal, &previous, NULL);
            previous.sa_sigaction(signal, info, context);
            sg_inHandler = 0;
            return;
        }
        if (previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN && previous.sa_handler) {
            sigaction(signal, &previous, NULL);
            previous.sa_handler(signal);
            sg_inHandler = 0;
            return;
        }
    }
    struct sigaction fallback = {0};
    fallback.sa_handler = SIG_DFL;
    sigaction(signal, &fallback, NULL);
    raise(signal);
}

static void logLastCrash(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text.length) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    SGLog(@"crash trace: the last launch ended on a signal");
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (line.length) SGLog(@"crash trace: %@", line);
    }
}

// Our handler for every signal that has lost it, the one there now kept as the one to hand on to. Spotify's crash
// reporter sets its own after launch, and a crash on the phone left no trace though ours was in (2026-10-24), so this
// runs again a few times while the launch settles (install).
static int arm(void) {
    int armed = 0;
    for (int i = 0; i < kSignalCount; i++) {
        struct sigaction current;
        if (sigaction(kSignals[i], NULL, &current) == 0 && (current.sa_flags & SA_SIGINFO) && current.sa_sigaction == handler) continue;
        struct sigaction action = {0};
        action.sa_sigaction = handler;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&action.sa_mask);
        struct sigaction previous;
        if (sigaction(kSignals[i], &action, &previous) == 0) {
            sg_previous[i] = previous;
            armed++;
        }
    }
    return armed;
}

// Armed again 5 s after install, then 10, 20, 40 and 80 s after that, and then left: by then Spotify's launch has set
// up its crash reporter.
static void armAgain(int64_t seconds) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        int armed = arm();
        if (armed) SGLog(@"crash trace: another handler had taken %d signals, taken back", armed);
        if (seconds < 80) armAgain(seconds * 2);
    });
}

static void install(void) {
    static void *altStack;
    altStack = malloc(SIGSTKSZ * 4);
    stack_t stack = {.ss_sp = altStack, .ss_size = SIGSTKSZ * 4, .ss_flags = 0};
    sigaltstack(&stack, NULL);
    sg_mainThread = pthread_self();
    sg_mainTop = (uintptr_t)pthread_get_stackaddr_np(sg_mainThread);
    sg_mainBottom = sg_mainTop - pthread_get_stacksize_np(sg_mainThread);
    // Called for every image already loaded, then for each one loaded later.
    _dyld_register_func_for_add_image(addImage);
    arm();
    armAgain(5);
}

__attribute__((constructor)) static void SGCrashTraceInit(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [caches stringByAppendingPathComponent:@"sg-crash.txt"];
    if (!path || path.length >= sizeof sg_path) return;
    strlcpy(sg_path, path.fileSystemRepresentation, sizeof sg_path);
    logLastCrash(path);
    // At once, so a crash at launch is caught too; the re-arms take the signals back from Spotify's crash reporter
    // once it has set itself up, so the trace goes first and hands on to it.
    install();
    SGLog(@"crash trace: watching for a crash");
}

#endif
