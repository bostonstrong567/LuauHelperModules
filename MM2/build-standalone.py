# Builds mm2-standalone.lua: main.luau with UniversalNav inlined. Ember is deliberately left as the
# runtime fetch from rbx.lol/ember.lua so the GUI keeps updating on its own. Run after changing
# main.luau or the nav library.
import os

HERE = os.path.dirname(os.path.abspath(__file__))
MAIN = os.path.join(HERE, "main.luau")
NAV = os.path.join(HERE, "..", "nav", "UniversalNav.luau")
OUT = os.path.join(HERE, "mm2-standalone.lua")

NAVFETCH = 'local UniversalNav = fetchLib("nav", "https://raw.githubusercontent.com/bostonstrong567/LuauHelperModules/main/nav/UniversalNav.luau", function(lib) return type(lib.Navigator) == "table" end)'

HEADER = (
    "-- UniversalNav, the navigation framework. Normally fetched from GitHub at runtime; inlined here so\n"
    "-- the script carries its own pathfinding. Ember is still fetched at runtime, just above.\n"
)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def main():
    src = read(MAIN)
    if src.count(NAVFETCH) != 1:
        raise SystemExit("main.luau no longer fetches nav the expected way; update this script")
    body = HEADER + "local UniversalNav = (function()\n" + read(NAV).rstrip() + "\nend)()"
    out = src.replace(NAVFETCH, body)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(out)
    print("wrote %s, %d lines, %d bytes" % (OUT, out.count("\n") + 1, len(out.encode("utf-8"))))


main()
