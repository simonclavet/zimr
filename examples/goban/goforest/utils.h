#pragma once

#include "math_utils.h"
#include "raymath.h"
#include "raylib.h"

#include <cassert>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <span>
#include <random>

#ifdef __GNUC__
#define ASSERT_EVEN_IN_RELEASE_FUNCTION __PRETTY_FUNCTION__
#elif defined(_MSC_VER)
#define ASSERT_EVEN_IN_RELEASE_FUNCTION __FUNCSIG__
#else
#define ASSERT_EVEN_IN_RELEASE_FUNCTION __func__
#endif

#define assertEvenInRelease(condition) \
    do { \
        if (!(condition)) { \
            std::cerr << "Assertion failed: " << #condition \
                      << "\nFile: " << __FILE__ \
                      << "\nLine: " << __LINE__ \
                      << "\nFunction: " << ASSERT_EVEN_IN_RELEASE_FUNCTION \
                      << std::endl; \
            __debugbreak(); \
        } \
    } while (false)


//std::abort(); \



template<typename... Ts>
constexpr void unused(Ts&&...) {}

// random int in [0, maxExclusive). Uses mt19937 so it works
// for ranges way beyond MSVC's RAND_MAX of 32767.
static inline int RandomInt(int maxExclusive)
{
    static thread_local std::mt19937 rng(std::random_device{}());
    std::uniform_int_distribution<int> dist(0, maxExclusive - 1);
    return dist(rng);
}

// random float in [0, 1)
static inline float RandomFloat01()
{
    static thread_local std::mt19937 rng(std::random_device{}());
    std::uniform_real_distribution<float> dist(0.0f, 1.0f);
    return dist(rng);
}

// random float from standard normal distribution N(0, 1)
static inline float RandomGaussian()
{
    static thread_local std::mt19937 rng(std::random_device{}());
    std::normal_distribution<float> dist(0.0f, 1.0f);
    return dist(rng);
}

//----------------------------------------------------------------------------------
// Command Line Args
//----------------------------------------------------------------------------------

// Finds an argument on the command line with the given name (in the format "--argName=argValue") and returns the argValue as a string
static inline const char* ArgFind(int argc, char** argv, const char* name)
{
    for (int i = 1; i < argc; i++)
    {
        if (strlen(argv[i]) > 4 &&
            argv[i][0] == '-' &&
            argv[i][1] == '-' &&
            strstr(argv[i] + 2, name) == argv[i] + 2)
        {
            const char* argStart = strchr(argv[i], '=');
            return argStart ? argStart + 1 : NULL;
        }
    }

    return NULL;
}

// Parse a float argument from the command line
static inline float ArgFloat(int argc, char** argv, const char* name, float defaultValue)
{
    const char* value = ArgFind(argc, argv, name);
    if (!value) { return defaultValue; }

    errno = 0;
    float output = strtof(value, NULL);
    if (errno == 0) { printf("INFO: Parsed option '%s' as '%s'\n", name, value); return output; }

    printf("ERROR: Could not parse value '%s' given for option '%s' as float\n", value, name);
    return defaultValue;
}

// Parse an integer argument from the command line
static inline int ArgInt(int argc, char** argv, const char* name, int defaultValue)
{
    const char* value = ArgFind(argc, argv, name);
    if (!value) { return defaultValue; }

    errno = 0;
    int output = (int)strtol(value, NULL, 10);
    if (errno == 0) { printf("INFO: Parsed option '%s' as '%s'\n", name, value); return output; }

    printf("ERROR: Could not parse value '%s' given for option '%s' as int\n", value, name);
    return defaultValue;
}

// Parse a boolean argument from the command line
static inline int ArgBool(int argc, char** argv, const char* name, bool defaultValue)
{
    const char* value = ArgFind(argc, argv, name);
    if (!value) { return defaultValue; }
    if (strcmp(value, "true") == 0) { printf("INFO: Parsed option '%s' as '%s'\n", name, value); return true; }
    if (strcmp(value, "false") == 0) { printf("INFO: Parsed option '%s' as '%s'\n", name, value); return false; }

    printf("ERROR: Could not parse value '%s' given for option '%s' as bool\n", value, name);
    return defaultValue;
}

// Parse an enum argument from the command line
static inline int ArgEnum(int argc, char** argv, const char* name, int optionCount, const char* options[], int defaultValue)
{
    const char* value = ArgFind(argc, argv, name);
    if (!value) { return defaultValue; }

    for (int i = 0; i < optionCount; i++)
    {
        if (strcmp(value, options[i]) == 0)
        {
            printf("INFO: Parsed option '%s' as '%s'\n", name, value);
            return i;
        }
    }

    printf("ERROR: Could not parse value '%s' given for option '%s' as enum\n", value, name);
    return defaultValue;
}

// Parse a string argument from the command line
static inline const char* ArgStr(int argc, char** argv, const char* name, const char* defaultValue)
{
    const char* value = ArgFind(argc, argv, name);
    if (!value) { return defaultValue; }

    printf("INFO: Parsed option '%s' as '%s'\n", name, value);
    return value;
}

// Parse a color argument from the command line
static inline Color ArgColor(int argc, char** argv, const char* name, Color defaultValue)
{
    const char* value = ArgFind(argc, argv, name);
    if (!value) { return defaultValue; }

    int cx, cy, cz;
    if (sscanf(value, "%i,%i,%i", &cx, &cy, &cz) == 3)
    {
        printf("INFO: Parsed option '%s' as '%s'\n", name, value);
        return Color{ (unsigned char)ClampInt(cx, 0, 255), (unsigned char)ClampInt(cy, 0, 255), (unsigned char)ClampInt(cz, 0, 255), 255 };
    }

    printf("ERROR: Could not parse value '%s' given for option '%s' as color\n", value, name);
    return defaultValue;
}

// Parse a vector3 argument from the command line
static inline Vector3 ArgVector3(int argc, char** argv, const char* name, Vector3 defaultValue)
{
    const char* value = ArgFind(argc, argv, name);
    if (!value) { return defaultValue; }

    float cx, cy, cz;
    if (sscanf(value, "%f,%f,%f", &cx, &cy, &cz) == 3)
    {
        printf("INFO: Parsed option '%s' as '%s'\n", name, value);
        return Vector3{ cx, cy, cz };
    }

    printf("ERROR: Could not parse value '%s' given for option '%s' as color\n", value, name);
    return defaultValue;
}



// Parse an integer value from JSON
static inline int ParseIntValue(const char* json, const char* key, int defaultVal)
{
    char searchKey[64];
    snprintf(searchKey, sizeof(searchKey), "\"%s\"", key);
    const char* found = strstr(json, searchKey);
    if (!found) return defaultVal;

    const char* colon = strchr(found, ':');
    if (!colon) return defaultVal;

    return atoi(colon + 1);
}

// Parse a float value from JSON
static inline float ParseFloatValue(const char* json, const char* key, float defaultVal)
{
    char searchKey[64];
    snprintf(searchKey, sizeof(searchKey), "\"%s\"", key);
    const char* found = strstr(json, searchKey);
    if (!found) return defaultVal;

    const char* colon = strchr(found, ':');
    if (!colon) return defaultVal;

    return (float)atof(colon + 1);
}

// Parse a bool value from JSON (0/1 or true/false)
static inline bool ParseBoolValue(const char* json, const char* key, bool defaultVal)
{
    char searchKey[64];
    snprintf(searchKey, sizeof(searchKey), "\"%s\"", key);
    const char* found = strstr(json, searchKey);
    if (!found) return defaultVal;

    const char* colon = strchr(found, ':');
    if (!colon) return defaultVal;

    const char* p = colon + 1;
    while (*p == ' ' || *p == '\t') ++p;
    if (strncmp(p, "true", 4) == 0) return true;
    if (strncmp(p, "false", 5) == 0) return false;

    return atoi(p) != 0;
}


// Parse a color stored as JSON array [r, g, b] (ints). Returns defaultVal on failure.
static inline Color ParseColorFromJson(const char* json, const char* key, Color defaultVal)
{
    if (!json) return defaultVal;
    char searchKey[64];
    snprintf(searchKey, sizeof(searchKey), "\"%s\"", key);
    const char* found = strstr(json, searchKey);
    if (!found) return defaultVal;

    const char* bracket = strchr(found, '[');
    if (!bracket) return defaultVal;

    int r = -1, g = -1, b = -1;
    // sscanf tolerates spaces; expect three integers
    if (sscanf(bracket, " [ %d , %d , %d", &r, &g, &b) >= 3) {
        // Clamp 0..255
        r = (r < 0) ? 0 : (r > 255) ? 255 : r;
        g = (g < 0) ? 0 : (g > 255) ? 255 : g;
        b = (b < 0) ? 0 : (b > 255) ? 255 : b;
        return Color{ (unsigned char)r, (unsigned char)g, (unsigned char)b, 255 };
    }

    return defaultVal;
}

// -----------------------------------------------------------------------------
// Helper resolvers: apply precedence defaults -> JSON -> command line
// -----------------------------------------------------------------------------
static inline int ResolveIntConfig(const char* jsonBuffer, const char* key, int defaultVal, int argc, char** argv)
{
    int v = defaultVal;
    if (jsonBuffer) v = ParseIntValue(jsonBuffer, key, v);
    if (argc > 0 && argv) v = ArgInt(argc, argv, key, v);
    return v;
}

static inline float ResolveFloatConfig(const char* jsonBuffer, const char* key, float defaultVal, int argc, char** argv)
{
    float v = defaultVal;
    if (jsonBuffer) v = ParseFloatValue(jsonBuffer, key, v);
    if (argc > 0 && argv) v = ArgFloat(argc, argv, key, v);
    return v;
}

static inline bool ResolveBoolConfig(const char* jsonBuffer, const char* key, bool defaultVal, int argc, char** argv)
{
    bool v = defaultVal;
    if (jsonBuffer) v = ParseBoolValue(jsonBuffer, key, v);
    if (argc > 0 && argv) v = ArgBool(argc, argv, key, v);
    return v;
}

static inline Color ResolveColorConfig(const char* jsonBuffer, const char* key, Color defaultVal, int argc, char** argv)
{
    Color v = defaultVal;
    if (jsonBuffer) v = ParseColorFromJson(jsonBuffer, key, v);
    if (argc > 0 && argv) v = ArgColor(argc, argv, key, v);
    return v;
}

// Returns a lowercase std::string copy of a C string (safe for null)
static inline std::string ToLowerCopy(const char* s)
{
    std::string out = s ? std::string(s) : std::string();
    for (size_t i = 0; i < out.size(); ++i)
    {
        out[i] = (char)std::tolower((unsigned char)out[i]);
    }
    return out;
}

// Case-insensitive substring test: returns true if 'needle' is found inside 'hay'.
// Both inputs are expected to already be lower-case if you want faster behaviour.
static inline bool StrContainsCaseInsensitive(const std::string& hay, const std::string& needle)
{
    if (needle.empty()) return false;
    return hay.find(needle) != std::string::npos;
}

static constexpr int SIDE_LEFT = 0;
static constexpr int SIDE_RIGHT = 1;
static constexpr int SIDES_COUNT = 2;

// Exposed array of both sides for easy iteration.
static inline const int sides[] = { SIDE_LEFT, SIDE_RIGHT };

// Returns the opposite side (int)
static inline int OtherSideInt(int side)
{
    return (side == SIDE_LEFT) ? SIDE_RIGHT : SIDE_LEFT;
}

// Convert side int to lowercase string ("left"/"right").
static inline const char* StringFromSide(int side)
{
    return (side == SIDE_LEFT) ? "left" : "right";
}

// Parse a side from a C string, case-insensitive and forgiving.
// Accepts "left", "l", "right", "r" (any case). Returns defaultVal on failure.
static inline int SideFromString(const char* s, int defaultVal)
{
    if (!s) return defaultVal;
    std::string lower = ToLowerCopy(s);
    if (lower == "left" || lower == "l") return SIDE_LEFT;
    if (lower == "right" || lower == "r") return SIDE_RIGHT;
    // Also tolerate strings containing the token, e.g. "LeftArm"
    if (StrContainsCaseInsensitive(lower, "left")) return SIDE_LEFT;
    if (StrContainsCaseInsensitive(lower, "right")) return SIDE_RIGHT;
    return defaultVal;
}

struct Index2D
{
    int row = -1;
    int col = -1;

    bool operator==(const Index2D other) const 
    {
        return other.row == row && other.col == col;
    }
};

template<typename T>
class Array2D
{
private:
    int rows_;
    int cols_;
    std::vector<T> data_;

public:
    // Default constructor (empty array)
    Array2D()
        : rows_(0), cols_(0), data_()
    {
    }

    // Constructor with dimensions
    Array2D(int rows, int cols)
        : rows_(rows), cols_(cols), data_(rows * cols)
    {
        assert(rows >= 0 && cols >= 0 && "Array2D dimensions must be non-negative");
    }

    // Constructor with initial value
    Array2D(int rows, int cols, const T& initial_value)
        : rows_(rows), cols_(cols), data_(rows * cols, initial_value)
    {
        assert(rows >= 0 && cols >= 0 && "Array2D dimensions must be non-negative");
    }

    // Resize the array (invalidates existing data)
    void resize(int rows, int cols)
    {
        assert(rows >= 0 && cols >= 0 && "Array2D dimensions must be non-negative");
        rows_ = rows;
        cols_ = cols;
        data_.resize(rows * cols);
    }

    // Clear the array (set to empty)
    void clear()
    {
        rows_ = 0;
        cols_ = 0;
        data_.clear();
    }

    // Check if empty
    bool empty() const noexcept
    {
        return data_.empty();
    }

    // Non-const element access with bounds checking
    T& at(int row_view, int col)
    {
        assert(row_view >= 0 && row_view < rows_ && col >= 0 && col < cols_
            && "Array2D index out of bounds");
        return data_.at(row_view * cols_ + col);
    }


    // Const element access with bounds checking
    const T& at(int row_view, int col) const
    {
        assert(row_view >= 0 && row_view < rows_ && col >= 0 && col < cols_
            && "Array2D index out of bounds");
        return data_[row_view * cols_ + col];
    }

    T& at(const Index2D& index)
    {
        return at(index.row, index.col);
    }

    const T& at(const Index2D& index) const 
    {
        return at(index.row, index.col);
    }

    bool contains(Index2D p) const
    {
        return p.row >= 0 && p.row < rows_ && p.col >= 0 && p.col < cols_;
    }

    // Non-const row view
    std::span<T> row_view(int row_idx)
    {
        assert(row_idx >= 0 && row_idx < rows_ && "Array2D row index out of bounds");
        return std::span<T>(data_.data() + row_idx * cols_, cols_);
    }

    // Const row view
    std::span<const T> row_view(int row_idx) const
    {
        assert(row_idx >= 0 && row_idx < rows_ && "Array2D row index out of bounds");
        return std::span<const T>(data_.data() + row_idx * cols_, cols_);
    }

    // Fill all elements with the same value
    void fill(const T& value)
    {
        std::fill(data_.begin(), data_.end(), value);
    }

    // Get dimensions
    int rows() const noexcept
    {
        return rows_;
    }

    int cols() const noexcept
    {
        return cols_;
    }

    int size() const noexcept
    {
        return rows_ * cols_;
    }

    // Raw data access
    T* data() noexcept
    {
        return data_.data();
    }

    const T* data() const noexcept
    {
        return data_.data();
    }

    // Non-const operator[] for unchecked access
    T& operator()(int row_view, int col) noexcept
    {
        return data_[row_view * cols_ + col];
    }

    // Const operator[] for unchecked access
    const T& operator()(int row_view, int col) const noexcept
    {
        return data_[row_view * cols_ + col];
    }

    // Iterator support
    typename std::vector<T>::iterator begin() noexcept
    {
        return data_.begin();
    }

    typename std::vector<T>::iterator end() noexcept
    {
        return data_.end();
    }

    typename std::vector<T>::const_iterator begin() const noexcept
    {
        return data_.begin();
    }

    typename std::vector<T>::const_iterator end() const noexcept
    {
        return data_.end();
    }

    typename std::vector<T>::const_iterator cbegin() const noexcept
    {
        return data_.cbegin();
    }

    typename std::vector<T>::const_iterator cend() const noexcept
    {
        return data_.cend();
    }
};


using Clock = std::chrono::high_resolution_clock;
// use Clock::time_point
static inline double ElapsedSeconds(
    Clock::time_point start)
{
    return std::chrono::duration<double>(
        Clock::now() - start).count();
}
