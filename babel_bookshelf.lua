--[[
Bookshelf themes: installs Babel's themes, and the reader's own, for the Bookshelf plugin
(github.com/AndyHazz/bookshelf.koplugin).

Bookshelf reads "theme packs" from koreader/settings/bookshelf/ornaments/<pack>/: a theme/ folder
(theme.json, colours.json, a wallpaper, plank images) and ornaments (SVG or PNG) beside it, and
lets the reader choose one in its Theme library. This module copies Babel's packs there (from the
plugin's themes/ folder, or from GitHub when the plugin was installed without it), and checks and
copies a pack the reader brings, as a folder or a .zip.

It only ever removes what it put there: a pack it installed has a .babel-theme file listing its
files, a pack it imported a .babel-import file.
--]]

local DataStorage = require("datastorage")
local JSON = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ok_list, THEMES = pcall(require, "babel_themes")
if not ok_list or type(THEMES) ~= "table" then
    THEMES = {}
end

local M = { themes = THEMES }

M.URL = "https://raw.githubusercontent.com/Jouskaio/babel.koplugin/main/themes/"
M.MARK = ".babel-theme"
M.IMPORTED = ".babel-import"
M.MAX_FILES = 400
M.MAX_FILE = 25 * 1024 * 1024
M.MAX_TOTAL = 80 * 1024 * 1024

-- The names Bookshelf reads in colours.json (bookshelf_theme_pack COLOUR_NAMES).
M.COLOUR_NAMES = {
    ["text"] = true, ["progress bar"] = true, ["progress track"] = true, ["bookmark"] = true,
    ["finished bookmark"] = true, ["favourite star"] = true, ["favourite heart"] = true,
    ["badge text"] = true, ["badge background"] = true, ["menu bar"] = true, ["module card"] = true,
    ["module border"] = true, ["panel"] = true, ["panel text"] = true, ["cover border"] = true,
    ["selection"] = true, ["cover shadow"] = true, ["plank"] = true, ["folder label"] = true,
    ["folder text"] = true, ["selected shelf"] = true, ["selected shelf text"] = true, ["page"] = true,
}
M.WALL_EXTS = { png = true, jpg = true, jpeg = true, webp = true, bmp = true, gif = true }
M.WALL_STEMS = { ["wallpaper"] = true, ["wallpaper.full"] = true, ["wallpaper.dark"] = true,
                 ["wallpaper.full.dark"] = true }
-- Folder names Bookshelf keeps for its own themes: a pack named so would never be listed.
M.RESERVED = { plain = true, mine = true, none = true }

-- ── Files ─────────────────────────────────────────────────────────────────

local function isDir(p) return lfs.attributes(p, "mode") == "directory" end
local function isFile(p) return lfs.attributes(p, "mode") == "file" end

local function mkdirs(path)
    if isDir(path) then
        return true
    end
    local parent = path:match("^(.+)/[^/]+$")
    if parent then
        mkdirs(parent)
    end
    lfs.mkdir(path)
    return isDir(path)
end

local function readFile(path, limit)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read(limit or "*a")
    f:close()
    return data
end

-- Through a temporary file, so a failure never leaves half a file where Bookshelf reads.
local function writeFile(path, data)
    local tmp = path .. ".part"
    local f = io.open(tmp, "wb")
    if not f then
        return false
    end
    local ok = f:write(data)
    f:close()
    if not ok then
        os.remove(tmp)
        return false
    end
    os.remove(path)
    return os.rename(tmp, path) and true or false
end

local function copyFile(src, dst)
    local data = readFile(src)
    if not data then
        return false
    end
    local parent = dst:match("^(.+)/[^/]+$")
    if parent and not mkdirs(parent) then
        return false
    end
    return writeFile(dst, data)
end

local function listDir(dir)
    local out = {}
    pcall(function()
        for name in lfs.dir(dir) do
            if name ~= "." and name ~= ".." then
                out[#out + 1] = name
            end
        end
    end)
    table.sort(out)
    return out
end

local function removeTree(path)
    if isDir(path) then
        for _i, name in ipairs(listDir(path)) do
            removeTree(path .. "/" .. name)
        end
        lfs.rmdir(path)
    elseif lfs.attributes(path, "mode") then
        os.remove(path)
    end
end

-- The files a marker lists (one per line after the first, which is the version).
local function readMark(path)
    local text = readFile(path)
    if not text then
        return nil
    end
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    local version = table.remove(lines, 1)
    return { version = version, files = lines }
end

local function writeMark(path, version, files)
    return writeFile(path, version .. "\n" .. table.concat(files, "\n") .. "\n")
end

-- Removes the files a marker lists, the marker, then the folders if nothing else is left in them
-- (a file the reader put there stays, and so does its folder).
local function removeMarked(dir, mark_name)
    local mark = readMark(dir .. "/" .. mark_name)
    if not mark then
        return false
    end
    for _i, f in ipairs(mark.files) do
        if not f:find("%.%.") then
            os.remove(dir .. "/" .. f)
        end
    end
    os.remove(dir .. "/" .. mark_name)
    lfs.rmdir(dir .. "/theme")
    lfs.rmdir(dir)
    return true
end

-- ── Bookshelf ─────────────────────────────────────────────────────────────

function M.root()
    return DataStorage:getSettingsDir() .. "/bookshelf/ornaments"
end

function M.dirOf(theme)
    return M.root() .. "/" .. theme.folder
end

-- Whether Bookshelf is on the e-reader (loaded, or beside this plugin).
function M.bookshelfFound(plugin_path)
    if package.loaded["lib/bookshelf_theme_pack"] then
        return true
    end
    local parent = plugin_path and plugin_path:match("^(.+)/[^/]+$")
    return parent and isDir(parent .. "/bookshelf.koplugin") or false
end

-- Tells Bookshelf, when it runs, that its packs changed: it shows them now, not in a while.
function M.refresh()
    local tp = package.loaded["lib/bookshelf_theme_pack"]
    if type(tp) == "table" and type(tp.rescan) == "function" then
        pcall(tp.rescan)
    end
end

-- ── Babel's themes ────────────────────────────────────────────────────────

function M.find(id)
    for _i, theme in ipairs(THEMES) do
        if theme.id == id then
            return theme
        end
    end
end

-- "installed" (this version), "outdated", "absent" or "foreign" (a folder of that name this
-- plugin did not make: left alone).
function M.state(theme)
    local dir = M.dirOf(theme)
    if not isDir(dir) then
        return "absent"
    end
    local mark = readMark(dir .. "/" .. M.MARK)
    if not mark then
        return "foreign"
    end
    return mark.version == theme.version and "installed" or "outdated"
end

-- Downloads [url] to [path]; true when it all came.
function M.fetch(url, path)
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local parent = path:match("^(.+)/[^/]+$")
    if parent and not mkdirs(parent) then
        return false
    end
    local tmp = path .. ".part"
    local file = io.open(tmp, "wb")
    if not file then
        return false
    end
    socketutil:set_timeout(10, 60)
    local code = socket.skip(1, require("ssl.https").request({
        url = url,
        method = "GET",
        sink = ltn12.sink.file(file),
    }))
    socketutil:reset_timeout()
    if code == 200 and (lfs.attributes(tmp, "size") or 0) > 0 then
        os.remove(path)
        return os.rename(tmp, path) and true or false
    end
    os.remove(tmp)
    logger.warn("Babel: could not download a theme file", url, code)
    return false
end

-- Copies a theme into Bookshelf's folder, from the plugin's themes/ folder, else (when
-- [download] is true) from GitHub. Returns true, or false and "missing" (the files are not here
-- and downloading was not allowed), "foreign" (a folder of that name is someone else's) or
-- "failed".
function M.install(plugin_path, theme, download)
    local state = M.state(theme)
    if state == "foreign" then
        return false, "foreign"
    end
    local src = plugin_path and (plugin_path .. "/themes/" .. theme.id)
    local here = src and isFile(src .. "/" .. theme.files[1])
    if not here and not download then
        return false, "missing"
    end
    local dest = M.dirOf(theme)
    if not mkdirs(dest .. "/theme") then
        return false, "failed"
    end
    -- What an older version had and this one has not goes.
    local old = readMark(dest .. "/" .. M.MARK)
    if old then
        local keep = {}
        for _i, f in ipairs(theme.files) do
            keep[f] = true
        end
        for _i, f in ipairs(old.files) do
            if not keep[f] and not f:find("%.%.") then
                os.remove(dest .. "/" .. f)
            end
        end
    end
    for _i, f in ipairs(theme.files) do
        local ok
        if here then
            ok = copyFile(src .. "/" .. f, dest .. "/" .. f)
        else
            ok = M.fetch(M.URL .. theme.id .. "/" .. f, dest .. "/" .. f)
        end
        if not ok then
            return false, "failed"
        end
    end
    writeMark(dest .. "/" .. M.MARK, theme.version, theme.files)
    M.refresh()
    return true
end

function M.uninstall(theme)
    local done = removeMarked(M.dirOf(theme), M.MARK)
    M.refresh()
    return done
end

-- Installs the chosen themes that are missing or older than the plugin's. Returns how many were
-- installed and how many still wait for a connection.
function M.sync(plugin_path, chosen, download)
    local installed, waiting = 0, 0
    for _i, theme in ipairs(THEMES) do
        if chosen[theme.id] then
            local state = M.state(theme)
            if state == "absent" or state == "outdated" then
                local ok, err = M.install(plugin_path, theme, download)
                if ok then
                    installed = installed + 1
                elseif err == "missing" then
                    waiting = waiting + 1
                end
            end
        end
    end
    return installed, waiting
end

-- ── The reader's own themes ───────────────────────────────────────────────

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- A path inside an archive that is safe to write under a folder: relative, no "..", and not the
-- litter some systems add (__MACOSX, ._ files, .DS_Store).
local function safeEntry(p)
    p = p:gsub("\\", "/"):gsub("^%./", "")
    if p == "" or p:sub(1, 1) == "/" or p:find("^%a:") then
        return nil
    end
    for part in p:gmatch("[^/]+") do
        if part == ".." or part:sub(1, 2) == "._" or part == "__MACOSX" or part == ".DS_Store" then
            return nil
        end
    end
    return p
end

-- Unpacks [zip] into [dest]. Returns true, or nil and why.
function M.unzip(zip, dest)
    if not mkdirs(dest) then
        return nil, _("could not make a folder to unpack it")
    end
    local ok_a, Archiver = pcall(require, "ffi/archiver")
    if ok_a and type(Archiver) == "table" and Archiver.Reader then
        local reader = Archiver.Reader:new()
        if not reader:open(zip) then
            return nil, _("this file is not a zip archive KOReader can read")
        end
        local count, total = 0, 0
        local result, why = true, nil
        for entry in reader:iterate() do
            local path = entry.mode == "file" and safeEntry(entry.path)
            if path then
                count = count + 1
                total = total + (tonumber(entry.size) or 0)
                if count > M.MAX_FILES or total > M.MAX_TOTAL or (tonumber(entry.size) or 0) > M.MAX_FILE then
                    result, why = nil, _("the archive is too big for a theme")
                    break
                end
                local data = reader:extractToMemory(entry.path)
                local parent = (dest .. "/" .. path):match("^(.+)/[^/]+$")
                if not data or not mkdirs(parent) or not writeFile(dest .. "/" .. path, data) then
                    result, why = nil, _("a file of the archive could not be unpacked")
                    break
                end
            end
        end
        reader:close()
        return result, why
    end
    -- An older KOReader, without its archive library: the system's unzip, where there is one.
    local cmd = "unzip -qo " .. shellQuote(zip) .. " -d " .. shellQuote(dest) .. " >/dev/null 2>&1"
    local code = os.execute(cmd)
    if code == 0 or code == true then
        return true
    end
    return nil, _("it is not a zip file, or this KOReader cannot unpack one (unzip it on a computer, then choose the folder)")
end

local function ext(name)
    return (name:match("%.([^%./]+)$") or ""):lower()
end

-- The kind of picture a file holds, from its first bytes (never from its name).
local function imageKind(path)
    local head = readFile(path, 16) or ""
    if head:sub(1, 8) == "\137PNG\r\n\026\n" then
        return "png"
    elseif head:sub(1, 3) == "\255\216\255" then
        return "jpeg"
    elseif head:sub(1, 4) == "GIF8" then
        return "gif"
    elseif head:sub(1, 2) == "BM" then
        return "bmp"
    elseif head:sub(1, 4) == "RIFF" and head:sub(9, 12) == "WEBP" then
        return "webp"
    end
end

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

-- A PNG's width and height, from its header.
local function pngSize(path)
    local head = readFile(path, 24) or ""
    if #head < 24 or head:sub(1, 8) ~= "\137PNG\r\n\026\n" or head:sub(13, 16) ~= "IHDR" then
        return nil
    end
    return be32(head, 17), be32(head, 21)
end

local function decodeJson(path)
    local text = readFile(path)
    if not text then
        return nil
    end
    local ok, doc = pcall(JSON.decode, text)
    if ok and type(doc) == "table" then
        return doc
    end
end

-- The folder of a pack inside what was unpacked: the folder itself, or the one folder it holds
-- (a zip of a folder), at most two levels down.
function M.packRoot(dir)
    for _depth = 1, 3 do
        if isDir(dir .. "/theme") then
            return dir
        end
        local dirs, files = {}, 0
        for _i, name in ipairs(listDir(dir)) do
            if safeEntry(name) and name:sub(1, 1) ~= "." then
                if isDir(dir .. "/" .. name) then
                    dirs[#dirs + 1] = name
                else
                    files = files + 1
                end
            end
        end
        if files > 0 or #dirs ~= 1 then
            return dir
        end
        dir = dir .. "/" .. dirs[1]
    end
    return dir
end

--[[
Checks that [root] is a Bookshelf theme pack. Returns a report:
  ok        no error: it can be installed
  errors    what makes it unusable, warnings what Bookshelf will ignore
  name      what Bookshelf will call it; files the paths to copy (relative to root)
  wallpaper, planks, ornaments, colours: what it brings
The rules are Bookshelf's (bookshelf_theme_pack and bookshelf_ornaments): theme/theme.json a JSON
object ("shelf" light or dark), theme/colours.json {"day": {...}, "night": {...}} of #RRGGBB
colours under Bookshelf's names, wallpaper[.full][.dark].<png|jpg|webp|bmp|gif>,
plank[.<name>].<middle|left|right>.png the same height (three equal bands), and ornaments: SVG
drawings or PNG pictures beside theme/.
--]]
function M.check(root, fallback_name)
    local r = { errors = {}, warnings = {}, files = {}, planks = 0, ornaments = 0, total = 0 }
    local function err(text) r.errors[#r.errors + 1] = text end
    local function warn(text) r.warnings[#r.warnings + 1] = text end
    local function add(rel)
        local size = lfs.attributes(root .. "/" .. rel, "size") or 0
        r.total = r.total + size
        if size > M.MAX_FILE then
            err(T(_("%1 is too big (over 25 MB)."), rel))
        end
        r.files[#r.files + 1] = rel
    end

    -- The ornaments, beside theme/.
    for _i, name in ipairs(listDir(root)) do
        local path = root .. "/" .. name
        local e = ext(name)
        if name:sub(1, 1) == "." or name == "theme" or not safeEntry(name) then
            -- Hidden files and the theme folder (read below).
        elseif isDir(path) then
            warn(T(_("The folder %1 is ignored: Bookshelf reads ornaments beside theme/ only."), name))
        elseif e == "svg" then
            local text = readFile(path, 65536) or ""
            if not text:find("<svg", 1, true) then
                err(T(_("%1 is not an SVG drawing."), name))
            else
                if not text:find("viewBox", 1, true) and not text:match("<svg[^>]-width") then
                    warn(T(_("%1 has no viewBox: Bookshelf may not know its shape."), name))
                end
                r.ornaments = r.ornaments + 1
                add(name)
            end
        elseif e == "png" then
            if not pngSize(path) then
                err(T(_("%1 is not a PNG picture."), name))
            else
                r.ornaments = r.ornaments + 1
                add(name)
            end
        elseif name:lower() == "ornaments.json" then
            if decodeJson(path) then
                add(name)
            else
                err(_("ornaments.json is not valid JSON."))
            end
        else
            warn(T(_("%1 is ignored (ornaments are SVG or PNG)."), name))
        end
    end

    -- theme/: the manifest, the colours, the wallpaper, the planks.
    local tdir = root .. "/theme"
    local manifest, manifest_file
    local planks = {}
    if isDir(tdir) then
        for _i, name in ipairs(listDir(tdir)) do
            local path = tdir .. "/" .. name
            local rel = "theme/" .. name
            local lower = name:lower()
            local stem = lower:match("^(.-)%.[^%.]+$")
            local e = ext(name)
            if name:sub(1, 1) == "." or not safeEntry(name) then
                -- Hidden: skipped.
            elseif isDir(path) then
                warn(T(_("The folder theme/%1 is ignored."), name))
            elseif lower == "theme.json" then
                manifest_file = true
                manifest = decodeJson(path)
                if not manifest or manifest[1] ~= nil then
                    err(_("theme/theme.json is not a valid JSON object."))
                    manifest = nil
                else
                    if manifest.shelf ~= nil and manifest.shelf ~= "light" and manifest.shelf ~= "dark" then
                        warn(_("theme.json: \"shelf\" must be \"light\" or \"dark\"; Bookshelf will ignore it."))
                    end
                    if manifest.name ~= nil and (type(manifest.name) ~= "string" or manifest.name == "") then
                        warn(_("theme.json: \"name\" should be some text; the folder's name is used."))
                    end
                    add(rel)
                end
            elseif lower == "colours.json" or lower == "colors.json" then
                local doc = decodeJson(path)
                if lower == "colors.json" then
                    err(_("The colors file must be called colours.json (British spelling) for Bookshelf to read it."))
                elseif not doc or (type(doc.day) ~= "table" and type(doc.night) ~= "table") then
                    err(_("theme/colours.json must be a JSON object with \"day\" and/or \"night\" colours."))
                else
                    local skipped, count = {}, 0
                    for _j, look in ipairs({ "day", "night" }) do
                        if type(doc[look]) == "table" then
                            for key, hex in pairs(doc[look]) do
                                local known = type(key) == "string" and M.COLOUR_NAMES[key:lower()]
                                if known and type(hex) == "string" and hex:match("^#%x%x%x%x%x%x$") then
                                    count = count + 1
                                else
                                    skipped[#skipped + 1] = look .. "/" .. tostring(key)
                                end
                            end
                        end
                    end
                    if #skipped > 0 then
                        table.sort(skipped)
                        warn(T(_("colours.json: Bookshelf will skip %1 (unknown name, or not #RRGGBB)."),
                            table.concat(skipped, ", ")))
                    end
                    r.colours = count
                    add(rel)
                end
            elseif stem and M.WALL_STEMS[stem] and M.WALL_EXTS[e] then
                local kind = imageKind(path)
                if not kind then
                    err(T(_("theme/%1 is not a picture."), name))
                elseif (kind == "jpeg") ~= (e == "jpg" or e == "jpeg") or (kind ~= "jpeg" and kind ~= e) then
                    err(T(_("theme/%1 is a %2 picture: its name must end in .%3."), name, kind:upper(),
                        kind == "jpeg" and "jpg" or kind))
                else
                    r.wallpaper = true
                    add(rel)
                end
            elseif lower:match("^plank%.") then
                local pname, part = lower:match("^plank%.(.-)%.?(%a+)%.png$")
                if pname and pname:sub(-1) == "." then
                    pname = pname:sub(1, -2)
                end
                if not part or (part ~= "middle" and part ~= "left" and part ~= "right") or e ~= "png" then
                    err(T(_("theme/%1: plank pictures are named plank[.name].middle.png, .left.png or .right.png."), name))
                else
                    local w, h = pngSize(path)
                    if not w then
                        err(T(_("theme/%1 is not a PNG picture."), name))
                    else
                        planks[pname] = planks[pname] or {}
                        planks[pname][part] = { name = name, h = h }
                        add(rel)
                    end
                end
            else
                warn(T(_("theme/%1 is ignored: Bookshelf does not use it."), name))
            end
        end
    end
    for pname, parts in pairs(planks) do
        local label = pname == "" and _("The plank") or T(_("The plank \"%1\""), pname)
        if not parts.middle then
            err(T(_("%1 has no middle picture (plank…middle.png), which Bookshelf needs."), label))
        else
            r.planks = r.planks + 1
            local h = parts.middle.h
            for _j, side in ipairs({ "left", "right" }) do
                if parts[side] and parts[side].h ~= h then
                    err(T(_("%1: %2 is not as tall as the middle picture (%3 px)."), label, parts[side].name, h))
                end
            end
            if h % 3 ~= 0 then
                warn(T(_("%1 is %2 px tall: Bookshelf cuts it in three equal bands (above, the plank, below), so a height divisible by 3 lines up best."), label, h))
            end
        end
    end

    if r.ornaments == 0 and r.planks == 0 and not r.wallpaper and not manifest then
        err(_("Nothing Bookshelf uses was found: a theme folder (theme.json, a wallpaper, plank pictures) or SVG/PNG ornaments."))
    elseif not manifest_file and isDir(tdir) then
        warn(_("There is no theme/theme.json: Bookshelf names the theme after its folder."))
    elseif not manifest and r.ornaments > 0 and not r.wallpaper then
        warn(_("There is no theme folder: Bookshelf adds these as ornaments, not as a theme."))
    end
    if r.total > M.MAX_TOTAL then
        err(_("The theme is too big (over 80 MB)."))
    end

    local name = manifest and type(manifest.name) == "string" and manifest.name ~= "" and manifest.name
        or fallback_name or root:match("([^/]+)$") or "Theme"
    r.name = name
    r.ok = #r.errors == 0
    return r
end

-- A folder name for [name] under Bookshelf's folder: safe characters, not one of Bookshelf's
-- own names, and not a folder that is already there (unless it is the reader's earlier import of
-- the same name, which is replaced).
function M.folderFor(name)
    local base = name:gsub("[/\\:*?\"<>|%c]", "_"):gsub("^[%s%.]+", ""):gsub("%s+$", "")
    if base == "" then
        base = "Theme"
    end
    if M.RESERVED[base:lower()] then
        base = base .. " theme"
    end
    local folder, n = base, 1
    while isDir(M.root() .. "/" .. folder) and not isFile(M.root() .. "/" .. folder .. "/" .. M.IMPORTED) do
        n = n + 1
        folder = T("%1 (%2)", base, n)
    end
    return folder
end

-- Copies a checked pack into Bookshelf's folder. Returns the folder's name, or nil.
function M.installChecked(root, report)
    if not mkdirs(M.root()) then
        return nil
    end
    local folder = M.folderFor(report.name)
    local dest = M.root() .. "/" .. folder
    removeMarked(dest, M.IMPORTED)
    for _i, rel in ipairs(report.files) do
        if not copyFile(root .. "/" .. rel, dest .. "/" .. rel) then
            removeTree(dest)
            return nil
        end
    end
    writeMark(dest .. "/" .. M.IMPORTED, report.name, report.files)
    M.refresh()
    return folder
end

-- Where a zip is unpacked before it is checked.
function M.stagingDir()
    return DataStorage:getDataDir() .. "/cache/babel-theme-import"
end

-- Unpacks (a .zip) and checks [path]. Returns the report and the folder that holds the pack (to
-- give to installChecked, then cleanUp), or nil and why.
function M.prepare(path)
    local name = path:match("([^/]+)/*$") or path
    if isDir(path) then
        local root = M.packRoot(path)
        return M.check(root, name), root
    end
    if ext(path) ~= "zip" then
        return nil, _("Choose a theme's folder or a .zip file.")
    end
    local staging = M.stagingDir()
    removeTree(staging)
    local ok, why = M.unzip(path, staging)
    if not ok then
        removeTree(staging)
        return nil, T(_("Could not unpack %1: %2."), name, why or "?")
    end
    local root = M.packRoot(staging)
    return M.check(root, name:gsub("%.[Zz][Ii][Pp]$", "")), root
end

function M.cleanUp()
    removeTree(M.stagingDir())
end

-- The packs the reader added through the plugin: { {folder, name} }.
function M.imported()
    local out = {}
    for _i, folder in ipairs(listDir(M.root())) do
        local mark = readMark(M.root() .. "/" .. folder .. "/" .. M.IMPORTED)
        if mark then
            out[#out + 1] = { folder = folder, name = mark.version or folder }
        end
    end
    return out
end

function M.removeImported(folder)
    local done = removeMarked(M.root() .. "/" .. folder, M.IMPORTED)
    M.refresh()
    return done
end

-- For the tests.
M._safeEntry = safeEntry

return M
