#include "utils.h"
#include "raylib.h"
#include "imgui.h"
#include "rlImGui.h"

// we need direct access to GLFW so we can set a window refresh callback
// that fires during window resize (otherwise Windows blocks the main loop)
#define GLFW_INCLUDE_NONE
#include "GLFW/glfw3.h"

#include <vector>
#include <unordered_set>

using namespace std;

using Stone = char;
using BoardIndex = int;

constexpr Stone STONE_NONE = 0;
constexpr Stone STONE_BLACK = 1;
constexpr Stone STONE_WHITE = 2;
constexpr BoardIndex INVALID_INDEX = -1;

int boardSize = 13;

// these are recomputed each frame based on window size
int boardOffsetX = 100;
int boardOffsetY = 100;
int boardPixelSize = 600;
int spacing = boardPixelSize / (boardSize - 1);
int totalCells = boardSize * boardSize;

Stone OtherStoneColor(Stone s)
{
    assert(s != STONE_NONE);
    return (s == STONE_BLACK) ? STONE_WHITE : STONE_BLACK;
}

BoardIndex Index1D(int row, int col)
{
    return row * boardSize + col;
}

int RowFrom1D(int id)
{
    return id / boardSize;
}

int ColFrom1D(int id)
{
    return id % boardSize;
}

bool IsValidRowCol(int row, int col)
{
    return row >= 0 && row < boardSize && col >= 0 && col < boardSize;
}

BoardIndex GetBoardIndexFromScreenPos(int x, int y)
{
    // snap mouse position to nearest intersection
    const int mouseRelativeX = x - boardOffsetX + spacing / 2;
    const int mouseRelativeY = y - boardOffsetY + spacing / 2;

    // negative values would round toward zero and give a wrong row/col
    if (mouseRelativeX < 0 || mouseRelativeY < 0)
    {
        return INVALID_INDEX;
    }

    const int col = mouseRelativeX / spacing;
    const int row = mouseRelativeY / spacing;

    if (!IsValidRowCol(row, col))
    {
        return INVALID_INDEX;
    }

    return Index1D(row, col);
}

Vector2 GetScreenPosFromBoardIndex(BoardIndex id)
{
    const float x = (float)(ColFrom1D(id) * spacing + boardOffsetX);
    const float y = (float)(RowFrom1D(id) * spacing + boardOffsetY);
    return { x, y };
}

// writes up to 4 neighbor 1D indices into result, returns count
int GetNeighbors(BoardIndex id, BoardIndex result[4])
{
    const int row = RowFrom1D(id);
    const int col = ColFrom1D(id);
    int count = 0;

    if (row > 0)             { result[count++] = Index1D(row - 1, col); }
    if (row < boardSize - 1) { result[count++] = Index1D(row + 1, col); }
    if (col > 0)             { result[count++] = Index1D(row, col - 1); }
    if (col < boardSize - 1) { result[count++] = Index1D(row, col + 1); }

    return count;
}


void FindGroupAndLiberties(
    BoardIndex id,
    Stone stoneColor,
    const vector<Stone>& board,
    vector<char>& visited,
    vector<char>& libertyVisited,
    vector<BoardIndex>& resultGroup,
    int& resultLiberties)
{
    visited[id] = true;
    resultGroup.push_back(id);

    BoardIndex neighbors[4];
    const int neighborCount = GetNeighbors(id, neighbors);

    for (int i = 0; i < neighborCount; i++)
    {
        const BoardIndex n = neighbors[i];
        const Stone neighborColor = board[n];

        if (neighborColor == STONE_NONE)
        {
            if (!libertyVisited[n])
            {
                libertyVisited[n] = true;
                resultLiberties++;
            }
        }
        else if (neighborColor == stoneColor)
        {
            if (!visited[n])
            {
                FindGroupAndLiberties(
                    n, stoneColor, board,
                    visited, libertyVisited,
                    resultGroup, resultLiberties);
            }
        }
    }
}

void CaptureStones(
    BoardIndex placedId,
    Stone enemyColor,
    vector<Stone>& board,
    int& resultNumberOfStonesCaptured,
    BoardIndex& resultLastCapturedId)
{
    resultNumberOfStonesCaptured = 0;
    resultLastCapturedId = INVALID_INDEX;

    vector<char> visited(totalCells, false);
    vector<char> libertyVisited(totalCells, false);
    vector<BoardIndex> enemyGroup;

    BoardIndex neighbors[4];
    const int neighborCount = GetNeighbors(placedId, neighbors);

    for (int i = 0; i < neighborCount; i++)
    {
        const BoardIndex n = neighbors[i];
        if (board[n] != enemyColor)
        {
            continue;
        }

        fill(visited.begin(), visited.end(), false);
        fill(libertyVisited.begin(), libertyVisited.end(), false);
        enemyGroup.clear();

        int enemyLiberties = 0;
        FindGroupAndLiberties(
            n, enemyColor, board,
            visited, libertyVisited,
            enemyGroup, enemyLiberties);

        if (enemyLiberties == 0)
        {
            for (const BoardIndex capturedId : enemyGroup)
            {
                board[capturedId] = STONE_NONE;
                resultNumberOfStonesCaptured++;
                resultLastCapturedId = capturedId;
            }
        }
    }
}

// finds the leader of the index
BoardIndex FindGroupRootAndCompressPath(
    BoardIndex index,
    vector<BoardIndex>& groupRoot)
{
    assert(index != INVALID_INDEX);

    const BoardIndex maybeGroupLeader = groupRoot[index];

    if (maybeGroupLeader == INVALID_INDEX)
    {
        return INVALID_INDEX;
    }

    if (maybeGroupLeader == index)
    {
        // my group leader is myself: I am the leader
        return index;
    }

    const BoardIndex leaderOfLeader = groupRoot[maybeGroupLeader];

    if (leaderOfLeader == maybeGroupLeader)
    {
        // the leader of my leader is himself: he is the leader
        return maybeGroupLeader;
    }

    // my leader is not a leader: we need to recurse down the chain of leaders and compress the path

    const BoardIndex recursiveCallResult = FindGroupRootAndCompressPath(
        maybeGroupLeader, 
        groupRoot);

    // ok now we compress the path by pointing directly to the result of the recursion
    groupRoot[index] = recursiveCallResult;

    return recursiveCallResult;
}

void MergeGroups(
    BoardIndex A,
    BoardIndex B,
    vector<BoardIndex>& groupRoot,
    vector<unordered_set<BoardIndex>>& groupLiberties,
    vector<vector<BoardIndex>>& groupStones)
{
    if (A == B)
    {
        return;
    }

    groupRoot[B] = A;

    groupLiberties[A].insert(
        groupLiberties[B].begin(), 
        groupLiberties[B].end());

    groupLiberties[B].clear();

    groupStones[A].insert(
        groupStones[A].end(), 
        groupStones[B].begin(), 
        groupStones[B].end());

    groupStones[B].clear();
}

void KillGroup(
    BoardIndex killedLeader,
    vector<Stone>& board,
    vector<BoardIndex>& groupRoot,
    vector<unordered_set<BoardIndex>>& groupLiberties,
    vector<vector<BoardIndex>>& groupStones,
    int& resultCapturedStoneCount,
    BoardIndex& resultLastCapturedPosition)
{
    // note: does NOT reset resultCapturedStoneCount, it accumulates.
    // caller is responsible for initializing it to 0.

    const Stone killedStoneColor = board[killedLeader];
    const Stone killerColor = OtherStoneColor(killedStoneColor);

    vector<BoardIndex>& killedStones = groupStones[killedLeader];

    for (BoardIndex killedStone : killedStones)
    {
        board[killedStone] = STONE_NONE;
        groupRoot[killedStone] = INVALID_INDEX;

        BoardIndex neighbors[4];
        const int neighborCount = GetNeighbors(killedStone, neighbors);
        for (int i = 0; i < neighborCount; i++)
        {
            const BoardIndex neighbor = neighbors[i];
            const Stone neighborColor = board[neighbor];

            if (neighborColor == killerColor)
            {
                // this neighbor with the color of the killer has a new liberty

                const BoardIndex leaderOfNeigbor = FindGroupRootAndCompressPath(
                    neighbor, groupRoot);

                groupLiberties[leaderOfNeigbor].insert(killedStone);
            }
        }

        resultCapturedStoneCount++;
        resultLastCapturedPosition = killedStone;
    }

    killedStones.clear();
}


struct GameState
{
    // which stone (or none) is at each intersection
    vector<Stone> board;

    // DSU: each stone points to the leader of its group (-1 if empty)
    vector<BoardIndex> groupRoot;

    // for each group leader, the set of adjacent empty positions
    vector<unordered_set<BoardIndex>> groupLiberties;

    // for each group leader, all stones belonging to that group
    vector<vector<BoardIndex>> groupStones;

    // ko rule: the position that can't be played this turn (-1 if none)
    BoardIndex koForbidden = INVALID_INDEX;

    // whose turn it is
    Stone currentPlayer = STONE_BLACK;

    // the last move that was played, for highlighting (-1 if none)
    BoardIndex lastPlaced = INVALID_INDEX;

    // how many stones each player has captured total
    int capturedByBlack = 0;
    int capturedByWhite = 0;

    // STONE_NONE = game in progress, STONE_BLACK/WHITE = that player won
    Stone winner = STONE_NONE;

    // filled by KillGroup each move, read by the main loop to create animations
    vector<BoardIndex> lastCapturedPositions;

    // undo/redo history
    vector<BoardIndex> moveHistory;
    int historyPosition = -1;
};

struct CaptureAnimation
{
    Vector2 startPos;
    Vector2 endPos;
    float startSize;
    float endSize;
    Stone stoneColor;
    double startTime;
    float duration;
};

struct AppOptions
{
    bool showDebug = false;
    bool showDoomedStones = true;
    bool showLiberties = true;
    bool showAtariGroups = true;
};

enum Screen
{
    SCREEN_MAIN_MENU,
    SCREEN_GAME,
};

struct AppState
{
    Screen screen = SCREEN_MAIN_MENU;
    bool pauseMenuOpen = false;
    bool showDebugPanel = false;
    bool quitRequested = false;
    int selectedBoardSize = 13;
    bool atariGoMode = false;
    int atariCaptureGoal = 1;
    Texture2D woodTexture = {};
    Texture2D blackStoneTexture = {};
    Texture2D whiteStoneTexture = {};
    vector<CaptureAnimation> captureAnimations;
    GameState game;
    AppOptions options;
};

// allocates the DSU arrays and resets everything for a new game
void InitGameState(GameState& gs, int newBoardSize)
{
    boardSize = newBoardSize;
    totalCells = boardSize * boardSize;

    gs.board.assign(totalCells, STONE_NONE);
    gs.groupRoot.assign(totalCells, INVALID_INDEX);
    gs.groupLiberties.assign(totalCells, unordered_set<BoardIndex>());
    gs.groupStones.assign(totalCells, vector<BoardIndex>());
    gs.koForbidden = INVALID_INDEX;
    gs.currentPlayer = STONE_BLACK;
    gs.lastPlaced = INVALID_INDEX;
    gs.capturedByBlack = 0;
    gs.capturedByWhite = 0;
    gs.winner = STONE_NONE;
    gs.moveHistory.clear();
    gs.historyPosition = -1;
}

// resets board state but assumes arrays are already the right size
void ResetGameState(GameState& gs)
{
    fill(gs.board.begin(), gs.board.end(), STONE_NONE);
    fill(gs.groupRoot.begin(), gs.groupRoot.end(), INVALID_INDEX);
    for (int i = 0; i < totalCells; i++)
    {
        gs.groupLiberties[i].clear();
        gs.groupStones[i].clear();
    }
    gs.koForbidden = INVALID_INDEX;
    gs.currentPlayer = STONE_BLACK;
    gs.lastPlaced = INVALID_INDEX;
    gs.capturedByBlack = 0;
    gs.capturedByWhite = 0;
    gs.winner = STONE_NONE;
    gs.moveHistory.clear();
    gs.historyPosition = -1;
}

// places a stone and does all DSU bookkeeping (merge, capture, ko).
// assumes the move is valid (call IsMoveSuicide first).
// returns the number of stones captured by this move.
int PlayMove(BoardIndex clickedId, GameState& gs)
{
    const Stone enemyPlayer = OtherStoneColor(gs.currentPlayer);

    int numberOfStonesCaptured = 0;
    BoardIndex lastCapturedPosition = INVALID_INDEX;
    gs.lastCapturedPositions.clear();

    gs.board[clickedId] = gs.currentPlayer;
    gs.groupRoot[clickedId] = clickedId;
    gs.groupStones[clickedId].push_back(clickedId);

    BoardIndex neighbors[4];
    const int neighborCount = GetNeighbors(clickedId, neighbors);

    // update liberties
    for (int i = 0; i < neighborCount; i++)
    {
        const BoardIndex neighbor = neighbors[i];
        if (gs.board[neighbor] == STONE_NONE)
        {
            gs.groupLiberties[clickedId].insert(neighbor);
        }
        else
        {
            const BoardIndex neighborLeader = FindGroupRootAndCompressPath(
                neighbor, gs.groupRoot);
            gs.groupLiberties[neighborLeader].erase(clickedId);
        }
    }

    // merge with friendly neighbors
    for (int i = 0; i < neighborCount; i++)
    {
        const BoardIndex neighbor = neighbors[i];
        if (gs.board[neighbor] == gs.currentPlayer)
        {
            const BoardIndex neighborLeader = FindGroupRootAndCompressPath(
                neighbor, gs.groupRoot);
            MergeGroups(
                clickedId, neighborLeader,
                gs.groupRoot, gs.groupLiberties, gs.groupStones);
        }
    }

    // capture enemy neighbors
    for (int i = 0; i < neighborCount; i++)
    {
        const BoardIndex neighbor = neighbors[i];
        if (gs.board[neighbor] == enemyPlayer)
        {
            const BoardIndex neighborLeader = FindGroupRootAndCompressPath(
                neighbor, gs.groupRoot);
            if (gs.groupLiberties[neighborLeader].size() == 0)
            {
                // record positions before KillGroup clears the stone list
                for (const BoardIndex stoneId : gs.groupStones[neighborLeader])
                {
                    gs.lastCapturedPositions.push_back(stoneId);
                }

                KillGroup(
                    neighborLeader,
                    gs.board, gs.groupRoot, gs.groupLiberties, gs.groupStones,
                    numberOfStonesCaptured, lastCapturedPosition);
            }
        }
    }

    // ko
    if (numberOfStonesCaptured == 1)
    {
        gs.koForbidden = lastCapturedPosition;
    }
    else
    {
        gs.koForbidden = INVALID_INDEX;
    }

    // accumulate captures per player
    if (numberOfStonesCaptured > 0)
    {
        if (gs.currentPlayer == STONE_BLACK)
        {
            gs.capturedByBlack += numberOfStonesCaptured;
        }
        else
        {
            gs.capturedByWhite += numberOfStonesCaptured;
        }
    }

    gs.lastPlaced = clickedId;
    gs.currentPlayer = enemyPlayer;
    return numberOfStonesCaptured;
}

// replays moves from scratch up to the given position.
// we need to save/restore the history because ResetGameState clears it.
void ReplayMoves(int upToPosition, GameState& gs)
{
    vector<BoardIndex> savedHistory = gs.moveHistory;
    ResetGameState(gs);
    gs.moveHistory = savedHistory;

    for (int i = 0; i <= upToPosition; i++)
    {
        PlayMove(gs.moveHistory[i], gs);
    }

    gs.historyPosition = upToPosition;
}

void UndoMove(GameState& gs)
{
    if (gs.historyPosition < 0)
    {
        return;
    }

    gs.historyPosition--;
    if (gs.historyPosition >= 0)
    {
        ReplayMoves(gs.historyPosition, gs);
    }
    else
    {
        vector<BoardIndex> savedHistory = gs.moveHistory;
        ResetGameState(gs);
        gs.moveHistory = savedHistory;
    }
}

void RedoMove(GameState& gs)
{
    if (gs.historyPosition >= (int)gs.moveHistory.size() - 1)
    {
        return;
    }

    gs.historyPosition++;
    ReplayMoves(gs.historyPosition, gs);
}

// draws the wood texture scaled to cover the entire window, maintaining aspect ratio
void DrawBackgroundTexture(const Texture2D& texture)
{
    const float windowW = (float)GetScreenWidth();
    const float windowH = (float)GetScreenHeight();
    const float scaleX = windowW / (float)texture.width;
    const float scaleY = windowH / (float)texture.height;
    const float scale = Max(scaleX, scaleY);

    const float drawW = texture.width * scale;
    const float drawH = texture.height * scale;
    const float offsetX = (windowW - drawW) * 0.5f;
    const float offsetY = (windowH - drawH) * 0.5f;

    const Rectangle source = { 0, 0, (float)texture.width, (float)texture.height };
    const Rectangle dest = { offsetX, offsetY, drawW, drawH };
    DrawTexturePro(texture, source, dest, {0, 0}, 0.0f, WHITE);
}

// layout values for the capture stone columns, recomputed each frame
float captureStoneRadius = 0.0f;
float captureColumnLeftX = 0.0f;
float captureColumnRightX = 0.0f;
float captureColumnTopY = 0.0f;
float captureStoneSpacing = 0.0f;
float captureDrawSize = 0.0f;

// recomputes board layout globals from the current window size.
// the margin accounts for stone overhang + gap + capture column + window edge padding.
void UpdateBoardLayout(int maxCaptures)
{
    const int windowW = GetScreenWidth();
    const int windowH = GetScreenHeight();
    const int minDim = MinInt(windowW, windowH);

    // spacing is derived so that the board + margins + capture columns fit.
    // from grid edge to window edge: stoneRadius + gap + captureColumn + gap
    // all proportional to spacing, so we just need a big enough divisor.
    spacing = MaxInt(minDim / (boardSize + 3), 1);
    boardPixelSize = spacing * (boardSize - 1);
    boardOffsetX = (windowW - boardPixelSize) / 2;
    boardOffsetY = (windowH - boardPixelSize) / 2;

    // capture column layout
    const float stoneRadius = (float)(spacing / 2);
    const float gap = stoneRadius * 0.5f;
    captureStoneRadius = stoneRadius * 0.6f;
    captureDrawSize = captureStoneRadius * 2.2f;
    captureColumnTopY = (float)boardOffsetY;
    captureColumnLeftX = (float)boardOffsetX - stoneRadius - gap - captureStoneRadius;
    captureColumnRightX = (float)(boardOffsetX + boardPixelSize) + stoneRadius + gap + captureStoneRadius;

    // capture stone vertical spacing: both sides use the same spacing,
    // determined by whichever side has more captures.
    // ideal spacing has stones not touching. when a side overflows the board height,
    // we compress until they overlap like a stack of coins.
    // ideal = touching (one diameter apart, center to center)
    const float idealSpacing = captureStoneRadius * 2.0f;
    const float minSpacing = captureStoneRadius * 0.6f;
    const float availableHeight = (float)boardPixelSize;

    if (maxCaptures <= 1)
    {
        captureStoneSpacing = idealSpacing;
    }
    else
    {
        // spacing needed so that maxCaptures stones fit in the board height.
        // the first stone is at the top, each subsequent one is offset by spacing,
        // so total height = (maxCaptures - 1) * spacing
        const float neededSpacing = availableHeight / (float)(maxCaptures - 1);
        captureStoneSpacing = Clamp(neededSpacing, minSpacing, idealSpacing);
    }
}

void DrawStoneTexture(const Texture2D& tex, float centerX, float centerY, float size, Color tint)
{
    const Rectangle src = { 0, 0, (float)tex.width, (float)tex.height };
    const Rectangle dst = { centerX - size * 0.5f, centerY - size * 0.5f, size, size };
    DrawTexturePro(tex, src, dst, {0, 0}, 0.0f, tint);
}

// draws the board grid, stones, and last-move marker.
// does NOT call BeginDrawing/EndDrawing — caller is responsible for that.
// hoveredId: the intersection the mouse is over (INVALID_INDEX if none)
void DrawBoardAndStones(const AppState& app, BoardIndex hoveredId, float hoverElapsed)
{
    const GameState& gs = app.game;
    const AppOptions& opt = app.options;
    // grid lines
    for (int i = 0; i < boardSize; i++)
    {
        const int x = boardOffsetX + i * spacing;
        const int y = boardOffsetY + i * spacing;
        DrawLine(x, boardOffsetY, x, boardOffsetY + boardPixelSize, BLACK);
        DrawLine(boardOffsetX, y, boardOffsetX + boardPixelSize, y, BLACK);
    }

    // star points (hoshi)
    if (boardSize >= 5)
    {
        const int offset = (boardSize <= 9) ? 2 : 3;
        const float dotRadius = (float)MaxInt(spacing / 8, 2);
        const bool hasCenter = (boardSize % 2 == 1);
        const int center = boardSize / 2;

        // corner star points
        const int corners[] = { offset, boardSize - 1 - offset };
        for (int r : corners)
        {
            for (int c : corners)
            {
                DrawCircle(
                    boardOffsetX + c * spacing,
                    boardOffsetY + r * spacing,
                    dotRadius, BLACK);
            }
        }

        if (hasCenter)
        {
            // center point
            DrawCircle(
                boardOffsetX + center * spacing,
                boardOffsetY + center * spacing,
                dotRadius, BLACK);

            // side star points (only on boards large enough that they don't overlap corners)
            if (boardSize >= 13)
            {
                for (int edge : corners)
                {
                    DrawCircle(
                        boardOffsetX + center * spacing,
                        boardOffsetY + edge * spacing,
                        dotRadius, BLACK);
                    DrawCircle(
                        boardOffsetX + edge * spacing,
                        boardOffsetY + center * spacing,
                        dotRadius, BLACK);
                }
            }
        }
    }

    const float stoneDrawSize = (float)spacing * 1.1f;

    // doomed stones glow (drawn before stones so it appears underneath)
    // a group is doomed if hovering an empty valid spot would capture it
    if (opt.showDoomedStones && hoveredId != INVALID_INDEX &&
        gs.board[hoveredId] == STONE_NONE)
    {
        const Stone enemyPlayer = OtherStoneColor(gs.currentPlayer);
        BoardIndex neighbors[4];
        const int neighborCount = GetNeighbors(hoveredId, neighbors);

        for (int i = 0; i < neighborCount; i++)
        {
            const BoardIndex neighbor = neighbors[i];
            if (gs.board[neighbor] != enemyPlayer)
            {
                continue;
            }

            // annoying: path compression mutates groupRoot
            vector<BoardIndex>& mutableGroupRoot = const_cast<vector<BoardIndex>&>(gs.groupRoot);
            const BoardIndex neighborRoot = FindGroupRootAndCompressPath(neighbor, mutableGroupRoot);
            if (gs.groupLiberties[neighborRoot].size() == 1)
            {
                const float fadeIn = Saturate(hoverElapsed * 3.0f);
                const float pulse = 0.5f + 0.5f * sinf(hoverElapsed * 4.0f);
                const unsigned char doomAlpha = (unsigned char)(fadeIn * (80 + pulse * 100));

                for (const BoardIndex stoneId : gs.groupStones[neighborRoot])
                {
                    const Vector2 pos = GetScreenPosFromBoardIndex(stoneId);
                    const float r = stoneDrawSize * 0.5f;
                    DrawRing(pos, r + 1, r + 3, 0.0f, 360.0f, 36, Color{150, 0, 0, doomAlpha});
                }
            }
        }
    }

    // atari group highlights (groups with only 1 liberty, drawn under stones)
    if (opt.showAtariGroups)
    {
        for (BoardIndex id = 0; id < totalCells; id++)
        {
            if (gs.board[id] == STONE_NONE || gs.groupRoot[id] != id)
            {
                continue;
            }

            if (gs.groupLiberties[id].size() == 1)
            {
                for (const BoardIndex stoneId : gs.groupStones[id])
                {
                    const Vector2 pos = GetScreenPosFromBoardIndex(stoneId);
                    DrawCircleLines((int)pos.x, (int)pos.y, (float)(spacing / 2) + 3, Color{255, 0, 0, 100});
                }
            }
        }
    }

    // stones
    for (BoardIndex id = 0; id < totalCells; id++)
    {
        const Stone stone = gs.board[id];
        if (stone == STONE_NONE)
        {
            continue;
        }

        const float x = (float)(ColFrom1D(id) * spacing + boardOffsetX);
        const float y = (float)(RowFrom1D(id) * spacing + boardOffsetY);
        const Texture2D& tex = (stone == STONE_BLACK)
            ? app.blackStoneTexture : app.whiteStoneTexture;
        DrawStoneTexture(tex, x, y, stoneDrawSize, WHITE);
    }

    // highlight last placed stone
    if (gs.lastPlaced != INVALID_INDEX)
    {
        const Color markerColor = (gs.board[gs.lastPlaced] == STONE_WHITE) ? BLACK : GRAY;
        DrawCircleLines(
            ColFrom1D(gs.lastPlaced) * spacing + boardOffsetX,
            RowFrom1D(gs.lastPlaced) * spacing + boardOffsetY,
            (float)spacing / 3, markerColor);
    }

    // captured stones on the sides of the board.
    // left: stones captured by black (shown as white). right: captured by white (shown as black).
    // in atari go, empty circles show the goal, filled circles show progress.
    // skip stones that are still animating (flying from the board to the column).
    {
        int animatingLeft = 0;
        int animatingRight = 0;
        for (const CaptureAnimation& anim : app.captureAnimations)
        {
            if (anim.stoneColor == STONE_WHITE)
            {
                animatingLeft++;
            }
            else
            {
                animatingRight++;
            }
        }

        const int goalLeft = app.atariGoMode ? app.atariCaptureGoal : 0;
        const int goalRight = app.atariGoMode ? app.atariCaptureGoal : 0;
        const int settledLeft = gs.capturedByBlack - animatingLeft;
        const int settledRight = gs.capturedByWhite - animatingRight;
        const int showCountLeft = MaxInt(settledLeft, goalLeft);
        const int showCountRight = MaxInt(settledRight, goalRight);

        // left side: stones captured by black (shown as white stones)
        for (int i = 0; i < showCountLeft; i++)
        {
            const float y = captureColumnTopY + i * captureStoneSpacing;
            if (i < settledLeft)
            {
                DrawStoneTexture(app.whiteStoneTexture, captureColumnLeftX, y, captureDrawSize, WHITE);
            }
            else
            {
                DrawCircleLines((int)captureColumnLeftX, (int)y, captureStoneRadius, GRAY);
            }
        }

        // right side: stones captured by white (shown as black stones)
        for (int i = 0; i < showCountRight; i++)
        {
            const float y = captureColumnTopY + i * captureStoneSpacing;
            if (i < settledRight)
            {
                DrawStoneTexture(app.blackStoneTexture, captureColumnRightX, y, captureDrawSize, WHITE);
            }
            else
            {
                DrawCircleLines((int)captureColumnRightX, (int)y, captureStoneRadius, GRAY);
            }
        }
    }

}

// global pointer so the GLFW callback can access the app state.
// set once at startup, only used during resize.
AppState* g_appStateForResizeCallback = nullptr;

// raylib sets its own window size callback to handle viewport updates.
// we save it here so we can call it first, then do our redraw on top.
GLFWwindowsizefun g_originalRaylibSizeCallback = nullptr;

void GlfwWindowSizeCallback(GLFWwindow* window, int width, int height)
{
    // let raylib update its viewport/projection first
    if (g_originalRaylibSizeCallback != nullptr)
    {
        g_originalRaylibSizeCallback(window, width, height);
    }

    if (g_appStateForResizeCallback != nullptr)
    {
        const GameState& resizeGs = g_appStateForResizeCallback->game;
        UpdateBoardLayout(MaxInt(resizeGs.capturedByBlack, resizeGs.capturedByWhite));
        BeginDrawing();
        ClearBackground(BLACK);
        DrawBackgroundTexture(g_appStateForResizeCallback->woodTexture);

        // only draw the board if a game is active (arrays are initialized)
        if (g_appStateForResizeCallback->screen == SCREEN_GAME)
        {
            DrawBoardAndStones(*g_appStateForResizeCallback, INVALID_INDEX, 0.0f);
        }

        EndDrawing();
    }
}

// checks if placing here would be suicide. we look at each neighbor and try to
// find any reason it's NOT suicide:
// - empty neighbor = we have a liberty
// - friendly neighbor with >= 2 liberties = merged group survives (we eat one liberty)
// - enemy neighbor with exactly 1 liberty = we capture them, creating space
// if none of those hold for any neighbor, it's suicide
bool IsMoveSuicide(BoardIndex move, GameState& gs)
{
    const Stone enemyPlayer = OtherStoneColor(gs.currentPlayer);

    BoardIndex neighbors[4];
    const int neighborCount = GetNeighbors(move, neighbors);
    for (int i = 0; i < neighborCount; i++)
    {
        const BoardIndex neighbor = neighbors[i];
        const Stone neighborColor = gs.board[neighbor];

        if (neighborColor == STONE_NONE)
        {
            return false;
        }

        const BoardIndex neighborLeader = FindGroupRootAndCompressPath(
            neighbor, gs.groupRoot);
        const int libertyCount = (int)gs.groupLiberties[neighborLeader].size();

        if (neighborColor == gs.currentPlayer && libertyCount >= 2)
        {
            return false;
        }
        if (neighborColor == enemyPlayer && libertyCount == 1)
        {
            return false;
        }
    }

    return true;
}

void GoGameDSU()
{
    SetConfigFlags(FLAG_WINDOW_RESIZABLE);
    InitWindow(1000, 1000, "Gogus");
    SetTargetFPS(60);
    rlImGuiSetup(true);

    // find the project root so we can load data/ assets.
    // we might be at the root, in build/, or in build/Debug/.
    if (!DirectoryExists("data"))
    {
        if (DirectoryExists("../data"))
        {
            ChangeDirectory("..");
        }
        else if (DirectoryExists("../../data"))
        {
            ChangeDirectory("../..");
        }
    }

    // scale up imgui fonts and UI
    ImGuiIO& io = ImGui::GetIO();
    io.FontGlobalScale = 2.0f;
    ImGui::GetStyle().ScaleAllSizes(2.0f);

    // don't let raylib close the window on ESC, we handle it ourselves
    SetExitKey(KEY_NULL);

    // hook into GLFW so we can redraw during window resize
    GLFWwindow* glfwWindow = glfwGetCurrentContext();
    g_originalRaylibSizeCallback = glfwSetWindowSizeCallback(glfwWindow, GlfwWindowSizeCallback);

    AppState app;
    app.woodTexture = LoadTexture("data/wood.png");
    app.blackStoneTexture = LoadTexture("data/b.png");
    app.whiteStoneTexture = LoadTexture("data/w_1.png");
    g_appStateForResizeCallback = &app;

    GameState& gs = app.game;
    AppOptions& opt = app.options;

    // smooth ghost stone position
    DoubleSpringDamperStateVector2 ghostDamper;
    bool ghostHasTarget = false;

    // for smooth pulse restart when changing hovered position
    BoardIndex lastHoveredForPulse = INVALID_INDEX;
    double hoverPulseStartTime = 0.0;

    // smooth capture column compression
    DoubleSpringDamperState captureSpacingDamper = {};
    bool captureSpacingInitialized = false;

    // when the mouse is held down, we show a near-opaque ghost but don't commit.
    // on release, we place the stone at wherever the ghost ended up.
    bool placingStone = false;

    while (!WindowShouldClose() && !app.quitRequested)
    {
        UpdateBoardLayout(MaxInt(gs.capturedByBlack, gs.capturedByWhite));

        // smooth the capture column spacing
        if (!captureSpacingInitialized)
        {
            captureSpacingDamper.x = captureStoneSpacing;
            captureSpacingDamper.xi = captureStoneSpacing;
            captureSpacingInitialized = true;
        }
        DoubleSpringDamper(captureSpacingDamper, captureStoneSpacing, 0.3f, GetFrameTime());
        captureStoneSpacing = captureSpacingDamper.x;


        BeginDrawing();
        ClearBackground(BLACK);
        DrawBackgroundTexture(app.woodTexture);

        rlImGuiBegin();

        // =====================================================================
        // main menu
        // =====================================================================
        if (app.screen == SCREEN_MAIN_MENU)
        {
            const float windowW = (float)GetScreenWidth();
            const float windowH = (float)GetScreenHeight();
            const ImVec2 menuSize = {400, 0};
            ImGui::SetNextWindowPos(
                {windowW * 0.5f, windowH * 0.4f},
                ImGuiCond_Always, {0.5f, 0.5f});
            ImGui::SetNextWindowSize(menuSize, ImGuiCond_Always);

            ImGui::Begin("##mainmenu", nullptr,
                ImGuiWindowFlags_NoResize |
                ImGuiWindowFlags_NoMove |
                ImGuiWindowFlags_NoCollapse |
                ImGuiWindowFlags_NoTitleBar);

            // board size selection
            ImGui::Text("Board Size");

            const int standardSizes[] = { 9, 13, 19 };
            for (int i = 0; i < 3; i++)
            {
                const int size = standardSizes[i];
                char label[16];
                snprintf(label, sizeof(label), "%dx%d", size, size);

                bool isSelected = (app.selectedBoardSize == size);
                if (isSelected)
                {
                    ImGui::PushStyleColor(ImGuiCol_Button, ImGui::GetStyleColorVec4(ImGuiCol_ButtonActive));
                }

                if (ImGui::Button(label, {90, 40}))
                {
                    app.selectedBoardSize = size;
                }

                if (isSelected)
                {
                    ImGui::PopStyleColor();
                }

                if (i < 2)
                {
                    ImGui::SameLine();
                }
            }

            ImGui::SetNextItemWidth(-1);
            ImGui::SliderInt("##boardsize", &app.selectedBoardSize, 3, 19);

            ImGui::Separator();

            ImGui::Checkbox("Atari Go", &app.atariGoMode);
            if (app.atariGoMode)
            {
                ImGui::SameLine();
                ImGui::SetNextItemWidth(80);
                const char* captureGoalLabels[] = { "1", "3", "5" };
                const int captureGoalValues[] = { 1, 3, 5 };

                // find current selection index
                int currentIndex = 0;
                for (int i = 0; i < 3; i++)
                {
                    if (captureGoalValues[i] == app.atariCaptureGoal)
                    {
                        currentIndex = i;
                    }
                }

                if (ImGui::BeginCombo("##captures", captureGoalLabels[currentIndex]))
                {
                    for (int i = 0; i < 3; i++)
                    {
                        const bool selected = (currentIndex == i);
                        if (ImGui::Selectable(captureGoalLabels[i], selected))
                        {
                            app.atariCaptureGoal = captureGoalValues[i];
                        }
                    }
                    ImGui::EndCombo();
                }
                ImGui::SameLine();
                ImGui::Text("captures to win");
            }

            ImGui::Separator();

            if (ImGui::Button("Start Game", {-1, 40}))
            {
                InitGameState(gs, app.selectedBoardSize);

                // in atari go, place 4 stones in a 2x2 square near the center.
                // black on one diagonal, white on the other.
                if (app.atariGoMode && boardSize >= 3)
                {
                    const int r = boardSize / 2 - 1;
                    const int c = boardSize / 2 - 1;
                    PlayMove(Index1D(r,     c    ), gs); // black top-left
                    PlayMove(Index1D(r,     c + 1), gs); // white top-right
                    PlayMove(Index1D(r + 1, c + 1), gs); // black bottom-right
                    PlayMove(Index1D(r + 1, c    ), gs); // white bottom-left
                }

                app.screen = SCREEN_GAME;
                app.pauseMenuOpen = false;
            }
            if (ImGui::Button("Quit", {-1, 40}))
            {
                app.quitRequested = true;
            }

            ImGui::End();
        }

        // =====================================================================
        // in-game
        // =====================================================================
        if (app.screen == SCREEN_GAME)
        {
            // ESC toggles pause menu
            if (IsKeyPressed(KEY_ESCAPE))
            {
                app.pauseMenuOpen = !app.pauseMenuOpen;
            }

            // H toggles debug panel
            if (IsKeyPressed(KEY_H))
            {
                app.showDebugPanel = !app.showDebugPanel;
            }

            // input (only when not paused and no winner yet)
            if (!app.pauseMenuOpen && gs.winner == STONE_NONE)
            {
                if (IsMouseButtonPressed(MOUSE_BUTTON_SIDE))
                {
                    UndoMove(gs);
                    app.captureAnimations.clear();
                }

                // press to start placing (ghost becomes nearly opaque)
                if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT))
                {
                    const BoardIndex clickedId = GetBoardIndexFromScreenPos(
                        GetMouseX(), GetMouseY());
                    if (clickedId != INVALID_INDEX &&
                        gs.board[clickedId] == STONE_NONE &&
                        clickedId != gs.koForbidden &&
                        !IsMoveSuicide(clickedId, gs))
                    {
                        placingStone = true;
                    }
                }

                // release to commit the stone at the current ghost position
                if (placingStone && IsMouseButtonReleased(MOUSE_BUTTON_LEFT))
                {
                    placingStone = false;

                    const BoardIndex releaseId = GetBoardIndexFromScreenPos(
                        GetMouseX(), GetMouseY());

                    bool moveValid = (releaseId != INVALID_INDEX &&
                        gs.board[releaseId] == STONE_NONE &&
                        releaseId != gs.koForbidden &&
                        !IsMoveSuicide(releaseId, gs));

                    if (moveValid)
                    {
                        gs.moveHistory.resize(gs.historyPosition + 1);
                        gs.moveHistory.push_back(releaseId);
                        gs.historyPosition++;
                        // remember who's moving (PlayMove swaps currentPlayer)
                        const Stone playerWhoMoved = gs.currentPlayer;
                        PlayMove(releaseId, gs);

                        // create animations for captured stones
                        if (!gs.lastCapturedPositions.empty())
                        {
                            // figure out which capture column they go to and what slot index
                            const bool capturedByBlackPlayer = (playerWhoMoved == STONE_BLACK);
                            const int capturesBefore = capturedByBlackPlayer
                                ? (gs.capturedByBlack - (int)gs.lastCapturedPositions.size())
                                : (gs.capturedByWhite - (int)gs.lastCapturedPositions.size());

                            const float targetX = capturedByBlackPlayer
                                ? captureColumnLeftX : captureColumnRightX;

                            const float boardStoneSize = (float)spacing * 1.1f;
                            const float captureSize = captureStoneRadius * 2.2f;
                            const double now = GetTime();

                            for (int i = 0; i < (int)gs.lastCapturedPositions.size(); i++)
                            {
                                const BoardIndex capturedId = gs.lastCapturedPositions[i];
                                const int slotIndex = capturesBefore + i;
                                const float targetY = captureColumnTopY + slotIndex * captureStoneSpacing;

                                CaptureAnimation anim;
                                anim.startPos = GetScreenPosFromBoardIndex(capturedId);
                                anim.endPos = { targetX, targetY };
                                anim.startSize = boardStoneSize;
                                anim.endSize = captureSize;
                                anim.stoneColor = OtherStoneColor(playerWhoMoved);
                                anim.startTime = now + i * 0.05;
                                anim.duration = 0.4f;
                                app.captureAnimations.push_back(anim);
                            }
                        }

                        // atari go: reach the capture goal to win
                        if (app.atariGoMode)
                        {
                            if (gs.capturedByBlack >= app.atariCaptureGoal)
                            {
                                gs.winner = STONE_BLACK;
                            }
                            if (gs.capturedByWhite >= app.atariCaptureGoal)
                            {
                                gs.winner = STONE_WHITE;
                            }
                        }
                    }
                }
            }

            // compute hovered position once, used by board drawing and hover overlays
            const BoardIndex hoveredId = (!app.pauseMenuOpen && gs.winner == STONE_NONE)
                ? GetBoardIndexFromScreenPos(GetMouseX(), GetMouseY())
                : INVALID_INDEX;

            // restart pulse when hover target changes
            if (hoveredId != lastHoveredForPulse)
            {
                lastHoveredForPulse = hoveredId;
                hoverPulseStartTime = GetTime();
            }

            // draw board (always, even when paused)
            const float hoverElapsed = (float)(GetTime() - hoverPulseStartTime);
            DrawBoardAndStones(app, hoveredId, hoverElapsed);

            // menu button in top-right corner
            {
                const float buttonW = 100.0f;
                const float buttonH = 50.0f;
                const float pad = 10.0f;
                ImGui::SetNextWindowPos(
                    {(float)GetScreenWidth() - buttonW - pad, pad},
                    ImGuiCond_Always);
                ImGui::SetNextWindowSize({buttonW, buttonH}, ImGuiCond_Always);
                ImGui::Begin("##menubutton", nullptr,
                    ImGuiWindowFlags_NoTitleBar |
                    ImGuiWindowFlags_NoResize |
                    ImGuiWindowFlags_NoMove |
                    ImGuiWindowFlags_NoScrollbar |
                    ImGuiWindowFlags_NoBackground);
                if (ImGui::Button("Menu", {-1, -1}))
                {
                    app.pauseMenuOpen = true;
                }
                ImGui::End();
            }

            // undo button at the bottom center
            {
                const float buttonW = 120.0f;
                const float buttonH = 50.0f;
                const float pad = 10.0f;
                ImGui::SetNextWindowPos(
                    {(float)GetScreenWidth() * 0.5f - buttonW * 0.5f,
                     (float)GetScreenHeight() - buttonH - pad},
                    ImGuiCond_Always);
                ImGui::SetNextWindowSize({buttonW, buttonH}, ImGuiCond_Always);
                ImGui::Begin("##undobutton", nullptr,
                    ImGuiWindowFlags_NoTitleBar |
                    ImGuiWindowFlags_NoResize |
                    ImGuiWindowFlags_NoMove |
                    ImGuiWindowFlags_NoScrollbar |
                    ImGuiWindowFlags_NoBackground);
                if (ImGui::Button("Undo", {-1, -1}))
                {
                    UndoMove(gs);
                    app.captureAnimations.clear();
                }
                ImGui::End();
            }

            // debug panel (toggle with H)
            if (app.showDebugPanel)
            {
                ImGui::Begin("Go");
                ImGui::Text("Current player: %s",
                    (gs.currentPlayer == STONE_BLACK) ? "Black" : "White");
                ImGui::Text("Move: %d / %d",
                    gs.historyPosition + 1, (int)gs.moveHistory.size());
                ImGui::Checkbox("Show Debug", &opt.showDebug);
                ImGui::Checkbox("Show Doomed Stones", &opt.showDoomedStones);
                ImGui::Checkbox("Show Liberties", &opt.showLiberties);
                ImGui::Checkbox("Show Atari Groups", &opt.showAtariGroups);
                ImGui::Separator();

                if (ImGui::Button("Undo"))
                {
                    UndoMove(gs);
                }
                ImGui::SameLine();
                if (ImGui::Button("Redo"))
                {
                    RedoMove(gs);
                    app.captureAnimations.clear();
                }
                ImGui::SameLine();
                if (ImGui::Button("Restart"))
                {
                    ResetGameState(gs);
                    app.captureAnimations.clear();
                }
                ImGui::End();
            }

            // hover overlays (only when not paused and no winner)
            if (!app.pauseMenuOpen && gs.winner == STONE_NONE)
            {
                // ghost stone
                const bool validHover = (hoveredId != INVALID_INDEX &&
                    gs.board[hoveredId] == STONE_NONE &&
                    hoveredId != gs.koForbidden &&
                    !IsMoveSuicide(hoveredId, gs));

                if (validHover)
                {
                    const Vector2 targetPos = GetScreenPosFromBoardIndex(hoveredId);
                    const float dt = GetFrameTime();

                    // snap to target on first valid hover
                    if (!ghostHasTarget)
                    {
                        ghostDamper.x = targetPos;
                        ghostDamper.xi = targetPos;
                        ghostDamper.v = {0.0f, 0.0f};
                        ghostDamper.vi = {0.0f, 0.0f};
                        ghostHasTarget = true;
                    }

                    DoubleSpringDamperVector2(ghostDamper, targetPos, 0.08f, dt);

                    const bool isBlack = (gs.currentPlayer == STONE_BLACK);
                    const unsigned char ghostAlpha = placingStone ? 220 : (isBlack ? 180 : 80);
                    const Texture2D& ghostTex = (gs.currentPlayer == STONE_BLACK)
                        ? app.blackStoneTexture : app.whiteStoneTexture;
                    DrawStoneTexture(ghostTex, ghostDamper.x.x, ghostDamper.x.y,
                        (float)spacing * 1.1f, Color{255, 255, 255, ghostAlpha});
                }
                else
                {
                    ghostHasTarget = false;
                }

                // liberties: dark gold hollow circles with a gentle pulse
                if (opt.showLiberties &&
                    hoveredId != INVALID_INDEX &&
                    gs.groupRoot[hoveredId] != INVALID_INDEX)
                {
                    const BoardIndex rootId =
                        FindGroupRootAndCompressPath(hoveredId, gs.groupRoot);

                    // fade in from 0 over the first cycle, then pulse normally
                    const float fadeIn = Saturate(hoverElapsed * 3.0f);
                    const float pulse = 0.5f + 0.5f * sinf(hoverElapsed * 4.0f);
                    const unsigned char alpha = (unsigned char)(fadeIn * (100 + (int)(pulse * 120)));
                    const Color libertyColor = { 180, 140, 30, alpha };
                    const float libertyRadius = (float)spacing * 0.15f;

                    for (const BoardIndex libertyId : gs.groupLiberties[rootId])
                    {
                        const Vector2 libertyPos = GetScreenPosFromBoardIndex(libertyId);
                        DrawCircleLines(
                            (int)libertyPos.x, (int)libertyPos.y,
                            libertyRadius, libertyColor);
                    }
                }

                // debug: group root and leader lines
                if (opt.showDebug &&
                    hoveredId != INVALID_INDEX &&
                    gs.groupRoot[hoveredId] != INVALID_INDEX)
                {
                    const BoardIndex rootId =
                        FindGroupRootAndCompressPath(hoveredId, gs.groupRoot);
                    const Vector2 hoveredPos = GetScreenPosFromBoardIndex(hoveredId);
                    const Vector2 rootPos = GetScreenPosFromBoardIndex(rootId);

                    DrawLineEx(hoveredPos, rootPos, 3.0f, RED);
                    DrawRectangleLines(
                        (int)rootPos.x - 8, (int)rootPos.y - 8, 16, 16, RED);

                    for (const BoardIndex stoneId : gs.groupStones[rootId])
                    {
                        const Vector2 stonePos = GetScreenPosFromBoardIndex(stoneId);
                        DrawCircleLines(
                            (int)stonePos.x, (int)stonePos.y,
                            (float)spacing / 2 + 2, RED);
                    }
                }
            }

            // pause menu overlay
            if (app.pauseMenuOpen)
            {
                // dim the background
                DrawRectangle(0, 0, GetScreenWidth(), GetScreenHeight(),
                    Color{0, 0, 0, 120});

                const float windowW = (float)GetScreenWidth();
                const float windowH = (float)GetScreenHeight();
                ImGui::SetNextWindowPos(
                    {windowW * 0.5f, windowH * 0.4f},
                    ImGuiCond_Always, {0.5f, 0.5f});
                ImGui::SetNextWindowSize({400, 0}, ImGuiCond_Always);

                ImGui::Begin("Paused", nullptr,
                    ImGuiWindowFlags_NoResize |
                    ImGuiWindowFlags_NoMove |
                    ImGuiWindowFlags_NoCollapse);

                if (ImGui::Button("Return to Game", {-1, 40}))
                {
                    app.pauseMenuOpen = false;
                }

                ImGui::Separator();
                ImGui::Checkbox("Show Doomed Stones", &opt.showDoomedStones);
                ImGui::Checkbox("Show Liberties", &opt.showLiberties);
                ImGui::Checkbox("Show Atari Groups", &opt.showAtariGroups);

                ImGui::Separator();
                if (ImGui::Button("Return to Main Menu", {-1, 40}))
                {
                    app.pauseMenuOpen = false;
                    app.screen = SCREEN_MAIN_MENU;
                }
                if (ImGui::Button("Quit to Desktop", {-1, 40}))
                {
                    app.quitRequested = true;
                }

                ImGui::End();
            }

            // victory overlay
            if (gs.winner != STONE_NONE)
            {
                DrawRectangle(0, 0, GetScreenWidth(), GetScreenHeight(),
                    Color{0, 0, 0, 120});

                const float windowW = (float)GetScreenWidth();
                const float windowH = (float)GetScreenHeight();
                ImGui::SetNextWindowPos(
                    {windowW * 0.5f, windowH * 0.4f},
                    ImGuiCond_Always, {0.5f, 0.5f});
                ImGui::SetNextWindowSize({400, 0}, ImGuiCond_Always);

                const char* winnerName = (gs.winner == STONE_BLACK) ? "Black" : "White";
                char title[64];
                snprintf(title, sizeof(title), "%s wins!", winnerName);

                ImGui::Begin(title, nullptr,
                    ImGuiWindowFlags_NoResize |
                    ImGuiWindowFlags_NoMove |
                    ImGuiWindowFlags_NoCollapse);

                if (ImGui::Button("Continue Playing", {-1, 40}))
                {
                    app.atariGoMode = false;
                    gs.winner = STONE_NONE;
                }
                if (ImGui::Button("Restart", {-1, 40}))
                {
                    InitGameState(gs, boardSize);

                    if (app.atariGoMode && boardSize >= 3)
                    {
                        const int r = boardSize / 2 - 1;
                        const int c = boardSize / 2 - 1;
                        PlayMove(Index1D(r,     c    ), gs);
                        PlayMove(Index1D(r,     c + 1), gs);
                        PlayMove(Index1D(r + 1, c + 1), gs);
                        PlayMove(Index1D(r + 1, c    ), gs);
                    }
                }
                if (ImGui::Button("Main Menu", {-1, 40}))
                {
                    app.screen = SCREEN_MAIN_MENU;
                }

                ImGui::End();
            }
        }

        rlImGuiEnd();

        // draw and update capture animations
        {
            const double now = GetTime();
            int writeIndex = 0;
            for (int i = 0; i < (int)app.captureAnimations.size(); i++)
            {
                CaptureAnimation& anim = app.captureAnimations[i];
                const float elapsed = (float)(now - anim.startTime);

                // hasn't started yet (staggered delay)
                if (elapsed < 0.0f)
                {
                    // still waiting, draw at start position
                    const Texture2D& tex = (anim.stoneColor == STONE_BLACK)
                        ? app.blackStoneTexture : app.whiteStoneTexture;
                    DrawStoneTexture(tex, anim.startPos.x, anim.startPos.y, anim.startSize, WHITE);
                    app.captureAnimations[writeIndex++] = anim;
                    continue;
                }

                const float t = Saturate(elapsed / anim.duration);
                const float smooth = SmootherStep(t);

                const float x = Lerp(anim.startPos.x, anim.endPos.x, smooth);
                const float y = Lerp(anim.startPos.y, anim.endPos.y, smooth);
                const float size = Lerp(anim.startSize, anim.endSize, smooth);

                const Texture2D& tex = (anim.stoneColor == STONE_BLACK)
                    ? app.blackStoneTexture : app.whiteStoneTexture;
                DrawStoneTexture(tex, x, y, size, WHITE);

                // keep if not done
                if (t < 1.0f)
                {
                    app.captureAnimations[writeIndex++] = anim;
                }
            }
            app.captureAnimations.resize(writeIndex);
        }

        EndDrawing();
    }

    UnloadTexture(app.woodTexture);
    UnloadTexture(app.blackStoneTexture);
    UnloadTexture(app.whiteStoneTexture);
    rlImGuiShutdown();
    CloseWindow();
}





int main()
{
    GoGameDSU();
}