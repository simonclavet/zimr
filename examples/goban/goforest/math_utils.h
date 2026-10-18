#pragma once

#include "raylib.h"
#include "raymath.h"
#include <cmath>

//----------------------------------------------------------------------------------
// Additional Raylib Functions
//----------------------------------------------------------------------------------

static inline float Max(float x, float y)
{
    return x > y ? x : y;
}

static inline float Min(float x, float y)
{
    return x < y ? x : y;
}

static inline float Saturate(float x)
{
    return Clamp(x, 0.0f, 1.0f);
}

// Clamp value to [0, 1] range (same as Saturate, but more explicit name for in-place operations)
static inline float ClampZeroOne(float x)
{
    if (x < 0.0f) return 0.0f;
    if (x > 1.0f) return 1.0f;
    return x;
}

// smoothstep: smooth interpolation with zero derivative at endpoints
// t should be in [0, 1], returns value in [0, 1]
static inline float SmoothStep(float t)
{
    return t * t * (3.0f - 2.0f * t);
}

// smootherstep (Perlin): C2 continuous (zero 1st and 2nd derivatives at 0 and 1)
static inline float SmootherStep(float t)
{
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

// Smooth lerp: interpolates from a to b using smoothstep for smoother transitions
static inline float SmoothLerp(float a, float b, float t)
{
    return Lerp(a, b, SmoothStep(t));
}

static inline float Square(float x)
{
    return x * x;
}

static inline int ClampInt(int x, int min, int max)
{
    return x < min ? min : x > max ? max : x;
}

static inline int MaxInt(int x, int y)
{
    return x > y ? x : y;
}

static inline int MinInt(int x, int y)
{
    return x < y ? x : y;
}

// Acos that prevents domain errors (NaNs) if inputs are slightly > 1.0 or < -1.0
static inline float SafeAcos(float x) {
    if (x > 1.0f) return 0.0f;
    if (x < -1.0f) return PI;
    return std::acos(x);
}

// 2D length utilities (XZ plane, ignoring Y)
static inline float Vector3LengthSqr2D(Vector3 v)
{
    return v.x * v.x + v.z * v.z;
}

static inline float Vector3Length2D(Vector3 v)
{
    return sqrtf(v.x * v.x + v.z * v.z);
}

// signed angle from 'from' to 'to' around Y (XZ plane), in radians
// positive = counterclockwise viewed from above
static inline float SignedAngleY(Vector3 from, Vector3 to)
{
    const float cross = from.z * to.x - from.x * to.z;
    const float dot = from.x * to.x + from.z * to.z;
    return atan2f(cross, dot);
}

// rotate XZ direction by angle radians around Y (positive = CCW from above)
// this is the Y-axis rotation matrix: new_x = x*cos + z*sin, new_z = -x*sin + z*cos
static inline Vector3 RotateXZByAngle(Vector3 dir, float angle)
{
    const float c = cosf(angle);
    const float s = sinf(angle);
    return Vector3{ dir.x * c + dir.z * s, 0.0f, -dir.x * s + dir.z * c };
}

// Clamped inverse lerp: returns t in [0,1] such that Lerp(a, b, t) = value
// Automatically clamps the result to [0,1] range
static inline float ClampedInvLerp(float a, float b, float value)
{
    if (fabsf(b - a) < 1e-6f) return 0.0f;  // Avoid division by zero
    const float t = (value - a) / (b - a);
    return Clamp(t, 0.0f, 1.0f);
}

// Wrap angle to [-PI, PI] range
// Useful for computing angular differences and velocities
static inline float WrapAngleToPi(float angle)
{
    while (angle > PI) angle -= 2.0f * PI;
    while (angle < -PI) angle += 2.0f * PI;
    return angle;
}

// Lerp between two angles (in radians) taking the shortest path around the circle
// This correctly handles wrapping (e.g., lerping from -175° to 175° goes through 180°, not through 0°)
static inline float LerpAngle(float angleA, float angleB, float t)
{
    const float delta = WrapAngleToPi(angleB - angleA);
    return angleA + delta * t;
}

// This is a safe version of QuaternionBetween which returns a 180 deg rotation
// at the singularity where vectors are facing exactly in opposite directions
static inline Quaternion QuaternionBetween(Vector3 p, Vector3 q)
{
    const Vector3 c = Vector3CrossProduct(p, q);

    const Quaternion o = {
        c.x,
        c.y,
        c.z,
        sqrtf(Vector3DotProduct(p, p) * Vector3DotProduct(q, q)) + Vector3DotProduct(p, q),
    };

    return QuaternionLength(o) < 1e-8f ?
        QuaternionFromAxisAngle(Vector3{ 1.0f, 0.0f, 0.0f }, PI) :
        QuaternionNormalize(o);
}


// Puts the quaternion in the hemisphere closest to the identity
static inline Quaternion QuaternionAbsolute(Quaternion q)
{
    if (q.w < 0.0f)
    {
        q.x = -q.x;
        q.y = -q.y;
        q.z = -q.z;
        q.w = -q.w;
    }

    return q;
}

// Quaternion exponent, log, and angle axis functions (see: https://theorangeduck.com/page/exponential-map-angle-axis-angular-velocity)

static inline Quaternion QuaternionExp(Vector3 v)
{
    const float halfangle = sqrtf(v.x * v.x + v.y * v.y + v.z * v.z);

    if (halfangle < 1e-4f)
    {
        return QuaternionNormalize(Quaternion{ v.x, v.y, v.z, 1.0f });
    }
    else
    {
        const float c = cosf(halfangle);
        const float s = sinf(halfangle) / halfangle;
        return Quaternion{ s * v.x, s * v.y, s * v.z, c };
    }
}

static inline Vector3 QuaternionLog(Quaternion q)
{
    const float length = sqrtf(q.x * q.x + q.y * q.y + q.z * q.z);

    if (length < 1e-4f)
    {
        return Vector3{ q.x, q.y, q.z };
    }
    else
    {
        const float halfangle = atan2f(length, q.w);
        return Vector3Scale(Vector3{ q.x, q.y, q.z }, halfangle / length);
    }
}


// Extract only the Y-axis rotation component from a quaternion
static inline Quaternion QuaternionYComponent(Quaternion q)
{
    // Project to Y-axis rotation only: keep y and w, zero x and z
    Quaternion yOnly = { 0.0f, q.y, 0.0f, q.w };
    float len = sqrtf(yOnly.y * yOnly.y + yOnly.w * yOnly.w);
    if (len < 1e-8f) return QuaternionIdentity();
    return Quaternion{ 0.0f, yOnly.y / len, 0.0f, yOnly.w / len };
}


static inline Vector3 QuaternionToScaledAngleAxis(Quaternion q)
{
    return Vector3Scale(QuaternionLog(q), 2.0f);
}

static inline Quaternion QuaternionFromScaledAngleAxis(Vector3 v)
{
    return QuaternionExp(Vector3Scale(v, 0.5f));
}

// Cubic Interpolation (see: https://theorangeduck.com/page/cubic-interpolation-quaternions)

static inline Vector3 Vector3Hermite(Vector3 p0, Vector3 p1, Vector3 v0, Vector3 v1, float alpha)
{
    const float x = alpha;
    const float w0 = 2 * x * x * x - 3 * x * x + 1;
    const float w1 = 3 * x * x - 2 * x * x * x;
    const float w2 = x * x * x - 2 * x * x + x;
    const float w3 = x * x * x - x * x;

    return Vector3Add(
        Vector3Add(Vector3Scale(p0, w0), Vector3Scale(p1, w1)),
        Vector3Add(Vector3Scale(v0, w2), Vector3Scale(v1, w3)));
}

static inline Vector3 Vector3InterpolateCubic(Vector3 p0, Vector3 p1, Vector3 p2, Vector3 p3, float alpha)
{
    const Vector3 v1 = Vector3Scale(Vector3Add(Vector3Subtract(p1, p0), Vector3Subtract(p2, p1)), 0.5f);
    const Vector3 v2 = Vector3Scale(Vector3Add(Vector3Subtract(p2, p1), Vector3Subtract(p3, p2)), 0.5f);
    return Vector3Hermite(p1, p2, v1, v2, alpha);
}

static inline Quaternion QuaternionHermite(Quaternion r0, Quaternion r1, Vector3 v0, Vector3 v1, float alpha)
{
    const float x = alpha;
    const float w1 = 3 * x * x - 2 * x * x * x;
    const float w2 = x * x * x - 2 * x * x + x;
    const float w3 = x * x * x - x * x;

    const Vector3 r1r0 = QuaternionToScaledAngleAxis(
        QuaternionAbsolute(
            QuaternionMultiply(r1, QuaternionInvert(r0))));

    return QuaternionMultiply(QuaternionFromScaledAngleAxis(
        Vector3Add(
            Vector3Add(
                Vector3Scale(r1r0, w1),
                Vector3Scale(v0, w2)),
            Vector3Scale(v1, w3))),
        r0);
}

static inline Quaternion QuaternionInterpolateCubic(Quaternion r0, Quaternion r1, Quaternion r2, Quaternion r3, float alpha)
{
    const Vector3 r1r0 = QuaternionToScaledAngleAxis(QuaternionAbsolute(QuaternionMultiply(r1, QuaternionInvert(r0))));
    const Vector3 r2r1 = QuaternionToScaledAngleAxis(QuaternionAbsolute(QuaternionMultiply(r2, QuaternionInvert(r1))));
    const Vector3 r3r2 = QuaternionToScaledAngleAxis(QuaternionAbsolute(QuaternionMultiply(r3, QuaternionInvert(r2))));

    const Vector3 v1 = Vector3Scale(Vector3Add(r1r0, r2r1), 0.5f);
    const Vector3 v2 = Vector3Scale(Vector3Add(r2r1, r3r2), 0.5f);
    return QuaternionHermite(r1, r2, v1, v2, alpha);
}

// Frustum culling (based off https://github.com/JeffM2501/raylibExtras)

typedef struct
{
    Vector4 back;
    Vector4 front;
    Vector4 bottom;
    Vector4 top;
    Vector4 right;
    Vector4 left;

} Frustum;

static inline Vector4 FrustumPlaneNormalize(Vector4 plane)
{
    const float magnitude = sqrtf(Square(plane.x) + Square(plane.y) + Square(plane.z));
    plane.x /= magnitude;
    plane.y /= magnitude;
    plane.z /= magnitude;
    plane.w /= magnitude;
    return plane;
}

static inline Frustum FrustumFromCameraMatrices(
    const Matrix& projection,
    const Matrix& modelview)
{
    Frustum resultFrustum;
    Matrix planes = { 0 };
    planes.m0 = modelview.m0 * projection.m0 + modelview.m1 * projection.m4 + modelview.m2 * projection.m8 + modelview.m3 * projection.m12;
    planes.m1 = modelview.m0 * projection.m1 + modelview.m1 * projection.m5 + modelview.m2 * projection.m9 + modelview.m3 * projection.m13;
    planes.m2 = modelview.m0 * projection.m2 + modelview.m1 * projection.m6 + modelview.m2 * projection.m10 + modelview.m3 * projection.m14;
    planes.m3 = modelview.m0 * projection.m3 + modelview.m1 * projection.m7 + modelview.m2 * projection.m11 + modelview.m3 * projection.m15;
    planes.m4 = modelview.m4 * projection.m0 + modelview.m5 * projection.m4 + modelview.m6 * projection.m8 + modelview.m7 * projection.m12;
    planes.m5 = modelview.m4 * projection.m1 + modelview.m5 * projection.m5 + modelview.m6 * projection.m9 + modelview.m7 * projection.m13;
    planes.m6 = modelview.m4 * projection.m2 + modelview.m5 * projection.m6 + modelview.m6 * projection.m10 + modelview.m7 * projection.m14;
    planes.m7 = modelview.m4 * projection.m3 + modelview.m5 * projection.m7 + modelview.m6 * projection.m11 + modelview.m7 * projection.m15;
    planes.m8 = modelview.m8 * projection.m0 + modelview.m9 * projection.m4 + modelview.m10 * projection.m8 + modelview.m11 * projection.m12;
    planes.m9 = modelview.m8 * projection.m1 + modelview.m9 * projection.m5 + modelview.m10 * projection.m9 + modelview.m11 * projection.m13;
    planes.m10 = modelview.m8 * projection.m2 + modelview.m9 * projection.m6 + modelview.m10 * projection.m10 + modelview.m11 * projection.m14;
    planes.m11 = modelview.m8 * projection.m3 + modelview.m9 * projection.m7 + modelview.m10 * projection.m11 + modelview.m11 * projection.m15;
    planes.m12 = modelview.m12 * projection.m0 + modelview.m13 * projection.m4 + modelview.m14 * projection.m8 + modelview.m15 * projection.m12;
    planes.m13 = modelview.m12 * projection.m1 + modelview.m13 * projection.m5 + modelview.m14 * projection.m9 + modelview.m15 * projection.m13;
    planes.m14 = modelview.m12 * projection.m2 + modelview.m13 * projection.m6 + modelview.m14 * projection.m10 + modelview.m15 * projection.m14;
    planes.m15 = modelview.m12 * projection.m3 + modelview.m13 * projection.m7 + modelview.m14 * projection.m11 + modelview.m15 * projection.m15;

    resultFrustum.back = FrustumPlaneNormalize(Vector4{ planes.m3 - planes.m2, planes.m7 - planes.m6, planes.m11 - planes.m10, planes.m15 - planes.m14 });
    resultFrustum.front = FrustumPlaneNormalize(Vector4{ planes.m3 + planes.m2, planes.m7 + planes.m6, planes.m11 + planes.m10, planes.m15 + planes.m14 });
    resultFrustum.bottom = FrustumPlaneNormalize(Vector4{ planes.m3 + planes.m1, planes.m7 + planes.m5, planes.m11 + planes.m9, planes.m15 + planes.m13 });
    resultFrustum.top = FrustumPlaneNormalize(Vector4{ planes.m3 - planes.m1, planes.m7 - planes.m5, planes.m11 - planes.m9, planes.m15 - planes.m13 });
    resultFrustum.left = FrustumPlaneNormalize(Vector4{ planes.m3 + planes.m0, planes.m7 + planes.m4, planes.m11 + planes.m8, planes.m15 + planes.m12 });
    resultFrustum.right = FrustumPlaneNormalize(Vector4{ planes.m3 - planes.m0, planes.m7 - planes.m4, planes.m11 - planes.m8, planes.m15 - planes.m12 });
    return resultFrustum;
}

static inline float FrustumPlaneDistanceToPoint(Vector4 plane, Vector3 position)
{
    return (plane.x * position.x + plane.y * position.y + plane.z * position.z + plane.w);
}

static inline bool FrustumContainsSphere(Frustum frustum, Vector3 position, float radius)
{
    if (FrustumPlaneDistanceToPoint(frustum.back, position) < -radius) { return false; }
    if (FrustumPlaneDistanceToPoint(frustum.front, position) < -radius) { return false; }
    if (FrustumPlaneDistanceToPoint(frustum.bottom, position) < -radius) { return false; }
    if (FrustumPlaneDistanceToPoint(frustum.top, position) < -radius) { return false; }
    if (FrustumPlaneDistanceToPoint(frustum.left, position) < -radius) { return false; }
    if (FrustumPlaneDistanceToPoint(frustum.right, position) < -radius) { return false; }
    return true;
}

static inline float FastNegExp(float x)
{
    return 1.0f / (1.0f + x + 0.48f * x * x + 0.235f * x * x * x);
}

static inline float HalflifeToDamping(float halflife, float eps = 1e-5f)
{
    return (4.0f * 0.69314718056f) / (halflife + eps);
}

static inline void SimpleSpringDamperUsingDampingEydt(
    float& x,
    float& v,
    float x_goal,
    float damping,
    float eydt,
    float dt)
{
    const float y = damping;
    const float j0 = x - x_goal;
    const float j1 = v + j0 * y;

    x = eydt * (j0 + j1 * dt) + x_goal;
    v = eydt * (v - j1 * y * dt);
}


static inline void SimpleSpringDamper(
    float& x,
    float& v,
    float x_goal,
    float blendtime,
    float dt)
{
    const float y = HalflifeToDamping(blendtime / 2.0f) / 2.0f;
    const float eydt = FastNegExp(y * dt);

    SimpleSpringDamperUsingDampingEydt(x, v, x_goal, y, eydt, dt);
}

struct DoubleSpringDamperState
{
    float x;
    float v;
    float xi;
    float vi;
};

static inline void DoubleSpringDamper(
    DoubleSpringDamperState& state,
    float x_goal,
    float blendtime,
    float dt)
{
    // half of the blendtime for each damper
    const float y = HalflifeToDamping(blendtime / 4.0f) / 2.0f;
    const float eydt = FastNegExp(y * dt);

    SimpleSpringDamperUsingDampingEydt(state.xi, state.vi, x_goal, y, eydt, dt);
    SimpleSpringDamperUsingDampingEydt(state.x, state.v, state.xi, y, eydt, dt);
}

// Vector2 versions of spring dampers

static inline void SimpleSpringDamperUsingDampingEydtVector2(
    Vector2& x,
    Vector2& v,
    Vector2 x_goal,
    float damping,
    float eydt,
    float dt)
{
    const float y = damping;
    const Vector2 j0 = Vector2Subtract(x, x_goal);
    const Vector2 j1 = Vector2Add(v, Vector2Scale(j0, y));

    x = Vector2Add(Vector2Scale(Vector2Add(j0, Vector2Scale(j1, dt)), eydt), x_goal);
    v = Vector2Scale(Vector2Subtract(v, Vector2Scale(j1, y * dt)), eydt);
}

struct DoubleSpringDamperStateVector2
{
    Vector2 x = {0.0f, 0.0f};
    Vector2 v = {0.0f, 0.0f};
    Vector2 xi = {0.0f, 0.0f};
    Vector2 vi = {0.0f, 0.0f};
};

static inline void DoubleSpringDamperVector2(
    DoubleSpringDamperStateVector2& state,
    Vector2 x_goal,
    float blendtime,
    float dt)
{
    const float y = HalflifeToDamping(blendtime / 4.0f) / 2.0f;
    const float eydt = FastNegExp(y * dt);

    SimpleSpringDamperUsingDampingEydtVector2(state.xi, state.vi, x_goal, y, eydt, dt);
    SimpleSpringDamperUsingDampingEydtVector2(state.x, state.v, state.xi, y, eydt, dt);
}

// Vector3 versions of spring dampers
static inline void SimpleSpringDamperUsingDampingEydtVector3(
    Vector3& x,
    Vector3& v,
    Vector3 x_goal,
    float damping,
    float eydt,
    float dt)
{
    const float y = damping;
    const Vector3 j0 = Vector3Subtract(x, x_goal);
    const Vector3 j1 = Vector3Add(v, Vector3Scale(j0, y));

    x = Vector3Add(Vector3Scale(Vector3Add(j0, Vector3Scale(j1, dt)), eydt), x_goal);
    v = Vector3Scale(Vector3Subtract(v, Vector3Scale(j1, y * dt)), eydt);
}

static inline void SimpleSpringDamperVector3(
    Vector3& x,
    Vector3& v,
    Vector3 x_goal,
    float blendtime,
    float dt)
{
    const float y = HalflifeToDamping(blendtime / 2.0f) / 2.0f;
    const float eydt = FastNegExp(y * dt);

    SimpleSpringDamperUsingDampingEydtVector3(x, v, x_goal, y, eydt, dt);
}

struct DoubleSpringDamperStateVector3
{
    Vector3 x = Vector3Zero();
    Vector3 v = Vector3Zero();
    Vector3 xi = Vector3Zero();
    Vector3 vi = Vector3Zero();
};

static inline void DoubleSpringDamperVector3(
    DoubleSpringDamperStateVector3& state,
    Vector3 x_goal,
    float blendtime,
    float dt)
{
    // half of the blendtime for each damper
    const float y = HalflifeToDamping(blendtime / 4.0f) / 2.0f;
    const float eydt = FastNegExp(y * dt);

    SimpleSpringDamperUsingDampingEydtVector3(state.xi, state.vi, x_goal, y, eydt, dt);
    SimpleSpringDamperUsingDampingEydtVector3(state.x, state.v, state.xi, y, eydt, dt);
}





struct Rot6d
{
    float ax, ay, az;
    float bx, by, bz;
};

inline float FastInvSqrt(const float x)
{
    const float xhalf = 0.5f * x;
    int32_t i = *(int32_t*)&x;
    i = 0x5f3759df - (i >> 1);
    float y = *(float*)&i;
    y = y * (1.5f - xhalf * y * y);
    return y;
}

void Rot6dRotate(Rot6d& rot, const Vector3& omega, float dt)
{
    const float wx = omega.x * dt;
    const float wy = omega.y * dt;
    const float wz = omega.z * dt;

    const float thetaSq = wx * wx + wy * wy + wz * wz;
    if (thetaSq < 1e-12f)
    {
        return;
    }

    const float nax = rot.ax + (wy * rot.az - wz * rot.ay);
    const float nay = rot.ay + (wz * rot.ax - wx * rot.az);
    const float naz = rot.az + (wx * rot.ay - wy * rot.ax);

    const float nbx = rot.bx + (wy * rot.bz - wz * rot.by);
    const float nby = rot.by + (wz * rot.bx - wx * rot.bz);
    const float nbz = rot.bz + (wx * rot.by - wy * rot.bx);

    const float invLenA = FastInvSqrt(nax * nax + nay * nay + naz * naz);
    rot.ax = nax * invLenA;
    rot.ay = nay * invLenA;
    rot.az = naz * invLenA;

    const float dot = rot.ax * nbx + rot.ay * nby + rot.az * nbz;
    const float rbx = nbx - dot * rot.ax;
    const float rby = nby - dot * rot.ay;
    const float rbz = nbz - dot * rot.az;

    const float invLenB = FastInvSqrt(rbx * rbx + rby * rby + rbz * rbz);
    rot.bx = rbx * invLenB;
    rot.by = rby * invLenB;
    rot.bz = rbz * invLenB;
}

Rot6d Rot6dMultiply(const Rot6d& lhs, const Rot6d& rhs)
{
    const float lcx = lhs.ay * lhs.bz - lhs.az * lhs.by;
    const float lcy = lhs.az * lhs.bx - lhs.ax * lhs.bz;
    const float lcz = lhs.ax * lhs.by - lhs.ay * lhs.bx;

    Rot6d out;
    out.ax = lhs.ax * rhs.ax + lhs.bx * rhs.ay + lcx * rhs.az;
    out.ay = lhs.ay * rhs.ax + lhs.by * rhs.ay + lcy * rhs.az;
    out.az = lhs.az * rhs.ax + lhs.bz * rhs.ay + lcz * rhs.az;

    out.bx = lhs.ax * rhs.bx + lhs.bx * rhs.by + lcx * rhs.bz;
    out.by = lhs.ay * rhs.bx + lhs.by * rhs.by + lcy * rhs.bz;
    out.bz = lhs.az * rhs.bx + lhs.bz * rhs.by + lcz * rhs.bz;
    return out;
}

Rot6d Rot6dInverse(const Rot6d& rot)
{
    const float cx = rot.ay * rot.bz - rot.az * rot.by;
    const float cy = rot.az * rot.bx - rot.ax * rot.bz;

    Rot6d out;
    out.ax = rot.ax; out.ay = rot.bx; out.az = cx;
    out.bx = rot.ay; out.by = rot.by; out.bz = cy;
    return out;
}

static inline Vector3 Vector3RotateByRot6d(Vector3 v, const Rot6d& rot)
{
    const float cx = rot.ay * rot.bz - rot.az * rot.by;
    const float cy = rot.az * rot.bx - rot.ax * rot.bz;
    const float cz = rot.ax * rot.by - rot.ay * rot.bx;

    Vector3 result;
    result.x = v.x * rot.ax + v.y * rot.bx + v.z * cx;
    result.y = v.x * rot.ay + v.y * rot.by + v.z * cy;
    result.z = v.x * rot.az + v.y * rot.bz + v.z * cz;

    return result;
}

Quaternion Rot6dToQuaternion(const Rot6d& rot)
{
    // third column via cross product: c = a × b
    const float cx = rot.ay * rot.bz - rot.az * rot.by;
    const float cy = rot.az * rot.bx - rot.ax * rot.bz;
    const float cz = rot.ax * rot.by - rot.ay * rot.bx;

    Quaternion q;
    const float tr = rot.ax + rot.by + cz;
    if (tr > 0.0f)
    {
        const float s = std::sqrt(tr + 1.0f) * 2.0f;
        q.w = 0.25f * s;
        q.x = (rot.bz - cy) / s;
        q.y = (cx - rot.az) / s;
        q.z = (rot.ay - rot.bx) / s;
    }
    else if ((rot.ax > rot.by) && (rot.ax > cz))
    {
        const float s = std::sqrt(1.0f + rot.ax - rot.by - cz) * 2.0f;
        q.w = (rot.bz - cy) / s;
        q.x = 0.25f * s;
        q.y = (rot.ay + rot.bx) / s;
        q.z = (rot.az + cx) / s;
    }
    else if (rot.by > cz)
    {
        const float s = std::sqrt(1.0f + rot.by - rot.ax - cz) * 2.0f;
        q.w = (cx - rot.az) / s;
        q.x = (rot.ay + rot.bx) / s;
        q.y = 0.25f * s;
        q.z = (rot.bz + cy) / s;
    }
    else
    {
        const float s = std::sqrt(1.0f + cz - rot.ax - rot.by) * 2.0f;
        q.w = (rot.ay - rot.bx) / s;
        q.x = (rot.az + cx) / s;
        q.y = (rot.bz + cy) / s;
        q.z = 0.25f * s;
    }
    return q;
}

Rot6d QuaternionToRot6d(const Quaternion& q)
{
    const float x2 = q.x + q.x, y2 = q.y + q.y, z2 = q.z + q.z;
    const float xx = q.x * x2, xy = q.x * y2, xz = q.x * z2;
    const float yy = q.y * y2, yz = q.y * z2, zz = q.z * z2;
    const float wx = q.w * x2, wy = q.w * y2, wz = q.w * z2;

    Rot6d r;
    r.ax = 1.0f - (yy + zz);
    r.ay = xy + wz;
    r.az = xz - wy;
    r.bx = xy - wz;
    r.by = 1.0f - (xx + zz);
    r.bz = yz + wx;
    return r;
}

Matrix Rot6dToMatrix(const Rot6d& rot)
{
    const float cx = rot.ay * rot.bz - rot.az * rot.by;
    const float cy = rot.az * rot.bx - rot.ax * rot.bz;
    const float cz = rot.ax * rot.by - rot.ay * rot.bx;

    Matrix m;
    m.m0 = rot.ax; m.m4 = rot.bx; m.m8 = cx;   m.m12 = 0.0f;
    m.m1 = rot.ay; m.m5 = rot.by; m.m9 = cy;   m.m13 = 0.0f;
    m.m2 = rot.az; m.m6 = rot.bz; m.m10 = cz;   m.m14 = 0.0f;
    m.m3 = 0.0f;   m.m7 = 0.0f;   m.m11 = 0.0f; m.m15 = 1.0f;
    return m;
}

Rot6d MatrixToRot6d(const Matrix& mat)
{
    Rot6d r;
    r.ax = mat.m0; r.ay = mat.m1; r.az = mat.m2;
    r.bx = mat.m4; r.by = mat.m5; r.bz = mat.m6;
    return r;
}

Rot6d Rot6dLerp(const Rot6d& start, const Rot6d& end, float t)
{
    const float invT = 1.0f - t;

    const float nax = start.ax * invT + end.ax * t;
    const float nay = start.ay * invT + end.ay * t;
    const float naz = start.az * invT + end.az * t;

    const float nbx = start.bx * invT + end.bx * t;
    const float nby = start.by * invT + end.by * t;
    const float nbz = start.bz * invT + end.bz * t;

    // Normalize a-column
    const float invLenA = FastInvSqrt(nax * nax + nay * nay + naz * naz);
    const float ax = nax * invLenA;
    const float ay = nay * invLenA;
    const float az = naz * invLenA;

    // Gram-Schmidt: remove a-component from b
    const float dot = ax * nbx + ay * nby + az * nbz;
    const float rbx = nbx - dot * ax;
    const float rby = nby - dot * ay;
    const float rbz = nbz - dot * az;

    // Normalize b-column
    const float invLenB = FastInvSqrt(rbx * rbx + rby * rby + rbz * rbz);

    return Rot6d{ ax, ay, az, rbx * invLenB, rby * invLenB, rbz * invLenB };
}

// Frame interpolation helpers - given pointer to arr[f0], lerp with arr[f0+1]
static inline Vector3 LerpFrames(const Vector3* base, float alpha)
{
    return Vector3Lerp(base[0], base[1], alpha);
}

static inline float LerpFrames(const float* base, float alpha)
{
    return Lerp(base[0], base[1], alpha);
}

static inline Rot6d LerpFrames(const Rot6d* base, float alpha)
{
    return Rot6dLerp(base[0], base[1], alpha);
}

// Rot6d scaled addition: inout = a*x + inout (like BLAS axpy)
// Useful for weighted accumulation of rotations
static inline void Rot6dScaledAdd(float a, const Rot6d& x, Rot6d& inout)
{
    inout.ax += a * x.ax;
    inout.ay += a * x.ay;
    inout.az += a * x.az;
    inout.bx += a * x.bx;
    inout.by += a * x.by;
    inout.bz += a * x.bz;
}

Rot6d Rot6dSlerp(const Rot6d& start, const Rot6d& end, float t)
{
    const Quaternion qStart = Rot6dToQuaternion(start);
    const Quaternion qEnd = Rot6dToQuaternion(end);
    return QuaternionToRot6d(QuaternionSlerp(qStart, qEnd, t));
}

// orthonormalize a Rot6d (useful after weighted accumulation)
void Rot6dNormalize(Rot6d& rot)
{
    // normalize a-column
    const float invLenA = FastInvSqrt(rot.ax * rot.ax + rot.ay * rot.ay + rot.az * rot.az);
    rot.ax *= invLenA;
    rot.ay *= invLenA;
    rot.az *= invLenA;

    // remove a-component from b, then normalize b
    const float dot = rot.ax * rot.bx + rot.ay * rot.by + rot.az * rot.bz;
    rot.bx -= dot * rot.ax;
    rot.by -= dot * rot.ay;
    rot.bz -= dot * rot.az;

    const float invLenB = FastInvSqrt(rot.bx * rot.bx + rot.by * rot.by + rot.bz * rot.bz);
    rot.bx *= invLenB;
    rot.by *= invLenB;
    rot.bz *= invLenB;
}

// identity Rot6d
static inline Rot6d Rot6dIdentity()
{
    return Rot6d{ 1.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f };
}

// use this only to initialize accumulators
static inline Rot6d Rot6dZero()
{
    return Rot6d{ 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f };
}


// extract Y-rotation (yaw) angle from Rot6d
// the first column (a) of a Y-rotation matrix is [cos(y), 0, -sin(y)]
// so yaw = atan2(-az, ax)
static inline float Rot6dGetYaw(const Rot6d& rot)
{
    return atan2f(-rot.az, rot.ax);
}

// create a Y-only rotation Rot6d from an angle
static inline Rot6d Rot6dFromYaw(float yaw)
{
    const float c = cosf(yaw);
    const float s = sinf(yaw);
    // Y-rotation matrix:
    // | cos   0  sin |
    // |  0    1   0  |
    // |-sin   0  cos |
    // first column (a) = [cos, 0, -sin], second column (b) = [0, 1, 0]
    return Rot6d{ c, 0.0f, -s, 0.0f, 1.0f, 0.0f };
}

// remove Y-rotation component from a Rot6d, returning just the tilt/roll
// result = inverse(yaw) * rot
// safe to call with rot == out (handles aliasing)
static inline Rot6d Rot6dRemoveYComponent(const Rot6d& rot)
{
    const float yaw = Rot6dGetYaw(rot);
    const Rot6d invYaw = Rot6dFromYaw(-yaw);
    Rot6d result = Rot6dMultiply(invYaw, rot);
    Rot6dNormalize(result);  // ensure orthonormal after multiplication
    return result;
}

Vector3 Rot6dGetVelocity(const Rot6d& current, const Rot6d& target, float dt)
{
    const Quaternion qCurrent = Rot6dToQuaternion(current);
    const Quaternion qTarget = Rot6dToQuaternion(target);

    const float qx = qTarget.w * -qCurrent.x + qTarget.x * qCurrent.w + qTarget.y * -qCurrent.z - qTarget.z * -qCurrent.y;
    const float qy = qTarget.w * -qCurrent.y - qTarget.x * -qCurrent.z + qTarget.y * qCurrent.w + qTarget.z * -qCurrent.x;
    const float qz = qTarget.w * -qCurrent.z + qTarget.x * -qCurrent.y - qTarget.y * -qCurrent.x + qTarget.z * qCurrent.w;
    const float qw = qTarget.w * qCurrent.w - qTarget.x * -qCurrent.x - qTarget.y * -qCurrent.y - qTarget.z * -qCurrent.z;

    float absQw = (qw < 0.0f) ? -qw : qw;
    if (absQw > 1.0f) absQw = 1.0f;

    const float angle = 2.0f * std::acos(absQw);

    if (angle < 1e-6f)
    {
        return Vector3Zero();
    }

    const float sinHalf = std::sqrt(1.0f - absQw * absQw);
    float factor = (angle / dt) / (sinHalf < 1e-6f ? 1.0f : sinHalf);
    if (qw < 0.0f) factor = -factor;

    return Vector3{ qx * factor, qy * factor, qz * factor };
}