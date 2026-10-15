#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include "../SonyClassicConnection.h"
#include "LDACParentLifetime.h"
#include <CoreAudio/AudioHardware.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <time.h>
#include <math.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL inputEnded;
static BOOL disarmed;
static char parentCommand[16];
static size_t parentCommandLength;

static void RunLoopFor(NSTimeInterval seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
}

static double MonotonicTime(void) {
    return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000000.0;
}

static NSString *NormalizeAddress(const char *value) {
    if (!value || strlen(value) != 17 || (value[2] != ':' && value[2] != '-')) return nil;
    for (NSUInteger index = 0; index < 17; index++) {
        if (index % 3 == 2) {
            if (value[index] != value[2]) return nil;
        } else if (!((value[index] >= '0' && value[index] <= '9') ||
                     (value[index] >= 'a' && value[index] <= 'f') ||
                     (value[index] >= 'A' && value[index] <= 'F'))) return nil;
    }
    return [[[NSString stringWithUTF8String:value] uppercaseString] stringByReplacingOccurrencesOfString:@":" withString:@"-"];
}

static BOOL ParentInputEnded(void) {
    if (inputEnded || disarmed) return YES;
    struct pollfd descriptor = {STDIN_FILENO, POLLIN, 0};
    int status = poll(&descriptor, 1, 0);
    if (status < 0) return errno != EINTR;
    if (!status) return NO;
    if (descriptor.revents & (POLLIN | POLLHUP)) {
        char values[64];
        ssize_t count = read(STDIN_FILENO, values, sizeof(values));
        if (!count || (count < 0 && errno != EINTR)) inputEnded = YES;
        for (ssize_t index = 0; index < count; index++) {
            if (values[index] == '\n') {
                disarmed |= parentCommandLength == 6 && !memcmp(parentCommand, "disarm", 6);
                parentCommandLength = 0;
            } else if (parentCommandLength < sizeof(parentCommand)) {
                parentCommand[parentCommandLength++] = values[index];
            } else inputEnded = YES;
        }
    }
    if (descriptor.revents & (POLLERR | POLLNVAL)) inputEnded = YES;
    return inputEnded || disarmed;
}

static BOOL ParentExited(int events) {
    struct kevent event;
    struct timespec immediately = {0, 0};
    return kevent(events, NULL, 0, &event, 1, &immediately) == 1 &&
        event.filter == EVFILT_PROC && (event.fflags & NOTE_EXIT);
}

static int ConnectionLock(NSString *address, BOOL watchParent) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"dev.baglayan.Acouplet.audio-%@.lock", address]];
    int descriptor = open(path.fileSystemRepresentation, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat attributes;
    if (descriptor < 0) return -1;
    if (fstat(descriptor, &attributes) || !S_ISREG(attributes.st_mode) ||
        attributes.st_uid != geteuid() || attributes.st_nlink != 1 || (attributes.st_mode & 0077)) {
        close(descriptor);
        return -1;
    }
    double deadline = MonotonicTime() + 5;
    while (flock(descriptor, LOCK_EX | LOCK_NB)) {
        if ((errno != EWOULDBLOCK && errno != EINTR) || MonotonicTime() >= deadline ||
            (watchParent && ParentInputEnded())) {
            close(descriptor);
            return -1;
        }
        RunLoopFor(0.01);
    }
    return descriptor;
}

static BOOL ReadAudio(AudioObjectID object, UInt32 selector, UInt32 scope, UInt32 capacity, void *value) {
    AudioObjectPropertyAddress property = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 size = capacity;
    return AudioObjectGetPropertyData(object, &property, 0, NULL, &size, value) == noErr && size == capacity;
}

static int NativeOutputState(NSString *address) {
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &property, 0, NULL, &size) != noErr ||
        size % sizeof(AudioObjectID)) return -1;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    UInt32 capacity = size;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, 0, NULL, &size, data.mutableBytes) != noErr ||
        size > capacity || size % sizeof(AudioObjectID)) return -1;
    const AudioObjectID *devices = data.bytes;
    for (UInt32 index = 0; index < size / sizeof(AudioObjectID); index++) {
        CFStringRef rawUID = NULL;
        if (!ReadAudio(devices[index], kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, sizeof(rawUID), &rawUID) ||
            !rawUID || CFGetTypeID(rawUID) != CFStringGetTypeID()) {
            if (rawUID) CFRelease(rawUID);
            return -1;
        }
        NSString *uid = CFBridgingRelease(rawUID);
        if (uid.length < 17 || (uid.length > 17 && [uid characterAtIndex:17] != ':') ||
            ![NormalizeAddress([uid substringToIndex:17].UTF8String) isEqualToString:address]) continue;
        UInt32 transport = 0, alive = 0;
        if (!ReadAudio(devices[index], kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, sizeof(transport), &transport) ||
            !ReadAudio(devices[index], kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, sizeof(alive), &alive)) return -1;
        if (transport != kAudioDeviceTransportTypeBluetooth || alive != 1) continue;
        property = (AudioObjectPropertyAddress){kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
        UInt32 configurationSize = 0;
        if (AudioObjectGetPropertyDataSize(devices[index], &property, 0, NULL, &configurationSize) != noErr ||
            configurationSize < offsetof(AudioBufferList, mBuffers)) return -1;
        NSMutableData *configuration = [NSMutableData dataWithLength:configurationSize];
        UInt32 configurationCapacity = configurationSize;
        if (AudioObjectGetPropertyData(devices[index], &property, 0, NULL, &configurationSize, configuration.mutableBytes) != noErr ||
            configurationSize > configurationCapacity || configurationSize < offsetof(AudioBufferList, mBuffers)) return -1;
        const AudioBufferList *buffers = configuration.bytes;
        if (buffers->mNumberBuffers > (configurationSize - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer)) return -1;
        for (UInt32 buffer = 0; buffer < buffers->mNumberBuffers; buffer++) {
            if (buffers->mBuffers[buffer].mNumberChannels) return 1;
        }
    }
    return 0;
}

static int PriorityIdle(NSString *uid) {
    CFStringRef qualifier = (__bridge CFStringRef)uid;
    AudioObjectPropertyAddress property = {kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &property, sizeof(qualifier), &qualifier, &size, &device) != noErr ||
        size != sizeof(device) || device == kAudioObjectUnknown) return -1;
    CFPropertyListRef value = NULL;
    if (!ReadAudio(device, 'xmpr', kAudioObjectPropertyScopeGlobal, sizeof(value), &value) ||
        !value || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
        if (value) CFRelease(value);
        return -1;
    }
    CFTypeRef phase = CFDictionaryGetValue(value, CFSTR("phase"));
    int idle = phase && CFGetTypeID(phase) == CFStringGetTypeID()
        ? (CFEqual(phase, CFSTR("idle")) ? 1 : 0) : -1;
    CFRelease(value);
    return idle;
}

@interface ConnectionObserver : NSObject
@property BOOL done;
@property IOReturn status;
@property BOOL disconnected;
@property BluetoothConnectionHandle originalHandle;
@property IOBluetoothUserNotification *disconnectNotification;
@end
@implementation ConnectionObserver
- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    self.status = status;
    self.done = YES;
    if (status == kIOReturnSuccess && SonyClassicIsConnected(device)) self.originalHandle = device.connectionHandle;
    printf("CONNECTION_CALLBACK time=%.6f status=0x%08X connected=%d\n", NSDate.date.timeIntervalSince1970, status, SonyClassicIsConnected(device));
}
- (void)disconnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device {
    self.disconnected = YES;
    [notification unregister];
    self.disconnectNotification = nil;
    printf("CONNECTION_DISCONNECTED handle=%04X connected=%d\n", self.originalHandle, SonyClassicIsConnected(device));
}
@end

static int WatchConnection(IOBluetoothDevice *device, ConnectionObserver *observer, NSString *address, NSString *priorityUID, int parentEvents) {
    // IOBluetooth reports handle 0000 for every ACL on current macOS, so a zero handle cannot tell connections
    // apart; say so instead of claiming a guard. The disconnect notification still retires the connection.
    printf("CONNECT_READY handle=%04X guarded=%d\n", observer.originalHandle, observer.originalHandle != 0);
    BOOL parentExited = NO;
    while (YES) {
        ParentInputEnded();
        parentExited |= ParentExited(parentEvents);
        if (observer.disconnected || !SonyClassicIsConnected(device) || device.connectionHandle != observer.originalHandle) {
            printf("CONNECT_RETIRED reason=original-connection-ended\n");
            [observer.disconnectNotification unregister];
            return 0;
        }
        if (disarmed) {
            printf("CONNECT_DISARMED explicit=%d parentExited=%d\n", disarmed, parentExited);
            [observer.disconnectNotification unregister];
            return 0;
        }
        if (parentExited) break;
        RunLoopFor(0.1);
    }
    alarm(80);
    printf("CONNECT_OWNER_EXIT handle=%04X\n", observer.originalHandle);
    double deadline = MonotonicTime() + 45;
    while (MonotonicTime() < deadline) {
        if (observer.disconnected || !SonyClassicIsConnected(device) || device.connectionHandle != observer.originalHandle) break;
        int native = NativeOutputState(address);
        int idle = priorityUID ? PriorityIdle(priorityUID) : 1;
        if (native != 0 || idle < 0) {
            printf("CONNECT_RECOVERY_SKIPPED native=%d priority=%d\n", native, idle);
            [observer.disconnectNotification unregister];
            return native == 1 ? 0 : 6;
        }
        if (idle == 1) {
            RunLoopFor(0.1);
            if (observer.disconnected || !SonyClassicIsConnected(device) || device.connectionHandle != observer.originalHandle) break;
            native = NativeOutputState(address);
            if (native != 0) {
                printf("CONNECT_RECOVERY_SKIPPED native=%d priority=1\n", native);
                [observer.disconnectNotification unregister];
                return native == 1 ? 0 : 6;
            }
            if (observer.disconnected || !SonyClassicIsConnected(device) || device.connectionHandle != observer.originalHandle) break;
            IOReturn status = [device closeConnection];
            printf("CONNECT_RECOVERY_CLOSE status=0x%08X handle=%04X\n", status, observer.originalHandle);
            if (status != kIOReturnSuccess) return 6;
            double closeDeadline = MonotonicTime() + 5;
            while (!observer.disconnected && SonyClassicIsConnected(device) && MonotonicTime() < closeDeadline)
                RunLoopFor(0.01);
            [observer.disconnectNotification unregister];
            if (SonyClassicIsConnected(device)) {
                printf("CONNECT_RECOVERY_SKIPPED reason=connection-present-after-close\n");
                return 6;
            }
            ConnectionObserver *restored = [ConnectionObserver new];
            status = [device openConnection:restored];
            printf("CONNECT_RECOVERY_OPEN status=0x%08X\n", status);
            if (status != kIOReturnSuccess) return 6;
            double openDeadline = MonotonicTime() + 15;
            while (!restored.done && MonotonicTime() < openDeadline)
                RunLoopFor(0.01);
            if (!restored.done) {
                double settlementDeadline = MonotonicTime() + 2;
                while (!restored.done && MonotonicTime() < settlementDeadline)
                    RunLoopFor(0.01);
            }
            if (!restored.done || restored.status != kIOReturnSuccess || !SonyClassicIsConnected(device)) {
                printf("CONNECT_RECOVERY_UNCONFIRMED callback=%d connected=%d status=0x%08X\n", restored.done, SonyClassicIsConnected(device), restored.status);
                return 6;
            }
            double publishDeadline = MonotonicTime() + 8;
            native = NativeOutputState(address);
            while (native == 0 && SonyClassicIsConnected(device) && device.connectionHandle == restored.originalHandle && MonotonicTime() < publishDeadline) {
                RunLoopFor(0.05);
                native = NativeOutputState(address);
            }
            printf("CONNECT_RECOVERED native=%d connected=%d\n", native, SonyClassicIsConnected(device));
            return native == 1 ? 0 : 6;
        }
        RunLoopFor(0.05);
    }
    [observer.disconnectNotification unregister];
    printf("CONNECT_RECOVERY_SKIPPED reason=connection-ended-or-priority-deadline\n");
    return 6;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *address = nil;
        BOOL addressSeen = NO;
        BOOL disconnect = NO;
        BOOL watchParent = NO;
        BOOL restore = NO;
        NSString *priorityUID = nil;
        BluetoothConnectionHandle expectedHandle = kBluetoothConnectionHandleNone;
        BOOL expectedHandleSeen = NO;
        for (int index = 1; index < argc; index++) {
            if (!strcmp(argv[index], "--address") && !addressSeen && index + 1 < argc) {
                address = NormalizeAddress(argv[++index]);
                addressSeen = YES;
                if (address) continue;
            } else if (!strcmp(argv[index], "--disconnect") && !disconnect) {
                disconnect = YES;
                continue;
            } else if (!strcmp(argv[index], "--watch-parent") && !watchParent) {
                watchParent = YES;
                continue;
            } else if (!strcmp(argv[index], "--restore") && !restore) {
                restore = YES;
                continue;
            } else if (!strcmp(argv[index], "--expected-handle") && !expectedHandleSeen && index + 1 < argc) {
                const char *value = argv[++index];
                expectedHandleSeen = YES;
                if (strlen(value) == 4 && strspn(value, "0123456789abcdefABCDEF") == 4) {
                    unsigned long handle = strtoul(value, NULL, 16);
                    if (handle < kBluetoothConnectionHandleNone) {
                        expectedHandle = (BluetoothConnectionHandle)handle;
                        continue;
                    }
                }
            } else if (!strcmp(argv[index], "--priority-device-uid") && !priorityUID && index + 1 < argc) {
                priorityUID = [NSString stringWithUTF8String:argv[++index]];
                if (priorityUID.length > 0 && priorityUID.length <= 1024) continue;
            }
            fprintf(stderr, "Usage: %s --address XX-XX-XX-XX-XX-XX [--disconnect] [--watch-parent] [--restore] [--priority-device-uid UID] [--expected-handle HHHH]\n", argv[0]);
            return 2;
        }
        if (!addressSeen || (priorityUID && (!watchParent || disconnect)) || (restore && watchParent) ||
            (expectedHandleSeen && (!restore || !disconnect))) return 2;
        if (!LDACWatchParent(90)) return 3;
        setbuf(stdout, NULL);
        signal(SIGPIPE, SIG_IGN);
        int parentEvents = -1;
        if (watchParent) {
            pid_t parent = getppid();
            parentEvents = kqueue();
            struct kevent event;
            EV_SET(&event, parent, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
            if (parent <= 1 || parentEvents < 0 || kevent(parentEvents, &event, 1, NULL, 0, NULL)) return 3;
        }
        int connectionLock = ConnectionLock(address, watchParent);
        if (connectionLock < 0) {
            BOOL canceled = watchParent && ParentInputEnded();
            printf("CONNECT_LOCK_UNAVAILABLE canceled=%d\n", canceled);
            return canceled ? 0 : 3;
        }
        IOBluetoothDevice *device = [IOBluetoothDevice deviceWithAddressString:address];
        printf("BEFORE time=%.6f address=%s paired=%d connected=%d\n", NSDate.date.timeIntervalSince1970, address.UTF8String, device.isPaired, SonyClassicIsConnected(device));
        if (!device || !device.isPaired) return 2;
        double restoreDeadline = restore ? MonotonicTime() + 45 : INFINITY;
        if (restore) {
            int native = NativeOutputState(address);
            if (native != 0) {
                BOOL connected = SonyClassicIsConnected(device);
                if (native == 1 && connected) printf("RESTORE_PRESERVED native=1 connected=1\n");
                else if (native == 1) printf("RESTORE_UNCONFIRMED native=1 connected=0 reason=native-output-without-connection\n");
                else printf("RESTORE_UNCONFIRMED native=-1 connected=%d reason=output-inspection\n", SonyClassicIsConnected(device));
                return native == 1 && connected ? 0 : 6;
            }
            if (SonyClassicIsConnected(device) && (!disconnect || !expectedHandleSeen || device.connectionHandle != expectedHandle)) {
                double publishDeadline = MonotonicTime() + 8;
                while (native == 0 && SonyClassicIsConnected(device) && MonotonicTime() < publishDeadline) {
                    RunLoopFor(0.05);
                    native = NativeOutputState(address);
                }
                if (native != 0 || SonyClassicIsConnected(device)) {
                    BOOL connected = SonyClassicIsConnected(device);
                    if (native == 1 && connected) printf("RESTORE_PRESERVED native=1 connected=1\n");
                    else if (native == 1) printf("RESTORE_UNCONFIRMED native=1 connected=0 reason=native-output-without-connection\n");
                    else if (native < 0) printf("RESTORE_UNCONFIRMED native=-1 connected=%d reason=output-inspection\n", connected);
                    else printf("RESTORE_UNCONFIRMED native=%d connected=%d reason=existing-connection-without-native-output\n", native, connected);
                    return native == 1 && connected ? 0 : 6;
                }
            }
        }
        if (disconnect) {
            if (restore && SonyClassicIsConnected(device) &&
                (!expectedHandleSeen || device.connectionHandle != expectedHandle)) {
                printf("RESTORE_UNCONFIRMED connected=1 reason=unowned-connection expected=%04X current=%04X\n",
                       expectedHandle, device.connectionHandle);
                return 6;
            }
            IOReturn status = SonyClassicIsConnected(device) ? [device closeConnection] : kIOReturnSuccess;
            printf("DISCONNECT_RETURN time=%.6f status=0x%08X\n", NSDate.date.timeIntervalSince1970, status);
            if (status != kIOReturnSuccess) return 3;
            double deadline = MonotonicTime() + 5;
            while (SonyClassicIsConnected(device) && MonotonicTime() < deadline)
                RunLoopFor(0.01);
            BOOL disconnected = !SonyClassicIsConnected(device);
            printf("AFTER disconnected=%d connected=%d\n", disconnected, !disconnected);
            if (restore && disconnected) printf("RESTORE_DISCONNECTED disconnected=1\n");
            return disconnected ? 0 : 4;
        }
        if (SonyClassicIsConnected(device)) return 2;
        if (watchParent && (ParentInputEnded() || ParentExited(parentEvents))) {
            printf("CONNECT_CANCELED issued=0 settled=1\n");
            return 0;
        }
        ConnectionObserver *observer = [ConnectionObserver new];
        if (watchParent) {
            observer.disconnectNotification = [device registerForDisconnectNotification:observer selector:@selector(disconnected:device:)];
            if (!observer.disconnectNotification) return 3;
        }
        IOReturn status = [device openConnection:observer];
        printf("CONNECT_RETURN time=%.6f status=0x%08X\n", NSDate.date.timeIntervalSince1970, status);
        if (status != kIOReturnSuccess) return 3;
        double deadline = restore ? restoreDeadline : MonotonicTime() + 45;
        BOOL cancelled = NO;
        while (!observer.done && MonotonicTime() < deadline) {
            if (watchParent && (ParentInputEnded() || ParentExited(parentEvents))) {
                cancelled = YES;
                break;
            }
            RunLoopFor(0.01);
        }
        if (cancelled) {
            BOOL closeRequested = NO;
            IOReturn closeStatus = kIOReturnSuccess;
            double cancelDeadline = MonotonicTime() + 2;
            while (MonotonicTime() < cancelDeadline) {
                if (observer.disconnected || (observer.done && SonyClassicIsConnected(device) && device.connectionHandle != observer.originalHandle)) {
                    printf("CONNECT_CANCELED callback=%d originalDisconnected=%d retired=1\n", observer.done, observer.disconnected);
                    return 0;
                }
                if (observer.done && observer.status == kIOReturnSuccess && SonyClassicIsConnected(device) && !closeRequested) {
                    closeRequested = YES;
                    closeStatus = [device closeConnection];
                    printf("CONNECT_CANCEL_CLOSE status=0x%08X\n", closeStatus);
                }
                if (observer.done && !SonyClassicIsConnected(device) && closeStatus == kIOReturnSuccess) {
                    printf("CONNECT_CANCELED callback=1 disconnected=1 settled=1\n");
                    return 0;
                }
                RunLoopFor(0.01);
            }
            printf("CONNECT_CANCELLATION_UNCONFIRMED callback=%d disconnected=%d closeRequested=%d status=0x%08X\n",
                   observer.done, !SonyClassicIsConnected(device), closeRequested, closeStatus);
            return 5;
        }
        printf("AFTER callback=%d status=0x%08X connected=%d\n", observer.done, observer.status, SonyClassicIsConnected(device));
        if (!observer.done) printf("CONNECT_TERMINAL_UNCONFIRMED callback=0 connected=%d\n", SonyClassicIsConnected(device));
        if (watchParent && observer.done && observer.status == kIOReturnSuccess && SonyClassicIsConnected(device) &&
            observer.originalHandle != kBluetoothConnectionHandleNone)
            return WatchConnection(device, observer, address, priorityUID, parentEvents);
        if (restore) {
            int native = observer.done && observer.status == kIOReturnSuccess && SonyClassicIsConnected(device) ? NativeOutputState(address) : 0;
            while (native == 0 && observer.done && observer.status == kIOReturnSuccess && SonyClassicIsConnected(device) && MonotonicTime() < deadline) {
                RunLoopFor(0.05);
                native = NativeOutputState(address);
            }
            BOOL connected = SonyClassicIsConnected(device);
            if (native == 1 && connected) printf("RESTORE_CONNECTED native=1 connected=1\n");
            else printf("RESTORE_UNCONFIRMED native=%d connected=%d callback=%d status=0x%08X\n", native, connected, observer.done, observer.status);
            return native == 1 && connected ? 0 : 6;
        }
        return observer.done && observer.status == kIOReturnSuccess && SonyClassicIsConnected(device) ? 0 : 4;
    }
}