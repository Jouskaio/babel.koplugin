--[[
Babel: sends KOReader's reading statistics to your Babel server.

It reads statistics.sqlite3 (what the "Reading statistics" plugin records) and sends, for each
book, how long and how many pages you read each day. Babel adds them to your own statistics
(reading time, reading days, streaks). It uses the server address and the login of KOReader's
"Progress sync" plugin: set that up first (Tools > Progress sync > Custom sync server).

It also brings your books to the e-reader: the ones marked "On my e-reader" in Babel (or the whole
library) are downloaded into a "Babel" folder, one after the other, when the e-reader goes online.

Menu: Tools > Babel.
--]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local JSON = require("json")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ltn12 = require("ltn12")
local logger = require("logger")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")
local T = require("ffi/util").template

local DAY = 24 * 60 * 60

-- What this e-reader is called in Babel: anything the plugin does shows it as connected.
local function deviceName()
    local ok, device = pcall(require, "device")
    return ok and device.model or "e-reader"
end

local Babel = WidgetContainer:extend{
    name = "babel",
    is_doc_only = false,
}

function Babel:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/babel.lua")
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- One-tap actions: they can be put in a gesture, a profile or the Bookshelf start menu
-- ("System action...").
function Babel:onDispatcherRegisterActions()
    Dispatcher:registerAction("babel_send_stats", {
        category = "none", event = "BabelSendStats", general = true,
        title = _("Babel: send reading statistics"),
    })
    Dispatcher:registerAction("babel_download", {
        category = "none", event = "BabelDownload", general = true,
        title = _("Babel: download my books"),
    })
    Dispatcher:registerAction("babel_send_books", {
        category = "none", event = "BabelSendBooks", general = true,
        title = _("Babel: send the e-reader's books"),
    })
end

function Babel:onBabelSendStats()
    NetworkMgr:runWhenOnline(function()
        self:upload(true)
    end)
    return true
end

function Babel:onBabelDownload()
    NetworkMgr:runWhenOnline(function()
        self:download(true)
    end)
    return true
end

function Babel:onBabelSendBooks()
    NetworkMgr:runWhenOnline(function()
        self:sendBooks(true)
    end)
    return true
end

-- The server and the login of the Progress sync plugin.
function Babel:login()
    -- Progress sync keeps them in kosync.lua, under the "settings" table.
    local sync = LuaSettings:open(DataStorage:getSettingsDir() .. "/kosync.lua")
    local conf = sync:readSetting("settings")
    if type(conf) ~= "table" then
        conf = {
            custom_server = sync:readSetting("custom_server"),
            username = sync:readSetting("username"),
            userkey = sync:readSetting("userkey"),
        }
    end
    local server, user, key = conf.custom_server, conf.username, conf.userkey
    if not server or server == "" or not user or not key then
        local seen = {}
        for name in pairs(sync.data or {}) do
            seen[#seen + 1] = tostring(name)
        end
        return nil, string.format(
            "%s (server %s, e-mail %s, key %s; found: %s)",
            sync.file or "kosync.lua",
            server and "ok" or "missing",
            user and "ok" or "missing",
            key and "ok" or "missing",
            #seen > 0 and table.concat(seen, ", ") or "nothing"
        )
    end
    return (server:gsub("/+$", "")), user, key
end

-- Midnight (local time) of the day [days] before [from].
local function midnight(from, days)
    local t = os.date("*t", from - days * DAY)
    t.hour, t.min, t.sec = 0, 0, 0
    return os.time(t)
end

-- Books and days read since [since] (a timestamp), from the statistics database.
function Babel:collect(since)
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn = SQ3.open(path, "ro")
    local books, days = {}, {}
    local ok, err = pcall(function()
        local res = conn:exec([[
            SELECT md5, COALESCE(title, ''), COALESCE(authors, ''), COALESCE(pages, 0),
                   COALESCE(last_open, 0), COALESCE(total_read_time, 0),
                   COALESCE(total_read_pages, 0)
            FROM book WHERE md5 IS NOT NULL AND md5 != '']])
        if res and res[1] then
            for i = 1, #res[1] do
                books[#books + 1] = {
                    md5 = res[1][i],
                    title = res[2][i],
                    authors = res[3][i],
                    pages = tonumber(res[4][i]) or 0,
                    last_open = tonumber(res[5][i]) or 0,
                    total_read_time = tonumber(res[6][i]) or 0,
                    total_read_pages = tonumber(res[7][i]) or 0,
                }
            end
        end
        res = conn:exec(string.format([[
            SELECT b.md5, strftime('%%Y-%%m-%%d', p.start_time, 'unixepoch', 'localtime'),
                   SUM(p.duration), COUNT(DISTINCT p.page)
            FROM page_stat_data p JOIN book b ON b.id = p.id_book
            WHERE p.start_time >= %d AND b.md5 IS NOT NULL AND b.md5 != ''
            GROUP BY b.md5, 2]], since))
        if res and res[1] then
            for i = 1, #res[1] do
                local seconds = tonumber(res[3][i]) or 0
                if seconds > 0 then
                    days[#days + 1] = {
                        md5 = res[1][i],
                        day = res[2][i],
                        seconds = math.min(seconds, DAY),
                        pages = tonumber(res[4][i]) or 0,
                    }
                end
            end
        end
    end)
    conn:close()
    if not ok then
        logger.warn("Babel: could not read the statistics", err)
        return nil, err
    end
    return books, days
end

-- Sends the statistics. [verbose]: tell the reader how it went (a manual send).
function Babel:upload(verbose)
    local function say(text)
        if verbose then
            UIManager:show(InfoMessage:new{ text = text })
        end
    end
    local server, user, key = self:login()
    if not server then
        say(_("Set up Progress sync first (Tools > Progress sync > Custom sync server), with the address, e-mail and password from Babel.") .. "\n\nBabel plugin 3: " .. tostring(user))
        return
    end
    local last = self.settings:readSetting("last_upload")
    -- A little before the last send, from midnight: a day is always sent whole.
    local since = last and midnight(last, 2) or 0
    local books, days = self:collect(since)
    if not books then
        say(_("Could not read the reading statistics. Is the Reading statistics plugin enabled?"))
        return
    end
    if #books == 0 then
        say(_("No reading statistics yet. Read a book for a while, then try again."))
        return
    end
    local body = JSON.encode({ books = books, days = days, device = deviceName() })
    local url = server .. "/syncs/stats"
    local request = url:match("^https") and require("ssl.https").request
        or require("socket.http").request
    local sink = {}
    socketutil:set_timeout(15, 90)
    local code = socket.skip(1, request{
        url = url,
        method = "PUT",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["Accept"] = "application/vnd.koreader.v1+json",
            ["x-auth-user"] = user,
            ["x-auth-key"] = key,
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code == 200 then
        self.settings:saveSetting("last_upload", os.time())
        self.settings:flush()
        say(T(_("Sent to Babel: %1 books, %2 days of reading."), #books, #days))
    elseif code == 401 then
        say(_("Babel refused the login. Check the e-mail and the KOReader password in Progress sync."))
    else
        logger.warn("Babel: upload failed", code, table.concat(sink))
        say(T(_("Could not send the statistics to Babel (%1)."), tostring(code)))
    end
end

-- The request function for an address: https needs its own module.
local function requester(url)
    return url:match("^https") and require("ssl.https").request or require("socket.http").request
end

-- The server's answer as a table, or nil and the HTTP code.
function Babel:getJson(path)
    local server, user, key = self:login()
    if not server then
        return nil, "login"
    end
    path = path .. (path:find("?", 1, true) and "&" or "?") .. "device=" .. require("socket.url").escape(deviceName())
    local sink = {}
    socketutil:set_timeout(15, 60)
    local code = socket.skip(1, requester(server)({
        url = server .. path,
        method = "GET",
        headers = { ["Accept"] = "application/vnd.koreader.v1+json", ["x-auth-user"] = user, ["x-auth-key"] = key },
        sink = ltn12.sink.table(sink),
    }))
    socketutil:reset_timeout()
    if code ~= 200 then
        return nil, code
    end
    local ok, data = pcall(JSON.decode, table.concat(sink))
    return ok and data or nil, ok and 200 or "json"
end

-- Where the books go: a "Babel" folder in KOReader's home folder.
function Babel:downloadDir()
    local dir = self.settings:readSetting("download_dir")
    if not dir then
        local home = G_reader_settings:readSetting("home_dir") or "/sdcard/Books"
        dir = home .. "/Babel"
    end
    return dir
end

local function safeName(name)
    return (name:gsub("[/\\:*?\"<>|%c]", "_"))
end

-- Downloads one book to [path] (through a temporary file, so a failure leaves nothing half-written).
function Babel:fetchBook(book, path)
    local server, user, key = self:login()
    local tmp = path .. ".part"
    local file = io.open(tmp, "wb")
    if not file then
        return false
    end
    socketutil:set_timeout(15, 900)
    local code = socket.skip(1, requester(server)({
        url = server .. "/library/files/" .. book.sha256 .. "?device=" .. require("socket.url").escape(deviceName()),
        method = "GET",
        headers = { ["x-auth-user"] = user, ["x-auth-key"] = key },
        sink = ltn12.sink.file(file),
    }))
    socketutil:reset_timeout()
    if code == 200 and lfs.attributes(tmp, "size") == book.size then
        os.rename(tmp, path)
        local mine = self.settings:readSetting("downloaded") or {}
        mine[book.sha256] = path
        self.settings:saveSetting("downloaded", mine)
        self.settings:flush()
        return true
    end
    os.remove(tmp)
    logger.warn("Babel: could not download", book.name, code)
    return false
end

-- Removes the books this plugin downloaded that are no longer on the list (finished, or taken
-- off "On my e-reader"), when the reader asked for it. Never touches a file it did not download.
function Babel:cleanUp(books, verbose)
    if self.settings:readSetting("cleanup") ~= true then
        return
    end
    local wanted = {}
    for _i, book in ipairs(books) do
        wanted[book.sha256] = true
    end
    local mine = self.settings:readSetting("downloaded") or {}
    local removed = 0
    for sha, path in pairs(mine) do
        if not wanted[sha] then
            if lfs.attributes(path, "mode") == "file" then
                os.remove(path)
                removed = removed + 1
            end
            mine[sha] = nil
        end
    end
    self.settings:saveSetting("downloaded", mine)
    self.settings:flush()
    if removed > 0 and verbose then
        UIManager:show(InfoMessage:new{ text = T(_("%1 books removed from the e-reader."), removed), timeout = 4 })
    end
end

-- Brings the books of the library missing from the e-reader, one per tick so the screen stays alive.
-- [verbose]: tell the reader how it went (a manual download).
function Babel:download(verbose)
    if self.downloading then
        return
    end
    local scope = self.settings:readSetting("download_scope") or "ereader"
    local data, code = self:getJson("/library?scope=" .. scope)
    if not data then
        if verbose then
            UIManager:show(InfoMessage:new{
                text = code == "login"
                    and _("Set up Progress sync first (Tools > Progress sync > Custom sync server), with the address, e-mail and password from Babel.")
                    or T(_("Could not reach Babel (%1)."), tostring(code)),
            })
        end
        return
    end
    local dir = self:downloadDir()
    lfs.mkdir(dir)
    self:cleanUp(data.books or {}, verbose)
    local queue = {}
    for _i, book in ipairs(data.books or {}) do
        local path = dir .. "/" .. safeName(book.name)
        if lfs.attributes(path, "size") ~= book.size then
            queue[#queue + 1] = { book = book, path = path }
        end
    end
    if #queue == 0 then
        if verbose then
            UIManager:show(InfoMessage:new{ text = _("Your Babel books are all on the e-reader.") })
        end
        return
    end
    self.downloading = true
    local done, failed, index = 0, 0, 0
    local notice
    local function step()
        if notice then
            UIManager:close(notice)
        end
        index = index + 1
        local job = queue[index]
        if not job then
            self.downloading = false
            local FileManager = require("apps/filemanager/filemanager")
            if FileManager.instance then
                FileManager.instance:onRefresh()
            end
            UIManager:show(InfoMessage:new{
                text = failed == 0 and T(_("%1 books downloaded from Babel."), done)
                    or T(_("%1 books downloaded from Babel, %2 failed."), done, failed),
                timeout = 5,
            })
            return
        end
        notice = InfoMessage:new{
            text = T(_("Downloading from Babel (%1/%2): %3"), index, #queue, job.book.name),
        }
        UIManager:show(notice)
        UIManager:forceRePaint()
        UIManager:scheduleIn(0.2, function()
            if self:fetchBook(job.book, job.path) then
                done = done + 1
            else
                failed = failed + 1
            end
            step()
        end)
    end
    step()
end

-- Sends a JSON body with PUT; returns the HTTP code (nil when the network failed).
function Babel:putJson(path, body)
    local server, user, key = self:login()
    if not server then
        return "login"
    end
    local payload = JSON.encode(body)
    local sink = {}
    socketutil:set_timeout(15, 60)
    local code = socket.skip(1, requester(server)({
        url = server .. path,
        method = "PUT",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#payload),
            ["Accept"] = "application/vnd.koreader.v1+json",
            ["x-auth-user"] = user,
            ["x-auth-key"] = key,
        },
        source = ltn12.source.string(payload),
        sink = ltn12.sink.table(sink),
    }))
    socketutil:reset_timeout()
    return code
end

-- Tells the reader whether the e-reader can reach Babel and is logged in.
function Babel:testConnection()
    local server, user = self:login()
    if not server then
        UIManager:show(InfoMessage:new{
            text = _("Set up Progress sync first (Tools > Progress sync > Custom sync server), with the address, e-mail and password from Babel."),
        })
        return
    end
    local data, code = self:getJson("/users/auth")
    local text
    if data then
        text = T(_("Connected to Babel as %1."), user)
    elseif code == 401 then
        text = _("Babel refused the login. Log in again in Progress sync with your e-mail and the KOReader password made in Babel (Account > KOReader).")
    elseif code == nil or code == "timeout" then
        text = T(_("Could not reach %1. Check that the e-reader is online and the address is right."), server)
    else
        text = T(_("Babel answered with an error (%1)."), tostring(code))
    end
    UIManager:show(InfoMessage:new{ text = text })
end

-- What this book says about being finished and about its highlights, read before it closes.
function Babel:readBook()
    local ok, book = pcall(function()
        local document = self.ui.document
        if not document then
            return nil
        end
        local md5 = document.fastDigest and document:fastDigest()
        if not md5 then
            return nil
        end
        local summary = self.ui.doc_settings and self.ui.doc_settings:readSetting("summary") or {}
        local pages = document.getPageCount and document:getPageCount() or 0
        local notes = {}
        local list = self.ui.annotation and self.ui.annotation.annotations or {}
        for _i, a in ipairs(list) do
            if a.text and a.text ~= "" then
                notes[#notes + 1] = {
                    text = a.text,
                    note = a.note,
                    datetime = a.datetime,
                    percent = (pages > 0 and tonumber(a.pageno)) and (a.pageno / pages * 100) or nil,
                }
            end
        end
        return { md5 = md5, finished = summary.status == "complete", notes = notes }
    end)
    return ok and book or nil
end

-- Sends a closed book's finished state and highlights (the ones already sent are ignored by Babel).
function Babel:syncBook(book)
    local device = require("device").model or "e-reader"
    if book.finished and self.settings:readSetting("sync_finished") ~= false then
        self:putJson("/syncs/finished", { document = book.md5, device = device })
    end
    if #book.notes > 0 and self.settings:readSetting("sync_notes") ~= false then
        self:putJson("/syncs/annotations", { document = book.md5, device = device, annotations = book.notes })
    end
end

-- Books on the e-reader (in KOReader's home folder, except the Babel folder) that Babel lacks.
local BOOK_EXTENSIONS = { epub = true, pdf = true, cbz = true, cbr = true }
local MAX_BOOK_BYTES = 300 * 1024 * 1024

function Babel:findBooks(dir, found, skip)
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." and not name:match("%.sdr$") then
            local path = dir .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" and path ~= skip then
                self:findBooks(path, found, skip)
            elseif attr and attr.mode == "file" then
                local ext = name:match("%.(%w+)$")
                if ext and BOOK_EXTENSIONS[ext:lower()] and attr.size > 0 and attr.size <= MAX_BOOK_BYTES then
                    found[#found + 1] = { path = path, name = name, size = attr.size }
                end
            end
        end
    end
    return found
end

-- Sends Babel the e-reader's books it does not have; Babel marks them "On my e-reader".
-- One book per tick so the screen stays alive.
function Babel:sendBooks(verbose)
    if self.sending then
        return
    end
    local server, user, key = self:login()
    if not server then
        if verbose then
            UIManager:show(InfoMessage:new{
                text = _("Set up Progress sync first (Tools > Progress sync > Custom sync server), with the address, e-mail and password from Babel."),
            })
        end
        return
    end
    local home = G_reader_settings:readSetting("home_dir") or "/sdcard/Books"
    local books = {}
    pcall(function()
        self:findBooks(home, books, self:downloadDir())
    end)
    local util = require("util")
    local byDocument, documents = {}, {}
    for _i, book in ipairs(books) do
        local ok, md5 = pcall(util.partialMD5, book.path)
        if ok and md5 then
            byDocument[md5] = book
            documents[#documents + 1] = md5
        end
    end
    local queue = {}
    for first = 1, #documents, 200 do
        local batch = {}
        for i = first, math.min(first + 199, #documents) do
            batch[#batch + 1] = documents[i]
        end
        local payload = JSON.encode({ documents = batch, device = deviceName() })
        local sink = {}
        socketutil:set_timeout(15, 60)
        local code = socket.skip(1, requester(server)({
            url = server .. "/library/missing",
            method = "POST",
            headers = {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#payload),
                ["x-auth-user"] = user,
                ["x-auth-key"] = key,
            },
            source = ltn12.source.string(payload),
            sink = ltn12.sink.table(sink),
        }))
        socketutil:reset_timeout()
        if code ~= 200 then
            if verbose then
                UIManager:show(InfoMessage:new{ text = T(_("Could not reach Babel (%1)."), tostring(code)) })
            end
            return
        end
        local ok, data = pcall(JSON.decode, table.concat(sink))
        for _i, md5 in ipairs(ok and data and data.missing or {}) do
            if byDocument[md5] then
                queue[#queue + 1] = byDocument[md5]
            end
        end
    end
    if #queue == 0 then
        if verbose then
            UIManager:show(InfoMessage:new{ text = _("Babel already has all the books of this e-reader.") })
        end
        return
    end
    self.sending = true
    local done, failed, index = 0, 0, 0
    local notice
    local function step()
        if notice then
            UIManager:close(notice)
        end
        index = index + 1
        local job = queue[index]
        if not job then
            self.sending = false
            UIManager:show(InfoMessage:new{
                text = failed == 0 and T(_("%1 books sent to Babel."), done)
                    or T(_("%1 books sent to Babel, %2 failed."), done, failed),
                timeout = 5,
            })
            return
        end
        notice = InfoMessage:new{ text = T(_("Sending to Babel (%1/%2): %3"), index, #queue, job.name) }
        UIManager:show(notice)
        UIManager:forceRePaint()
        UIManager:scheduleIn(0.2, function()
            local file = io.open(job.path, "rb")
            local code
            if file then
                socketutil:set_timeout(15, 900)
                code = socket.skip(1, requester(server)({
                    url = server .. "/library/upload?name=" .. require("socket.url").escape(job.name)
                        .. "&device=" .. require("socket.url").escape(deviceName()),
                    method = "PUT",
                    headers = {
                        ["Content-Type"] = "application/octet-stream",
                        ["Content-Length"] = tostring(job.size),
                        ["x-auth-user"] = user,
                        ["x-auth-key"] = key,
                    },
                    source = ltn12.source.file(file),
                    sink = ltn12.sink.null(),
                }))
                socketutil:reset_timeout()
            end
            if code == 200 then
                done = done + 1
            else
                failed = failed + 1
                logger.warn("Babel: could not send", job.name, code)
            end
            step()
        end)
    end
    step()
end

-- Online again: bring new books, at most once an hour.
function Babel:onNetworkConnected()
    if self.settings:readSetting("auto_download") == false then
        return
    end
    local last = self.settings:readSetting("last_download_check")
    if last and os.time() - last < 3600 then
        return
    end
    self.settings:saveSetting("last_download_check", os.time())
    self.settings:flush()
    UIManager:scheduleIn(5, function()
        self:download(false)
    end)
end

function Babel:onCloseDocument()
    local book = self:readBook()
    if book and (book.finished or #book.notes > 0) then
        UIManager:scheduleIn(8, function()
            if NetworkMgr:isConnected() then
                self:syncBook(book)
            end
        end)
    end
    if self.settings:readSetting("auto_upload") == false then
        return
    end
    -- A few seconds later, once the Reading statistics plugin has saved the session; and only
    -- when the e-reader is already online (nothing is switched on for this).
    UIManager:scheduleIn(5, function()
        if NetworkMgr:isConnected() then
            self:upload(false)
        end
    end)
end

function Babel:addToMainMenu(menu_items)
    menu_items.babel = {
        text = _("Babel"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Send reading statistics now"),
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        self:upload(true)
                    end)
                end,
            },
            {
                text = _("Send automatically when closing a book"),
                checked_func = function()
                    return self.settings:readSetting("auto_upload") ~= false
                end,
                callback = function()
                    local on = self.settings:readSetting("auto_upload") ~= false
                    self.settings:saveSetting("auto_upload", not on)
                    self.settings:flush()
                end,
            },
            {
                text = _("Download my Babel books now"),
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        self:download(true)
                    end)
                end,
            },
            {
                text = _("Send the e-reader's books to Babel"),
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        self:sendBooks(true)
                    end)
                end,
            },
            {
                text = _("Download new books when online"),
                checked_func = function()
                    return self.settings:readSetting("auto_download") ~= false
                end,
                callback = function()
                    local on = self.settings:readSetting("auto_download") ~= false
                    self.settings:saveSetting("auto_download", not on)
                    self.settings:flush()
                end,
            },
            {
                text = _("Download the whole library (not only the books marked \"On my e-reader\")"),
                checked_func = function()
                    return self.settings:readSetting("download_scope") == "all"
                end,
                callback = function()
                    local all = self.settings:readSetting("download_scope") == "all"
                    self.settings:saveSetting("download_scope", all and "ereader" or "all")
                    self.settings:flush()
                end,
            },
            {
                text_func = function()
                    return T(_("Download folder: %1"), self:downloadDir())
                end,
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{ text = self:downloadDir() })
                end,
            },
            {
                text = _("Remove finished books from the Babel folder"),
                checked_func = function()
                    return self.settings:readSetting("cleanup") == true
                end,
                callback = function()
                    local on = self.settings:readSetting("cleanup") == true
                    self.settings:saveSetting("cleanup", not on)
                    self.settings:flush()
                end,
            },
            {
                text = _("Tell Babel when I finish a book"),
                checked_func = function()
                    return self.settings:readSetting("sync_finished") ~= false
                end,
                callback = function()
                    local on = self.settings:readSetting("sync_finished") ~= false
                    self.settings:saveSetting("sync_finished", not on)
                    self.settings:flush()
                end,
            },
            {
                text = _("Send my highlights and notes to Babel"),
                checked_func = function()
                    return self.settings:readSetting("sync_notes") ~= false
                end,
                callback = function()
                    local on = self.settings:readSetting("sync_notes") ~= false
                    self.settings:saveSetting("sync_notes", not on)
                    self.settings:flush()
                end,
            },
            {
                text = _("Test the connection to Babel"),
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        self:testConnection()
                    end)
                end,
            },
            {
                text = _("Send everything again"),
                callback = function()
                    self.settings:delSetting("last_upload")
                    self.settings:flush()
                    NetworkMgr:runWhenOnline(function()
                        self:upload(true)
                    end)
                end,
            },
        },
    }
end

return Babel
