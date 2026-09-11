# LuauHelperModules

Two things: a game-agnostic navigation library, and the Murder Mystery 2 script that uses it.

## `nav/UniversalNav.luau`

A navigation framework that searches any state space you describe, and discovers what the world lets
an agent do rather than being told. It knows nothing about any particular game.

Perception scans a world for candidate affordances (what the platform says a thing is, and what the
geometry suggests). Capabilities are read off the agent. A traversal provider emits a move only where
an affordance meets a capability, so what the body can do decides what the search may plan. Outcomes
are reported back, so a surface that failed is distrusted and a climb that was measured is re-priced.

Used directly:

```lua
local UniversalNav = loadstring(game:HttpGet("https://raw.githubusercontent.com/bostonstrong567/LuauHelperModules/main/nav/UniversalNav.luau"))()
```

## `MM2/`

| File | What it is |
|---|---|
| `main.luau` | The script. Fetches Ember and UniversalNav at runtime. |
| `mm2-standalone.lua` | The same script with UniversalNav inlined — only Ember is fetched. |
| `build-standalone.py` | Regenerates the standalone. Run it after changing `main.luau` or the library. |
| `showcase.luau` | Demo/storyboard pilot for the GUI. |

The GUI is [Ember](https://rbx.lol/docs/ember), loaded at runtime from `rbx.lol/ember.lua`.

### Rebuilding the standalone

```bash
cd MM2 && python build-standalone.py
```

It string-matches the library's fetch line in `main.luau`, so it fails loudly rather than silently
producing a broken file if that line ever changes.
