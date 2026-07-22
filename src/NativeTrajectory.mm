#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <dispatch/dispatch.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <dlfcn.h>

#include "NativeTrajectoryProbe.hpp"

// Minimal IL2CPP ABI declarations. The replica deliberately uses only the
// public export surface and never stores a scene object across frames.
struct Il2CppClass;
struct Il2CppType;
struct FieldInfo;
struct MethodInfo;
struct Il2CppException;
struct Il2CppDomain;
struct Il2CppAssembly;
struct Il2CppImage;

struct Il2CppObject {
    Il2CppClass* klass;
    void* monitor;
};

struct Il2CppArray {
    Il2CppObject object;
    void* bounds;
    uintptr_t maxLength;
    Il2CppObject* vector[0];
};

namespace {

using DomainGetFn = Il2CppDomain* (*)();
using ThreadAttachFn = void* (*)(Il2CppDomain*);
using DomainGetAssembliesFn = const Il2CppAssembly** (*)(Il2CppDomain*, size_t*);
using AssemblyGetImageFn = const Il2CppImage* (*)(const Il2CppAssembly*);
using ImageGetNameFn = const char* (*)(const Il2CppImage*);
using ClassFromNameFn = Il2CppClass* (*)(const Il2CppImage*, const char*, const char*);
using ClassGetFieldFn = FieldInfo* (*)(Il2CppClass*, const char*);
using FieldStaticGetFn = void (*)(FieldInfo*, void*);
using FieldGetFn = void (*)(Il2CppObject*, FieldInfo*, void*);
using FieldSetFn = void (*)(Il2CppObject*, FieldInfo*, void*);
using ClassGetMethodFn = const MethodInfo* (*)(Il2CppClass*, const char*, int);
using ClassGetTypeFn = const Il2CppType* (*)(Il2CppClass*);
using TypeGetObjectFn = Il2CppObject* (*)(const Il2CppType*);

static bool imageNameMatches(const char* actual, const char* wanted) {
    if (!actual || !wanted) return false;
    if (std::strcmp(actual, wanted) == 0) return true;

    // Unity/HybridCLR builds are seen with and without the .dll suffix.
    const size_t wantedLength = std::strlen(wanted);
    if (wantedLength > 4 &&
        std::strcmp(wanted + wantedLength - 4, ".dll") == 0 &&
        std::strncmp(actual, wanted, wantedLength - 4) == 0 &&
        (actual[wantedLength - 4] == '\0' || actual[wantedLength - 4] == '.')) {
        return true;
    }
    return std::strncmp(actual, wanted, wantedLength) == 0 &&
           (actual[wantedLength] == '\0' || actual[wantedLength] == '.');
}

// UnityEngine.CoreModule is AOT code in this target. Its MethodInfo starts
// with the generated native function pointer used by IL2CPP.
struct MethodInfoPrefix {
    void* methodPointer;
    void* virtualMethodPointer;
    void* invokerMethod;
    const char* name;
    Il2CppClass* klass;
};

template <typename T>
T methodPointer(const MethodInfo* method) {
    if (!method) return nullptr;
    return reinterpret_cast<T>(
        reinterpret_cast<const MethodInfoPrefix*>(method)->methodPointer);
}

struct Il2CppApi {
    DomainGetFn domainGet = nullptr;
    ThreadAttachFn threadAttach = nullptr;
    DomainGetAssembliesFn domainGetAssemblies = nullptr;
    AssemblyGetImageFn assemblyGetImage = nullptr;
    ImageGetNameFn imageGetName = nullptr;
    ClassFromNameFn classFromName = nullptr;
    ClassGetFieldFn classGetField = nullptr;
    FieldStaticGetFn fieldStaticGet = nullptr;
    FieldGetFn fieldGet = nullptr;
    FieldSetFn fieldSet = nullptr;
    ClassGetMethodFn classGetMethod = nullptr;
    ClassGetTypeFn classGetType = nullptr;
    TypeGetObjectFn typeGetObject = nullptr;

    bool ready() const {
        return domainGet && threadAttach && domainGetAssemblies &&
               assemblyGetImage && imageGetName && classFromName &&
               classGetField && fieldStaticGet && fieldGet && fieldSet &&
               classGetMethod && classGetType && typeGetObject;
    }

    template <typename T>
    static T resolve(const char* name) {
        return reinterpret_cast<T>(dlsym(RTLD_DEFAULT, name));
    }

    bool resolveAll() {
        domainGet = resolve<DomainGetFn>("il2cpp_domain_get");
        threadAttach = resolve<ThreadAttachFn>("il2cpp_thread_attach");
        domainGetAssemblies = resolve<DomainGetAssembliesFn>(
            "il2cpp_domain_get_assemblies");
        assemblyGetImage = resolve<AssemblyGetImageFn>("il2cpp_assembly_get_image");
        imageGetName = resolve<ImageGetNameFn>("il2cpp_image_get_name");
        classFromName = resolve<ClassFromNameFn>("il2cpp_class_from_name");
        classGetField = resolve<ClassGetFieldFn>(
            "il2cpp_class_get_field_from_name");
        fieldStaticGet = resolve<FieldStaticGetFn>("il2cpp_field_static_get_value");
        fieldGet = resolve<FieldGetFn>("il2cpp_field_get_value");
        fieldSet = resolve<FieldSetFn>("il2cpp_field_set_value");
        classGetMethod = resolve<ClassGetMethodFn>(
            "il2cpp_class_get_method_from_name");
        classGetType = resolve<ClassGetTypeFn>("il2cpp_class_get_type");
        typeGetObject = resolve<TypeGetObjectFn>("il2cpp_type_get_object");
        return ready();
    }
};

struct TickStats {
    size_t objectCount = 0;
    size_t eligibleCount = 0;
    size_t activeCount = 0;
    size_t writeCount = 0;
    size_t verifyCount = 0;
    float lastBefore = 0.0f;
    float lastAfter = 0.0f;
    int32_t lastReflectNodeCount = 0;
    bool reflectApplied = false;
};

static NativeTrajectoryProbeSnapshot gLatestProbeSnapshot{};
static uint64_t gProbeSequence = 0;

struct ReplicaState {
    Il2CppApi api;
    Il2CppDomain* attachedDomain = nullptr;
    Il2CppClass* gameInfoClass = nullptr;
    Il2CppClass* settingDataClass = nullptr;
    Il2CppClass* cueUIClass = nullptr;
    Il2CppClass* resourcesClass = nullptr;
    FieldInfo* gameInfoInstance = nullptr;
    FieldInfo* gameInfoSetting = nullptr;
    FieldInfo* reflectCount = nullptr;
    FieldInfo* cueReflectNodeCount = nullptr;
    FieldInfo* cueScaleAim = nullptr;
    FieldInfo* cueIsInit = nullptr;
    FieldInfo* cueIsShowLine = nullptr;
    FieldInfo* cueShowHelp = nullptr;
    FieldInfo* cueShowHelpEx = nullptr;
    const MethodInfo* findObjectsOfTypeAll = nullptr;
    bool metadataReady = false;

    bool attach() {
        Il2CppDomain* domain = api.domainGet ? api.domainGet() : nullptr;
        if (!domain) return false;
        if (attachedDomain != domain) {
            if (!api.threadAttach || !api.threadAttach(domain)) return false;
            attachedDomain = domain;
            metadataReady = false;
        }
        return true;
    }

    const Il2CppImage* findImage(const char* wanted) const {
        if (!attachedDomain || !api.domainGetAssemblies) return nullptr;
        size_t count = 0;
        const Il2CppAssembly** assemblies =
            api.domainGetAssemblies(attachedDomain, &count);
        if (!assemblies || count == 0 || count > 4096) return nullptr;
        for (size_t i = 0; i < count; ++i) {
            const Il2CppImage* image = api.assemblyGetImage(assemblies[i]);
            const char* name = image ? api.imageGetName(image) : nullptr;
            if (imageNameMatches(name, wanted)) return image;
        }
        return nullptr;
    }

    Il2CppClass* findClass(const char* imageName, const char* namesp,
                           const char* name) const {
        const Il2CppImage* image = findImage(imageName);
        return image ? api.classFromName(image, namesp, name) : nullptr;
    }

    Il2CppClass* findPocketClass(const char* namesp, const char* name) const {
        Il2CppClass* klass = findClass("Pocket.Main.dll", namesp, name);
        if (!klass) klass = findClass("Pocket.Main", namesp, name);
        return klass;
    }

    bool prepareMetadata() {
        if (metadataReady) return true;
        cueUIClass = findPocketClass("pocket.tencent.com", "PocketCueUI");
        gameInfoClass = findPocketClass("", "GameInfo");
        settingDataClass = findPocketClass("", "SettingData");
        resourcesClass = findClass("UnityEngine.CoreModule.dll", "UnityEngine",
                                   "Resources");
        if (!resourcesClass)
            resourcesClass = findClass("UnityEngine.CoreModule", "UnityEngine",
                                       "Resources");
        if (!resourcesClass)
            resourcesClass = findClass("UnityEngine.dll", "UnityEngine", "Resources");
        if (!resourcesClass)
            resourcesClass = findClass("UnityEngine", "UnityEngine", "Resources");
        if (!cueUIClass || !gameInfoClass || !settingDataClass || !resourcesClass)
            return false;

        gameInfoInstance = api.classGetField(gameInfoClass, "instance");
        gameInfoSetting = api.classGetField(gameInfoClass, "Setting");
        reflectCount = api.classGetField(settingDataClass, "pocketCueReflectNum");
        cueReflectNodeCount = api.classGetField(cueUIClass, "_numReflectSubNode");
        cueScaleAim = api.classGetField(cueUIClass, "ScaleAim");
        cueIsInit = api.classGetField(cueUIClass, "_isInit");
        cueIsShowLine = api.classGetField(cueUIClass, "_isShowLine");
        cueShowHelp = api.classGetField(cueUIClass, "_showHelp");
        cueShowHelpEx = api.classGetField(cueUIClass, "_showHelpEx");
        findObjectsOfTypeAll = api.classGetMethod(resourcesClass,
                                                   "FindObjectsOfTypeAll", 1);
        metadataReady = gameInfoInstance && gameInfoSetting && reflectCount &&
                        cueReflectNodeCount && cueScaleAim &&
                        findObjectsOfTypeAll;
        return metadataReady;
    }

    bool setReflectCount() const {
        Il2CppObject* game = nullptr;
        api.fieldStaticGet(gameInfoInstance, &game);
        if (!game) return false;
        Il2CppObject* setting = nullptr;
        api.fieldGet(game, gameInfoSetting, &setting);
        if (!setting) return false;
        int32_t current = 0;
        api.fieldGet(setting, reflectCount, &current);
        if (current == 3) return true;
        if (current < 0 || current > 64) return false;
        current = 3;
        api.fieldSet(setting, reflectCount, &current);
        int32_t verify = 0;
        api.fieldGet(setting, reflectCount, &verify);
        return verify == 3;
    }

    TickStats extendCurrentCueUIs() const {
        TickStats stats;
        if (!findObjectsOfTypeAll) return stats;
        const Il2CppType* cueType = api.classGetType(cueUIClass);
        Il2CppObject* cueTypeObject = cueType ? api.typeGetObject(cueType) : nullptr;
        using FindObjectsFn = Il2CppArray* (*)(Il2CppObject*, const MethodInfo*);
        FindObjectsFn findObjects = methodPointer<FindObjectsFn>(
            findObjectsOfTypeAll);
        Il2CppArray* objects = findObjects && cueTypeObject
                                  ? findObjects(cueTypeObject,
                                                findObjectsOfTypeAll)
                                  : nullptr;
        if (!objects) return stats;
        if (objects->maxLength == 0 || objects->maxLength > 256) return stats;
        for (uintptr_t i = 0; i < objects->maxLength; ++i) {
            ++stats.objectCount;
            Il2CppObject* candidate = objects->vector[i];
            if (!candidate) continue;
            int32_t marker = 0;
            float scale = 0.0f;
            api.fieldGet(candidate, cueReflectNodeCount, &marker);
            api.fieldGet(candidate, cueScaleAim, &scale);
            // The old H5GG script used 64 as a memory-search signature. It is
            // not a semantic constant: match/ranked tables may allocate a
            // different number of reflection sub-nodes. The typed Resources
            // query already guarantees PocketCueUI-compatible objects, so use
            // only broad field sanity checks here.
            if (marker < 0 || marker > 4096 || !std::isfinite(scale)) continue;
            ++stats.eligibleCount;
            stats.lastReflectNodeCount = marker;
            uint8_t isInit = 0;
            uint8_t isShowLine = 0;
            uint8_t showHelp = 0;
            uint8_t showHelpEx = 0;
            if (cueIsInit) api.fieldGet(candidate, cueIsInit, &isInit);
            if (cueIsShowLine) api.fieldGet(candidate, cueIsShowLine, &isShowLine);
            if (cueShowHelp) api.fieldGet(candidate, cueShowHelp, &showHelp);
            if (cueShowHelpEx) api.fieldGet(candidate, cueShowHelpEx, &showHelpEx);
            if (isInit && (isShowLine || showHelp || showHelpEx))
                ++stats.activeCount;
            // The marker identifies the ScaleAim field. Accept the native
            // range broadly enough to observe a reset or a mode-specific value.
            if (scale < -1.0f || scale > 20000.0f) continue;
            stats.lastBefore = scale;
            float extendedLength = 9999.0f;
            api.fieldSet(candidate, cueScaleAim, &extendedLength);
            ++stats.writeCount;
            float verify = 0.0f;
            api.fieldGet(candidate, cueScaleAim, &verify);
            stats.lastAfter = verify;
            if (std::isfinite(verify) && std::fabs(verify - extendedLength) < 0.5f)
                ++stats.verifyCount;
        }
        return stats;
    }

    TickStats tick() {
        TickStats stats;
        // IL2CPP may not have finished loading when the constructor runs.
        // Retry resolution until the complete export set is available.
        if (!api.ready() && !api.resolveAll()) return stats;
        if (!attach() || !prepareMetadata()) return stats;
        // This is the original native behavior: the game then draws its own
        // full collision/reflection/pocket route. We never cache this object.
        stats.reflectApplied = setReflectCount();
        TickStats lineStats = extendCurrentCueUIs();
        lineStats.reflectApplied = stats.reflectApplied;
        return lineStats;
    }
};

} // namespace

extern "C" __attribute__((visibility("default")))
bool NativeTrajectoryCopyProbeSnapshot(
        NativeTrajectoryProbeSnapshot* output) {
    if (!output) return false;
    *output = gLatestProbeSnapshot;
    return output->sequence != 0;
}

@interface NativeTrajectoryDriver : NSObject
@property(nonatomic, strong) CADisplayLink* displayLink;
@property(nonatomic, assign) BOOL writePending;
@property(nonatomic, assign) CFTimeInterval nextLogTimestamp;
@property(nonatomic, assign) ReplicaState* state;
@end

@implementation NativeTrajectoryDriver

- (void)start {
    self.state = new ReplicaState();
    self.displayLink = [CADisplayLink displayLinkWithTarget:self
                                                    selector:@selector(onFrame:)];
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop]
                            forMode:NSRunLoopCommonModes];
}

- (void)onFrame:(CADisplayLink*)link {
    (void)link;
    // Queue after the current display callback. This gives Unity's own
    // Update/LateUpdate a chance to finish before ScaleAim is re-applied.
    if (self.writePending) return;
    self.writePending = YES;
    __weak NativeTrajectoryDriver* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        NativeTrajectoryDriver* strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.writePending = NO;
        if (!strongSelf.state) return;
        const TickStats stats = strongSelf.state->tick();
        const CFTimeInterval now = CACurrentMediaTime();
        gLatestProbeSnapshot.sequence = ++gProbeSequence;
        gLatestProbeSnapshot.timestamp = now;
        gLatestProbeSnapshot.objectCount = stats.objectCount;
        gLatestProbeSnapshot.eligibleCount = stats.eligibleCount;
        gLatestProbeSnapshot.activeCount = stats.activeCount;
        gLatestProbeSnapshot.writeCount = stats.writeCount;
        gLatestProbeSnapshot.verifyCount = stats.verifyCount;
        gLatestProbeSnapshot.reflectNodeCount = stats.lastReflectNodeCount;
        gLatestProbeSnapshot.reflectApplied = stats.reflectApplied ? 1 : 0;
        gLatestProbeSnapshot.scaleBefore = stats.lastBefore;
        gLatestProbeSnapshot.scaleAfter = stats.lastAfter;
        if (now < strongSelf.nextLogTimestamp) return;
        strongSelf.nextLogTimestamp = now + 2.0;
        NSLog(@"[NativeTrajectory 0.1.2] objects=%lu eligible=%lu active=%lu writes=%lu verified=%lu nodes=%d reflect=%d ScaleAim %.3f -> %.3f",
              (unsigned long)stats.objectCount,
              (unsigned long)stats.eligibleCount,
              (unsigned long)stats.activeCount,
              (unsigned long)stats.writeCount,
              (unsigned long)stats.verifyCount,
              stats.lastReflectNodeCount,
              stats.reflectApplied ? 1 : 0,
              stats.lastBefore,
              stats.lastAfter);
    });
}

- (void)dealloc {
    [self.displayLink invalidate];
    delete self.state;
    self.state = nullptr;
}

@end

static NativeTrajectoryDriver* gNativeTrajectoryDriver = nil;

extern "C" __attribute__((visibility("default"))) void NativeTrajectoryInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gNativeTrajectoryDriver) return;
        gNativeTrajectoryDriver = [NativeTrajectoryDriver new];
        [gNativeTrajectoryDriver start];
    });
}

__attribute__((constructor)) static void NativeTrajectoryConstructor(void) {
    NativeTrajectoryInit();
}
