-- sdl_test.lua — minimal SDL2 test on luazig
-- Tests: require("SDL"), init, createWindow, createRenderer,
--        event loop, drawing primitives, ESC to quit.

local SDL = require("SDL")

local ok, err = SDL.init { SDL.flags.Video }
if not ok then error(err) end

local win, werr = SDL.createWindow {
    title  = "luazig SDL2 test",
    width  = 640,
    height = 480,
    flags  = { SDL.window.Resizable },
}
if not win then error(werr) end

local rdr, rerr = SDL.createRenderer(win, -1)
if not rdr then error(rerr) end

local running = true
local frame = 0
local max_frames = 300 -- ~5 seconds at 60fps, then auto-quit

while running and frame < max_frames do
    for e in SDL.pollEvent() do
        if e.type == SDL.event.Quit then
            running = false
        elseif e.type == SDL.event.KeyDown then
            if e.keysym.sym == 27 then -- ESC
                running = false
            end
        end
    end

    frame = frame + 1

    -- Cycle background color
    local r = (frame * 3) % 256
    local g = (frame * 5) % 256
    local b = (frame * 7) % 256
    rdr:setDrawColor(r, g, b, 255)
    rdr:clear()

    -- Draw a white rectangle in center
    rdr:setDrawColor(255, 255, 255, 255)
    rdr:fillRect {
        x = 220,
        y = 160,
        w = 200,
        h = 160,
    }

    rdr:present()
    SDL.delay(16) -- ~60fps
end

SDL.quit()
print(string.format("luazig SDL2 test: %d frames rendered", frame))
