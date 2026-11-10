--[[
Random sleep and power-off screens on BOOX e-readers.

On a BOOX it is the system, not KOReader, that draws the sleep screen and the power-off screen:
KOReader's own screensaver settings (and Storefront's "Random from folder", which sets them) have
no effect there. The BOOX system app (com.onyx) takes a new image from any app through the
broadcast `onyx.action.SCREENSAVER`, with the extras:

  type             int     16: the sleep image, 17: the power-off image
  file             string  the image's path (png, jpg, jpeg or bmp, under 10 MB)
  show_result_hint boolean false: no "set" message

This is what BOOX's own "Set as screensaver" does (checked on a Go Color 7, firmware 4.2). Setting
the sleep image this way replaces BOOX's own rotation list with this single image.

So each time the e-reader wakes up with KOReader open (and when KOReader starts), Babel draws
an image at random from a folder (by default the one Storefront and KOReader use) and hands it
to BOOX for the next sleep, and another one for the next power-off.
--]]

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Boox = {}

Boox.SLEEP = 16
Boox.POWER_OFF = 17

-- What BOOX shows (it skips images over 10 MB).
local MAX_SIZE = 10 * 1024 * 1024
local DEPTH = 3

local function lower(s)
    return (s or ""):lower()
end

-- Whether this is a BOOX (Onyx) running Android.
function Boox.isBoox()
    local ok, Device = pcall(require, "device")
    if not ok or not Device.isAndroid or not Device:isAndroid() then
        return false
    end
    local ok_android, android = pcall(require, "android")
    if not ok_android then
        return false
    end
    local prop = android.prop or {}
    for _i, value in ipairs({ prop.manufacturer, prop.brand, prop.model, prop.product }) do
        local v = lower(value)
        if v:find("onyx", 1, true) or v:find("boox", 1, true) then
            return true
        end
    end
    local ok_pkg, enabled = pcall(android.isPackageEnabled, "com.onyx")
    return ok_pkg and enabled == true
end

-- The folder KOReader's screensaver (and Storefront) use.
function Boox.defaultFolder()
    local dir = G_reader_settings and G_reader_settings:readSetting("screensaver_dir")
    if dir and lfs.attributes(dir, "mode") == "directory" then
        return dir
    end
    return DataStorage:getDataDir() .. "/screensavers"
end

function Boox.isImage(name)
    local n = lower(name)
    return (n:match("%.png$") or n:match("%.jpe?g$") or n:match("%.bmp$")) ~= nil
end

-- The images BOOX can show in [folder] and its subfolders (hidden files left out).
function Boox.images(folder)
    local found = {}
    local function scan(dir, depth)
        local ok, iter, state = pcall(lfs.dir, dir)
        if not ok then
            return
        end
        for name in iter, state do
            if name:sub(1, 1) ~= "." then
                local path = dir .. "/" .. name
                local attr = lfs.attributes(path)
                if attr and attr.mode == "directory" and depth < DEPTH then
                    scan(path, depth + 1)
                elseif attr and attr.mode == "file" and Boox.isImage(name)
                    and attr.size > 0 and attr.size <= MAX_SIZE then
                    found[#found + 1] = path
                end
            end
        end
    end
    scan(folder, 1)
    table.sort(found)
    return found
end

-- One image at random, other than those in [avoid] when there are enough to choose from.
function Boox.pick(images, avoid, random)
    random = random or math.random
    if #images == 0 then
        return nil
    end
    local skip = {}
    for _i, path in ipairs(avoid or {}) do
        if path then
            skip[path] = true
        end
    end
    local pool = {}
    for _i, path in ipairs(images) do
        if not skip[path] then
            pool[#pool + 1] = path
        end
    end
    if #pool == 0 then
        pool = images
    end
    return pool[random(#pool)]
end

-- Sends `onyx.action.SCREENSAVER` from KOReader's activity. Returns true when Android took it.
local function broadcastJni(kind, path)
    local android = require("android")
    local ffi = require("ffi")
    return android.jni:context(android.app.activity.vm, function(jni)
        local env = jni.env
        local refs = {}
        local function keep(ref)
            refs[#refs + 1] = ref
            return ref
        end
        local function str(s)
            return keep(env[0].NewStringUTF(env, s))
        end
        local intent_class = keep(env[0].FindClass(env, "android/content/Intent"))
        local init = env[0].GetMethodID(env, intent_class, "<init>", "(Ljava/lang/String;)V")
        local intent = keep(env[0].NewObject(env, intent_class, init, str("onyx.action.SCREENSAVER")))
        -- putExtra returns the intent again (a new local reference).
        keep(jni:callObjectMethod(intent, "putExtra", "(Ljava/lang/String;I)Landroid/content/Intent;",
            str("type"), ffi.new("int32_t", kind)))
        keep(jni:callObjectMethod(intent, "putExtra", "(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;",
            str("file"), str(path)))
        keep(jni:callObjectMethod(intent, "putExtra", "(Ljava/lang/String;Z)Landroid/content/Intent;",
            str("show_result_hint"), ffi.new("int32_t", 0)))
        jni:callVoidMethod(android.app.activity.clazz, "sendBroadcast", "(Landroid/content/Intent;)V", intent)
        local failed = env[0].ExceptionCheck(env) ~= 0
        if failed then
            env[0].ExceptionClear(env)
        end
        for i = #refs, 1, -1 do
            if refs[i] ~= nil then
                env[0].DeleteLocalRef(env, refs[i])
            end
        end
        return not failed
    end)
end

-- The same through Android's `am` command, in case the first way fails.
local function broadcastAm(kind, path)
    local android = require("android")
    return android.execute("am", "broadcast", "-a", "onyx.action.SCREENSAVER",
        "--ei", "type", tostring(kind), "--es", "file", path,
        "--ez", "show_result_hint", "false") == 0
end

-- Hands [path] to BOOX as its sleep (Boox.SLEEP) or power-off (Boox.POWER_OFF) image.
function Boox.set(kind, path)
    local ok, sent = pcall(broadcastJni, kind, path)
    if ok and sent then
        return true
    end
    logger.warn("Babel: BOOX screen broadcast failed, trying am", sent)
    local ok_am, sent_am = pcall(broadcastAm, kind, path)
    if ok_am and sent_am then
        return true
    end
    logger.warn("Babel: BOOX screen not set", sent_am)
    return false
end

--[[
Draws and sets new images. [options]:
  folder     the collection
  sleep      change the sleep image
  power_off  change the power-off image
  last       { sleep = path, power_off = path }: the images set last time, not drawn again
Returns { sleep = path, power_off = path } (what was set) and the number of images found.
--]]
function Boox.rotate(options, random)
    local images = Boox.images(options.folder)
    local last = options.last or {}
    local set = {}
    if #images == 0 then
        return set, 0
    end
    if options.sleep then
        local path = Boox.pick(images, { last.sleep }, random)
        if path and Boox.set(Boox.SLEEP, path) then
            set.sleep = path
        end
    end
    if options.power_off then
        local path = Boox.pick(images, { last.power_off, set.sleep }, random)
        if path and Boox.set(Boox.POWER_OFF, path) then
            set.power_off = path
        end
    end
    return set, #images
end

return Boox
