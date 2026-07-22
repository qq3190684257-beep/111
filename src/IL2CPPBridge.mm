#include "IL2CPPBridge.hpp"

#include <dlfcn.h>
#include <mach-o/dyld.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <string>
#include <vector>

namespace poollab {
namespace {

struct Il2CppDomain;
struct Il2CppAssembly;
struct Il2CppImage;
struct Il2CppClass;
struct Il2CppType;
struct Il2CppThread;
struct Il2CppObject {
    Il2CppClass* klass;
    void* monitor;
};
struct Il2CppString : Il2CppObject {
    int32_t length;
    char16_t chars[0];
};
struct Il2CppArrayBounds {
    uintptr_t length;
    int32_t lowerBound;
};
struct Il2CppArray : Il2CppObject {
    Il2CppArrayBounds* bounds;
    uintptr_t maxLength;
    void* vector[0];
};
struct MethodInfo;
struct FieldInfo;

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
    return reinterpret_cast<T>(reinterpret_cast<const MethodInfoPrefix*>(method)->methodPointer);
}

std::string lower(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return text;
}

int parseBallIndex(const std::string& objectName) {
    std::string name = lower(objectName);
    std::size_t start = name.find("ball_");
    if (start == std::string::npos) return -1;
    start += 5;
    if (start >= name.size() || !std::isdigit(static_cast<unsigned char>(name[start]))) return -1;
    int value = 0;
    while (start < name.size() && std::isdigit(static_cast<unsigned char>(name[start]))) {
        value = value * 10 + (name[start] - '0');
        ++start;
    }
    return value >= 0 && value < static_cast<int>(kBallCapacity) ? value : -1;
}

bool saneVector(Vec3 value) {
    constexpr float limit = 100000.0f;
    return std::isfinite(value.x) && std::isfinite(value.y) && std::isfinite(value.z) &&
           std::fabs(value.x) < limit && std::fabs(value.y) < limit && std::fabs(value.z) < limit;
}

float signedAngleDegrees(Vec2 from, Vec2 to) {
    from = normalized(from);
    to = normalized(to);
    if (lengthSquared(from) < kEpsilon || lengthSquared(to) < kEpsilon) return 0.0f;
    constexpr float kRadiansToDegrees = 57.295779513082320876f;
    const float cross = from.x * to.y - from.y * to.x;
    return std::atan2(cross, dot(from, to)) * kRadiansToDegrees;
}

// SHOOT_INFO is a value type. Dump offsets start at 0x10 because a boxed value
// includes the Il2CppObject header; field_get_value copies the unboxed 0x38 bytes.
struct ShootInfoValue {
    float value;
    float fForce;
    float xSpin;
    float ySpin;
    float xMouse;
    float yMouse;
    int32_t nDegree;
    int32_t randIc;
    float fTrace;
    Il2CppArray* xPosList;
    Il2CppArray* yPosList;
};

static_assert(sizeof(ShootInfoValue) == 0x38, "Unexpected SHOOT_INFO layout");

// Unboxed layouts from Pocket.AOTs / PhysicsDefine. Il2CppDumper includes the
// 0x10 boxed-object header in its displayed offsets, so the native fields begin
// at zero when these value types are returned by a managed method.
template <typename T>
struct NativeArrayBuffer {
    T* pointer;
    int32_t size;
    int32_t reserved;
};

using NativeArrayBufferF32 = NativeArrayBuffer<float>;
using NativeArrayBufferI32 = NativeArrayBuffer<int32_t>;

struct NativeOneCollisionDataFinal {
    int32_t ballIndex;
    int32_t reserved;
    NativeArrayBufferF32 xPos;
    NativeArrayBufferF32 yPos;
    NativeArrayBufferF32 xCollision;
    NativeArrayBufferF32 yCollision;
    NativeArrayBufferI32 collisionBalls;
};

struct NativeCollisionInfoFinal {
    std::array<NativeOneCollisionDataFinal, kNativePhysicsRouteCapacity> routes;
};

static_assert(sizeof(NativeArrayBufferF32) == 0x10,
              "Unexpected ArrayBufferF32 layout");
static_assert(sizeof(NativeOneCollisionDataFinal) == 0x58,
              "Unexpected OneCollisionDataFinal layout");
static_assert(sizeof(NativeCollisionInfoFinal) == 0x160,
              "Unexpected CollisionInfoFinal layout");

}  // namespace

struct IL2CPPBridge::Impl {
    using domain_get_t = Il2CppDomain* (*)();
    using thread_attach_t = Il2CppThread* (*)(Il2CppDomain*);
    using domain_get_assemblies_t = const Il2CppAssembly** (*)(const Il2CppDomain*, std::size_t*);
    using assembly_get_image_t = const Il2CppImage* (*)(const Il2CppAssembly*);
    using image_get_name_t = const char* (*)(const Il2CppImage*);
    using class_from_name_t = Il2CppClass* (*)(const Il2CppImage*, const char*, const char*);
    using class_get_method_from_name_t = const MethodInfo* (*)(Il2CppClass*, const char*, int);
    using class_get_type_t = const Il2CppType* (*)(Il2CppClass*);
    using type_get_object_t = Il2CppObject* (*)(const Il2CppType*);
    using class_get_field_from_name_t = FieldInfo* (*)(Il2CppClass*, const char*);
    using field_get_value_t = void (*)(Il2CppObject*, FieldInfo*, void*);
    using field_static_get_value_t = void (*)(FieldInfo*, void*);
    using runtime_invoke_t = Il2CppObject* (*)(const MethodInfo*, void*, void**,
                                               Il2CppObject**);
    using value_box_t = Il2CppObject* (*)(Il2CppClass*, void*);
    using gchandle_new_t = uint32_t (*)(Il2CppObject*, bool);
    using gchandle_get_target_t = Il2CppObject* (*)(uint32_t);
    using gchandle_free_t = void (*)(uint32_t);

    void* unityHandle = nullptr;
    bool apiReady = false;
    domain_get_t domainGet = nullptr;
    thread_attach_t threadAttach = nullptr;
    domain_get_assemblies_t domainGetAssemblies = nullptr;
    assembly_get_image_t assemblyGetImage = nullptr;
    image_get_name_t imageGetName = nullptr;
    class_from_name_t classFromName = nullptr;
    class_get_method_from_name_t classGetMethod = nullptr;
    class_get_type_t classGetType = nullptr;
    type_get_object_t typeGetObject = nullptr;
    class_get_field_from_name_t classGetField = nullptr;
    field_get_value_t fieldGetValue = nullptr;
    field_static_get_value_t fieldStaticGetValue = nullptr;
    runtime_invoke_t runtimeInvoke = nullptr;
    value_box_t valueBox = nullptr;
    gchandle_new_t gchandleNew = nullptr;
    gchandle_get_target_t gchandleGetTarget = nullptr;
    gchandle_free_t gchandleFree = nullptr;

    Il2CppClass* objectClass = nullptr;
    Il2CppClass* componentClass = nullptr;
    Il2CppClass* transformClass = nullptr;
    Il2CppClass* cameraClass = nullptr;
    Il2CppClass* screenClass = nullptr;
    Il2CppClass* resourcesClass = nullptr;
    Il2CppClass* pocketBallUIClass = nullptr;
    Il2CppClass* pocketCueUIClass = nullptr;
    Il2CppClass* physicsCoordinateClass = nullptr;
    Il2CppClass* pocketAIModelClass = nullptr;
    Il2CppClass* edgeInfoClass = nullptr;
    Il2CppClass* holeInfoClass = nullptr;
    Il2CppClass* physicsCallClass = nullptr;
    Il2CppClass* arrayBufferF32Class = nullptr;
    Il2CppClass* arrayBufferI32Class = nullptr;
    Il2CppClass* collisionInfoFinalClass = nullptr;
    Il2CppClass* oneCollisionDataFinalClass = nullptr;

    const MethodInfo* findObjectsOfTypeAllMethod = nullptr;
    const MethodInfo* objectGetNameMethod = nullptr;
    const MethodInfo* objectImplicitMethod = nullptr;
    const MethodInfo* componentGetTransformMethod = nullptr;
    const MethodInfo* transformGetPositionMethod = nullptr;
    const MethodInfo* cameraWorldToScreenMethod = nullptr;
    const MethodInfo* screenGetWidthMethod = nullptr;
    const MethodInfo* screenGetHeightMethod = nullptr;
    const MethodInfo* pocketAIGetInstanceMethod = nullptr;
    const MethodInfo* nativeCollisionFinalSimpleMethod = nullptr;
    const MethodInfo* arrayBufferF32ToArrayMethod = nullptr;
    const MethodInfo* arrayBufferI32ToArrayMethod = nullptr;
    const MethodInfo* collisionInfoValidCountMethod = nullptr;
    const MethodInfo* collisionInfoGetDataMethod = nullptr;
    const MethodInfo* collisionInfoGetAllDataMethod = nullptr;
    const MethodInfo* oneCollisionIsValidMethod = nullptr;
    const MethodInfo* oneCollisionTrajectoryCountMethod = nullptr;
    const MethodInfo* oneCollisionCollisionCountMethod = nullptr;
    const MethodInfo* physicsGetBallCountMethod = nullptr;
    const MethodInfo* physicsGetBallTypeMethod = nullptr;
    const MethodInfo* physicsGetBallPosMethod = nullptr;
    const MethodInfo* physicsGetBallSpeedMethod = nullptr;

    Il2CppObject* cachedCamera = nullptr;
    Il2CppObject* cachedCueUI = nullptr;
    uint32_t cachedCameraHandle = 0;
    uint32_t cachedCueUIHandle = 0;
    std::array<Il2CppObject*, 6> cachedPocketTransforms{};
    std::array<Il2CppObject*, kBallCapacity> cachedBallTransforms{};
    std::array<uint32_t, 6> cachedPocketHandles{};
    std::array<uint32_t, kBallCapacity> cachedBallHandles{};
    std::array<std::string, kBallCapacity> cachedBallNames{};
    std::chrono::steady_clock::time_point nextObjectRefresh{};
    float tableScaleX = 1.0f;
    float tableScaleY = 1.0f;
    float pocketScale = 1.0f;
    float bounceAngleOffsetDegrees = 0.0f;
    float secondaryBounceAngleOffsetDegrees = 0.0f;
    bool secondaryBounceAngleLinked = true;
    float railInsetScale = 0.0f;
    int maximumRailBounces = 1;
    bool probeEnabled = false;
    RuntimeNativePhysicsProbe cachedNativePhysicsProbe{};
    std::chrono::steady_clock::time_point nextNativePhysicsProbe{};

    template <typename T>
    bool bind(T& output, const char* symbol) {
        output = reinterpret_cast<T>(dlsym(unityHandle, symbol));
        return output != nullptr;
    }

    bool openUnity() {
        if (unityHandle) return true;
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            const char* path = _dyld_get_image_name(i);
            if (!path || !std::strstr(path, "UnityFramework")) continue;
            unityHandle = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
            if (!unityHandle) unityHandle = dlopen(path, RTLD_NOW);
            if (unityHandle) return true;
        }
        unityHandle = dlopen("UnityFramework.framework/UnityFramework", RTLD_NOW | RTLD_NOLOAD);
        return unityHandle != nullptr;
    }

    bool bindApi() {
        if (apiReady) return true;
        if (!openUnity()) return false;
        bool ok = true;
        ok &= bind(domainGet, "il2cpp_domain_get");
        ok &= bind(threadAttach, "il2cpp_thread_attach");
        ok &= bind(domainGetAssemblies, "il2cpp_domain_get_assemblies");
        ok &= bind(assemblyGetImage, "il2cpp_assembly_get_image");
        ok &= bind(imageGetName, "il2cpp_image_get_name");
        ok &= bind(classFromName, "il2cpp_class_from_name");
        ok &= bind(classGetMethod, "il2cpp_class_get_method_from_name");
        ok &= bind(classGetType, "il2cpp_class_get_type");
        ok &= bind(typeGetObject, "il2cpp_type_get_object");
        ok &= bind(classGetField, "il2cpp_class_get_field_from_name");
        ok &= bind(fieldGetValue, "il2cpp_field_get_value");
        ok &= bind(fieldStaticGetValue, "il2cpp_field_static_get_value");
        // Optional for the overlay core, mandatory for the boxed native-physics
        // probe. runtime_invoke handles the large struct return ABI and reports
        // managed exceptions instead of calling the method pointer directly.
        bind(runtimeInvoke, "il2cpp_runtime_invoke");
        bind(valueBox, "il2cpp_value_box");
        // GC handles are optional on unusual IL2CPP exports. When present, they keep the
        // managed wrappers alive while Unity owns the native object; op_Implicit below
        // still detects a destroyed native UnityEngine.Object.
        bind(gchandleNew, "il2cpp_gchandle_new");
        bind(gchandleGetTarget, "il2cpp_gchandle_get_target");
        bind(gchandleFree, "il2cpp_gchandle_free");
        apiReady = ok;
        return ok;
    }

    std::vector<const Il2CppImage*> images() const {
        std::vector<const Il2CppImage*> result;
        Il2CppDomain* domain = domainGet ? domainGet() : nullptr;
        if (!domain) return result;
        if (threadAttach) threadAttach(domain);
        std::size_t count = 0;
        const Il2CppAssembly** assemblies = domainGetAssemblies(domain, &count);
        if (!assemblies || count == 0 || count > 2048) return result;
        result.reserve(count);
        for (std::size_t i = 0; i < count; ++i) {
            const Il2CppImage* image = assemblyGetImage(assemblies[i]);
            if (image) result.push_back(image);
        }
        return result;
    }

    Il2CppClass* findClass(const char* namespaze, const char* name,
                           const char* preferredImage = nullptr) const {
        const auto allImages = images();
        if (preferredImage) {
            for (const Il2CppImage* image : allImages) {
                const char* imageName = imageGetName(image);
                if (imageName && std::strstr(imageName, preferredImage)) {
                    if (Il2CppClass* klass = classFromName(image, namespaze, name)) return klass;
                }
            }
        }
        for (const Il2CppImage* image : allImages) {
            if (Il2CppClass* klass = classFromName(image, namespaze, name)) return klass;
        }
        return nullptr;
    }

    bool bindClassesAndMethods() {
        const bool coreBound = findObjectsOfTypeAllMethod && objectGetNameMethod &&
                               componentGetTransformMethod && transformGetPositionMethod &&
                               cameraWorldToScreenMethod && screenGetWidthMethod &&
                               screenGetHeightMethod;
        if (!coreBound) {
            objectClass = findClass("UnityEngine", "Object", "UnityEngine.CoreModule");
            componentClass = findClass("UnityEngine", "Component", "UnityEngine.CoreModule");
            transformClass = findClass("UnityEngine", "Transform", "UnityEngine.CoreModule");
            cameraClass = findClass("UnityEngine", "Camera", "UnityEngine.CoreModule");
            screenClass = findClass("UnityEngine", "Screen", "UnityEngine.CoreModule");
            resourcesClass = findClass("UnityEngine", "Resources", "UnityEngine.CoreModule");

            if (!objectClass || !componentClass || !transformClass || !cameraClass ||
                !screenClass || !resourcesClass) {
                return false;
            }
            findObjectsOfTypeAllMethod = classGetMethod(resourcesClass, "FindObjectsOfTypeAll", 1);
            objectGetNameMethod = classGetMethod(objectClass, "get_name", 0);
            objectImplicitMethod = classGetMethod(objectClass, "op_Implicit", 1);
            componentGetTransformMethod = classGetMethod(componentClass, "get_transform", 0);
            transformGetPositionMethod = classGetMethod(transformClass, "get_position", 0);
            cameraWorldToScreenMethod = classGetMethod(cameraClass, "WorldToScreenPoint", 1);
            screenGetWidthMethod = classGetMethod(screenClass, "get_width", 0);
            screenGetHeightMethod = classGetMethod(screenClass, "get_height", 0);
        }

        // HybridCLR/game images may load after Unity core. Retry optional classes until present.
        if (!pocketBallUIClass)
            pocketBallUIClass = findClass("pocket.tencent.com", "PocketBallUI", "Pocket.Main");
        if (!pocketCueUIClass)
            pocketCueUIClass = findClass("pocket.tencent.com", "PocketCueUI", "Pocket.Main");
        if (!physicsCoordinateClass)
            physicsCoordinateClass = findClass("", "PhysicsCoordinate", "Pocket.AOTs");
        if (!pocketAIModelClass)
            pocketAIModelClass = findClass("Plugin.Physics", "PocketAIModel", "Pocket.Main");
        if (!edgeInfoClass)
            edgeInfoClass = findClass("Plugin.Physics", "EdgeInfo", "Pocket.Main");
        if (!holeInfoClass)
            holeInfoClass = findClass("Plugin.Physics", "HoleInfo", "Pocket.Main");
        if (pocketAIModelClass && !pocketAIGetInstanceMethod)
            pocketAIGetInstanceMethod = classGetMethod(pocketAIModelClass, "get_Instance", 0);

        // Tencent's own deterministic preview API lives in Pocket.AOTs. Resolve
        // by metadata name on every launch; never rely on the dump RVA, which is
        // rebased and may move between builds.
        if (!physicsCallClass)
            physicsCallClass = findClass("PhysicsEx", "PhysicsCall", "Pocket.AOTs");
        if (!arrayBufferF32Class)
            arrayBufferF32Class = findClass("PhysicsDefine", "ArrayBufferF32", "Pocket.AOTs");
        if (!arrayBufferI32Class)
            arrayBufferI32Class = findClass("PhysicsDefine", "ArrayBufferI32", "Pocket.AOTs");
        if (!collisionInfoFinalClass)
            collisionInfoFinalClass = findClass(
                "PhysicsDefine", "CollisionInfoFinal", "Pocket.AOTs");
        if (!oneCollisionDataFinalClass)
            oneCollisionDataFinalClass = findClass(
                "PhysicsDefine", "OneCollisionDataFinal", "Pocket.AOTs");
        if (physicsCallClass && !nativeCollisionFinalSimpleMethod) {
            nativeCollisionFinalSimpleMethod = classGetMethod(
                physicsCallClass, "getAllCollisionDataFinalSimple", 6);
        }
        if (physicsCallClass && !physicsGetBallCountMethod)
            physicsGetBallCountMethod = classGetMethod(physicsCallClass, "getBallCount", 0);
        if (physicsCallClass && !physicsGetBallTypeMethod)
            physicsGetBallTypeMethod = classGetMethod(physicsCallClass, "getBallType", 0);
        if (physicsCallClass && !physicsGetBallPosMethod)
            physicsGetBallPosMethod = classGetMethod(physicsCallClass, "getBallPos", 3);
        if (physicsCallClass && !physicsGetBallSpeedMethod)
            physicsGetBallSpeedMethod = classGetMethod(physicsCallClass, "getBallSpeed", 3);
        if (arrayBufferF32Class && !arrayBufferF32ToArrayMethod)
            arrayBufferF32ToArrayMethod = classGetMethod(arrayBufferF32Class, "ToArray", 0);
        if (arrayBufferI32Class && !arrayBufferI32ToArrayMethod)
            arrayBufferI32ToArrayMethod = classGetMethod(arrayBufferI32Class, "ToArray", 0);
        if (collisionInfoFinalClass && !collisionInfoValidCountMethod)
            collisionInfoValidCountMethod = classGetMethod(
                collisionInfoFinalClass, "get_ValidCount", 0);
        if (collisionInfoFinalClass && !collisionInfoGetDataMethod)
            collisionInfoGetDataMethod = classGetMethod(
                collisionInfoFinalClass, "GetCollisionData", 1);
        if (collisionInfoFinalClass && !collisionInfoGetAllDataMethod)
            collisionInfoGetAllDataMethod = classGetMethod(
                collisionInfoFinalClass, "GetAllValidCollisionData", 0);
        if (oneCollisionDataFinalClass && !oneCollisionIsValidMethod)
            oneCollisionIsValidMethod = classGetMethod(
                oneCollisionDataFinalClass, "get_IsValid", 0);
        if (oneCollisionDataFinalClass && !oneCollisionTrajectoryCountMethod)
            oneCollisionTrajectoryCountMethod = classGetMethod(
                oneCollisionDataFinalClass, "get_TrajectoryPointCount", 0);
        if (oneCollisionDataFinalClass && !oneCollisionCollisionCountMethod)
            oneCollisionCollisionCountMethod = classGetMethod(
                oneCollisionDataFinalClass, "get_CollisionPointCount", 0);

        return findObjectsOfTypeAllMethod && objectGetNameMethod && componentGetTransformMethod &&
               transformGetPositionMethod && cameraWorldToScreenMethod &&
               screenGetWidthMethod && screenGetHeightMethod;
    }

    Il2CppArray* findObjects(Il2CppClass* klass) const {
        if (!klass || !findObjectsOfTypeAllMethod) return nullptr;
        Il2CppObject* typeObject = typeGetObject(classGetType(klass));
        using Fn = Il2CppArray* (*)(Il2CppObject*, const MethodInfo*);
        Fn fn = methodPointer<Fn>(findObjectsOfTypeAllMethod);
        return fn && typeObject ? fn(typeObject, findObjectsOfTypeAllMethod) : nullptr;
    }

    bool objectAlive(Il2CppObject* object) const {
        if (!object) return false;
        using Fn = bool (*)(Il2CppObject*, const MethodInfo*);
        Fn fn = methodPointer<Fn>(objectImplicitMethod);
        return fn ? fn(object, objectImplicitMethod) : true;
    }

    Il2CppObject* cachedTarget(Il2CppObject* fallback, uint32_t handle) const {
        Il2CppObject* object = handle && gchandleGetTarget ? gchandleGetTarget(handle) : fallback;
        return objectAlive(object) ? object : nullptr;
    }

    void retainCached(Il2CppObject* object, Il2CppObject*& slot, uint32_t& handle) {
        slot = objectAlive(object) ? object : nullptr;
        const bool handlesReady = gchandleNew && gchandleGetTarget && gchandleFree;
        handle = slot && handlesReady ? gchandleNew(slot, false) : 0;
    }

    void releaseHandle(uint32_t& handle) {
        if (handle && gchandleFree) gchandleFree(handle);
        handle = 0;
    }

    void releaseObjectCache() {
        releaseHandle(cachedCameraHandle);
        releaseHandle(cachedCueUIHandle);
        for (uint32_t& handle : cachedPocketHandles) releaseHandle(handle);
        for (uint32_t& handle : cachedBallHandles) releaseHandle(handle);
        cachedCamera = cachedCueUI = nullptr;
        cachedPocketTransforms.fill(nullptr);
        cachedBallTransforms.fill(nullptr);
        cachedBallNames.fill(std::string{});
    }

    std::string objectName(Il2CppObject* object) const {
        using Fn = Il2CppString* (*)(Il2CppObject*, const MethodInfo*);
        Fn fn = methodPointer<Fn>(objectGetNameMethod);
        Il2CppString* value = fn && objectAlive(object) ? fn(object, objectGetNameMethod) : nullptr;
        if (!value || value->length <= 0 || value->length > 1024) return {};
        std::string result;
        result.reserve(static_cast<std::size_t>(value->length));
        for (int32_t i = 0; i < value->length; ++i) {
            const char16_t c = value->chars[i];
            result.push_back(c <= 0x7f ? static_cast<char>(c) : '?');
        }
        return result;
    }

    Il2CppObject* componentTransform(Il2CppObject* component) const {
        using Fn = Il2CppObject* (*)(Il2CppObject*, const MethodInfo*);
        Fn fn = methodPointer<Fn>(componentGetTransformMethod);
        return fn && objectAlive(component) ? fn(component, componentGetTransformMethod) : nullptr;
    }

    Vec3 transformPosition(Il2CppObject* transform) const {
        using Fn = Vec3 (*)(Il2CppObject*, const MethodInfo*);
        Fn fn = methodPointer<Fn>(transformGetPositionMethod);
        return fn && objectAlive(transform) ? fn(transform, transformGetPositionMethod) : Vec3{};
    }

    Vec3 worldToScreen(Il2CppObject* camera, Vec3 world) const {
        using Fn = Vec3 (*)(Il2CppObject*, Vec3, const MethodInfo*);
        Fn fn = methodPointer<Fn>(cameraWorldToScreenMethod);
        return fn && objectAlive(camera) ? fn(camera, world, cameraWorldToScreenMethod) : Vec3{};
    }

    int screenDimension(const MethodInfo* method) const {
        using Fn = int (*)(const MethodInfo*);
        Fn fn = methodPointer<Fn>(method);
        return fn ? fn(method) : 0;
    }

    template <typename T>
    bool readField(Il2CppObject* object, Il2CppClass* klass, const char* name, T& value) const {
        if (!objectAlive(object) || !klass || !classGetField || !fieldGetValue) return false;
        FieldInfo* field = classGetField(klass, name);
        if (!field) return false;
        std::memset(&value, 0, sizeof(T));
        fieldGetValue(object, field, &value);
        return true;
    }

    template <typename T>
    bool readStaticField(Il2CppClass* klass, const char* name, T& value) const {
        if (!klass || !classGetField || !fieldStaticGetValue) return false;
        FieldInfo* field = classGetField(klass, name);
        if (!field) return false;
        std::memset(&value, 0, sizeof(T));
        fieldStaticGetValue(field, &value);
        return true;
    }

    // Plain managed objects such as PocketAIModel, List<T>, EdgeInfo and HoleInfo
    // are not UnityEngine.Object instances. Never pass them to Object.op_Implicit.
    template <typename T>
    bool readManagedField(Il2CppObject* object, Il2CppClass* klass,
                          const char* name, T& value) const {
        if (!object || !klass || !classGetField || !fieldGetValue) return false;
        FieldInfo* field = classGetField(klass, name);
        if (!field) return false;
        std::memset(&value, 0, sizeof(T));
        fieldGetValue(object, field, &value);
        return true;
    }

    bool readSerializableVector2(Il2CppObject* vector, Vec2& value) const {
        if (!vector || !vector->klass) return false;
        Il2CppObject* elements = nullptr;
        if (!readManagedField(vector, vector->klass, "elements", elements) ||
            !elements || !elements->klass) return false;
        float x = 0.0f;
        float y = 0.0f;
        if (!readManagedField(elements, elements->klass, "_0", x) ||
            !readManagedField(elements, elements->klass, "_1", y)) return false;
        value = {x, y};
        return finite(value) && std::fabs(x) < 100000.0f && std::fabs(y) < 100000.0f;
    }

    bool readManagedList(Il2CppObject* list, Il2CppArray*& items, int& size) const {
        items = nullptr;
        size = 0;
        if (!list || !list->klass ||
            !readManagedField(list, list->klass, "_items", items) ||
            !readManagedField(list, list->klass, "_size", size)) return false;
        return items && size >= 0 && size <= 256 &&
               items->maxLength >= static_cast<uintptr_t>(size) && items->maxLength <= 4096;
    }

    Il2CppObject* firstObjectOfClass(Il2CppClass* klass) const {
        Il2CppArray* array = findObjects(klass);
        if (!array || array->maxLength == 0 || array->maxLength > 100000) return nullptr;
        for (uintptr_t i = 0; i < array->maxLength; ++i) {
            if (array->vector[i]) return static_cast<Il2CppObject*>(array->vector[i]);
        }
        return nullptr;
    }

    Il2CppObject* findMainCamera() const {
        Il2CppArray* cameras = findObjects(cameraClass);
        if (!cameras || cameras->maxLength == 0 || cameras->maxLength > 128) return nullptr;
        Il2CppObject* fallback = nullptr;
        for (uintptr_t i = 0; i < cameras->maxLength; ++i) {
            auto* camera = static_cast<Il2CppObject*>(cameras->vector[i]);
            if (!camera) continue;
            if (!fallback) fallback = camera;
            if (objectName(camera) == "Main Camera") return camera;
        }
        return fallback;
    }

    void refreshObjectCache() {
        releaseObjectCache();
        retainCached(findMainCamera(), cachedCamera, cachedCameraHandle);
        retainCached(pocketCueUIClass ? firstObjectOfClass(pocketCueUIClass) : nullptr,
                     cachedCueUI, cachedCueUIHandle);

        Il2CppObject* ballUI = pocketBallUIClass ? firstObjectOfClass(pocketBallUIClass) : nullptr;
        Il2CppArray* transforms = nullptr;
        if (readField(ballUI, pocketBallUIClass, "_holdTransformArr", transforms) && transforms &&
            transforms->maxLength > 0 && transforms->maxLength <= 64) {
            const uintptr_t pocketCount = std::min<uintptr_t>(6, transforms->maxLength);
            for (uintptr_t i = 0; i < pocketCount; ++i)
                retainCached(static_cast<Il2CppObject*>(transforms->vector[i]),
                             cachedPocketTransforms[i], cachedPocketHandles[i]);
            const uintptr_t ballEnd = std::min<uintptr_t>(6 + kBallCapacity,
                                                          transforms->maxLength);
            for (uintptr_t i = 6; i < ballEnd; ++i) {
                const std::size_t index = static_cast<std::size_t>(i - 6);
                retainCached(static_cast<Il2CppObject*>(transforms->vector[i]),
                             cachedBallTransforms[index], cachedBallHandles[index]);
                if (cachedBallTransforms[index])
                    cachedBallNames[index] = objectName(cachedBallTransforms[index]);
            }
        }

        bool missingBall = false;
        for (Il2CppObject* transform : cachedBallTransforms) missingBall |= transform == nullptr;
        if (missingBall) {
            Il2CppArray* allTransforms = findObjects(transformClass);
            if (allTransforms && allTransforms->maxLength > 0 && allTransforms->maxLength <= 100000) {
                for (uintptr_t i = 0; i < allTransforms->maxLength; ++i) {
                    auto* transform = static_cast<Il2CppObject*>(allTransforms->vector[i]);
                    if (!transform) continue;
                    const std::string name = objectName(transform);
                    const int index = parseBallIndex(name);
                    if (index < 0 || cachedBallTransforms[static_cast<std::size_t>(index)]) continue;
                    const std::string exact = "ball_" + std::to_string(index) + "_h";
                    if (lower(name) != exact) continue;
                    retainCached(transform, cachedBallTransforms[static_cast<std::size_t>(index)],
                                 cachedBallHandles[static_cast<std::size_t>(index)]);
                    cachedBallNames[static_cast<std::size_t>(index)] = name;
                }
            }
        }
        nextObjectRefresh = std::chrono::steady_clock::now() + std::chrono::milliseconds(750);
    }

    bool objectCacheNeedsRefresh() const {
        if (std::chrono::steady_clock::now() >= nextObjectRefresh) return true;
        if (cachedCamera && !cachedTarget(cachedCamera, cachedCameraHandle)) return true;
        if (cachedCueUI && !cachedTarget(cachedCueUI, cachedCueUIHandle)) return true;
        for (std::size_t i = 0; i < cachedPocketTransforms.size(); ++i) {
            if (cachedPocketTransforms[i] &&
                !cachedTarget(cachedPocketTransforms[i], cachedPocketHandles[i])) return true;
        }
        for (std::size_t i = 0; i < cachedBallTransforms.size(); ++i) {
            if (cachedBallTransforms[i] &&
                !cachedTarget(cachedBallTransforms[i], cachedBallHandles[i])) return true;
        }
        return false;
    }

    void configurePhysics(RuntimeSnapshot& snapshot) const {
        if (!physicsCoordinateClass) return;
        float fullWidth = 0.0f;
        float fullHeight = 0.0f;
        float radius = 0.0f;
        float scale = 1.0f;
        Vec2 offset{};
        readStaticField(physicsCoordinateClass, "DAI_Rx", fullWidth);
        readStaticField(physicsCoordinateClass, "DAI_Ry", fullHeight);
        readStaticField(physicsCoordinateClass, "BALL_SCREEN_R", radius);
        readStaticField(physicsCoordinateClass, "gCoordScale", scale);
        readStaticField(physicsCoordinateClass, "gCoordOffset", offset);
        snapshot.physicsConfig.coordinateWidth = fullWidth;
        snapshot.physicsConfig.coordinateHeight = fullHeight;
        snapshot.physicsConfig.coordinateScale = scale;
        snapshot.physicsConfig.coordinateOffset = offset;
        snapshot.physicsConfig.ballScreenRadius = radius;
        if (!std::isfinite(scale) || std::fabs(scale) < kEpsilon) scale = 1.0f;
        if (fullWidth > 0.1f && fullWidth < 100.0f &&
            fullHeight > 0.1f && fullHeight < 100.0f) {
            snapshot.tableBounds = boundsFromFullDimensions(
                {fullWidth, fullHeight}, scale, offset);
            snapshot.physicsConfig.coordinateBoundsReady = snapshot.tableBounds.valid();
            snapshot.physicsReady = snapshot.physicsConfig.coordinateBoundsReady;
        }
        if (radius > 0.001f && radius < 10.0f) snapshot.ballRadius = radius;
        else snapshot.ballRadius = 0.04123377f * std::fabs(scale);
    }

    void collectPhysicsModel(RuntimeSnapshot& snapshot, Il2CppObject* camera,
                             float tableZ) const {
        RuntimePhysicsConfig& config = snapshot.physicsConfig;
        if (!probeEnabled) return;
        config.modelFound = pocketAIModelClass && pocketAIGetInstanceMethod;
        if (!config.modelFound || !edgeInfoClass || !holeInfoClass) return;

        using GetInstanceFn = Il2CppObject* (*)(const MethodInfo*);
        GetInstanceFn getInstance = methodPointer<GetInstanceFn>(pocketAIGetInstanceMethod);
        Il2CppObject* model = getInstance ? getInstance(pocketAIGetInstanceMethod) : nullptr;
        if (!model) return;

        Il2CppObject* edgeList = nullptr;
        Il2CppObject* holeList = nullptr;
        Il2CppArray* edgeItems = nullptr;
        Il2CppArray* holeItems = nullptr;
        int edgeCount = 0;
        int holeCount = 0;
        if (!readManagedField(model, pocketAIModelClass, "m_edgeInfos", edgeList) ||
            !readManagedField(model, pocketAIModelClass, "m_holeInfos", holeList)) return;
        const bool edgesReady = readManagedList(edgeList, edgeItems, edgeCount);
        const bool holesReady = readManagedList(holeList, holeItems, holeCount);
        if (!edgesReady && !holesReady) return;

        config.edgeCount = edgesReady ? edgeCount : 0;
        config.holeCount = holesReady ? holeCount : 0;
        config.edgeCaptured = edgesReady
            ? std::min<int>(edgeCount, static_cast<int>(config.edges.size())) : 0;
        config.holeCaptured = holesReady
            ? std::min<int>(holeCount, static_cast<int>(config.holes.size())) : 0;

        for (int i = 0; i < config.edgeCaptured; ++i) {
            auto* edge = static_cast<Il2CppObject*>(edgeItems->vector[i]);
            if (!edge) continue;
            Il2CppObject* start = nullptr;
            Il2CppObject* end = nullptr;
            RuntimePhysicsEdge& output = config.edges[static_cast<std::size_t>(i)];
            if (!readManagedField(edge, edgeInfoClass, "startPos", start) ||
                !readManagedField(edge, edgeInfoClass, "endPos", end) ||
                !readSerializableVector2(start, output.start) ||
                !readSerializableVector2(end, output.end)) continue;
            output.visible = true;
            if (camera) {
                output.startScreen = worldToScreen(camera, {output.start.x, output.start.y, tableZ});
                output.endScreen = worldToScreen(camera, {output.end.x, output.end.y, tableZ});
            }
        }

        auto readHoleVector = [&](Il2CppObject* hole, const char* name, Vec2& value) {
            Il2CppObject* vector = nullptr;
            return readManagedField(hole, holeInfoClass, name, vector) &&
                   readSerializableVector2(vector, value);
        };
        for (int i = 0; i < config.holeCaptured; ++i) {
            auto* hole = static_cast<Il2CppObject*>(holeItems->vector[i]);
            if (!hole) continue;
            RuntimePhysicsHole& output = config.holes[static_cast<std::size_t>(i)];
            readManagedField(hole, holeInfoClass, "holeIndex", output.index);
            const bool valid = readHoleVector(hole, "centerPos", output.center) &&
                readHoleVector(hole, "leftOffsetPos", output.leftOffset) &&
                readHoleVector(hole, "rightOffsetPos", output.rightOffset) &&
                readHoleVector(hole, "leftHoleEdgePos", output.leftEdge) &&
                readHoleVector(hole, "rightHoleEdgePos", output.rightEdge) &&
                readHoleVector(hole, "leftHoleEdgeDir", output.leftDirection) &&
                readHoleVector(hole, "rightHoleEdgeDir", output.rightDirection);
            if (!valid) continue;
            output.visible = true;
            if (camera) {
                output.centerScreen = worldToScreen(camera, {output.center.x, output.center.y, tableZ});
                output.leftEdgeScreen = worldToScreen(camera, {output.leftEdge.x, output.leftEdge.y, tableZ});
                output.rightEdgeScreen = worldToScreen(camera, {output.rightEdge.x, output.rightEdge.y, tableZ});
            }
        }
        config.available = config.edgeCaptured > 0 || config.holeCaptured > 0;
    }

    void collectPocketAndBallAnchors(RuntimeSnapshot& snapshot) const {
        if (!pocketBallUIClass) return;
        Il2CppObject* ui = firstObjectOfClass(pocketBallUIClass);
        Il2CppArray* transforms = nullptr;
        if (!readField(ui, pocketBallUIClass, "_holdTransformArr", transforms) || !transforms ||
            transforms->maxLength == 0 || transforms->maxLength > 64) {
            return;
        }
        // Device evidence shows entries 0..5 are the six pocket anchors and
        // entries 6..21 are cue/numbered-ball transforms 0..15.
        const uintptr_t pocketCount = std::min<uintptr_t>(6, transforms->maxLength);
        for (uintptr_t i = 0; i < pocketCount; ++i) {
            auto* transform = static_cast<Il2CppObject*>(transforms->vector[i]);
            if (!transform) continue;
            const Vec3 world = transformPosition(transform);
            if (!saneVector(world)) continue;
            RuntimePocket& pocket = snapshot.pockets[i];
            pocket.world = world;
            pocket.visible = true;
        }
        const uintptr_t ballEnd = std::min<uintptr_t>(6 + kBallCapacity,
                                                      transforms->maxLength);
        for (uintptr_t i = 6; i < ballEnd; ++i) {
            auto* transform = static_cast<Il2CppObject*>(transforms->vector[i]);
            if (!transform) continue;
            const Vec3 world = transformPosition(transform);
            if (!saneVector(world)) continue;
            const std::size_t ballIndex = static_cast<std::size_t>(i - 6);
            RuntimeBall& ball = snapshot.balls[ballIndex];
            ball.index = static_cast<int>(ballIndex);
            ball.name = objectName(transform);
            ball.world = world;
            ball.transformWorld = world;
            ball.visible = true;
            ball.transformVisible = true;
        }
    }

    void collectBallsFromTransforms(RuntimeSnapshot& snapshot) const {
        Il2CppArray* transforms = findObjects(transformClass);
        if (!transforms || transforms->maxLength == 0 || transforms->maxLength > 100000) return;
        for (uintptr_t i = 0; i < transforms->maxLength; ++i) {
            auto* transform = static_cast<Il2CppObject*>(transforms->vector[i]);
            if (!transform) continue;
            const std::string name = objectName(transform);
            const int index = parseBallIndex(name);
            if (index < 0) continue;
            const Vec3 world = transformPosition(transform);
            if (!saneVector(world)) continue;
            RuntimeBall& ball = snapshot.balls[static_cast<std::size_t>(index)];
            if (ball.visible) continue;
            const std::string exact = "ball_" + std::to_string(index) + "_h";
            if (lower(name) != exact) continue;
            ball.index = index;
            ball.name = name;
            ball.world = world;
            ball.transformWorld = world;
            ball.visible = true;
            ball.transformVisible = true;
        }
    }

    bool collectAim(RuntimeSnapshot& snapshot, Vec2& crosshairWorld) const {
        if (!pocketCueUIClass || !cachedCueUI) return false;
        Il2CppObject* ui = cachedTarget(cachedCueUI, cachedCueUIHandle);
        if (!ui) return false;
        Vec2 lastDirection{};
        if (readField(ui, pocketCueUIClass, "_lastDir", lastDirection) &&
            finite(lastDirection) && lengthSquared(lastDirection) > kEpsilon) {
            snapshot.lastAimAvailable = true;
            snapshot.lastAimDirection = normalized(lastDirection);
        }

        Vec2 direction{};
        Il2CppObject* crosshairTransform = nullptr;
        if (snapshot.balls[0].visible &&
            readField(ui, pocketCueUIClass, "_crosshairTransform", crosshairTransform) &&
            crosshairTransform) {
            const Vec3 point = transformPosition(crosshairTransform);
            direction = {point.x - snapshot.balls[0].world.x,
                         point.y - snapshot.balls[0].world.y};
            const float margin = snapshot.ballRadius * 4.0f;
            const bool crosshairInsideTable = snapshot.tableBounds.valid() &&
                point.x >= snapshot.tableBounds.min.x - margin &&
                point.x <= snapshot.tableBounds.max.x + margin &&
                point.y >= snapshot.tableBounds.min.y - margin &&
                point.y <= snapshot.tableBounds.max.y + margin;
            if (crosshairInsideTable && finite(direction) &&
                lengthSquared(direction) > kEpsilon) {
                crosshairWorld = {point.x, point.y};
                snapshot.crosshairWorld = crosshairWorld;
                snapshot.crosshairAimDirection = normalized(direction);
                snapshot.crosshairAimAvailable = true;
                snapshot.aimDirection = snapshot.crosshairAimDirection;
                snapshot.aimSource = "crosshair";
                if (snapshot.lastAimAvailable) {
                    snapshot.crosshairLastAngleDeltaDegrees = signedAngleDegrees(
                        snapshot.lastAimDirection, snapshot.crosshairAimDirection);
                }
                return true;
            }
        }
        if (snapshot.lastAimAvailable) {
            snapshot.aimDirection = snapshot.lastAimDirection;
            snapshot.aimSource = "last_dir";
            return false;
        }
        return false;
    }

    template <typename T, std::size_t N>
    void copyValueArray(Il2CppArray* source, int& total, int& captured,
                        std::array<T, N>& destination) const {
        total = 0;
        captured = 0;
        destination.fill(T{});
        if (!source || source->maxLength > 4096) return;
        total = static_cast<int>(source->maxLength);
        captured = static_cast<int>(std::min<uintptr_t>(source->maxLength, N));
        const T* values = reinterpret_cast<const T*>(source->vector);
        for (int i = 0; i < captured; ++i) destination[static_cast<std::size_t>(i)] = values[i];
    }

    void collectProbe(RuntimeSnapshot& snapshot) const {
        if (!pocketCueUIClass) return;
        Il2CppObject* ui = cachedTarget(cachedCueUI, cachedCueUIHandle);
        if (!ui) return;

        RuntimeProbe& probe = snapshot.probe;
        probe.available = true;
        readField(ui, pocketCueUIClass, "_isShowLine", probe.isShowLine);
        if (!probeEnabled) return;
        readField(ui, pocketCueUIClass, "_fForceVal", probe.forceValue);
        readField(ui, pocketCueUIClass, "_fDurForce", probe.forceDuration);
        readField(ui, pocketCueUIClass, "_shotForce", probe.shotForce);
        readField(ui, pocketCueUIClass, "_addedForce", probe.addedForce);

        Il2CppArray* lineData = nullptr;
        if (readField(ui, pocketCueUIClass, "_lineData", lineData)) {
            copyValueArray(lineData, probe.lineDataCount, probe.lineDataCaptured,
                           probe.lineData);
        }

        ShootInfoValue info{};
        if (readField(ui, pocketCueUIClass, "shootInfo", info)) {
            probe.shootInfoAvailable = true;
            probe.shootValue = info.value;
            probe.shootForce = info.fForce;
            probe.xSpin = info.xSpin;
            probe.ySpin = info.ySpin;
            probe.xMouse = info.xMouse;
            probe.yMouse = info.yMouse;
            probe.degree = info.nDegree;
            probe.randIc = info.randIc;
            probe.trace = info.fTrace;
            copyValueArray(info.xPosList, probe.xPosCount, probe.xPosCaptured, probe.xPos);
            copyValueArray(info.yPosList, probe.yPosCount, probe.yPosCaptured, probe.yPos);
        }
    }

    template <typename ValueT>
    bool copyBoxedValue(Il2CppObject* boxed, ValueT& output) const {
        if (!boxed) return false;
        std::memcpy(&output,
                    reinterpret_cast<const uint8_t*>(boxed) + sizeof(Il2CppObject),
                    sizeof(ValueT));
        return true;
    }

    RuntimeNativeRouteCandidate captureRouteCandidate(
        const NativeOneCollisionDataFinal& source) const {
        RuntimeNativeRouteCandidate candidate;
        candidate.captured = true;
        candidate.rawBallIndex = source.ballIndex;
        const uint32_t encodedBallIndex =
            static_cast<uint32_t>(source.ballIndex);
        candidate.selfValid = (encodedBallIndex & 0x80000000u) != 0;
        candidate.ballIndex =
            static_cast<int>(encodedBallIndex & 0x7fffffffu);
        candidate.xTrajectorySize = source.xPos.size;
        candidate.yTrajectorySize = source.yPos.size;
        candidate.xCollisionSize = source.xCollision.size;
        candidate.yCollisionSize = source.yCollision.size;
        candidate.collisionBallSize = source.collisionBalls.size;
        return candidate;
    }

    bool routeCandidateSane(const RuntimeNativeRouteCandidate& candidate) const {
        constexpr int kMaximumBufferCount = 1 << 20;
        if (!candidate.captured || !candidate.selfValid ||
            candidate.ballIndex < 0 ||
            candidate.ballIndex >= 200) return false;
        const int counts[] = {candidate.xTrajectorySize,
                              candidate.yTrajectorySize,
                              candidate.xCollisionSize,
                              candidate.yCollisionSize,
                              candidate.collisionBallSize};
        for (int count : counts) {
            if (count < 0 || count > kMaximumBufferCount ||
                (count % static_cast<int>(sizeof(float))) != 0) return false;
        }
        if (candidate.xTrajectorySize != candidate.yTrajectorySize ||
            candidate.xCollisionSize != candidate.yCollisionSize) return false;
        if (candidate.getterAttempted && !candidate.getterAvailable) return false;
        if (candidate.getterAvailable) {
            if (candidate.getterValid != candidate.selfValid ||
                candidate.getterTrajectoryCount < 0 ||
                candidate.getterCollisionCount < 0) return false;
            if (candidate.getterTrajectoryCount !=
                    candidate.xTrajectorySize /
                        static_cast<int>(sizeof(float)) ||
                candidate.getterCollisionCount !=
                    candidate.xCollisionSize /
                        static_cast<int>(sizeof(float)))
                return false;
        }
        return candidate.xTrajectorySize > 0;
    }

    void collectOneCollisionGetterMetrics(
        const NativeOneCollisionDataFinal& source,
        RuntimeNativeRouteCandidate& candidate) const {
        candidate.getterAttempted = oneCollisionIsValidMethod &&
                                    oneCollisionTrajectoryCountMethod &&
                                    oneCollisionCollisionCountMethod;
        if (!candidate.getterAttempted) return;
        NativeOneCollisionDataFinal copy = source;
        using ValidFn = uint8_t (*)(NativeOneCollisionDataFinal*,
                                    const MethodInfo*);
        using CountFn = int32_t (*)(NativeOneCollisionDataFinal*,
                                    const MethodInfo*);
        ValidFn validFn = methodPointer<ValidFn>(oneCollisionIsValidMethod);
        CountFn trajectoryFn = methodPointer<CountFn>(
            oneCollisionTrajectoryCountMethod);
        CountFn collisionFn = methodPointer<CountFn>(
            oneCollisionCollisionCountMethod);
        candidate.getterAvailable = validFn && trajectoryFn && collisionFn;
        if (!candidate.getterAvailable) return;
        candidate.getterValid =
            validFn(&copy, oneCollisionIsValidMethod) != 0;
        candidate.getterTrajectoryCount = trajectoryFn(
            &copy, oneCollisionTrajectoryCountMethod);
        candidate.getterCollisionCount = collisionFn(
            &copy, oneCollisionCollisionCountMethod);
    }

    bool invokeStaticInt(const MethodInfo* method, int& output) const {
        if (!runtimeInvoke || !method) return false;
        Il2CppObject* exception = nullptr;
        Il2CppObject* boxed = runtimeInvoke(method, nullptr, nullptr, &exception);
        int32_t value = 0;
        if (exception || !copyBoxedValue(boxed, value)) return false;
        output = value;
        return true;
    }

    bool invokeBallVector(const MethodInfo* method, int index, Vec2& output) const {
        if (!runtimeInvoke || !method) return false;
        int32_t ballIndex = index;
        float x = 0.0f;
        float y = 0.0f;
        void* arguments[] = {&ballIndex, &x, &y};
        Il2CppObject* exception = nullptr;
        runtimeInvoke(method, nullptr, arguments, &exception);
        if (exception || !std::isfinite(x) || !std::isfinite(y) ||
            std::fabs(x) > 100.0f || std::fabs(y) > 100.0f) return false;
        output = {x, y};
        return true;
    }

    template <typename NativeBufferT, typename ValueT, std::size_t N>
    void copyNativeBuffer(NativeBufferT& buffer, Il2CppClass* bufferClass,
                          const MethodInfo* toArrayMethod,
                          int& total, int& captured,
                          std::array<ValueT, N>& destination) const {
        total = 0;
        captured = 0;
        destination.fill(ValueT{});
        (void)bufferClass;
        // The engine owns this pointer. ToArray performs the engine-side size
        // interpretation and gives us a managed copy, avoiding direct reads from
        // a buffer whose lifetime ends on the next preview call.
        if (!buffer.pointer || buffer.size <= 0 || buffer.size > (1 << 20) ||
            !toArrayMethod) return;
        using Fn = Il2CppArray* (*)(NativeBufferT*, const MethodInfo*);
        Fn fn = methodPointer<Fn>(toArrayMethod);
        Il2CppArray* values = fn ? fn(&buffer, toArrayMethod) : nullptr;
        copyValueArray(values, total, captured, destination);
    }

    void collectNativePhysicsProbe(RuntimeSnapshot& snapshot) {
        RuntimeNativePhysicsProbe probe;
        probe.classFound = physicsCallClass != nullptr;
        probe.methodFound = nativeCollisionFinalSimpleMethod != nullptr;
        probe.stateMethodsFound = physicsGetBallCountMethod && physicsGetBallTypeMethod &&
                                  physicsGetBallPosMethod && physicsGetBallSpeedMethod;
        probe.managedArrayMethodFound = collisionInfoGetAllDataMethod != nullptr;
        probe.managedParserFound = collisionInfoValidCountMethod &&
                                   (collisionInfoGetAllDataMethod ||
                                    collisionInfoGetDataMethod) &&
                                   oneCollisionIsValidMethod &&
                                   oneCollisionTrajectoryCountMethod &&
                                   oneCollisionCollisionCountMethod;
        probe.valueBoxAvailable = valueBox != nullptr;
        if (!probeEnabled) {
            probe.status = "recording_disabled";
            snapshot.nativePhysicsProbe = probe;
            return;
        }
        if (!probe.classFound || !probe.methodFound) {
            probe.status = probe.classFound ? "method_missing" : "class_missing";
            snapshot.nativePhysicsProbe = probe;
            return;
        }
        if (!arrayBufferF32ToArrayMethod || !arrayBufferI32ToArrayMethod) {
            probe.status = "buffer_converter_missing";
            snapshot.nativePhysicsProbe = probe;
            return;
        }
        if (!snapshot.aimingActive) {
            probe.status = "not_aiming";
            cachedNativePhysicsProbe = probe;
            nextNativePhysicsProbe = {};
            snapshot.nativePhysicsProbe = probe;
            return;
        }
        if (!snapshot.probe.shootInfoAvailable) {
            probe.status = "shoot_info_missing";
            snapshot.nativePhysicsProbe = probe;
            return;
        }

        probe.inputForce = snapshot.probe.shootForce;
        probe.inputXSpin = snapshot.probe.xSpin;
        probe.inputYSpin = snapshot.probe.ySpin;
        probe.inputXMouse = snapshot.probe.xMouse;
        probe.inputYMouse = snapshot.probe.yMouse;
        probe.inputDegree = snapshot.probe.degree;
        const bool finiteInput = std::isfinite(probe.inputForce) &&
                                 std::isfinite(probe.inputXSpin) &&
                                 std::isfinite(probe.inputYSpin) &&
                                 std::isfinite(probe.inputXMouse) &&
                                 std::isfinite(probe.inputYMouse) &&
                                 std::fabs(probe.inputForce) <= 20.0f &&
                                 std::fabs(probe.inputXSpin) <= 20.0f &&
                                 std::fabs(probe.inputYSpin) <= 20.0f &&
                                 std::fabs(probe.inputXMouse) <= 10000.0f &&
                                 std::fabs(probe.inputYMouse) <= 10000.0f;
        if (!finiteInput) {
            probe.status = "input_rejected";
            snapshot.nativePhysicsProbe = probe;
            return;
        }
        if (probe.inputForce <= 0.001f) {
            probe.status = "force_zero";
            snapshot.nativePhysicsProbe = probe;
            return;
        }
        probe.callEligible = true;

        const auto now = std::chrono::steady_clock::now();
        if (nextNativePhysicsProbe.time_since_epoch().count() != 0 &&
            now < nextNativePhysicsProbe) {
            snapshot.nativePhysicsProbe = cachedNativePhysicsProbe;
            snapshot.nativePhysicsProbe.classFound = true;
            snapshot.nativePhysicsProbe.methodFound = true;
            snapshot.nativePhysicsProbe.callEligible = true;
            snapshot.nativePhysicsProbe.callAttempted = false;
            snapshot.nativePhysicsProbe.status = "cached";
            return;
        }
        nextNativePhysicsProbe = now + std::chrono::milliseconds(100);

        probe.stateAttempted = probe.stateMethodsFound;
        if (probe.stateMethodsFound) {
            const bool countReady = invokeStaticInt(
                physicsGetBallCountMethod, probe.engineBallCount);
            invokeStaticInt(physicsGetBallTypeMethod, probe.engineBallType);
            if (countReady && probe.engineBallCount > 0 &&
                probe.engineBallCount <= 200) {
                const int captured = std::min(
                    probe.engineBallCount, static_cast<int>(kBallCapacity));
                for (int index = 0; index < captured; ++index) {
                    RuntimeNativeEngineBall& engineBall =
                        probe.engineBalls[static_cast<std::size_t>(index)];
                    engineBall.positionValid = invokeBallVector(
                        physicsGetBallPosMethod, index, engineBall.position);
                    engineBall.speedValid = invokeBallVector(
                        physicsGetBallSpeedMethod, index, engineBall.speed);
                    if (!engineBall.positionValid) continue;
                    ++probe.enginePositionCount;
                    const RuntimeBall& transformBall =
                        snapshot.balls[static_cast<std::size_t>(index)];
                    if (!transformBall.visible) continue;
                    const float coordinateScale =
                        snapshot.physicsConfig.coordinateScale;
                    const Vec2 coordinateOffset =
                        snapshot.physicsConfig.coordinateOffset;
                    const Vec2 engineWorld =
                        engineBall.position * coordinateScale + coordinateOffset;
                    const float delta = length(
                        engineWorld - Vec2{transformBall.world.x,
                                           transformBall.world.y});
                    if (!std::isfinite(delta)) continue;
                    ++probe.transformComparisonCount;
                    probe.transformMaximumDelta = std::max(
                        probe.transformMaximumDelta, delta);
                }
            }
            probe.stateAvailable = probe.enginePositionCount > 0;
        }

        probe.callAttempted = true;
        float force = probe.inputForce;
        float xMouse = probe.inputXMouse;
        float yMouse = probe.inputYMouse;
        float xSpin = probe.inputXSpin;
        float ySpin = probe.inputYSpin;
        int32_t degree = probe.inputDegree;
        using DirectFn = NativeCollisionInfoFinal (*)(
            float, float, float, float, float, int32_t, const MethodInfo*);
        DirectFn directFn = methodPointer<DirectFn>(nativeCollisionFinalSimpleMethod);
        if (!directFn) {
            probe.status = "direct_method_pointer_missing";
            cachedNativePhysicsProbe = probe;
            snapshot.nativePhysicsProbe = probe;
            return;
        }

        // This method returns a 0x160-byte value type. On ARM64 iOS, Clang
        // supplies the caller-owned result buffer in x8 for this function type.
        // Calling it through runtime_invoke boxes the result and shifts the
        // native layout, which made every route appear empty in 0.1.9.2.
        // Start with a distinctive local guard pattern. A zero-initialized
        // destination cannot distinguish a genuine empty CollisionInfoFinal
        // from a function which never receives or writes the sret buffer.
        NativeCollisionInfoFinal native;
        std::memset(&native, 0xA5, sizeof(native));
        NativeCollisionInfoFinal beforeCall = native;
        native = directFn(
            force, xMouse, yMouse, xSpin, ySpin, degree,
            nativeCollisionFinalSimpleMethod);
        probe.directSretUsed = true;
        probe.directSretChangedBytes = 0;
        const uint8_t* beforeBytes =
            reinterpret_cast<const uint8_t*>(&beforeCall);
        const uint8_t* afterBytes = reinterpret_cast<const uint8_t*>(&native);
        for (std::size_t byteIndex = 0; byteIndex < sizeof(native); ++byteIndex) {
            if (beforeBytes[byteIndex] != afterBytes[byteIndex])
                ++probe.directSretChangedBytes;
        }
        if (collisionInfoValidCountMethod) {
            using ValidCountFn = int32_t (*)(NativeCollisionInfoFinal*,
                                             const MethodInfo*);
            ValidCountFn validCountFn =
                methodPointer<ValidCountFn>(collisionInfoValidCountMethod);
            if (validCountFn) {
                probe.directCollisionValidCount = validCountFn(
                    &native, collisionInfoValidCountMethod);
            }
        }

        for (std::size_t routeIndex = 0;
             routeIndex < kNativePhysicsRouteCapacity; ++routeIndex) {
            RuntimeNativeRouteCandidate& resultCandidate =
                probe.resultCandidates[routeIndex];
            resultCandidate = captureRouteCandidate(native.routes[routeIndex]);
            collectOneCollisionGetterMetrics(native.routes[routeIndex],
                                             resultCandidate);
            if (resultCandidate.selfValid) ++probe.directValidCount;
        }

        for (std::size_t routeIndex = 0;
             routeIndex < kNativePhysicsRouteCapacity; ++routeIndex) {
            NativeOneCollisionDataFinal source{};
            const NativeOneCollisionDataFinal& rawSource = native.routes[routeIndex];
            int selectedSource = 0;
            const RuntimeNativeRouteCandidate& candidate =
                probe.resultCandidates[routeIndex];
            if (routeCandidateSane(candidate)) {
                source = native.routes[routeIndex];
                selectedSource = 1;
            }
            probe.selectedRouteSources[routeIndex] = selectedSource;
            RuntimeNativePhysicsRoute& route = probe.routes[routeIndex];
            route.ballIndex = selectedSource ? candidate.ballIndex : -1;
            // Keep raw sizes visible in the CSV even when the candidate fails
            // validation; only dereference buffers from a selected source.
            route.rawXTrajectorySize = rawSource.xPos.size;
            route.rawYTrajectorySize = rawSource.yPos.size;
            route.rawXCollisionSize = rawSource.xCollision.size;
            route.rawYCollisionSize = rawSource.yCollision.size;
            route.rawCollisionBallSize = rawSource.collisionBalls.size;

            std::array<float, kNativePhysicsTrajectoryCapacity> xTrajectory{};
            std::array<float, kNativePhysicsTrajectoryCapacity> yTrajectory{};
            int xTotal = 0;
            int xCaptured = 0;
            int yTotal = 0;
            int yCaptured = 0;
            copyNativeBuffer(source.xPos, arrayBufferF32Class,
                             arrayBufferF32ToArrayMethod,
                             xTotal, xCaptured, xTrajectory);
            copyNativeBuffer(source.yPos, arrayBufferF32Class,
                             arrayBufferF32ToArrayMethod,
                             yTotal, yCaptured, yTrajectory);
            route.trajectoryPointCount = std::min(xTotal, yTotal);
            route.trajectoryPointCaptured = std::min(xCaptured, yCaptured);
            for (int i = 0; i < route.trajectoryPointCaptured; ++i) {
                const Vec2 point{xTrajectory[static_cast<std::size_t>(i)],
                                 yTrajectory[static_cast<std::size_t>(i)]};
                if (!finite(point) || std::fabs(point.x) > 100.0f ||
                    std::fabs(point.y) > 100.0f) {
                    route.trajectoryPointCaptured = i;
                    break;
                }
                route.trajectory[static_cast<std::size_t>(i)] = point;
            }

            std::array<float, kNativePhysicsCollisionCapacity> xCollision{};
            std::array<float, kNativePhysicsCollisionCapacity> yCollision{};
            int cxTotal = 0;
            int cxCaptured = 0;
            int cyTotal = 0;
            int cyCaptured = 0;
            copyNativeBuffer(source.xCollision, arrayBufferF32Class,
                             arrayBufferF32ToArrayMethod,
                             cxTotal, cxCaptured, xCollision);
            copyNativeBuffer(source.yCollision, arrayBufferF32Class,
                             arrayBufferF32ToArrayMethod,
                             cyTotal, cyCaptured, yCollision);
            route.collisionPointCount = std::min(cxTotal, cyTotal);
            route.collisionPointCaptured = std::min(cxCaptured, cyCaptured);
            for (int i = 0; i < route.collisionPointCaptured; ++i) {
                route.collisionPoints[static_cast<std::size_t>(i)] = {
                    xCollision[static_cast<std::size_t>(i)],
                    yCollision[static_cast<std::size_t>(i)]};
            }
            copyNativeBuffer(source.collisionBalls, arrayBufferI32Class,
                             arrayBufferI32ToArrayMethod,
                             route.collisionBallCount, route.collisionBallCaptured,
                             route.collisionBalls);

            route.valid = route.ballIndex >= 0 && route.ballIndex < 200 &&
                          route.trajectoryPointCaptured > 0;
            if (route.valid) ++probe.validRouteCount;
        }
        probe.available = probe.validRouteCount > 0;
        if (probe.available) {
            probe.status = "ok";
        } else if (probe.directSretChangedBytes == 0) {
            probe.status = "direct_sret_untouched";
        } else if (probe.directCollisionValidCount == 0) {
            probe.status = "direct_empty";
        } else if (probe.directValidCount == 0) {
            probe.status = "direct_validity_mismatch";
        } else if (probe.directSretUsed) {
            probe.status = "direct_parse_empty";
        } else if (probe.stateAttempted && !probe.stateAvailable) {
            probe.status = "engine_state_empty";
        } else {
            probe.status = "raw_empty";
        }
        cachedNativePhysicsProbe = probe;
        snapshot.nativePhysicsProbe = probe;
    }

    void collectAimLineDiagnostics(RuntimeSnapshot& snapshot, Il2CppObject* camera,
                                   float tableZ) const {
        if (!camera || !snapshot.balls[0].visible ||
            lengthSquared(snapshot.aimDirection) < kEpsilon) return;
        Vec2 first{};
        Vec2 second{};
        bool haveFirst = false;
        for (int i = 0; i < snapshot.probe.lineDataCaptured; ++i) {
            const Vec2 point = snapshot.probe.lineData[static_cast<std::size_t>(i)];
            if (!finite(point) || std::fabs(point.x) >= 5000.0f ||
                std::fabs(point.y) >= 5000.0f) continue;
            if (!haveFirst) {
                first = point;
                haveFirst = true;
                continue;
            }
            if (lengthSquared(point - first) <= 1.0e-3f) continue;
            second = point;
            break;
        }
        if (!haveFirst || lengthSquared(second - first) <= 1.0e-3f) return;

        Vec2 gameDirection = normalized(second - first);
        const Vec3 cueScreen = worldToScreen(camera, {
            snapshot.balls[0].world.x, snapshot.balls[0].world.y, tableZ});
        const float sampleDistance = std::max(snapshot.ballRadius * 8.0f, 0.20f);
        const Vec2 aimPoint = Vec2{snapshot.balls[0].world.x, snapshot.balls[0].world.y} +
                              snapshot.aimDirection * sampleDistance;
        const Vec3 aimScreen = worldToScreen(camera, {aimPoint.x, aimPoint.y, tableZ});
        if (!saneVector(cueScreen) || !saneVector(aimScreen) ||
            cueScreen.z <= 0.0f || aimScreen.z <= 0.0f) return;
        Vec2 projectedDirection = normalized({aimScreen.x - cueScreen.x,
                                              aimScreen.y - cueScreen.y});
        if (dot(gameDirection, projectedDirection) < 0.0f)
            gameDirection = gameDirection * -1.0f;
        snapshot.gameLineAvailable = true;
        snapshot.gameLineScreenDirection = gameDirection;
        snapshot.gameLineAimDeltaDegrees = signedAngleDegrees(projectedDirection,
                                                               gameDirection);
    }

    void syncLegacyScreenRoutes(RuntimeSnapshot& snapshot) const {
        auto segmentAt = [](const RuntimeScreenRoute& route, int index) {
            return index >= 0 && index < route.count
                ? route.segments[static_cast<std::size_t>(index)]
                : RuntimeScreenSegment{};
        };
        snapshot.cueBeforeScreen = segmentAt(snapshot.cueApproachScreenRoute, 0);
        snapshot.cueRailBounceScreen = segmentAt(snapshot.cueApproachScreenRoute, 1);
        snapshot.cueAfterScreen = segmentAt(snapshot.cueAfterScreenRoute, 0);
        snapshot.cueAfterRailBounceScreen = segmentAt(snapshot.cueAfterScreenRoute, 1);
        snapshot.targetScreen = segmentAt(snapshot.targetScreenRoute, 0);
        snapshot.targetRailBounceScreen = segmentAt(snapshot.targetScreenRoute, 1);
    }

    void stopScreenRoutesAtPockets(RuntimeSnapshot& snapshot) const {
        std::vector<Vec2> rawCenters;
        rawCenters.reserve(snapshot.pockets.size());
        for (const RuntimePocket& pocket : snapshot.pockets) {
            if (!pocket.visible || pocket.screenPixels.z <= 0.0f) continue;
            rawCenters.push_back({pocket.screenPixels.x, pocket.screenPixels.y});
        }
        if (rawCenters.size() < 4) return;

        Vec2 minimum = rawCenters.front();
        Vec2 maximum = rawCenters.front();
        for (Vec2 point : rawCenters) {
            minimum.x = std::min(minimum.x, point.x);
            minimum.y = std::min(minimum.y, point.y);
            maximum.x = std::max(maximum.x, point.x);
            maximum.y = std::max(maximum.y, point.y);
        }
        const Vec2 center{(minimum.x + maximum.x) * 0.5f,
                          (minimum.y + maximum.y) * 0.5f};
        std::vector<Vec2> calibratedCenters;
        calibratedCenters.reserve(rawCenters.size());
        for (Vec2 point : rawCenters) {
            calibratedCenters.push_back({
                center.x + (point.x - center.x) * tableScaleX,
                center.y + (point.y - center.y) * tableScaleY
            });
        }
        const float calibratedWidth = (maximum.x - minimum.x) * tableScaleX;
        const float calibratedHeight = (maximum.y - minimum.y) * tableScaleY;
        const float captureRadius = std::max(
            6.0f, std::min(calibratedWidth, calibratedHeight) * 0.04f * pocketScale);

        auto clip = [&](RuntimeScreenSegment& segment) {
            if (!segment.visible) return false;
            Segment2 geometry{{segment.a.x, segment.a.y}, {segment.b.x, segment.b.y}, true};
            if (!truncateSegmentAtCircles(geometry, calibratedCenters, captureRadius))
                return false;
            segment.b.x = geometry.b.x;
            segment.b.y = geometry.b.y;
            return true;
        };
        auto clipRoute = [&](RuntimeScreenRoute& route) {
            for (int i = 0; i < route.count; ++i) {
                RuntimeScreenSegment& segment =
                    route.segments[static_cast<std::size_t>(i)];
                if (!clip(segment)) continue;
                for (int tail = i + 1; tail < route.count; ++tail)
                    route.segments[static_cast<std::size_t>(tail)] = {};
                route.count = i + 1;
                break;
            }
        };
        clipRoute(snapshot.cueApproachScreenRoute);
        clipRoute(snapshot.cueAfterScreenRoute);
        clipRoute(snapshot.targetScreenRoute);
        syncLegacyScreenRoutes(snapshot);
    }

    void configureTableFromPockets(RuntimeSnapshot& snapshot) const {
        Vec2 minimum{std::numeric_limits<float>::infinity(),
                     std::numeric_limits<float>::infinity()};
        Vec2 maximum{-std::numeric_limits<float>::infinity(),
                     -std::numeric_limits<float>::infinity()};
        int count = 0;
        for (const RuntimePocket& pocket : snapshot.pockets) {
            if (!pocket.visible || !saneVector(pocket.world)) continue;
            minimum.x = std::min(minimum.x, pocket.world.x);
            minimum.y = std::min(minimum.y, pocket.world.y);
            maximum.x = std::max(maximum.x, pocket.world.x);
            maximum.y = std::max(maximum.y, pocket.world.y);
            ++count;
        }
        Bounds2 anchors{minimum, maximum};
        if (count < 4 || !anchors.valid()) return;

        const Vec2 center{(anchors.min.x + anchors.max.x) * 0.5f,
                          (anchors.min.y + anchors.max.y) * 0.5f};
        const Vec2 half{(anchors.max.x - anchors.min.x) * 0.5f * tableScaleX,
                        (anchors.max.y - anchors.min.y) * 0.5f * tableScaleY};
        Bounds2 calibrated{{center.x - half.x, center.y - half.y},
                           {center.x + half.x, center.y + half.y}};
        if (!calibrated.valid()) return;
        snapshot.tableBounds = calibrated;
        snapshot.physicsReady = true;
        snapshot.physicsConfig.usedPocketFallback = true;
    }

    void projectPhysicsBounds(RuntimeSnapshot& snapshot, Il2CppObject* camera,
                              float tableZ) const {
        // Four camera projections are cheap and are also the fixed-table
        // screen fallback when match scenes expose no pocket/table objects.
        if (!camera || !snapshot.tableBounds.valid()) return;
        Bounds2 rail = snapshot.tableBounds;
        rail.min = rail.min + Vec2{snapshot.ballRadius, snapshot.ballRadius};
        rail.max = rail.max - Vec2{snapshot.ballRadius, snapshot.ballRadius};
        if (!rail.valid()) return;
        const std::array<Vec2, 4> outer{{
            snapshot.tableBounds.min,
            {snapshot.tableBounds.max.x, snapshot.tableBounds.min.y},
            snapshot.tableBounds.max,
            {snapshot.tableBounds.min.x, snapshot.tableBounds.max.y}
        }};
        const std::array<Vec2, 4> inner{{
            rail.min,
            {rail.max.x, rail.min.y},
            rail.max,
            {rail.min.x, rail.max.y}
        }};
        for (std::size_t i = 0; i < outer.size(); ++i) {
            snapshot.physicsConfig.outerBoundsScreen[i] =
                worldToScreen(camera, {outer[i].x, outer[i].y, tableZ});
            snapshot.physicsConfig.railBoundsScreen[i] =
                worldToScreen(camera, {inner[i].x, inner[i].y, tableZ});
        }
        snapshot.physicsConfig.boundsProjected = true;
    }

    RuntimeSnapshot sample() {
        RuntimeSnapshot snapshot;
        if (!bindApi()) {
            snapshot.status = "未找到 UnityFramework/IL2CPP API";
            return snapshot;
        }
        if (!bindClassesAndMethods()) {
            snapshot.status = "IL2CPP 已连接，等待游戏程序集";
            return snapshot;
        }
        snapshot.runtimeReady = true;
        snapshot.unityScreenWidth = screenDimension(screenGetWidthMethod);
        snapshot.unityScreenHeight = screenDimension(screenGetHeightMethod);

        if (objectCacheNeedsRefresh()) refreshObjectCache();
        Il2CppObject* camera = cachedTarget(cachedCamera, cachedCameraHandle);
        snapshot.cameraReady = camera != nullptr;
        configurePhysics(snapshot);
        for (std::size_t i = 0; i < cachedPocketTransforms.size(); ++i) {
            Il2CppObject* transform = cachedTarget(cachedPocketTransforms[i],
                                                   cachedPocketHandles[i]);
            if (!transform) continue;
            const Vec3 world = transformPosition(transform);
            if (!saneVector(world)) continue;
            snapshot.pockets[i].world = world;
            snapshot.pockets[i].visible = true;
        }
        for (std::size_t i = 0; i < cachedBallTransforms.size(); ++i) {
            Il2CppObject* transform = cachedTarget(cachedBallTransforms[i], cachedBallHandles[i]);
            if (!transform) continue;
            const Vec3 world = transformPosition(transform);
            if (!saneVector(world)) continue;
            RuntimeBall& ball = snapshot.balls[i];
            ball.index = static_cast<int>(i);
            ball.name = cachedBallNames[i];
            ball.typeName = "ball";
            ball.world = world;
            ball.transformWorld = world;
            ball.visible = true;
            ball.transformVisible = true;
        }
        float tableZ = 0.0f;
        if (snapshot.balls[0].visible) tableZ = snapshot.balls[0].world.z;
        else {
            for (const RuntimePocket& pocket : snapshot.pockets) {
                if (pocket.visible) { tableZ = pocket.world.z; break; }
            }
        }
        collectPhysicsModel(snapshot, camera, tableZ);
        // Device traces confirm DAI_Rx/DAI_Ry are full dimensions and gCoordScale maps
        // them to the ball world-coordinate space. Pocket anchors are now fallback only.
        if (!snapshot.physicsReady) configureTableFromPockets(snapshot);
        // Match/ranked scenes can omit or rename the table UI anchors. Their
        // world-space table is the same size, so keep sampling balls and aim
        // against the calibrated fixed bounds instead of declaring the table
        // unavailable.
        if (!snapshot.physicsReady && snapshot.tableBounds.valid()) {
            snapshot.physicsReady = true;
            snapshot.physicsConfig.usedFixedFallback = true;
        }
        collectProbe(snapshot);
        // shootInfo.xPosList/yPosList are rack/shot snapshots, not live ball
        // positions. Keep them for diagnostics only and never overwrite the
        // authoritative eight-ball Transform coordinates.
        snapshot.gameMode = "eight_ball";
        snapshot.ballPositionSource = "transform";
        snapshot.coordinateBallCount = static_cast<int>(kBallCapacity);
        projectPhysicsBounds(snapshot, camera, tableZ);
        Vec2 crosshairWorld{};
        const bool aimFromCrosshair = collectAim(snapshot, crosshairWorld);
        bool gameAimLineVisible = false;
        Il2CppObject* cueUI = cachedTarget(cachedCueUI, cachedCueUIHandle);
        const bool aimStateAvailable = cueUI &&
            readField(cueUI, pocketCueUIClass, "_isShowLine", gameAimLineVisible);
        snapshot.aimingActive = aimStateAvailable
            ? gameAimLineVisible
            : lengthSquared(snapshot.aimDirection) > kEpsilon;
        collectNativePhysicsProbe(snapshot);
        collectAimLineDiagnostics(snapshot, camera, tableZ);

        int ballCount = 0;
        int pocketCount = 0;
        for (RuntimePocket& pocket : snapshot.pockets) {
            if (!pocket.visible) continue;
            ++pocketCount;
            if (camera) pocket.screenPixels = worldToScreen(camera, pocket.world);
        }
        std::vector<Ball2> geometryBalls(snapshot.balls.size());
        for (std::size_t i = 0; i < snapshot.balls.size(); ++i) {
            RuntimeBall& ball = snapshot.balls[i];
            if (!ball.visible) continue;
            ++ballCount;
            if (camera) ball.screenPixels = worldToScreen(camera, ball.world);
            geometryBalls[i] = {static_cast<int>(i), {ball.world.x, ball.world.y}, true};
        }
        snapshot.activeBallCount = ballCount;
        if (snapshot.aimingActive && geometryBalls[0].active &&
            lengthSquared(snapshot.aimDirection) > kEpsilon) {
            int crosshairTarget = -1;
            if (aimFromCrosshair) {
                // Device logs show the Crosshair impact center sits about 2.1 ball
                // radii from the target Transform center. Keep the search local so
                // a nearby but unrelated ball cannot be selected.
                const float targetSearchRadius = snapshot.ballRadius * 2.80f;
                float nearestDistance = std::numeric_limits<float>::infinity();
                const Vec2 cue = geometryBalls[0].center;
                for (std::size_t i = 1; i < geometryBalls.size(); ++i) {
                    if (!geometryBalls[i].active) continue;
                    const Vec2 cueToBall = geometryBalls[i].center - cue;
                    if (dot(cueToBall, snapshot.aimDirection) <= 0.0f) continue;
                    const float distance = length(geometryBalls[i].center - crosshairWorld);
                    if (distance <= targetSearchRadius && distance < nearestDistance) {
                        nearestDistance = distance;
                        crosshairTarget = static_cast<int>(i);
                    }
                }
            }
            if (crosshairTarget >= 0) {
                snapshot.prediction = predictFromKnownImpact(
                    geometryBalls, 0, crosshairTarget, crosshairWorld,
                    snapshot.ballRadius, snapshot.tableBounds,
                    bounceAngleOffsetDegrees, maximumRailBounces,
                    secondaryBounceAngleOffsetDegrees,
                    secondaryBounceAngleLinked, railInsetScale);
            } else {
                snapshot.prediction = predict(geometryBalls, 0, snapshot.aimDirection,
                                              snapshot.ballRadius, snapshot.tableBounds,
                                              !aimFromCrosshair,
                                              bounceAngleOffsetDegrees,
                                              maximumRailBounces,
                                              secondaryBounceAngleOffsetDegrees,
                                              secondaryBounceAngleLinked,
                                              railInsetScale);
            }
            if (camera) {
                const float z = snapshot.balls[0].world.z;
                auto projectSegment = [&](const Segment2& source, RuntimeScreenSegment& destination) {
                    if (!source.valid) return;
                    destination.a = worldToScreen(camera, {source.a.x, source.a.y, z});
                    destination.b = worldToScreen(camera, {source.b.x, source.b.y, z});
                    destination.visible = saneVector(destination.a) && saneVector(destination.b) &&
                                          destination.a.z > 0.0f && destination.b.z > 0.0f;
                };
                auto projectRoute = [&](const TrajectoryRoute& source,
                                        RuntimeScreenRoute& destination) {
                    destination.count = std::max(
                        0, std::min(static_cast<int>(kTrajectoryRouteCapacity), source.count));
                    for (int i = 0; i < destination.count; ++i) {
                        projectSegment(source.segments[static_cast<std::size_t>(i)],
                                       destination.segments[static_cast<std::size_t>(i)]);
                    }
                };
                projectRoute(snapshot.prediction.cueApproachRoute,
                             snapshot.cueApproachScreenRoute);
                projectRoute(snapshot.prediction.cueAfterRoute,
                             snapshot.cueAfterScreenRoute);
                projectRoute(snapshot.prediction.targetRoute,
                             snapshot.targetScreenRoute);
                syncLegacyScreenRoutes(snapshot);
                stopScreenRoutesAtPockets(snapshot);
            }
        }

        if (!camera) snapshot.status = "未找到 Main Camera";
        else if (ballCount == 0) snapshot.status = "Camera 已就绪，等待球对象";
        else if (!geometryBalls[0].active) snapshot.status = "已找到球对象，未识别母球";
        else if (!snapshot.aimingActive) snapshot.status = "已击球，预测已隐藏";
        else if (lengthSquared(snapshot.aimDirection) <= kEpsilon)
            snapshot.status = "球心已对齐，等待瞄准方向";
        else snapshot.status = "运行正常：" + snapshot.gameMode + " / 袋口 " +
                               std::to_string(pocketCount) + " / 球 " +
                               std::to_string(ballCount);
        return snapshot;
    }

    void invalidate() {
        objectClass = componentClass = transformClass = cameraClass = screenClass = resourcesClass = nullptr;
        pocketBallUIClass = pocketCueUIClass = physicsCoordinateClass = nullptr;
        pocketAIModelClass = edgeInfoClass = holeInfoClass = nullptr;
        physicsCallClass = arrayBufferF32Class = arrayBufferI32Class = nullptr;
        findObjectsOfTypeAllMethod = objectGetNameMethod = objectImplicitMethod = nullptr;
        transformGetPositionMethod = cameraWorldToScreenMethod = nullptr;
        screenGetWidthMethod = screenGetHeightMethod = nullptr;
        pocketAIGetInstanceMethod = nullptr;
        nativeCollisionFinalSimpleMethod = nullptr;
        arrayBufferF32ToArrayMethod = arrayBufferI32ToArrayMethod = nullptr;
        cachedNativePhysicsProbe = {};
        nextNativePhysicsProbe = {};
        releaseObjectCache();
        nextObjectRefresh = {};
    }
};

IL2CPPBridge::IL2CPPBridge() : impl_(new Impl()) {}
IL2CPPBridge::~IL2CPPBridge() { delete impl_; }

void IL2CPPBridge::setTableCalibration(float scaleX, float scaleY) {
    impl_->tableScaleX = std::max(0.50f, std::min(1.20f, scaleX));
    impl_->tableScaleY = std::max(0.50f, std::min(1.20f, scaleY));
}
void IL2CPPBridge::setPocketCalibration(float scale) {
    impl_->pocketScale = std::max(0.50f, std::min(2.00f, scale));
}
void IL2CPPBridge::setBounceAngleOffset(float degrees) {
    impl_->bounceAngleOffsetDegrees = clampedBounceAngleOffset(degrees);
}
void IL2CPPBridge::setSecondaryBounceAngleOffset(float degrees) {
    impl_->secondaryBounceAngleOffsetDegrees = clampedBounceAngleOffset(degrees);
}
void IL2CPPBridge::setSecondaryBounceAngleLinked(bool linked) {
    impl_->secondaryBounceAngleLinked = linked;
}
void IL2CPPBridge::setUseOuterRailBoundary(bool enabled) {
    impl_->railInsetScale = enabled ? 0.0f : 1.0f;
}
void IL2CPPBridge::setMaximumRailBounces(int count) {
    impl_->maximumRailBounces = clampedRailBounceCount(count);
}
void IL2CPPBridge::setProbeEnabled(bool enabled) { impl_->probeEnabled = enabled; }
RuntimeSnapshot IL2CPPBridge::sample() { return impl_->sample(); }
void IL2CPPBridge::invalidate() { impl_->invalidate(); }

}  // namespace poollab
