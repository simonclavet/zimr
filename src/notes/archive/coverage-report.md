# zimr cheatsheet

_Auto-generated audit of zimr's API surface against raylib 6.0._  
_Modeled on raylib's own cheatsheet at https://www.raylib.com/cheatsheet/cheatsheet.html._  
_Re-generate with `python3 docs/cheatsheet-generator.py > docs/coverage-report.md`._

## Coverage at a glance

| Metric | Value |
| ------ | ----- |
| Total raylib functions (raylib.h + raymath.h + rlgl.h) | **911** |
| Out of scope (rgestures, deferred) | 8 |
| In-scope raylib functions | **903** |
| Matched in zimr (by name) | **724** |
| Intentionally not ported (web-platform mismatch / use stdlib) | 180 |
| **Coverage of in-scope raylib API** | **80.2%** |
| zimr public functions | 1405 |
| zimr functions with `Allocator` parameter | 142 |
| zimr functions returning error union | 90 |
| zimr functions fully ziggified (alloc + error) | 85 |
| zimr functions referenced by an example | 462 (32.9%) |
| zimr examples shipped | 43 |
| raylib reference example count | ~150 |
| **Example portage** | **29%** |

## Per-module coverage

| raylib module | raylib fns | ported | %  | example coverage |
| ------------- | ---------: | -----: | -: | ---------------: |
| core | 208 | 108 | 51.9% | 57/121 (47.1%) |
| rcamera | 2 | 2 | 100.0% | 1/2 (50.0%) |
| shapes | 70 | 70 | 100.0% | 13/70 (18.6%) |
| textures | 116 | 106 | 91.4% | 29/106 (27.4%) |
| text | 59 | 35 | 59.3% | 7/33 (21.2%) |
| models | 73 | 69 | 94.5% | 28/69 (40.6%) |
| audio | 66 | 55 | 83.3% | 46/54 (85.2%) |
| rgestures _(deferred)_ | 8 | 8 | 100.0% | 5/8 (62.5%) |
| raymath | 146 | 146 | 100.0% | 7/149 (4.7%) |
| rlgl | 163 | 133 | 81.6% | 42/202 (20.8%) |

## Function-by-function status

Legend:  ✅ ported  ·  ❌ not yet ported  ·  🧪 exercised by an example  ·  💧 takes Allocator  ·  ❗ returns error union

### `core`

#### Window-related functions  (18/49)

- ❌ `InitWindow(int width, int height, const char *title)`
- ❌ `CloseWindow(void)`
- ✅ `WindowShouldClose` → `z.core.windowShouldClose`
- ❌ `IsWindowReady(void)`
- ✅🧪 `IsWindowFullscreen` → `z.core.isFullscreen` — _window_demo_
- ❌ `IsWindowHidden(void)`
- ❌ `IsWindowMinimized(void)`
- ❌ `IsWindowMaximized(void)`
- ✅🧪 `IsWindowFocused` → `z.core.isWindowFocused` — _imgui_demo_
- ✅ `IsWindowResized` → `z.core.isWindowResized`
- ❌ `IsWindowState(unsigned int flag)`
- ❌ `SetWindowState(unsigned int flags)`
- ❌ `ClearWindowState(unsigned int flags)`
- ✅🧪 `ToggleFullscreen` → `z.core.toggleFullscreen` — _window_demo_
- ❌ `ToggleBorderlessWindowed(void)`
- ❌ `MaximizeWindow(void)`
- ❌ `MinimizeWindow(void)`
- ❌ `RestoreWindow(void)`
- ✅💧 `SetWindowIcon` → `z.core.setWindowIcon`
- ✅💧 `SetWindowIcons` → `z.core.setWindowIcons`
- ✅🧪 `SetWindowTitle` → `z.core.setWindowTitle` — _window_demo_
- ❌ `SetWindowPosition(int x, int y)`
- ❌ `SetWindowMonitor(int monitor)`
- ❌ `SetWindowMinSize(int width, int height)`
- ❌ `SetWindowMaxSize(int width, int height)`
- ✅ `SetWindowSize` → `z.core.setWindowSize`
- ✅ `SetWindowOpacity` → `z.core.setWindowOpacity`
- ✅ `SetWindowFocused` → `z.core.setWindowFocused`
- ❌ `GetWindowHandle(void)`
- ✅🧪 `GetScreenWidth` → `z.core.getScreenWidth` — _png_demo_
- ✅🧪 `GetScreenHeight` → `z.core.getScreenHeight` — _png_demo_
- ✅ `GetRenderWidth` → `z.core.getRenderWidth`
- ✅ `GetRenderHeight` → `z.core.getRenderHeight`
- ❌ `GetMonitorCount(void)`
- ❌ `GetCurrentMonitor(void)`
- ❌ `GetMonitorPosition(int monitor)`
- ❌ `GetMonitorWidth(int monitor)`
- ❌ `GetMonitorHeight(int monitor)`
- ❌ `GetMonitorPhysicalWidth(int monitor)`
- ❌ `GetMonitorPhysicalHeight(int monitor)`
- ❌ `GetMonitorRefreshRate(int monitor)`
- ❌ `GetWindowPosition(void)`
- ✅🧪 `GetWindowScaleDPI` → `z.core.getWindowScaleDPI` — _window_demo_
- ❌ `GetMonitorName(int monitor)`
- ✅🧪 `SetClipboardText` → `z.core.setClipboardText` — _window_demo_
- ✅🧪 `GetClipboardText` → `z.core.getClipboardTextAsync` — _window_demo_
- ❌ `GetClipboardImage(void)`
- ❌ `EnableEventWaiting(void)`
- ❌ `DisableEventWaiting(void)`

#### Cursor-related functions  (6/6)

- ✅ `ShowCursor` → `z.input.showCursor`
- ✅ `HideCursor` → `z.input.hideCursor`
- ✅🧪 `IsCursorHidden` → `z.input.isCursorHidden` — _first_person_camera_
- ✅🧪 `EnableCursor` → `z.input.enableCursor` — _first_person_camera_
- ✅🧪 `DisableCursor` → `z.input.disableCursor` — _first_person_camera_
- ✅ `IsCursorOnScreen` → `z.input.isCursorOnScreen`

#### Drawing-related functions  (13/17)

- ✅🧪 `ClearBackground` → `z.Frame.clearBackground` — _camera2d_
- ❌ `BeginDrawing(void)`
- ❌ `EndDrawing(void)`
- ✅🧪 `BeginMode2D` → `z.camera.beginMode2D` — _camera2d_
- ✅🧪 `EndMode2D` → `z.camera.endMode2D` — _camera2d_
- ✅🧪 `BeginMode3D` → `z.camera.beginMode3D` — _billboards, cube3d, dynamic_mesh_
- ✅🧪 `EndMode3D` → `z.camera.endMode3D` — _billboards, cube3d, dynamic_mesh_
- ✅🧪 `BeginTextureMode` → `z.textures.beginTextureMode` — _rtt, texture_readback_
- ✅🧪 `EndTextureMode` → `z.textures.endTextureMode` — _rtt, texture_readback_
- ✅🧪 `BeginShaderMode` → `z.shaders.beginShaderMode` — _shader_uniforms_
- ✅🧪 `EndShaderMode` → `z.shaders.endShaderMode` — _shader_uniforms_
- ✅ `BeginBlendMode` → `z.shaders.beginBlendMode`
- ✅ `EndBlendMode` → `z.shaders.endBlendMode`
- ✅🧪 `BeginScissorMode` → `z.shaders.beginScissorMode` — _gallery_
- ✅🧪 `EndScissorMode` → `z.shaders.endScissorMode` — _gallery_
- ❌ `BeginVrStereoMode(VrStereoConfig config)`
- ❌ `EndVrStereoMode(void)`

#### VR stereo config functions  (0/2)

- ❌ `LoadVrStereoConfig(VrDeviceInfo device)`
- ❌ `UnloadVrStereoConfig(VrStereoConfig config)`

#### Shader management functions  (9/10)

- ❌ `LoadShader(const char *vsFileName, const char *fsFileName)`
- ✅🧪💧❗ `LoadShaderFromMemory` → `z.shaders.loadShaderFromMemory` — _instancing, shader_uniforms_
- ✅ `IsShaderValid` → `z.shaders.isShaderValid`
- ✅🧪 `GetShaderLocation` → `z.shaders.getShaderLocation` — _shader_uniforms_
- ✅ `GetShaderLocationAttrib` → `z.shaders.getShaderLocationAttrib`
- ✅🧪 `SetShaderValue` → `z.shaders.setShaderValue` — _shader_uniforms_
- ✅ `SetShaderValueV` → `z.shaders.setShaderValueV`
- ✅ `SetShaderValueMatrix` → `z.shaders.setShaderValueMatrix`
- ✅ `SetShaderValueTexture` → `z.shaders.setShaderValueTexture`
- ✅💧 `UnloadShader` → `z.shaders.unloadShader`

#### Screen-space-related functions  (8/8)

- ✅ `GetScreenToWorldRay` → `z.camera.getScreenToWorldRay`
- ✅ `GetScreenToWorldRayEx` → `z.camera.getScreenToWorldRayEx`
- ✅ `GetWorldToScreen` → `z.camera.getWorldToScreen`
- ✅ `GetWorldToScreenEx` → `z.camera.getWorldToScreenEx`
- ✅🧪 `GetWorldToScreen2D` → `z.camera.getWorldToScreen2D` — _camera2d_
- ✅🧪 `GetScreenToWorld2D` → `z.camera.getScreenToWorld2D` — _camera2d_
- ✅ `GetCameraMatrix` → `z.camera.getCameraMatrix`
- ✅ `GetCameraMatrix2D` → `z.camera.getCameraMatrix2D`

#### Timing-related functions  (4/4)

- ✅ `SetTargetFPS` → `z.core.setTargetFPS`
- ✅ `GetFrameTime` → `z.core.getFrameTime`
- ✅ `GetTime` → `z.core.getTime`
- ✅ `GetFPS` → `z.core.getFPS`

#### Custom frame control functions  (0/3)

- ❌ `SwapScreenBuffer(void)`
- ❌ `PollInputEvents(void)`
- ❌ `WaitTime(double seconds)`

#### Random values generation functions  (9/13)

- ✅ `SetRandomSeed` → `z.core.setRandomSeed`
- ✅🧪 `GetRandomValue` → `z.core.getRandomValue` — _particles_
- ✅💧❗ `LoadRandomSequence` → `z.core.loadRandomSequence`
- ✅💧 `UnloadRandomSequence` → `z.core.unloadRandomSequence`
- ✅🧪 `TakeScreenshot` → `z.core.takeScreenshot` — _window_demo_
- ❌ `SetConfigFlags(unsigned int flags)`
- ✅🧪 `OpenURL` → `z.core.openURL` — _window_demo_
- ✅ `SetTraceLogLevel` → `z.core.setTraceLogLevel`
- ✅🧪 `TraceLog` → `z.core.traceLog` — _keys_
- ✅ `SetTraceLogCallback` → `z.core.setTraceLogCallback`
- ❌ `MemAlloc(unsigned int size)`
- ❌ `MemRealloc(void *ptr, unsigned int size)`
- ❌ `MemFree(void *ptr)`

#### File system management functions  (6/57)

- ✅🧪 `LoadFileData` → `z.Loader.loadFileData` — _load_image_demo_
- ✅🧪 `UnloadFileData` → `z.Loader.unloadFileData` — _load_image_demo_
- ❌ `SaveFileData(const char *fileName, const void *data, int dataSize)`
- ❌ `ExportDataAsCode(const unsigned char *data, int dataSize, const char *fileNam...)`
- ❌ `LoadFileText(const char *fileName)`
- ❌ `UnloadFileText(char *text)`
- ❌ `SaveFileText(const char *fileName, const char *text)`
- ❌ `SetLoadFileDataCallback(LoadFileDataCallback callback)`
- ❌ `SetSaveFileDataCallback(SaveFileDataCallback callback)`
- ❌ `SetLoadFileTextCallback(LoadFileTextCallback callback)`
- ❌ `SetSaveFileTextCallback(SaveFileTextCallback callback)`
- ❌ `FileRename(const char *fileName, const char *fileRename)`
- ❌ `FileRemove(const char *fileName)`
- ❌ `FileCopy(const char *srcPath, const char *dstPath)`
- ❌ `FileMove(const char *srcPath, const char *dstPath)`
- ❌ `FileTextReplace(const char *fileName, const char *search, const char *replac...)`
- ❌ `FileTextFindIndex(const char *fileName, const char *search)`
- ❌ `FileExists(const char *fileName)`
- ❌ `DirectoryExists(const char *dirPath)`
- ❌ `IsFileExtension(const char *fileName, const char *ext)`
- ❌ `GetFileLength(const char *fileName)`
- ❌ `GetFileModTime(const char *fileName)`
- ❌ `GetFileExtension(const char *fileName)`
- ❌ `GetFileName(const char *filePath)`
- ❌ `GetFileNameWithoutExt(const char *filePath)`
- ❌ `GetDirectoryPath(const char *filePath)`
- ❌ `GetPrevDirectoryPath(const char *dirPath)`
- ❌ `GetWorkingDirectory(void)`
- ❌ `GetApplicationDirectory(void)`
- ❌ `MakeDirectory(const char *dirPath)`
- ❌ `ChangeDirectory(const char *dirPath)`
- ❌ `IsPathFile(const char *path)`
- ✅ `IsFileNameValid` → `z.core.isFileNameValid`
- ❌ `LoadDirectoryFiles(const char *dirPath)`
- ❌ `LoadDirectoryFilesEx(const char *basePath, const char *filter, bool scanSubdirs)`
- ❌ `UnloadDirectoryFiles(FilePathList files)`
- ✅ `IsFileDropped` → `z.core.isFileDropped`
- ✅💧❗ `LoadDroppedFiles` → `z.core.loadDroppedFiles`
- ✅💧 `UnloadDroppedFiles` → `z.core.unloadDroppedFiles`
- ❌ `GetDirectoryFileCount(const char *dirPath)`
- ❌ `GetDirectoryFileCountEx(const char *basePath, const char *filter, bool scanSubdirs)`
- ❌ `CompressData(const unsigned char *data, int dataSize, int *compDataSize)`
- ❌ `DecompressData(const unsigned char *compData, int compDataSize, int *dataSi...)`
- ❌ `EncodeDataBase64(const unsigned char *data, int dataSize, int *outputSize)`
- ❌ `DecodeDataBase64(const char *text, int *outputSize)`
- ❌ `ComputeCRC32(const unsigned char *data, int dataSize)`
- ❌ `ComputeMD5(const unsigned char *data, int dataSize)`
- ❌ `ComputeSHA1(const unsigned char *data, int dataSize)`
- ❌ `ComputeSHA256(const unsigned char *data, int dataSize)`
- ❌ `LoadAutomationEventList(const char *fileName)`
- ❌ `UnloadAutomationEventList(AutomationEventList list)`
- ❌ `ExportAutomationEventList(AutomationEventList list, const char *fileName)`
- ❌ `SetAutomationEventList(AutomationEventList *list)`
- ❌ `SetAutomationEventBaseFrame(int frame)`
- ❌ `StartAutomationEventRecording(void)`
- ❌ `StopAutomationEventRecording(void)`
- ❌ `PlayAutomationEvent(AutomationEvent event)`

#### Input-related functions  (35/39)

- ✅🧪 `IsKeyPressed` → `z.input.isKeyPressed` — _audio_basic, composer_drum, first_person_camera_
- ✅ `IsKeyPressedRepeat` → `z.input.isKeyPressedRepeat`
- ✅🧪 `IsKeyDown` → `z.input.isKeyDown` — _keys_
- ✅ `IsKeyReleased` → `z.input.isKeyReleased`
- ✅ `IsKeyUp` → `z.input.isKeyUp`
- ✅ `GetKeyPressed` → `z.input.getKeyPressed`
- ✅ `GetCharPressed` → `z.input.getCharPressed`
- ✅ `GetKeyName` → `z.input.getKeyName`
- ✅ `SetExitKey` → `z.input.setExitKey`
- ✅ `IsGamepadAvailable` → `z.input.isGamepadAvailable`
- ✅ `GetGamepadName` → `z.input.getGamepadName`
- ✅ `IsGamepadButtonPressed` → `z.input.isGamepadButtonPressed`
- ✅ `IsGamepadButtonDown` → `z.input.isGamepadButtonDown`
- ✅ `IsGamepadButtonReleased` → `z.input.isGamepadButtonReleased`
- ✅ `IsGamepadButtonUp` → `z.input.isGamepadButtonUp`
- ✅ `GetGamepadButtonPressed` → `z.input.getGamepadButtonPressed`
- ✅ `GetGamepadAxisCount` → `z.input.getGamepadAxisCount`
- ✅ `GetGamepadAxisMovement` → `z.input.getGamepadAxisMovement`
- ❌ `SetGamepadMappings(const char *mappings)`
- ✅ `SetGamepadVibration` → `z.input.setGamepadVibration`
- ✅🧪 `IsMouseButtonPressed` → `z.input.isMouseButtonPressed` — _audio_basic, audio_stream_synth, camera2d_
- ✅🧪 `IsMouseButtonDown` → `z.input.isMouseButtonDown` — _camera2d, life_
- ✅ `IsMouseButtonReleased` → `z.input.isMouseButtonReleased`
- ✅ `IsMouseButtonUp` → `z.input.isMouseButtonUp`
- ✅🧪 `GetMouseX` → `z.input.getMouseX` — _life_
- ✅🧪 `GetMouseY` → `z.input.getMouseY` — _life_
- ✅🧪 `GetMousePosition` → `z.input.getMousePosition` — _audio_basic, audio_stream_synth, camera2d_
- ✅🧪 `GetMouseDelta` → `z.input.getMouseDelta` — _camera2d_
- ❌ `SetMousePosition(int x, int y)`
- ❌ `SetMouseOffset(int offsetX, int offsetY)`
- ❌ `SetMouseScale(float scaleX, float scaleY)`
- ✅🧪 `GetMouseWheelMove` → `z.input.getMouseWheelMove` — _camera2d_
- ✅ `GetMouseWheelMoveV` → `z.input.getMouseWheelMoveV`
- ✅ `SetMouseCursor` → `z.input.setMouseCursor`
- ✅ `GetTouchX` → `z.input.getTouchX`
- ✅ `GetTouchY` → `z.input.getTouchY`
- ✅🧪 `GetTouchPosition` → `z.input.getTouchPosition` — _gestures_demo, gestures_testbed, touch_paint_
- ✅🧪 `GetTouchPointId` → `z.input.getTouchPointId` — _gestures_testbed, touch_paint_
- ✅🧪 `GetTouchPointCount` → `z.input.getTouchPointCount` — _gestures_demo, gestures_testbed, touch_paint_

### `rcamera`

#### Camera System  (2/2)

- ✅🧪 `UpdateCamera` → `z.camera.updateCamera` — _first_person_camera_
- ✅ `UpdateCameraPro` → `z.camera.updateCameraPro`

### `shapes`

#### Set texture and rectangle to be used on shapes drawing  (3/3)

- ✅ `SetShapesTexture` → `z.shapes.setShapesTexture`
- ✅ `GetShapesTexture` → `z.shapes.getShapesTexture`
- ✅ `GetShapesTextureRectangle` → `z.shapes.getShapesTextureRectangle`

#### Basic shapes drawing functions  (41/41)

- ✅ `DrawPixel` → `z.shapes.drawPixel`
- ✅ `DrawPixelV` → `z.shapes.drawPixelV`
- ✅🧪 `DrawLine` → `z.shapes.drawLine` — _audio_stream_synth, gallery_
- ✅🧪 `DrawLineV` → `z.shapes.drawLineV` — _keys_
- ✅🧪 `DrawLineEx` → `z.shapes.drawLineEx` — _camera2d_
- ✅ `DrawLineStrip` → `z.shapes.drawLineStrip`
- ✅ `DrawLineBezier` → `z.shapes.drawLineBezier`
- ✅ `DrawLineDashed` → `z.shapes.drawLineDashed`
- ✅🧪 `DrawCircle` → `z.shapes.drawCircle` — _audio_stream_synth, camera2d, gallery_
- ✅🧪 `DrawCircleV` → `z.shapes.drawCircleV` — _particles_
- ✅ `DrawCircleGradient` → `z.shapes.drawCircleGradient`
- ✅🧪 `DrawCircleSector` → `z.shapes.drawCircleSector` — _keys_
- ✅ `DrawCircleSectorLines` → `z.shapes.drawCircleSectorLines`
- ✅ `DrawCircleLines` → `z.shapes.drawCircleLines`
- ✅ `DrawCircleLinesV` → `z.shapes.drawCircleLinesV`
- ✅ `DrawEllipse` → `z.shapes.drawEllipse`
- ✅ `DrawEllipseV` → `z.shapes.drawEllipseV`
- ✅ `DrawEllipseLines` → `z.shapes.drawEllipseLines`
- ✅ `DrawEllipseLinesV` → `z.shapes.drawEllipseLinesV`
- ✅ `DrawRing` → `z.shapes.drawRing`
- ✅ `DrawRingLines` → `z.shapes.drawRingLines`
- ✅🧪 `DrawRectangle` → `z.shapes.drawRectangle` — _audio_basic, billboards, camera2d_
- ✅ `DrawRectangleV` → `z.shapes.drawRectangleV`
- ✅🧪 `DrawRectangleRec` → `z.shapes.drawRectangleRec` — _camera2d, gallery, image_editor_
- ✅🧪 `DrawRectanglePro` → `z.shapes.drawRectanglePro` — _camera2d_
- ✅ `DrawRectangleGradientV` → `z.shapes.drawRectangleGradientV`
- ✅ `DrawRectangleGradientH` → `z.shapes.drawRectangleGradientH`
- ✅ `DrawRectangleGradientEx` → `z.shapes.drawRectangleGradientEx`
- ✅🧪 `DrawRectangleLines` → `z.shapes.drawRectangleLines` — _audio_basic, composer_drum, load_image_demo_
- ✅ `DrawRectangleLinesEx` → `z.shapes.drawRectangleLinesEx`
- ✅ `DrawRectangleRounded` → `z.shapes.drawRectangleRounded`
- ✅ `DrawRectangleRoundedLines` → `z.shapes.drawRectangleRoundedLines`
- ✅ `DrawRectangleRoundedLinesEx` → `z.shapes.drawRectangleRoundedLinesEx`
- ✅🧪 `DrawTriangle` → `z.shapes.drawTriangle` — _gallery_
- ✅🧪 `DrawTriangleGradient` → `z.shapes.drawTriangleGradient` — _triangle_gradient_
- ✅🧪 `DrawTriangleLines` → `z.shapes.drawTriangleLines` — _gallery_
- ✅ `DrawTriangleFan` → `z.shapes.drawTriangleFan`
- ✅ `DrawTriangleStrip` → `z.shapes.drawTriangleStrip`
- ✅ `DrawPoly` → `z.shapes.drawPoly`
- ✅ `DrawPolyLines` → `z.shapes.drawPolyLines`
- ✅ `DrawPolyLinesEx` → `z.shapes.drawPolyLinesEx`

#### Splines drawing functions  (10/10)

- ✅ `DrawSplineLinear` → `z.shapes.drawSplineLinear`
- ✅ `DrawSplineBasis` → `z.shapes.drawSplineBasis`
- ✅ `DrawSplineCatmullRom` → `z.shapes.drawSplineCatmullRom`
- ✅ `DrawSplineBezierQuadratic` → `z.shapes.drawSplineBezierQuadratic`
- ✅ `DrawSplineBezierCubic` → `z.shapes.drawSplineBezierCubic`
- ✅ `DrawSplineSegmentLinear` → `z.shapes.drawSplineSegmentLinear`
- ✅ `DrawSplineSegmentBasis` → `z.shapes.drawSplineSegmentBasis`
- ✅ `DrawSplineSegmentCatmullRom` → `z.shapes.drawSplineSegmentCatmullRom`
- ✅ `DrawSplineSegmentBezierQuadratic` → `z.shapes.drawSplineSegmentBezierQuadratic`
- ✅ `DrawSplineSegmentBezierCubic` → `z.shapes.drawSplineSegmentBezierCubic`

#### Spline segment point evaluation functions  (5/5)

- ✅ `GetSplinePointLinear` → `z.shapes.getSplinePointLinear`
- ✅ `GetSplinePointBasis` → `z.shapes.getSplinePointBasis`
- ✅ `GetSplinePointCatmullRom` → `z.shapes.getSplinePointCatmullRom`
- ✅ `GetSplinePointBezierQuadratic` → `z.shapes.getSplinePointBezierQuad`
- ✅ `GetSplinePointBezierCubic` → `z.shapes.getSplinePointBezierCubic`

#### Basic shapes collision detection functions  (11/11)

- ✅ `CheckCollisionRecs` → `z.shapes.checkCollisionRecs`
- ✅ `CheckCollisionCircles` → `z.shapes.checkCollisionCircles`
- ✅ `CheckCollisionCircleRec` → `z.shapes.checkCollisionCircleRec`
- ✅ `CheckCollisionCircleLine` → `z.shapes.checkCollisionCircleLine`
- ✅ `CheckCollisionPointRec` → `z.shapes.checkCollisionPointRec`
- ✅ `CheckCollisionPointCircle` → `z.shapes.checkCollisionPointCircle`
- ✅ `CheckCollisionPointTriangle` → `z.shapes.checkCollisionPointTriangle`
- ✅ `CheckCollisionPointLine` → `z.shapes.checkCollisionPointLine`
- ✅ `CheckCollisionPointPoly` → `z.shapes.checkCollisionPointPoly`
- ✅ `CheckCollisionLines` → `z.shapes.checkCollisionLines`
- ✅ `GetCollisionRec` → `z.shapes.getCollisionRec`

### `textures`

#### Image loading functions  (6/12)

- ❌ `LoadImage(const char *fileName)`
- ❌ `LoadImageRaw(const char *fileName, int width, int height, int format, int...)`
- ❌ `LoadImageAnim(const char *fileName, int *frames)`
- ❌ `LoadImageAnimFromMemory(const char *fileType, const unsigned char *fileData, int dat...)`
- ✅🧪💧❗ `LoadImageFromMemory` → `z.zimr.loadImageFromMemory` — _image_editor_
- ✅🧪💧❗ `LoadImageFromTexture` → `z.textures.loadImageFromTexture` — _texture_readback_
- ✅💧❗ `LoadImageFromScreen` → `z.textures.loadImageFromScreen`
- ✅ `IsImageValid` → `z.textures.isImageValid`
- ✅🧪💧 `UnloadImage` → `z.textures.unloadImage` — _billboards, first_person_camera, image_editor_
- ❌ `ExportImage(Image image, const char *fileName)`
- ✅💧❗ `ExportImageToMemory` → `z.textures.exportImageToMemory`
- ❌ `ExportImageAsCode(Image image, const char *fileName)`

#### Image generation functions  (9/9)

- ✅🧪💧❗ `GenImageColor` → `z.textures.genImageColor` — _billboards, recursive_hud, skybox_
- ✅💧❗ `GenImageGradientLinear` → `z.textures.genImageGradientLinear`
- ✅💧❗ `GenImageGradientRadial` → `z.textures.genImageGradientRadial`
- ✅💧❗ `GenImageGradientSquare` → `z.textures.genImageGradientSquare`
- ✅🧪💧❗ `GenImageChecked` → `z.textures.genImageChecked` — _first_person_camera_
- ✅🧪💧❗ `GenImageWhiteNoise` → `z.textures.genImageWhiteNoise` — _procgen_noise_
- ✅🧪💧❗ `GenImagePerlinNoise` → `z.textures.genImagePerlinNoise` — _procgen_noise_
- ✅🧪💧❗ `GenImageCellular` → `z.textures.genImageCellular` — _procgen_noise_
- ✅💧❗ `GenImageText` → `z.textures.genImageText`

#### Image manipulation functions  (33/36)

- ✅🧪💧❗ `ImageCopy` → `z.textures.imageCopy` — _image_editor_
- ✅💧❗ `ImageFromImage` → `z.textures.imageFromImage`
- ✅💧❗ `ImageFromChannel` → `z.textures.imageFromChannel`
- ✅🧪💧❗ `ImageText` → `z.textures.imageText` — _image_text_
- ✅🧪💧❗ `ImageTextEx` → `z.textures.imageTextEx` — _image_text_
- ✅💧❗ `ImageFormat` → `z.textures.imageFormat`
- ✅💧❗ `ImageToPOT` → `z.textures.imageToPOT`
- ✅💧❗ `ImageCrop` → `z.textures.imageCrop`
- ✅💧❗ `ImageAlphaCrop` → `z.textures.imageAlphaCrop`
- ✅ `ImageAlphaClear` → `z.textures.imageAlphaClear`
- ✅ `ImageAlphaMask` → `z.textures.imageAlphaMask`
- ✅ `ImageAlphaPremultiply` → `z.textures.imageAlphaPremultiply`
- ✅🧪💧❗ `ImageBlurGaussian` → `z.textures.imageBlurGaussian` — _image_editor_
- ✅💧❗ `ImageKernelConvolution` → `z.textures.imageKernelConvolution`
- ✅💧❗ `ImageResize` → `z.textures.imageResize`
- ✅💧❗ `ImageResizeNN` → `z.textures.imageResizeNN`
- ✅💧❗ `ImageResizeCanvas` → `z.textures.imageResizeCanvas`
- ✅💧❗ `ImageMipmaps` → `z.textures.imageMipmaps`
- ✅💧❗ `ImageDither` → `z.textures.imageDither`
- ✅ `ImageFlipVertical` → `z.textures.imageFlipVertical`
- ✅ `ImageFlipHorizontal` → `z.textures.imageFlipHorizontal`
- ✅🧪💧❗ `ImageRotate` → `z.textures.imageRotate` — _image_editor_
- ✅🧪💧❗ `ImageRotateCW` → `z.textures.imageRotateCW` — _image_editor_
- ✅💧❗ `ImageRotateCCW` → `z.textures.imageRotateCCW`
- ✅ `ImageColorTint` → `z.textures.imageColorTint`
- ✅🧪 `ImageColorInvert` → `z.textures.imageColorInvert` — _image_editor_
- ✅ `ImageColorGrayscale` → `z.textures.imageColorGrayscale`
- ✅ `ImageColorContrast` → `z.textures.imageColorContrast`
- ✅ `ImageColorBrightness` → `z.textures.imageColorBrightness`
- ✅ `ImageColorReplace` → `z.textures.imageColorReplace`
- ✅💧❗ `LoadImageColors` → `z.models.loadImageColors`
- ❌ `LoadImagePalette(Image image, int maxPaletteSize, int *colorCount)`
- ❌ `UnloadImageColors(Color *colors)`
- ❌ `UnloadImagePalette(Color *colors)`
- ✅ `GetImageAlphaBorder` → `z.textures.getImageAlphaBorder`
- ✅ `GetImageColor` → `z.textures.getImageColor`

#### Image drawing functions  (23/23)

- ✅ `ImageClearBackground` → `z.textures.imageClearBackground`
- ✅🧪 `ImageDrawPixel` → `z.textures.imageDrawPixel` — _recursive_hud, skybox_
- ✅ `ImageDrawPixelV` → `z.textures.imageDrawPixelV`
- ✅ `ImageDrawLine` → `z.textures.imageDrawLine`
- ✅ `ImageDrawLineV` → `z.textures.imageDrawLineV`
- ✅ `ImageDrawLineEx` → `z.textures.imageDrawLineEx`
- ✅🧪 `ImageDrawCircle` → `z.textures.imageDrawCircle` — _skybox_
- ✅ `ImageDrawCircleV` → `z.textures.imageDrawCircleV`
- ✅ `ImageDrawCircleLines` → `z.textures.imageDrawCircleLines`
- ✅ `ImageDrawCircleLinesV` → `z.textures.imageDrawCircleLinesV`
- ✅ `ImageDrawRectangle` → `z.textures.imageDrawRectangle`
- ✅ `ImageDrawRectangleV` → `z.textures.imageDrawRectangleV`
- ✅ `ImageDrawRectangleRec` → `z.textures.imageDrawRectangleRec`
- ✅ `ImageDrawRectangleLines` → `z.textures.imageDrawRectangleLines`
- ✅ `ImageDrawRectangleLinesEx` → `z.textures.imageDrawRectangleLines`
- ✅ `ImageDrawTriangle` → `z.textures.imageDrawTriangle`
- ✅🧪 `ImageDrawTriangleGradient` → `z.textures.imageDrawTriangleEx` — _triangle_gradient_
- ✅ `ImageDrawTriangleLines` → `z.textures.imageDrawTriangleLines`
- ✅ `ImageDrawTriangleFan` → `z.textures.imageDrawTriangleFan`
- ✅ `ImageDrawTriangleStrip` → `z.textures.imageDrawTriangleStrip`
- ✅ `ImageDraw` → `z.textures.imageDraw`
- ✅🧪 `ImageDrawText` → `z.text.imageDrawText` — _billboards, text_on_texture_
- ✅ `ImageDrawTextEx` → `z.text.imageDrawTextEx`

#### Texture loading functions  (9/10)

- ❌ `LoadTexture(const char *fileName)`
- ✅🧪❗ `LoadTextureFromImage` → `z.textures.loadTextureFromImage` — _billboards, image_editor, image_text_
- ✅🧪💧❗ `LoadTextureCubemap` → `z.textures.loadTextureCubemap` — _skybox_
- ✅🧪❗ `LoadRenderTexture` → `z.textures.loadRenderTexture` — _recursive_hud, rtt, shader_
- ✅ `IsTextureValid` → `z.textures.isTextureValid`
- ✅🧪 `UnloadTexture` → `z.textures.unloadTexture` — _texture_readback_
- ✅ `IsRenderTextureValid` → `z.textures.isRenderTextureValid`
- ✅ `UnloadRenderTexture` → `z.textures.unloadRenderTexture`
- ✅🧪 `UpdateTexture` → `z.textures.updateTexture` — _image_editor, procgen_noise_
- ✅ `UpdateTextureRec` → `z.textures.updateTextureRec`

#### Texture configuration functions  (3/3)

- ✅ `GenTextureMipmaps` → `z.textures.genTextureMipmaps`
- ✅ `SetTextureFilter` → `z.textures.setTextureFilter`
- ✅ `SetTextureWrap` → `z.textures.setTextureWrap`

#### Texture drawing functions  (6/6)

- ✅🧪 `DrawTexture` → `z.textures.drawTexture` — _image_text, load_image_demo, texture_readback_
- ✅ `DrawTextureV` → `z.textures.drawTextureV`
- ✅ `DrawTextureEx` → `z.textures.drawTextureEx`
- ✅ `DrawTextureRec` → `z.textures.drawTextureRec`
- ✅🧪 `DrawTexturePro` → `z.textures.drawTexturePro` — _billboards, png_demo_
- ✅ `DrawTextureNPatch` → `z.textures.drawTextureNPatch`

#### Color/pixel related functions  (17/17)

- ✅ `ColorIsEqual` → `z.textures.colorIsEqual`
- ✅🧪 `Fade` → `z.textures.fade` — _gestures_demo, gestures_testbed, skinned_mesh_
- ✅ `ColorToInt` → `z.textures.colorToInt`
- ✅ `ColorNormalize` → `z.textures.colorNormalize`
- ✅ `ColorFromNormalized` → `z.textures.colorFromNormalized`
- ✅ `ColorToHSV` → `z.textures.colorToHSV`
- ✅ `ColorFromHSV` → `z.textures.colorFromHSV`
- ✅ `ColorTint` → `z.textures.colorTint`
- ✅ `ColorBrightness` → `z.textures.colorBrightness`
- ✅ `ColorContrast` → `z.textures.colorContrast`
- ✅ `ColorAlpha` → `z.textures.colorAlpha`
- ✅ `ColorAlphaBlend` → `z.textures.colorAlphaBlend`
- ✅🧪 `ColorLerp` → `z.textures.colorLerp` — _keys_
- ✅ `GetColor` → `z.textures.getColor`
- ✅ `GetPixelColor` → `z.textures.getPixelColor`
- ✅ `SetPixelColor` → `z.textures.setPixelColor`
- ✅ `GetPixelDataSize` → `z.textures.getPixelDataSize`

### `text`

#### Font loading/unloading functions  (6/11)

- ✅🧪 `GetFontDefault` → `z.text.getFontDefault` — _image_text, keys_
- ❌ `LoadFont(const char *fileName)`
- ❌ `LoadFontEx(const char *fileName, int fontSize, const int *codepoints, i...)`
- ❌ `LoadFontFromImage(Image image, Color key, int firstChar)`
- ✅🧪💧❗ `LoadFontFromMemory` → `z.text.loadFontFromTtfData` — _imgui_demo, text_layout_
- ✅ `IsFontValid` → `z.text.isFontValid`
- ❌ `LoadFontData(const unsigned char *fileData, int dataSize, int fontSize, c...)`
- ✅💧 `GenImageFontAtlas` → `z.text.genImageFontAtlas`
- ✅💧 `UnloadFontData` → `z.text.unloadFontData`
- ✅💧 `UnloadFont` → `z.text.unloadFont`
- ❌ `ExportFontAsCode(Font font, const char *fileName)`

#### Text drawing functions  (6/6)

- ✅ `DrawFPS` → `z.text.drawFPS`
- ✅🧪 `DrawText` → `z.text.draw` — _audio_basic, audio_stream_synth, basic_
- ✅🧪 `DrawTextEx` → `z.text.drawEx` — _text_layout_
- ✅ `DrawTextPro` → `z.text.drawPro`
- ✅🧪 `DrawTextCodepoint` → `z.text.drawTextCodepoint` — _text_layout_
- ✅ `DrawTextCodepoints` → `z.text.drawTextCodepoints`

#### Text font info functions  (7/7)

- ✅ `SetTextLineSpacing` → `z.text.setTextLineSpacing`
- ✅🧪 `MeasureText` → `z.text.measure` — _gallery, text_layout_
- ✅🧪 `MeasureTextEx` → `z.text.measureEx` — _text_layout_
- ✅ `MeasureTextCodepoints` → `z.text.measureTextCodepoints`
- ✅ `GetGlyphIndex` → `z.text.getGlyphIndex`
- ✅ `GetGlyphInfo` → `z.text.getGlyphInfo`
- ✅ `GetGlyphAtlasRec` → `z.text.getGlyphAtlasRec`

#### Text codepoints management functions  (8/9)

- ✅💧❗ `LoadUTF8` → `z.text.loadUTF8`
- ✅ `UnloadUTF8` → `z.std.gpa.free(slice)`
- ✅💧❗ `LoadCodepoints` → `z.text.loadCodepoints`
- ✅ `UnloadCodepoints` → `z.std.gpa.free(slice)`
- ✅ `GetCodepointCount` → `z.text.countCodepoints`
- ✅ `GetCodepoint` → `z.text.nextCodepoint`
- ✅ `GetCodepointNext` → `z.text.nextCodepoint`
- ✅ `GetCodepointPrevious` → `z.text.prevCodepoint`
- ❌ `CodepointToUTF8(int codepoint, int *utf8Size)`

#### Text strings management functions  (8/26)

- ❌ `LoadTextLines(const char *text, int *count)`
- ✅ `UnloadTextLines` → `z.std.gpa.free(slice_of_slices)`
- ✅ `TextCopy` → `z.std.@memcpy / std.mem.copyForwards`
- ✅ `TextIsEqual` → `z.std.std.mem.eql(u8, a, b)`
- ✅ `TextLength` → `z.std.s.len / std.mem.span(s).len`
- ❌ `TextFormat(const char *text, ...)`
- ❌ `TextSubtext(const char *text, int position, int length)`
- ❌ `TextRemoveSpaces(const char *text)`
- ❌ `GetTextBetween(const char *text, const char *begin, const char *end)`
- ❌ `TextReplace(const char *text, const char *search, const char *replacemen...)`
- ❌ `TextReplaceAlloc(const char *text, const char *search, const char *replacemen...)`
- ❌ `TextReplaceBetween(const char *text, const char *begin, const char *end, const ...)`
- ❌ `TextReplaceBetweenAlloc(const char *text, const char *begin, const char *end, const ...)`
- ❌ `TextInsert(const char *text, const char *insert, int position)`
- ❌ `TextInsertAlloc(const char *text, const char *insert, int position)`
- ❌ `TextJoin(char **textList, int count, const char *delimiter)`
- ❌ `TextSplit(const char *text, char delimiter, int *count)`
- ✅ `TextAppend` → `z.std.std.fmt.bufPrint`
- ✅ `TextFindIndex` → `z.std.std.mem.indexOf(u8, s, needle)`
- ❌ `TextToUpper(const char *text)`
- ❌ `TextToLower(const char *text)`
- ❌ `TextToPascal(const char *text)`
- ❌ `TextToSnake(const char *text)`
- ❌ `TextToCamel(const char *text)`
- ✅ `TextToInteger` → `z.std.std.fmt.parseInt(c_int, s, 10)`
- ✅ `TextToFloat` → `z.std.std.fmt.parseFloat(f32, s)`

### `models`

#### Basic geometric 3D shapes drawing functions  (21/21)

- ✅ `DrawLine3D` → `z.models.drawLine3D`
- ✅ `DrawPoint3D` → `z.models.drawPoint3D`
- ✅ `DrawCircle3D` → `z.models.drawCircle3D`
- ✅ `DrawTriangle3D` → `z.models.drawTriangle3D`
- ✅ `DrawTriangleStrip3D` → `z.models.drawTriangleStrip3D`
- ✅🧪 `DrawCube` → `z.models.drawCube` — _instancing, text_on_texture_
- ✅🧪 `DrawCubeV` → `z.models.drawCubeV` — _billboards, cube3d, first_person_camera_
- ✅🧪 `DrawCubeWires` → `z.models.drawCubeWires` — _skybox, text_on_texture_
- ✅🧪 `DrawCubeWiresV` → `z.models.drawCubeWiresV` — _cube3d, models3d_
- ✅ `DrawSphere` → `z.models.drawSphere`
- ✅🧪 `DrawSphereEx` → `z.models.drawSphereEx` — _cube3d, first_person_camera, models3d_
- ✅ `DrawSphereWires` → `z.models.drawSphereWires`
- ✅🧪 `DrawCylinder` → `z.models.drawCylinder` — _models3d_
- ✅🧪 `DrawCylinderEx` → `z.models.drawCylinderEx` — _models3d_
- ✅ `DrawCylinderWires` → `z.models.drawCylinderWires`
- ✅ `DrawCylinderWiresEx` → `z.models.drawCylinderWiresEx`
- ✅🧪 `DrawCapsule` → `z.models.drawCapsule` — _models3d_
- ✅ `DrawCapsuleWires` → `z.models.drawCapsuleWires`
- ✅🧪 `DrawPlane` → `z.models.drawPlane` — _text_on_texture_
- ✅ `DrawRay` → `z.models.drawRay`
- ✅🧪 `DrawGrid` → `z.models.drawGrid` — _billboards, cube3d, first_person_camera_

#### Model management functions  (5/5)

- ✅🧪💧❗ `LoadModel` → `z.models.loadModelFromMemory` — _gltf_simple, gltf_textured, skinned_mesh_
- ✅🧪💧❗ `LoadModelFromMesh` → `z.models.loadModelFromMesh` — _dynamic_mesh, first_person_camera, wireframe_
- ✅ `IsModelValid` → `z.models.isModelValid`
- ✅💧 `UnloadModel` → `z.models.unloadModel`
- ✅ `GetModelBoundingBox` → `z.models.getModelBoundingBox`

#### Model drawing functions  (8/8)

- ✅🧪 `DrawModel` → `z.models.drawModel` — _dynamic_mesh, first_person_camera, gltf_simple_
- ✅ `DrawModelEx` → `z.models.drawModelEx`
- ✅🧪 `DrawModelWires` → `z.models.drawModelWires` — _wireframe_
- ✅ `DrawModelWiresEx` → `z.models.drawModelWiresEx`
- ✅🧪 `DrawBoundingBox` → `z.models.drawBoundingBox` — _models3d_
- ✅🧪 `DrawBillboard` → `z.models.drawBillboard` — _billboards_
- ✅🧪 `DrawBillboardRec` → `z.models.drawBillboardRec` — _billboards_
- ✅🧪 `DrawBillboardPro` → `z.models.drawBillboardPro` — _billboards_

#### Mesh management functions  (7/9)

- ✅🧪💧❗ `UploadMesh` → `z.models.uploadMesh` — _dynamic_mesh, first_person_camera, instancing_
- ✅🧪 `UpdateMeshBuffer` → `z.models.updateMeshBuffer` — _dynamic_mesh_
- ✅💧 `UnloadMesh` → `z.models.unloadMesh`
- ✅ `DrawMesh` → `z.models.drawMesh`
- ✅🧪💧❗ `DrawMeshInstanced` → `z.models.drawMeshInstanced` — _instancing_
- ✅ `GetMeshBoundingBox` → `z.models.getMeshBoundingBox`
- ✅💧❗ `GenMeshTangents` → `z.models.genMeshTangents`
- ❌ `ExportMesh(Mesh mesh, const char *fileName)`
- ❌ `ExportMeshAsCode(Mesh mesh, const char *fileName)`

#### Mesh generation functions  (10/11)

- ✅💧❗ `GenMeshPoly` → `z.models.genMeshPoly`
- ✅💧❗ `GenMeshPlane` → `z.models.genMeshPlane`
- ✅🧪💧❗ `GenMeshCube` → `z.models.genMeshCube` — _instancing, wireframe_
- ✅🧪💧❗ `GenMeshSphere` → `z.models.genMeshSphere` — _wireframe_
- ✅💧❗ `GenMeshHemiSphere` → `z.models.genMeshHemiSphere`
- ✅💧❗ `GenMeshCylinder` → `z.models.genMeshCylinder`
- ✅💧❗ `GenMeshCone` → `z.models.genMeshCone`
- ✅💧❗ `GenMeshTorus` → `z.models.genMeshTorus`
- ✅💧❗ `GenMeshKnot` → `z.models.genMeshKnot`
- ✅🧪💧❗ `GenMeshHeightmap` → `z.models.genMeshHeightmap` — _first_person_camera_
- ❌ `GenMeshCubicmap(Image cubicmap, Vector3 cubeSize)`

#### Material loading/unloading functions  (5/6)

- ❌ `LoadMaterials(const char *fileName, int *materialCount)`
- ✅🧪💧❗ `LoadMaterialDefault` → `z.models.loadMaterialDefault` — _instancing_
- ✅ `IsMaterialValid` → `z.models.isMaterialValid`
- ✅💧 `UnloadMaterial` → `z.models.unloadMaterial`
- ✅ `SetMaterialTexture` → `z.models.setMaterialTexture`
- ✅ `SetModelMeshMaterial` → `z.models.setModelMeshMaterial`

#### Model animations loading/unloading functions  (5/5)

- ✅🧪💧❗ `LoadModelAnimations` → `z.models.loadModelAnimations` — _skinned_mesh_
- ✅🧪💧❗ `UpdateModelAnimation` → `z.models.updateModelAnimation` — _skinned_mesh_
- ✅🧪💧❗ `UpdateModelAnimationEx` → `z.models.updateModelAnimationEx` — _skinned_mesh_
- ✅💧 `UnloadModelAnimations` → `z.models.unloadModelAnimations`
- ✅ `IsModelAnimationValid` → `z.models.isModelAnimationValid`

#### Collision detection functions  (8/8)

- ✅ `CheckCollisionSpheres` → `z.models.checkCollisionSpheres`
- ✅ `CheckCollisionBoxes` → `z.models.checkCollisionBoxes`
- ✅ `CheckCollisionBoxSphere` → `z.models.checkCollisionBoxSphere`
- ✅ `GetRayCollisionSphere` → `z.models.getRayCollisionSphere`
- ✅ `GetRayCollisionBox` → `z.models.getRayCollisionBox`
- ✅ `GetRayCollisionMesh` → `z.models.getRayCollisionMesh`
- ✅ `GetRayCollisionTriangle` → `z.models.getRayCollisionTriangle`
- ✅ `GetRayCollisionQuad` → `z.models.getRayCollisionQuad`

### `audio`

#### Audio device management functions  (5/5)

- ✅🧪 `InitAudioDevice` → `z.audio_device.init` — _audio_basic, audio_stream_synth, basic_
- ✅🧪 `CloseAudioDevice` → `z.audio_device.close` — _camera2d, imgui_demo, recursive_hud_
- ✅🧪 `IsAudioDeviceReady` → `z.audio_device.isReady` — _audio_basic, composer_drum, music_streaming_
- ✅ `SetMasterVolume` → `z.audio_device.setMasterVolume`
- ✅ `GetMasterVolume` → `z.audio_device.getMasterVolume`

#### Wave/Sound loading/unloading functions  (9/13)

- ❌ `LoadWave(const char *fileName)`
- ✅🧪💧 `LoadWaveFromMemory` → `z.waves.loadFromMemory` — _music_streaming_
- ✅🧪 `IsWaveValid` → `z.waves.isValid` — _audio_stream_synth_
- ❌ `LoadSound(const char *fileName)`
- ✅🧪💧 `LoadSoundFromWave` → `z.sounds.loadFromWave` — _audio_basic, composer_drum_
- ✅ `LoadSoundAlias` → `z.sounds.loadAlias`
- ✅🧪 `IsSoundValid` → `z.sounds.isValid` — _audio_stream_synth_
- ❌ `UpdateSound(Sound sound, const void *data, int frameCount)`
- ✅🧪 `UnloadWave` → `z.waves.unload` — _audio_basic, composer_drum, image_editor_
- ✅🧪 `UnloadSound` → `z.sounds.unload` — _audio_basic, composer_drum, image_editor_
- ✅🧪 `UnloadSoundAlias` → `z.sounds.unload` — _audio_basic, composer_drum, image_editor_
- ✅💧 `ExportWave` → `z.waves.exportToMemory`
- ❌ `ExportWaveAsCode(Wave wave, const char *fileName)`

#### Wave/Sound management functions  (13/13)

- ✅🧪 `PlaySound` → `z.sounds.play` — _audio_basic, audio_stream_synth, composer_drum_
- ✅🧪 `StopSound` → `z.sounds.stop` — _composer_drum, music_streaming_
- ✅🧪 `PauseSound` → `z.sounds.pause` — _audio_stream_synth, life, music_streaming_
- ✅ `ResumeSound` → `z.sounds.resumeSound`
- ✅🧪 `IsSoundPlaying` → `z.sounds.isPlaying` — _audio_stream_synth, music_streaming_
- ✅🧪 `SetSoundVolume` → `z.sounds.setVolume` — _audio_basic, audio_stream_synth, music_streaming_
- ✅🧪 `SetSoundPitch` → `z.sounds.setPitch` — _audio_basic_
- ✅🧪 `SetSoundPan` → `z.sounds.setPan` — _audio_basic_
- ✅🧪💧 `WaveCopy` → `z.waves.copy` — _image_editor, window_demo_
- ✅💧 `WaveCrop` → `z.waves.crop`
- ✅🧪💧 `WaveFormat` → `z.waves.format` — _keys, png_demo_
- ✅💧 `LoadWaveSamples` → `z.waves.loadSamples`
- ✅💧 `UnloadWaveSamples` → `z.waves.unloadSamples`

#### Music management functions  (15/16)

- ❌ `LoadMusicStream(const char *fileName)`
- ✅🧪💧 `LoadMusicStreamFromMemory` → `z.music.loadFromMemory` — _music_streaming_
- ✅🧪 `IsMusicValid` → `z.music.isValid` — _audio_stream_synth_
- ✅🧪 `UnloadMusicStream` → `z.music.unload` — _audio_basic, composer_drum, image_editor_
- ✅🧪 `PlayMusicStream` → `z.music.play` — _audio_basic, audio_stream_synth, composer_drum_
- ✅🧪 `IsMusicStreamPlaying` → `z.music.isPlaying` — _audio_stream_synth, music_streaming_
- ✅🧪 `UpdateMusicStream` → `z.music.update` — _audio_basic, audio_stream_synth, basic_
- ✅🧪 `StopMusicStream` → `z.music.stop` — _composer_drum, music_streaming_
- ✅🧪 `PauseMusicStream` → `z.music.pause` — _audio_stream_synth, life, music_streaming_
- ✅🧪 `ResumeMusicStream` → `z.music.resumeMusic` — _music_streaming_
- ✅🧪 `SeekMusicStream` → `z.music.seek` — _music_streaming_
- ✅🧪 `SetMusicVolume` → `z.music.setVolume` — _audio_basic, audio_stream_synth, music_streaming_
- ✅🧪 `SetMusicPitch` → `z.music.setPitch` — _audio_basic_
- ✅🧪 `SetMusicPan` → `z.music.setPan` — _audio_basic_
- ✅🧪 `GetMusicTimeLength` → `z.music.getTimeLength` — _music_streaming_
- ✅🧪 `GetMusicTimePlayed` → `z.music.getTimePlayed` — _music_streaming_

#### AudioStream management functions  (13/19)

- ✅🧪 `LoadAudioStream` → `z.streams.load` — _audio_basic, audio_stream_synth, gallery_
- ✅🧪 `IsAudioStreamValid` → `z.streams.isValid` — _audio_stream_synth_
- ✅🧪 `UnloadAudioStream` → `z.streams.unload` — _audio_basic, composer_drum, image_editor_
- ✅🧪 `UpdateAudioStream` → `z.streams.update` — _audio_basic, audio_stream_synth, basic_
- ✅🧪 `IsAudioStreamProcessed` → `z.streams.isProcessed` — _audio_stream_synth_
- ✅🧪 `PlayAudioStream` → `z.streams.play` — _audio_basic, audio_stream_synth, composer_drum_
- ✅🧪 `PauseAudioStream` → `z.streams.pause` — _audio_stream_synth, life, music_streaming_
- ✅🧪 `ResumeAudioStream` → `z.streams.resumeStream` — _audio_stream_synth_
- ✅🧪 `IsAudioStreamPlaying` → `z.streams.isPlaying` — _audio_stream_synth, music_streaming_
- ✅🧪 `StopAudioStream` → `z.streams.stop` — _composer_drum, music_streaming_
- ✅🧪 `SetAudioStreamVolume` → `z.streams.setVolume` — _audio_basic, audio_stream_synth, music_streaming_
- ✅🧪 `SetAudioStreamPitch` → `z.streams.setPitch` — _audio_basic_
- ✅🧪 `SetAudioStreamPan` → `z.streams.setPan` — _audio_basic_
- ❌ `SetAudioStreamBufferSizeDefault(int size)`
- ❌ `SetAudioStreamCallback(AudioStream stream, AudioCallback callback)`
- ❌ `AttachAudioStreamProcessor(AudioStream stream, AudioCallback processor)`
- ❌ `DetachAudioStreamProcessor(AudioStream stream, AudioCallback processor)`
- ❌ `AttachAudioMixedProcessor(AudioCallback processor)`
- ❌ `DetachAudioMixedProcessor(AudioCallback processor)`

### `rgestures`

#### Gestures and Touch Handling  (8/8)

- ✅ `SetGesturesEnabled` → `z.gestures.setGesturesEnabled`
- ✅ `IsGestureDetected` → `z.gestures.isGestureDetected`
- ✅🧪 `GetGestureDetected` → `z.gestures.getGestureDetected` — _gestures_demo, gestures_testbed_
- ✅🧪 `GetGestureHoldDuration` → `z.gestures.getGestureHoldDuration` — _gestures_demo, gestures_testbed_
- ✅🧪 `GetGestureDragVector` → `z.gestures.getGestureDragVector` — _gestures_demo, gestures_testbed_
- ✅ `GetGestureDragAngle` → `z.gestures.getGestureDragAngle`
- ✅🧪 `GetGesturePinchVector` → `z.gestures.getGesturePinchVector` — _gestures_demo, gestures_testbed_
- ✅🧪 `GetGesturePinchAngle` → `z.gestures.getGesturePinchAngle` — _gestures_demo, gestures_testbed_

### `raymath`

#### uncategorized  (146/146)

- ✅🧪 `Clamp` → `z.raymath.clamp` — _imgui_demo, keys, shader_uniforms_
- ✅🧪 `Lerp` → `z.raymath.lerp` — _basic_
- ✅ `Normalize` → `z.raymath.normalize`
- ✅ `Remap` → `z.raymath.remap`
- ✅🧪 `Wrap` → `z.raymath.wrap` — _imgui_demo, text_layout_
- ✅ `FloatEquals` → `z.raymath.floatEquals`
- ✅ `Vector2Zero` → `z.raymath.vector2Zero`
- ✅ `Vector2One` → `z.raymath.vector2One`
- ✅ `Vector2Add` → `z.raymath.vector2Add`
- ✅ `Vector2AddValue` → `z.raymath.vector2AddValue`
- ✅ `Vector2Subtract` → `z.raymath.vector2Subtract`
- ✅ `Vector2SubtractValue` → `z.raymath.vector2SubtractValue`
- ✅ `Vector2Length` → `z.raymath.vector2Length`
- ✅ `Vector2LengthSqr` → `z.raymath.vector2LengthSqr`
- ✅ `Vector2DotProduct` → `z.raymath.vector2DotProduct`
- ✅ `Vector2CrossProduct` → `z.raymath.vector2CrossProduct`
- ✅ `Vector2Distance` → `z.raymath.vector2Distance`
- ✅ `Vector2DistanceSqr` → `z.raymath.vector2DistanceSqr`
- ✅ `Vector2Angle` → `z.raymath.vector2Angle`
- ✅ `Vector2LineAngle` → `z.raymath.vector2LineAngle`
- ✅ `Vector2Scale` → `z.raymath.vector2Scale`
- ✅ `Vector2Multiply` → `z.raymath.vector2Multiply`
- ✅ `Vector2Negate` → `z.raymath.vector2Negate`
- ✅ `Vector2Divide` → `z.raymath.vector2Divide`
- ✅ `Vector2Normalize` → `z.raymath.vector2Normalize`
- ✅ `Vector2Transform` → `z.raymath.vector2Transform`
- ✅ `Vector2Lerp` → `z.raymath.vector2Lerp`
- ✅ `Vector2Reflect` → `z.raymath.vector2Reflect`
- ✅ `Vector2Min` → `z.raymath.vector2Min`
- ✅ `Vector2Max` → `z.raymath.vector2Max`
- ✅ `Vector2Rotate` → `z.raymath.vector2Rotate`
- ✅ `Vector2MoveTowards` → `z.raymath.vector2MoveTowards`
- ✅ `Vector2Invert` → `z.raymath.vector2Invert`
- ✅ `Vector2Clamp` → `z.raymath.vector2Clamp`
- ✅ `Vector2ClampValue` → `z.raymath.vector2ClampValue`
- ✅ `Vector2Equals` → `z.raymath.vector2Equals`
- ✅ `Vector2Refract` → `z.raymath.vector2Refract`
- ✅ `Vector3Zero` → `z.raymath.vector3Zero`
- ✅ `Vector3One` → `z.raymath.vector3One`
- ✅ `Vector3Add` → `z.raymath.vector3Add`
- ✅ `Vector3AddValue` → `z.raymath.vector3AddValue`
- ✅ `Vector3Subtract` → `z.raymath.vector3Subtract`
- ✅ `Vector3SubtractValue` → `z.raymath.vector3SubtractValue`
- ✅ `Vector3Scale` → `z.raymath.vector3Scale`
- ✅ `Vector3Multiply` → `z.raymath.vector3Multiply`
- ✅ `Vector3CrossProduct` → `z.raymath.vector3CrossProduct`
- ✅ `Vector3Perpendicular` → `z.raymath.vector3Perpendicular`
- ✅ `Vector3Length` → `z.raymath.vector3Length`
- ✅ `Vector3LengthSqr` → `z.raymath.vector3LengthSqr`
- ✅ `Vector3DotProduct` → `z.raymath.vector3DotProduct`
- ✅ `Vector3Distance` → `z.raymath.vector3Distance`
- ✅ `Vector3DistanceSqr` → `z.raymath.vector3DistanceSqr`
- ✅ `Vector3Angle` → `z.raymath.vector3Angle`
- ✅ `Vector3Negate` → `z.raymath.vector3Negate`
- ✅ `Vector3Divide` → `z.raymath.vector3Divide`
- ✅ `Vector3Normalize` → `z.raymath.vector3Normalize`
- ✅ `Vector3Project` → `z.raymath.vector3Project`
- ✅ `Vector3Reject` → `z.raymath.vector3Reject`
- ✅ `Vector3OrthoNormalize` → `z.raymath.vector3OrthoNormalize`
- ✅ `Vector3Transform` → `z.raymath.vector3Transform`
- ✅ `Vector3RotateByQuaternion` → `z.raymath.vector3RotateByQuaternion`
- ✅ `Vector3RotateByAxisAngle` → `z.raymath.vector3RotateByAxisAngle`
- ✅ `Vector3MoveTowards` → `z.raymath.vector3MoveTowards`
- ✅ `Vector3Lerp` → `z.raymath.vector3Lerp`
- ✅ `Vector3CubicHermite` → `z.raymath.vector3CubicHermite`
- ✅ `Vector3Reflect` → `z.raymath.vector3Reflect`
- ✅ `Vector3Min` → `z.raymath.vector3Min`
- ✅ `Vector3Max` → `z.raymath.vector3Max`
- ✅ `Vector3Barycenter` → `z.raymath.vector3Barycenter`
- ✅ `Vector3Unproject` → `z.raymath.vector3Unproject`
- ✅ `Vector3ToFloatV` → `z.raymath.vector3ToFloatV`
- ✅ `Vector3Invert` → `z.raymath.vector3Invert`
- ✅ `Vector3Clamp` → `z.raymath.vector3Clamp`
- ✅ `Vector3ClampValue` → `z.raymath.vector3ClampValue`
- ✅ `Vector3Equals` → `z.raymath.vector3Equals`
- ✅ `Vector3Refract` → `z.raymath.vector3Refract`
- ✅ `Vector4Zero` → `z.raymath.vector4Zero`
- ✅ `Vector4One` → `z.raymath.vector4One`
- ✅ `Vector4Add` → `z.raymath.vector4Add`
- ✅ `Vector4AddValue` → `z.raymath.vector4AddValue`
- ✅ `Vector4Subtract` → `z.raymath.vector4Subtract`
- ✅ `Vector4SubtractValue` → `z.raymath.vector4SubtractValue`
- ✅ `Vector4Length` → `z.raymath.vector4Length`
- ✅ `Vector4LengthSqr` → `z.raymath.vector4LengthSqr`
- ✅ `Vector4DotProduct` → `z.raymath.vector4DotProduct`
- ✅ `Vector4Distance` → `z.raymath.vector4Distance`
- ✅ `Vector4DistanceSqr` → `z.raymath.vector4DistanceSqr`
- ✅ `Vector4Scale` → `z.raymath.vector4Scale`
- ✅ `Vector4Multiply` → `z.raymath.vector4Multiply`
- ✅ `Vector4Negate` → `z.raymath.vector4Negate`
- ✅ `Vector4Divide` → `z.raymath.vector4Divide`
- ✅ `Vector4Normalize` → `z.raymath.vector4Normalize`
- ✅ `Vector4Min` → `z.raymath.vector4Min`
- ✅ `Vector4Max` → `z.raymath.vector4Max`
- ✅ `Vector4Lerp` → `z.raymath.vector4Lerp`
- ✅ `Vector4MoveTowards` → `z.raymath.vector4MoveTowards`
- ✅ `Vector4Invert` → `z.raymath.vector4Invert`
- ✅ `Vector4Equals` → `z.raymath.vector4Equals`
- ✅ `MatrixDeterminant` → `z.raymath.matrixDeterminant`
- ✅ `MatrixTrace` → `z.raymath.matrixTrace`
- ✅ `MatrixTranspose` → `z.raymath.matrixTranspose`
- ✅ `MatrixInvert` → `z.raymath.matrixInvert`
- ✅ `MatrixIdentity` → `z.raymath.matrixIdentity`
- ✅ `MatrixAdd` → `z.raymath.matrixAdd`
- ✅ `MatrixSubtract` → `z.raymath.matrixSubtract`
- ✅🧪 `MatrixMultiply` → `z.raymath.matrixMultiply` — _instancing_
- ✅ `MatrixMultiplyValue` → `z.raymath.matrixMultiplyValue`
- ✅ `MatrixTranslate` → `z.raymath.matrixTranslate`
- ✅ `MatrixRotate` → `z.raymath.matrixRotate`
- ✅ `MatrixRotateX` → `z.raymath.matrixRotateX`
- ✅🧪 `MatrixRotateY` → `z.raymath.matrixRotateY` — _gltf_simple, gltf_textured_
- ✅ `MatrixRotateZ` → `z.raymath.matrixRotateZ`
- ✅ `MatrixRotateXYZ` → `z.raymath.matrixRotateXYZ`
- ✅ `MatrixRotateZYX` → `z.raymath.matrixRotateZYX`
- ✅ `MatrixScale` → `z.raymath.matrixScale`
- ✅ `MatrixFrustum` → `z.raymath.matrixFrustum`
- ✅ `MatrixPerspective` → `z.raymath.matrixPerspective`
- ✅ `MatrixOrtho` → `z.raymath.matrixOrtho`
- ✅ `MatrixLookAt` → `z.raymath.matrixLookAt`
- ✅ `MatrixToFloatV` → `z.raymath.matrixToFloatV`
- ✅ `QuaternionAdd` → `z.raymath.quaternionAdd`
- ✅ `QuaternionAddValue` → `z.raymath.quaternionAddValue`
- ✅ `QuaternionSubtract` → `z.raymath.quaternionSubtract`
- ✅ `QuaternionSubtractValue` → `z.raymath.quaternionSubtractValue`
- ✅ `QuaternionIdentity` → `z.raymath.quaternionIdentity`
- ✅ `QuaternionLength` → `z.raymath.quaternionLength`
- ✅ `QuaternionNormalize` → `z.raymath.quaternionNormalize`
- ✅ `QuaternionInvert` → `z.raymath.quaternionInvert`
- ✅ `QuaternionMultiply` → `z.raymath.quaternionMultiply`
- ✅ `QuaternionScale` → `z.raymath.quaternionScale`
- ✅ `QuaternionDivide` → `z.raymath.quaternionDivide`
- ✅ `QuaternionLerp` → `z.raymath.quaternionLerp`
- ✅ `QuaternionNlerp` → `z.raymath.quaternionNlerp`
- ✅ `QuaternionSlerp` → `z.raymath.quaternionSlerp`
- ✅ `QuaternionCubicHermiteSpline` → `z.raymath.quaternionCubicHermiteSpline`
- ✅ `QuaternionFromVector3ToVector3` → `z.raymath.quaternionFromVector3ToVector3`
- ✅ `QuaternionFromMatrix` → `z.raymath.quaternionFromMatrix`
- ✅ `QuaternionToMatrix` → `z.raymath.quaternionToMatrix`
- ✅ `QuaternionFromAxisAngle` → `z.raymath.quaternionFromAxisAngle`
- ✅ `QuaternionToAxisAngle` → `z.raymath.quaternionToAxisAngle`
- ✅ `QuaternionFromEuler` → `z.raymath.quaternionFromEuler`
- ✅ `QuaternionToEuler` → `z.raymath.quaternionToEuler`
- ✅ `QuaternionTransform` → `z.raymath.quaternionTransform`
- ✅ `QuaternionEquals` → `z.raymath.quaternionEquals`
- ✅ `MatrixCompose` → `z.raymath.matrixCompose`
- ✅ `MatrixDecompose` → `z.raymath.matrixDecompose`

### `rlgl`

#### Functions Declaration - Matrix operations  (14/14)

- ✅🧪 `rlMatrixMode` → `z.rlgl.rlMatrixMode` — _shader_
- ✅🧪 `rlPushMatrix` → `z.rlgl.rlPushMatrix` — _cube3d, recursive_hud, text_on_texture_
- ✅🧪 `rlPopMatrix` → `z.rlgl.rlPopMatrix` — _cube3d, recursive_hud, text_on_texture_
- ✅🧪 `rlLoadIdentity` → `z.rlgl.rlLoadIdentity` — _shader_
- ✅🧪 `rlTranslatef` → `z.rlgl.rlTranslatef` — _cube3d, text_on_texture_
- ✅🧪 `rlRotatef` → `z.rlgl.rlRotatef` — _cube3d, recursive_hud, text_on_texture_
- ✅ `rlScalef` → `z.rlgl.rlScalef`
- ✅🧪 `rlMultMatrixf` → `z.rlgl.rlMultMatrixf` — _wireframe_
- ✅ `rlFrustum` → `z.rlgl.rlFrustum`
- ✅🧪 `rlOrtho` → `z.rlgl.rlOrtho` — _shader_
- ✅🧪 `rlViewport` → `z.rlgl.rlViewport` — _rtt, shader_
- ✅ `rlSetClipPlanes` → `z.rlgl.rlSetClipPlanes`
- ✅ `rlGetCullDistanceNear` → `z.rlgl.rlGetCullDistanceNear`
- ✅ `rlGetCullDistanceFar` → `z.rlgl.rlGetCullDistanceFar`

#### Functions Declaration - Vertex level operations  (10/10)

- ✅🧪 `rlBegin` → `z.rlgl.rlBegin` — _basic, image_editor, procgen_noise_
- ✅🧪 `rlEnd` → `z.rlgl.rlEnd` — _basic, image_editor, procgen_noise_
- ✅ `rlVertex2i` → `z.rlgl.rlVertex2i`
- ✅🧪 `rlVertex2f` → `z.rlgl.rlVertex2f` — _basic, image_editor, procgen_noise_
- ✅🧪 `rlVertex3f` → `z.rlgl.rlVertex3f` — _recursive_hud, text_on_texture_
- ✅🧪 `rlTexCoord2f` → `z.rlgl.rlTexCoord2f` — _basic, image_editor, procgen_noise_
- ✅🧪 `rlNormal3f` → `z.rlgl.rlNormal3f` — _recursive_hud, text_on_texture_
- ✅🧪 `rlColor4ub` → `z.rlgl.rlColor4ub` — _basic, image_editor, procgen_noise_
- ✅ `rlColor3f` → `z.rlgl.rlColor3f`
- ✅ `rlColor4f` → `z.rlgl.rlColor4f`

#### Functions Declaration - OpenGL style functions  (109/139)

- ✅ `rlEnableVertexArray` → `z.rlgl.rlEnableVertexArray`
- ✅ `rlDisableVertexArray` → `z.rlgl.rlDisableVertexArray`
- ✅ `rlEnableVertexBuffer` → `z.rlgl.rlEnableVertexBuffer`
- ✅ `rlDisableVertexBuffer` → `z.rlgl.rlDisableVertexBuffer`
- ✅ `rlEnableVertexBufferElement` → `z.rlgl.rlEnableVertexBufferElement`
- ✅ `rlDisableVertexBufferElement` → `z.rlgl.rlDisableVertexBufferElement`
- ✅ `rlEnableVertexAttribute` → `z.rlgl.rlEnableVertexAttribute`
- ✅ `rlDisableVertexAttribute` → `z.rlgl.rlDisableVertexAttribute`
- ❌ `rlEnableStatePointer(int vertexAttribType, void *buffer)`
- ❌ `rlDisableStatePointer(int vertexAttribType)`
- ✅ `rlActiveTextureSlot` → `z.rlgl.rlActiveTextureSlot`
- ✅ `rlEnableTexture` → `z.rlgl.rlEnableTexture`
- ✅ `rlDisableTexture` → `z.rlgl.rlDisableTexture`
- ✅ `rlEnableTextureCubemap` → `z.rlgl.rlEnableTextureCubemap`
- ✅ `rlDisableTextureCubemap` → `z.rlgl.rlDisableTextureCubemap`
- ✅ `rlTextureParameters` → `z.rlgl.rlTextureParameters`
- ✅ `rlCubemapParameters` → `z.rlgl.rlCubemapParameters`
- ✅ `rlEnableShader` → `z.rlgl.rlEnableShader`
- ✅ `rlDisableShader` → `z.rlgl.rlDisableShader`
- ✅🧪 `rlEnableFramebuffer` → `z.rlgl.rlEnableFramebuffer` — _rtt, shader_
- ✅🧪 `rlDisableFramebuffer` → `z.rlgl.rlDisableFramebuffer` — _rtt, shader_
- ✅ `rlGetActiveFramebuffer` → `z.rlgl.rlGetActiveFramebuffer`
- ✅🧪 `rlActiveDrawBuffers` → `z.rlgl.rlActiveDrawBuffers` — _mrt_demo_
- ✅ `rlBlitFramebuffer` → `z.rlgl.rlBlitFramebuffer`
- ✅ `rlBindFramebuffer` → `z.rlgl.rlBindFramebuffer`
- ✅ `rlEnableColorBlend` → `z.rlgl.rlEnableColorBlend`
- ✅ `rlDisableColorBlend` → `z.rlgl.rlDisableColorBlend`
- ✅ `rlEnableDepthTest` → `z.rlgl.rlEnableDepthTest`
- ✅ `rlDisableDepthTest` → `z.rlgl.rlDisableDepthTest`
- ✅ `rlEnableDepthMask` → `z.rlgl.rlEnableDepthMask`
- ✅ `rlDisableDepthMask` → `z.rlgl.rlDisableDepthMask`
- ✅ `rlEnableBackfaceCulling` → `z.rlgl.rlEnableBackfaceCulling`
- ✅ `rlDisableBackfaceCulling` → `z.rlgl.rlDisableBackfaceCulling`
- ✅🧪 `rlColorMask` → `z.rlgl.rlColorMask` — _mrt_demo_
- ✅ `rlSetCullFace` → `z.rlgl.rlSetCullFace`
- ✅ `rlEnableScissorTest` → `z.rlgl.rlEnableScissorTest`
- ✅ `rlDisableScissorTest` → `z.rlgl.rlDisableScissorTest`
- ✅ `rlScissor` → `z.rlgl.rlScissor`
- ✅ `rlEnablePointMode` → `z.rlgl.rlEnablePointMode`
- ✅ `rlDisablePointMode` → `z.rlgl.rlDisablePointMode`
- ✅ `rlSetPointSize` → `z.rlgl.rlSetPointSize`
- ✅ `rlGetPointSize` → `z.rlgl.rlGetPointSize`
- ✅ `rlEnableWireMode` → `z.rlgl.rlEnableWireMode`
- ✅ `rlDisableWireMode` → `z.rlgl.rlDisableWireMode`
- ✅ `rlSetLineWidth` → `z.rlgl.rlSetLineWidth`
- ✅ `rlGetLineWidth` → `z.rlgl.rlGetLineWidth`
- ✅ `rlEnableSmoothLines` → `z.rlgl.rlEnableSmoothLines`
- ✅ `rlDisableSmoothLines` → `z.rlgl.rlDisableSmoothLines`
- ✅ `rlEnableStereoRender` → `z.rlgl.rlEnableStereoRender`
- ✅ `rlDisableStereoRender` → `z.rlgl.rlDisableStereoRender`
- ✅ `rlIsStereoRenderEnabled` → `z.rlgl.rlIsStereoRenderEnabled`
- ✅🧪 `rlClearColor` → `z.rlgl.rlClearColor` — _rtt, shader, texture_readback_
- ✅🧪 `rlClearScreenBuffers` → `z.rlgl.rlClearScreenBuffers` — _rtt, shader, texture_readback_
- ✅ `rlCheckErrors` → `z.rlgl.rlCheckErrors`
- ✅ `rlSetBlendMode` → `z.rlgl.rlSetBlendMode`
- ✅ `rlSetBlendFactors` → `z.rlgl.rlSetBlendFactors`
- ✅ `rlSetBlendFactorsSeparate` → `z.rlgl.rlSetBlendFactorsSeparate`
- ✅ `rlglInit` → `z.rlgl.rlglInit`
- ✅ `rlglClose` → `z.rlgl.rlglClose`
- ❌ `rlLoadExtensions(void *loader)`
- ❌ `rlGetProcAddress(const char *procName)`
- ❌ `rlGetVersion(void)`
- ✅ `rlSetFramebufferWidth` → `z.rlgl.rlSetFramebufferWidth`
- ✅ `rlGetFramebufferWidth` → `z.rlgl.rlGetFramebufferWidth`
- ✅ `rlSetFramebufferHeight` → `z.rlgl.rlSetFramebufferHeight`
- ✅ `rlGetFramebufferHeight` → `z.rlgl.rlGetFramebufferHeight`
- ✅ `rlGetTextureIdDefault` → `z.rlgl.rlGetTextureIdDefault`
- ✅ `rlGetShaderIdDefault` → `z.rlgl.rlGetShaderIdDefault`
- ✅ `rlGetShaderLocsDefault` → `z.rlgl.rlGetShaderLocsDefault`
- ❌ `rlLoadRenderBatch(int numBuffers, int bufferElements)`
- ❌ `rlUnloadRenderBatch(rlRenderBatch batch)`
- ✅ `rlDrawRenderBatch` → `z.rlgl.rlDrawRenderBatch`
- ❌ `rlSetRenderBatchActive(rlRenderBatch *batch)`
- ✅🧪 `rlDrawRenderBatchActive` → `z.rlgl.rlDrawRenderBatchActive` — _rtt, shader_
- ❌ `rlCheckRenderBatchLimit(int vCount)`
- ✅🧪 `rlSetTexture` → `z.rlgl.rlSetTexture` — _basic, image_editor, procgen_noise_
- ✅ `rlLoadVertexArray` → `z.rlgl.rlLoadVertexArray`
- ✅ `rlLoadVertexBuffer` → `z.rlgl.rlLoadVertexBuffer`
- ✅ `rlLoadVertexBufferElement` → `z.rlgl.rlLoadVertexBufferElement`
- ✅ `rlUpdateVertexBuffer` → `z.rlgl.rlUpdateVertexBuffer`
- ✅ `rlUpdateVertexBufferElements` → `z.rlgl.rlUpdateVertexBufferElements`
- ✅ `rlUnloadVertexArray` → `z.rlgl.rlUnloadVertexArray`
- ✅ `rlUnloadVertexBuffer` → `z.rlgl.rlUnloadVertexBuffer`
- ✅ `rlSetVertexAttribute` → `z.rlgl.rlSetVertexAttribute`
- ✅ `rlSetVertexAttributeDivisor` → `z.rlgl.rlSetVertexAttributeDivisor`
- ❌ `rlSetVertexAttributeDefault(int locIndex, const void *value, int attribType, int count)`
- ✅ `rlDrawVertexArray` → `z.rlgl.rlDrawVertexArray`
- ✅ `rlDrawVertexArrayElements` → `z.rlgl.rlDrawVertexArrayElements`
- ✅ `rlDrawVertexArrayInstanced` → `z.rlgl.rlDrawVertexArrayInstanced`
- ✅ `rlDrawVertexArrayElementsInstanced` → `z.rlgl.rlDrawVertexArrayElementsInstanced`
- ✅🧪 `rlLoadTexture` → `z.rlgl.rlLoadTexture` — _basic, load_image_demo, png_demo_
- ✅ `rlLoadTextureDepth` → `z.rlgl.rlLoadTextureDepth`
- ✅🧪 `rlLoadTextureCubemap` → `z.rlgl.rlLoadTextureCubemap` — _skybox_
- ✅ `rlUpdateTexture` → `z.rlgl.rlUpdateTexture`
- ✅ `rlGetGlTextureFormats` → `z.rlgl.rlGetGlTextureFormats`
- ✅ `rlGetPixelFormatName` → `z.rlgl.rlGetPixelFormatName`
- ✅ `rlUnloadTexture` → `z.rlgl.rlUnloadTexture`
- ✅ `rlGenTextureMipmaps` → `z.rlgl.rlGenTextureMipmaps`
- ❌ `rlReadTexturePixels(unsigned int id, int width, int height, int format)`
- ❌ `rlReadScreenPixels(int width, int height)`
- ✅ `rlLoadFramebuffer` → `z.rlgl.rlLoadFramebuffer`
- ✅ `rlFramebufferAttach` → `z.rlgl.rlFramebufferAttach`
- ✅🧪 `rlFramebufferComplete` → `z.rlgl.rlFramebufferComplete` — _rtt_
- ✅ `rlUnloadFramebuffer` → `z.rlgl.rlUnloadFramebuffer`
- ✅ `rlCopyFramebuffer` → `z.rlgl.rlCopyFramebuffer`
- ✅ `rlResizeFramebuffer` → `z.rlgl.rlResizeFramebuffer`
- ✅ `rlLoadShader` → `z.rlgl.rlLoadShader`
- ❌ `rlLoadShaderProgram(const char *vsCode, const char *fsCode)`
- ✅ `rlLoadShaderProgramEx` → `z.rlgl.rlLoadShaderProgramEx`
- ❌ `rlLoadShaderProgramCompute(unsigned int csId)`
- ❌ `rlUnloadShader(unsigned int id)`
- ✅ `rlUnloadShaderProgram` → `z.rlgl.rlUnloadShaderProgram`
- ✅🧪 `rlGetLocationUniform` → `z.rlgl.rlGetLocationUniform` — _shader_
- ✅ `rlGetLocationAttrib` → `z.rlgl.rlGetLocationAttrib`
- ✅🧪 `rlSetUniform` → `z.rlgl.rlSetUniform` — _shader_
- ✅ `rlSetUniformMatrix` → `z.rlgl.rlSetUniformMatrix`
- ✅ `rlSetUniformMatrices` → `z.rlgl.rlSetUniformMatrices`
- ✅ `rlSetUniformSampler` → `z.rlgl.rlSetUniformSampler`
- ✅🧪 `rlSetShader` → `z.rlgl.rlSetShader` — _shader_
- ❌ `rlComputeShaderDispatch(unsigned int groupX, unsigned int groupY, unsigned int group...)`
- ❌ `rlLoadShaderBuffer(unsigned int size, const void *data, int usageHint)`
- ❌ `rlUnloadShaderBuffer(unsigned int ssboId)`
- ❌ `rlUpdateShaderBuffer(unsigned int id, const void *data, unsigned int dataSize, un...)`
- ❌ `rlBindShaderBuffer(unsigned int id, unsigned int index)`
- ❌ `rlReadShaderBuffer(unsigned int id, void *dest, unsigned int count, unsigned in...)`
- ❌ `rlCopyShaderBuffer(unsigned int destId, unsigned int srcId, unsigned int destOf...)`
- ❌ `rlGetShaderBufferSize(unsigned int id)`
- ❌ `rlBindImageTexture(unsigned int id, unsigned int index, int format, bool readon...)`
- ✅ `rlGetMatrixModelview` → `z.rlgl.rlGetMatrixModelview`
- ✅ `rlGetMatrixProjection` → `z.rlgl.rlGetMatrixProjection`
- ✅ `rlGetMatrixTransform` → `z.rlgl.rlGetMatrixTransform`
- ❌ `rlGetMatrixProjectionStereo(int eye)`
- ❌ `rlGetMatrixViewOffsetStereo(int eye)`
- ✅ `rlSetMatrixProjection` → `z.rlgl.rlSetMatrixProjection`
- ✅ `rlSetMatrixModelview` → `z.rlgl.rlSetMatrixModelview`
- ❌ `rlSetMatrixProjectionStereo(Matrix right, Matrix left)`
- ❌ `rlSetMatrixViewOffsetStereo(Matrix right, Matrix left)`
- ❌ `rlLoadDrawCube(void)`
- ❌ `rlLoadDrawQuad(void)`

## Functions that should be ziggified

Functions whose names suggest they should take `Allocator` and/or return `!T`
(load*, decode*, save*, gen*, build*, *FromMemory etc.) but don't yet.  Some of
these are accurate as-is (e.g. legacy C-shim entry points by design); review
each against its module's design before mechanically converting.

_71 candidates_

- `z.png.loadAsync(allocator: Allocator, url: []const u8)` -> `LoadHandle`  _(no-error)_
- `z.png.pollLoad(handle: LoadHandle)` -> `LoadStatus`  _(no-alloc, no-error)_
- `z.png.releaseLoad(handle: LoadHandle)` -> `void`  _(no-alloc, no-error)_
- `z.truetype.load(bytes: []const u8)` -> ``  _(no-alloc, no-error)_
- `z.truetype.loadFontFromTtf(gpa: Allocator, ttf_bytes: []const u8,)` -> ``  _(no-error)_
- `z.code_point.decode(bytes: []const u8, offset: uoffset)` -> `?CodePoint`  _(no-alloc, no-error)_
- `z.code_point.decodeAtIndex(bytes: []const u8, index: uoffset)` -> `?CodePoint`  _(no-alloc, no-error)_
- `z.code_point.decodeAtCursor(bytes: []const u8, cursor: *uoffset)` -> `?CodePoint`  _(no-alloc, no-error)_
- `z.wav.decode(gpa: std_mod.mem.Allocator, reader: *std_mod.Io.Reader, ) (D...)` -> ``  _(no-error)_
- `z.textures.unloadImage(gpa: std.mem.Allocator, image: Image,)` -> `void`  _(no-error)_
- `z.textures.loadTextureFromImage(image: Image)` -> `types.LoadError`  _(no-alloc)_
- `z.textures.unloadTexture(texture: Texture2D_t)` -> `void`  _(no-alloc, no-error)_
- `z.textures.genTextureMipmaps(tex: *Texture2D_t)` -> `void`  _(no-alloc, no-error)_
- `z.textures.loadRenderTexture(width: c_int, height: c_int,)` -> `types.LoadError`  _(no-alloc)_
- `z.textures.unloadRenderTexture(target: RenderTexture2D_t)` -> `void`  _(no-alloc, no-error)_
- `z.text.loadFontDefault()` -> `void`  _(no-alloc, no-error)_
- `z.text.unloadFontDefault()` -> `void`  _(no-alloc, no-error)_
- `z.text.encodeCodepoint(codepoint: u21)` -> `Utf8Bytes`  _(no-alloc, no-error)_
- `z.text.unloadFontData(gpa: std.mem.Allocator, glyphs: []GlyphInfo,)` -> `void`  _(no-error)_
- `z.text.unloadFont(gpa: std.mem.Allocator, font: Font,)` -> `void`  _(no-error)_
- `z.text.genImageFontAtlas(gpa: Allocator, font: *const truetype.Font, font_size: c_int...)` -> ``  _(no-error)_
- `z.text.unloadFontDefaultImpl()` -> `void`  _(no-alloc, no-error)_
- `z.models.unloadMesh(gpa: std.mem.Allocator, mesh: Mesh,)` -> `void`  _(no-error)_
- `z.models.unloadMaterial(gpa: std.mem.Allocator, material: Material,)` -> `void`  _(no-error)_
- `z.models.unloadModel(gpa: std.mem.Allocator, model: Model,)` -> `void`  _(no-error)_
- `z.models.unloadModelAnimations(gpa: std.mem.Allocator, animations: []ModelAnimation,)` -> `void`  _(no-error)_
- `z.models.unloadSkybox()` -> `void`  _(no-alloc, no-error)_
- `z.shaders.unloadShader(gpa: std.mem.Allocator, shader: Shader,)` -> `void`  _(no-error)_
- `z.fwd.rlUnloadVertexArray(vao_id: c_uint)` -> `void`  _(no-alloc, no-error)_
- `z.fwd.rlUnloadVertexBuffer(vbo_id: c_uint)` -> `void`  _(no-alloc, no-error)_
- `z.fwd.rlUnloadTexture(tex_id: c_uint)` -> `void`  _(no-alloc, no-error)_
- `z.fwd.rlLoadTexture(data: ?*const anyopaque, width: c_int, height: c_int, format...)` -> `c_uint`  _(no-alloc, no-error)_
- `z.fwd.rlGenTextureMipmaps(id: c_uint, width: c_int, height: c_int, format: c_int, mipm...)` -> `void`  _(no-alloc, no-error)_
- `z.fwd.rlLoadFramebuffer()` -> `c_uint`  _(no-alloc, no-error)_
- `z.fwd.rlLoadTextureDepth(width: c_int, height: c_int, use_renderbuffer: bool)` -> `c_uint`  _(no-alloc, no-error)_
- `z.fwd.rlUnloadFramebuffer(fb_id: c_uint)` -> `void`  _(no-alloc, no-error)_
- `z.fwd.rlUnloadShaderProgram(prog_id: c_uint)` -> `void`  _(no-alloc, no-error)_
- `z.fwd.rlLoadShaderProgramFromMemory(vs: []const u8, fs: []const u8)` -> `c_uint`  _(no-alloc, no-error)_
- `z.fwd.rlLoadVertexArray()` -> `c_uint`  _(no-alloc, no-error)_
- `z.fwd.rlLoadVertexBuffer(bytes: []const u8, dynamic: bool)` -> `c_uint`  _(no-alloc, no-error)_
- `z.fwd.rlLoadVertexBufferElement(bytes: []const u8, dynamic: bool)` -> `c_uint`  _(no-alloc, no-error)_
- `z.fwd.rlLoadTextureCubemap(face_data: ?*const anyopaque, face_size: c_int, format: c_in...)` -> `c_uint`  _(no-alloc, no-error)_
- `z.core.unloadDroppedFiles(gpa: std.mem.Allocator, files: DroppedFiles)` -> `void`  _(no-error)_
- `z.core.unloadRandomSequence(gpa: std.mem.Allocator, seq: []i32,)` -> `void`  _(no-error)_
- `z.Loader.loadFileData(self: Loader, path: []const u8)` -> `Handle`  _(no-alloc, no-error)_
- `z.Loader.unloadFileData(self: Loader, h: Handle)` -> `void`  _(no-alloc, no-error)_
- `z.Browser.loader(self: *Browser)` -> `Loader`  _(no-alloc, no-error)_
- `z.Mock.loader(self: *Mock)` -> `Loader`  _(no-alloc, no-error)_
- `z.Scoped.loader(self: *const Scoped)` -> `Loader`  _(no-alloc, no-error)_
- `z.music.loadFromMemory(gpa: std.mem.Allocator, file_type: []const u8, bytes: []cons...)` -> ``  _(no-error)_
- `z.music.unload(track: Music)` -> `void`  _(no-alloc, no-error)_
- `z.streams.load(sample_rate: u32, sample_size: u32, channels: u32,)` -> `AudioStream`  _(no-alloc, no-error)_
- `z.streams.unload(stream: AudioStream)` -> `void`  _(no-alloc, no-error)_
- `z.sounds.loadFromWave(gpa: std.mem.Allocator, wave: Wave,)` -> ``  _(no-error)_
- `z.sounds.loadFromMemory(gpa: std.mem.Allocator, file_type: []const u8, bytes: []cons...)` -> ``  _(no-error)_
- `z.sounds.loadAlias(source: Sound)` -> `Sound`  _(no-alloc, no-error)_
- `z.sounds.unload(sound: Sound)` -> `void`  _(no-alloc, no-error)_
- `z.waves.loadFromMemory(gpa: std.mem.Allocator, file_type: []const u8, bytes: []cons...)` -> ``  _(no-error)_
- `z.waves.unload(wave: Wave)` -> `void`  _(no-alloc, no-error)_
- `z.waves.loadSamples(gpa: std.mem.Allocator, wave: Wave,)` -> ``  _(no-error)_
- `z.waves.unloadSamples(gpa: std.mem.Allocator, samples: []f32,)` -> `void`  _(no-error)_
- `z.waves.exportToMemory(gpa: std.mem.Allocator, wave: Wave,)` -> ``  _(no-error)_
- `z.audio.createContext()` -> `ContextId`  _(no-alloc, no-error)_
- `z.audio.loadAudioBuffer(ctx_id: ContextId, sample_rate: c_uint, channels: c_uint, fr...)` -> `BufferId`  _(no-alloc, no-error)_
- `z.audio.unloadAudioBuffer(ctx_id: ContextId, buffer_id: BufferId,)` -> `void`  _(no-alloc, no-error)_
- `z.audio.decodeOggBytes(ctx_id: ContextId, data: []const u8,)` -> `DecodeId`  _(no-alloc, no-error)_
- `z.audio.isDecodeReady(ctx_id: ContextId, decode_id: DecodeId,)` -> `bool`  _(no-alloc, no-error)_
- `z.audio.takeDecodedBuffer(ctx_id: ContextId, decode_id: DecodeId,)` -> `BufferId`  _(no-alloc, no-error)_
- `z.audio.cancelDecode(ctx_id: ContextId, decode_id: DecodeId,)` -> `void`  _(no-alloc, no-error)_
- `z.App.create(cfg: Config)` -> ``  _(no-alloc, no-error)_
- `z.App.setLoader(self: *App, l: ?Loader)` -> `void`  _(no-alloc, no-error)_

## Zig-idiom audit

Specific anti-patterns lurking in the public surface.  These are
more actionable than the heuristic _ziggify_ list above — each entry
here is an opportunity to drop a C-ism without changing semantics.

### C-style many-pointer (`[*c]T`)  (1)

- `z.core.traceLogRaw(level: c_int, msg_ptr: [*c]const u8, msg_len: usize)` -> `void`

## Top raylib functions still to port (in-scope only)

_179 in-scope raylib functions not yet ported._

### `core`  (100 missing)

**Window-related functions** (31)
  - `InitWindow`  ·  `CloseWindow`  ·  `IsWindowReady`
  - `IsWindowHidden`  ·  `IsWindowMinimized`  ·  `IsWindowMaximized`
  - `IsWindowState`  ·  `SetWindowState`  ·  `ClearWindowState`
  - `ToggleBorderlessWindowed`  ·  `MaximizeWindow`  ·  `MinimizeWindow`
  - `RestoreWindow`  ·  `SetWindowPosition`  ·  `SetWindowMonitor`
  - `SetWindowMinSize`  ·  `SetWindowMaxSize`  ·  `GetWindowHandle`
  - `GetMonitorCount`  ·  `GetCurrentMonitor`  ·  `GetMonitorPosition`
  - `GetMonitorWidth`  ·  `GetMonitorHeight`  ·  `GetMonitorPhysicalWidth`
  - `GetMonitorPhysicalHeight`  ·  `GetMonitorRefreshRate`  ·  `GetWindowPosition`
  - `GetMonitorName`  ·  `GetClipboardImage`  ·  `EnableEventWaiting`
  - `DisableEventWaiting`

**Drawing-related functions** (4)
  - `BeginDrawing`  ·  `EndDrawing`  ·  `BeginVrStereoMode`
  - `EndVrStereoMode`

**VR stereo config functions** (2)
  - `LoadVrStereoConfig`  ·  `UnloadVrStereoConfig`

**Shader management functions** (1)
  - `LoadShader`

**Custom frame control functions** (3)
  - `SwapScreenBuffer`  ·  `PollInputEvents`  ·  `WaitTime`

**Random values generation functions** (4)
  - `SetConfigFlags`  ·  `MemAlloc`  ·  `MemRealloc`
  - `MemFree`

**File system management functions** (51)
  - `SaveFileData`  ·  `ExportDataAsCode`  ·  `LoadFileText`
  - `UnloadFileText`  ·  `SaveFileText`  ·  `SetLoadFileDataCallback`
  - `SetSaveFileDataCallback`  ·  `SetLoadFileTextCallback`  ·  `SetSaveFileTextCallback`
  - `FileRename`  ·  `FileRemove`  ·  `FileCopy`
  - `FileMove`  ·  `FileTextReplace`  ·  `FileTextFindIndex`
  - `FileExists`  ·  `DirectoryExists`  ·  `IsFileExtension`
  - `GetFileLength`  ·  `GetFileModTime`  ·  `GetFileExtension`
  - `GetFileName`  ·  `GetFileNameWithoutExt`  ·  `GetDirectoryPath`
  - `GetPrevDirectoryPath`  ·  `GetWorkingDirectory`  ·  `GetApplicationDirectory`
  - `MakeDirectory`  ·  `ChangeDirectory`  ·  `IsPathFile`
  - `LoadDirectoryFiles`  ·  `LoadDirectoryFilesEx`  ·  `UnloadDirectoryFiles`
  - `GetDirectoryFileCount`  ·  `GetDirectoryFileCountEx`  ·  `CompressData`
  - `DecompressData`  ·  `EncodeDataBase64`  ·  `DecodeDataBase64`
  - `ComputeCRC32`  ·  `ComputeMD5`  ·  `ComputeSHA1`
  - `ComputeSHA256`  ·  `LoadAutomationEventList`  ·  `UnloadAutomationEventList`
  - `ExportAutomationEventList`  ·  `SetAutomationEventList`  ·  `SetAutomationEventBaseFrame`
  - `StartAutomationEventRecording`  ·  `StopAutomationEventRecording`  ·  `PlayAutomationEvent`

**Input-related functions** (4)
  - `SetGamepadMappings`  ·  `SetMousePosition`  ·  `SetMouseOffset`
  - `SetMouseScale`

### `textures`  (10 missing)

**Image loading functions** (6)
  - `LoadImage`  ·  `LoadImageRaw`  ·  `LoadImageAnim`
  - `LoadImageAnimFromMemory`  ·  `ExportImage`  ·  `ExportImageAsCode`

**Image manipulation functions** (3)
  - `LoadImagePalette`  ·  `UnloadImageColors`  ·  `UnloadImagePalette`

**Texture loading functions** (1)
  - `LoadTexture`

### `text`  (24 missing)

**Font loading/unloading functions** (5)
  - `LoadFont`  ·  `LoadFontEx`  ·  `LoadFontFromImage`
  - `LoadFontData`  ·  `ExportFontAsCode`

**Text codepoints management functions** (1)
  - `CodepointToUTF8`

**Text strings management functions** (18)
  - `LoadTextLines`  ·  `TextFormat`  ·  `TextSubtext`
  - `TextRemoveSpaces`  ·  `GetTextBetween`  ·  `TextReplace`
  - `TextReplaceAlloc`  ·  `TextReplaceBetween`  ·  `TextReplaceBetweenAlloc`
  - `TextInsert`  ·  `TextInsertAlloc`  ·  `TextJoin`
  - `TextSplit`  ·  `TextToUpper`  ·  `TextToLower`
  - `TextToPascal`  ·  `TextToSnake`  ·  `TextToCamel`

### `models`  (4 missing)

**Mesh management functions** (2)
  - `ExportMesh`  ·  `ExportMeshAsCode`

**Mesh generation functions** (1)
  - `GenMeshCubicmap`

**Material loading/unloading functions** (1)
  - `LoadMaterials`

### `audio`  (11 missing)

**Wave/Sound loading/unloading functions** (4)
  - `LoadWave`  ·  `LoadSound`  ·  `UpdateSound`
  - `ExportWaveAsCode`

**Music management functions** (1)
  - `LoadMusicStream`

**AudioStream management functions** (6)
  - `SetAudioStreamBufferSizeDefault`  ·  `SetAudioStreamCallback`  ·  `AttachAudioStreamProcessor`
  - `DetachAudioStreamProcessor`  ·  `AttachAudioMixedProcessor`  ·  `DetachAudioMixedProcessor`

### `rlgl`  (30 missing)

**Functions Declaration - OpenGL style functions** (30)
  - `rlEnableStatePointer`  ·  `rlDisableStatePointer`  ·  `rlLoadExtensions`
  - `rlGetProcAddress`  ·  `rlGetVersion`  ·  `rlLoadRenderBatch`
  - `rlUnloadRenderBatch`  ·  `rlSetRenderBatchActive`  ·  `rlCheckRenderBatchLimit`
  - `rlSetVertexAttributeDefault`  ·  `rlReadTexturePixels`  ·  `rlReadScreenPixels`
  - `rlLoadShaderProgram`  ·  `rlLoadShaderProgramCompute`  ·  `rlUnloadShader`
  - `rlComputeShaderDispatch`  ·  `rlLoadShaderBuffer`  ·  `rlUnloadShaderBuffer`
  - `rlUpdateShaderBuffer`  ·  `rlBindShaderBuffer`  ·  `rlReadShaderBuffer`
  - `rlCopyShaderBuffer`  ·  `rlGetShaderBufferSize`  ·  `rlBindImageTexture`
  - `rlGetMatrixProjectionStereo`  ·  `rlGetMatrixViewOffsetStereo`  ·  `rlSetMatrixProjectionStereo`
  - `rlSetMatrixViewOffsetStereo`  ·  `rlLoadDrawCube`  ·  `rlLoadDrawQuad`

[html] wrote /home/claude/zimr/src/notes/cheatsheet.html (242,556 bytes)
