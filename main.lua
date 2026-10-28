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
    self.jobs = {}
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

-- One-tap actions: they can be put in a gesture, a profile or the Bookshelf start menu
-- ("System action...").
function Babel:onDispatcherRegisterActions()
    Dispatcher:registerAction("babel_sync", {
        category = "none", event = "BabelSync", general = true,
        title = _("Babel: sync"),
    })
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

function Babel:onBabelSync()
    NetworkMgr:runWhenOnline(function()
        self:syncAll(true)
    end)
    return true
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
        -- Where the last session of each book ended: the reader is about there. Optional (older
        -- statistics have no total page count), so a failure here costs nothing else.
        pcall(function()
            local last = conn:exec([[
                SELECT b.md5, p.page, COALESCE(p.total_pages, b.pages, 0)
                FROM page_stat_data p JOIN book b ON b.id = p.id_book
                WHERE b.md5 IS NOT NULL AND b.md5 != ''
                  AND p.start_time = (SELECT MAX(start_time) FROM page_stat_data WHERE id_book = p.id_book)]])
            if last and last[1] then
                local reached = {}
                for i = 1, #last[1] do
                    local page, total = tonumber(last[2][i]) or 0, tonumber(last[3][i]) or 0
                    if total > 0 and page > 0 then
                        reached[last[1][i]] = math.min(1, page / total)
                    end
                end
                for _i, book in ipairs(books) do
                    book.progress = reached[book.md5]
                end
            end
        end)
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
        return true, #books, #days
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

-- Downloads one book to [path] through a temporary file, so a failure leaves no half-written
-- book. A partial file is continued where it stopped (big comics rarely arrive in one go).
-- Runs in the background process: the caller records the result.
function Babel:fetchBook(book, path)
    local server, user, key = self:login()
    local tmp = path .. ".part"
    local have = lfs.attributes(tmp, "size") or 0
    if have >= book.size then
        os.remove(tmp)
        have = 0
    end
    local headers = { ["x-auth-user"] = user, ["x-auth-key"] = key }
    if have > 0 then
        headers["Range"] = "bytes=" .. have .. "-"
    end
    local file = io.open(tmp, have > 0 and "ab" or "wb")
    if not file then
        return false
    end
    socketutil:set_timeout(15, 900)
    local code = socket.skip(1, requester(server)({
        url = server .. "/library/files/" .. book.sha256 .. "?device=" .. require("socket.url").escape(deviceName()),
        method = "GET",
        headers = headers,
        sink = ltn12.sink.file(file),
    }))
    socketutil:reset_timeout()
    pcall(file.close, file)
    if code == 200 and have > 0 then
        -- The server sent everything again: start over.
        have = 0
        local whole = io.open(tmp, "rb")
        local size = whole and whole:seek("end") or 0
        if whole then
            whole:close()
        end
        if size > book.size then
            os.remove(tmp)
            return false
        end
    end
    if (code == 200 or code == 206) and lfs.attributes(tmp, "size") == book.size then
        os.rename(tmp, path)
        return true
    end
    if code ~= 206 and code ~= 200 then
        os.remove(tmp)
    end
    logger.warn("Babel: could not download", book.name, code)
    return false
end

-- Runs [work(report)] in a separate process, so the e-reader stays usable (and a crash there
-- cannot take KOReader down). [report(line)] sends a line back; the parent calls [on_tick(lines)]
-- while it runs and [on_done(lines)] at the end. Returns false when it could not start.
function Babel:background(work, on_tick, on_done)
    local ffiutil = require("ffi/util")
    local log = DataStorage:getSettingsDir() .. "/babel-job.log"
    os.remove(log)
    local pid = ffiutil.runInSubProcess(function()
        local function report(line)
            local f = io.open(log, "ab")
            if f then
                f:write((line:gsub("\n", " ")), "\n")
                f:close()
            end
        end
        local ok, err = pcall(work, report)
        if not ok then
            report("error\t" .. tostring(err))
        end
    end)
    if not pid then
        return false
    end
    local function lines()
        local out = {}
        local f = io.open(log, "rb")
        if f then
            for line in f:lines() do
                out[#out + 1] = line
            end
            f:close()
        end
        return out
    end
    local function poll()
        if ffiutil.isSubProcessDone(pid) then
            local all = lines()
            os.remove(log)
            on_done(all)
        else
            on_tick(lines())
            UIManager:scheduleIn(2, poll)
        end
    end
    UIManager:scheduleIn(2, poll)
    return true
end

-- The last "progress" line of a job: "Downloading from Babel (3/40): name".
local function lastProgress(lines, label)
    for i = #lines, 1, -1 do
        local n, total, _size, name = lines[i]:match("^progress\t(%d+)\t(%d+)\t(%d+)\t(.*)$")
        if n then
            return T(label, n, total, name)
        end
    end
end

local function countLines(lines)
    local done, failed, none = 0, 0, false
    for _i, line in ipairs(lines) do
        local kind = line:match("^(%a+)")
        if kind == "ok" then
            done = done + 1
        elseif kind == "fail" or kind == "error" then
            failed = failed + 1
        elseif kind == "none" then
            none = true
        end
    end
    return done, failed, none
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

-- Brings the books of the library missing from the e-reader, in the background.
-- [verbose]: tell the reader how it went (a manual download).
function Babel:download(verbose, finished)
    local function stop(done, failed)
        if finished then
            finished(done or 0, failed or 0)
        end
    end
    if self.downloading then
        return stop()
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
        return stop()
    end
    local dir = self:downloadDir()
    lfs.mkdir(dir)
    self:cleanUp(data.books or {}, verbose)
    local books = data.books or {}
    local Notification = require("ui/widget/notification")
    self.downloading = true
    self.jobs.download, self.jobs.downloadEnded = {}, false
    local started = self:background(function(report)
        -- A book already on the e-reader, wherever it is, is not downloaded a second time.
        local here = self:localIndex()
        local queue = {}
        for _i, book in ipairs(books) do
            local path = dir .. "/" .. safeName(book.name)
            local present = (book.md5 and book.md5 ~= "" and here[book.md5]) or lfs.attributes(path, "size") == book.size
            if not present then
                queue[#queue + 1] = { book = book, path = path }
            end
        end
        if #queue == 0 then
            report("none")
            return
        end
        for i, job in ipairs(queue) do
            report(("progress\t%d\t%d\t%d\t%s"):format(i, #queue, job.book.size or 0, (job.book.name:gsub("\t", " "))))
            if self:fetchBook(job.book, job.path) then
                report("ok\t" .. job.book.sha256 .. "\t" .. job.path)
            else
                report("fail\t" .. job.book.name)
            end
        end
    end, function(lines)
        self.jobs.download = lines
        if verbose then
            local text = lastProgress(lines, _("Downloading from Babel (%1/%2): %3"))
            if text then
                Notification:notify(text)
            end
        end
    end, function(lines)
        self.downloading = false
        self.jobs.download = lines
        self.jobs.downloadEnded = true
        local mine = self.settings:readSetting("downloaded") or {}
        for _i, line in ipairs(lines) do
            local sha, path = line:match("^ok\t([^\t]+)\t(.*)$")
            if sha then
                mine[sha] = path
            end
        end
        self.settings:saveSetting("downloaded", mine)
        self.settings:flush()
        local done, failed, none = countLines(lines)
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
        if not finished and (verbose or done + failed > 0) then
            UIManager:show(InfoMessage:new{
                text = none and _("Your Babel books are all on the e-reader.")
                    or failed == 0 and T(_("%1 books downloaded from Babel."), done)
                    or T(_("%1 books downloaded from Babel, %2 failed."), done, failed),
                timeout = 5,
            })
        end
        stop(done, failed)
    end)
    if not started then
        self.downloading = false
        return stop()
    end
    if verbose then
        Notification:notify(_("Downloading from Babel in the background…"))
    end
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

-- The reading progress of the books read lately (from KOReader's own records of each book):
-- Babel shows it, and its reader opens the book there. Only what changed since the last send is
-- sent, so an old position never overrides a newer one made elsewhere. Returns how many were sent.
function Babel:pushProgress()
    if self.settings:readSetting("sync_progress") == false then
        return 0
    end
    local ok, history = pcall(require, "readhistory")
    if not ok or not history or not history.hist then
        return 0
    end
    local util = require("util")
    local DocSettings = require("docsettings")
    local sent = self.settings:readSetting("progress_sent") or {}
    local count, looked = 0, 0
    local recent = os.time() - 60 * DAY
    for _i, entry in ipairs(history.hist) do
        looked = looked + 1
        if looked > 60 then
            break
        end
        local path = entry.file
        if path and (entry.time or 0) >= recent and lfs.attributes(path, "mode") == "file" then
            local done, found = pcall(function()
                local doc = DocSettings:open(path)
                local percent = doc:readSetting("percent_finished")
                if not percent or percent <= 0 then
                    return nil
                end
                local md5 = doc:readSetting("partial_md5_checksum") or util.partialMD5(path)
                local position = doc:readSetting("last_xpointer") or tostring(doc:readSetting("last_page") or "")
                return { md5 = md5, percent = percent, position = position }
            end)
            if done and found and found.md5 and math.abs((sent[found.md5] or -1) - found.percent) > 0.001 then
                local code = self:putJson("/syncs/progress", {
                    document = found.md5,
                    progress = found.position,
                    percentage = found.percent,
                    device = deviceName(),
                    device_id = deviceName(),
                })
                if code == 200 then
                    sent[found.md5] = found.percent
                    count = count + 1
                end
            end
        end
    end
    self.settings:saveSetting("progress_sent", sent)
    self.settings:flush()
    return count
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
local MAX_BOOK_BYTES = 1000 * 1024 * 1024

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

-- Sends Babel the e-reader's books it does not have, in the background; Babel marks them
-- "On my e-reader".
function Babel:sendBooks(verbose, finished)
    local function stop(done, failed)
        if finished then
            finished(done or 0, failed or 0)
        end
    end
    if self.sending then
        return stop()
    end
    local server, user, key = self:login()
    if not server then
        if verbose then
            UIManager:show(InfoMessage:new{
                text = _("Set up Progress sync first (Tools > Progress sync > Custom sync server), with the address, e-mail and password from Babel."),
            })
        end
        return stop()
    end
    local Notification = require("ui/widget/notification")
    self.sending = true
    self.jobs.send, self.jobs.sendEnded = {}, false
    local started = self:background(function(report)
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
                report("error\tcode " .. tostring(code))
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
            report("none")
            return
        end
        for i, job in ipairs(queue) do
            report(("progress\t%d\t%d\t%d\t%s"):format(i, #queue, job.size or 0, (job.name:gsub("\t", " "))))
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
                pcall(file.close, file)
            end
            report((code == 200 and "ok\t" or "fail\t") .. job.name)
        end
    end, function(lines)
        self.jobs.send = lines
        if verbose then
            local text = lastProgress(lines, _("Sending to Babel (%1/%2): %3"))
            if text then
                Notification:notify(text)
            end
        end
    end, function(lines)
        self.sending = false
        self.jobs.send = lines
        self.jobs.sendEnded = true
        local done, failed, none = countLines(lines)
        if not finished and (verbose or done + failed > 0) then
            UIManager:show(InfoMessage:new{
                text = none and _("Babel already has all the books of this e-reader.")
                    or failed == 0 and T(_("%1 books sent to Babel."), done)
                    or T(_("%1 books sent to Babel, %2 failed."), done, failed),
                timeout = 5,
            })
        end
        stop(done, failed)
    end)
    if not started then
        self.sending = false
        return stop()
    end
    if verbose then
        Notification:notify(_("Sending to Babel in the background…"))
    end
end

-- Every book of the e-reader by KOReader's identifier (partial md5): identifier -> list of paths.
function Babel:localIndex()
    local home = G_reader_settings:readSetting("home_dir") or "/sdcard/Books"
    local books = {}
    pcall(function()
        self:findBooks(home, books, nil)
    end)
    local util = require("util")
    local index = {}
    for _i, book in ipairs(books) do
        local ok, md5 = pcall(util.partialMD5, book.path)
        if ok and md5 then
            index[md5] = index[md5] or {}
            index[md5][#index[md5] + 1] = book.path
        end
    end
    return index
end

-- Removes from the Babel folder the copies of books that are also elsewhere on the e-reader
-- (the original is kept). Returns how many were removed.
function Babel:cleanDuplicates()
    local dir = self:downloadDir()
    local prefix = dir .. "/"
    local removed = 0
    local mine = self.settings:readSetting("downloaded") or {}
    for _md5, paths in pairs(self:localIndex()) do
        local inside, outside = {}, 0
        for _i, path in ipairs(paths) do
            if path:sub(1, #prefix) == prefix then
                inside[#inside + 1] = path
            else
                outside = outside + 1
            end
        end
        -- Kept: one copy somewhere. If the original is outside the Babel folder, every copy inside
        -- goes; if all copies are inside, only the extra ones go.
        local first = outside > 0 and 1 or 2
        for i = first, #inside do
            if os.remove(inside[i]) then
                removed = removed + 1
                for sha, path in pairs(mine) do
                    if path == inside[i] then
                        mine[sha] = nil
                    end
                end
            end
        end
    end
    self.settings:saveSetting("downloaded", mine)
    self.settings:flush()
    return removed
end

-- One button for everything: sends the reading statistics, sends the e-reader's books Babel lacks,
-- brings the books marked "On my e-reader" (leaving the ones already there), tidies the Babel
-- folder (copies of books that are elsewhere on the e-reader, finished books if asked), and says
-- in one message what happened.
function Babel:syncAll(verbose)
    if self.syncing then
        return
    end
    if not self:login() then
        if verbose then
            UIManager:show(InfoMessage:new{
                text = _("Set up Progress sync first (Tools > Progress sync > Custom sync server), with the address, e-mail and password from Babel."),
            })
        end
        return
    end
    self.syncing = true
    local report = {}
    local function finish()
        self.syncing = false
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
        if verbose then
            UIManager:show(InfoMessage:new{
                text = table.concat(report, "\n"),
                timeout = 8,
            })
        end
    end
    local ok, books, days = self:upload(false)
    if ok then
        report[#report + 1] = T(_("Statistics sent: %1 books, %2 days."), books, days)
    end
    local progressed = self:pushProgress()
    if progressed > 0 then
        report[#report + 1] = T(_("Reading progress sent: %1 books."), progressed)
    end
    self:sendBooks(false, function(sent, sendFailed)
        if sent > 0 or sendFailed > 0 then
            report[#report + 1] = T(_("Books sent to Babel: %1 (%2 failed)."), sent, sendFailed)
        end
        self:download(false, function(got, getFailed)
            if got > 0 or getFailed > 0 then
                report[#report + 1] = T(_("Books downloaded: %1 (%2 failed)."), got, getFailed)
            end
            local removed = self:cleanDuplicates()
            if removed > 0 then
                report[#report + 1] = T(_("Duplicate copies removed: %1."), removed)
            end
            if #report == 0 then
                report[1] = _("Everything is already in sync with Babel.")
            end
            finish()
        end)
    end)
end

-- Online again: sync with Babel, at most once an hour.
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
        self:syncAll(false)
    end)
end

function Babel:onCloseDocument()
    UIManager:scheduleIn(10, function()
        if NetworkMgr:isConnected() then
            self:pushProgress()
        end
    end)
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

-- The plugin's own version (from _meta.lua).
function Babel:version()
    local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
    local ok, meta = pcall(dofile, (here or ".") .. "/_meta.lua")
    return ok and type(meta) == "table" and meta.version or "?"
end

local function megabytes(bytes)
    return ("%.1f"):format((bytes or 0) / 1048576)
end

-- One job in words: where it is now, how many are done, what failed.
function Babel:jobText(title, lines, ended, partOf)
    if not lines or #lines == 0 then
        return title .. ": " .. (ended and _("nothing to do.") or _("not started."))
    end
    local done, failed, none = countLines(lines)
    local text = { title .. ": " .. (ended and _("finished.") or _("running…")) }
    local n, total, size, name
    for i = #lines, 1, -1 do
        n, total, size, name = lines[i]:match("^progress\t(%d+)\t(%d+)\t(%d+)\t(.*)$")
        if n then
            break
        end
    end
    if n and not ended then
        local line = T(_("Book %1 of %2: %3"), n, total, name)
        local got = partOf and partOf(name)
        if got and tonumber(size) > 0 then
            line = line .. ("\n%s / %s MB (%d%%)"):format(megabytes(got), megabytes(tonumber(size)), math.floor(got * 100 / tonumber(size)))
        end
        text[#text + 1] = line
    end
    text[#text + 1] = T(_("Done: %1, failed: %2."), done, failed)
    if none then
        text[#text + 1] = _("Nothing was missing.")
    end
    for i = #lines, 1, -1 do
        local err = lines[i]:match("^error\t(.*)$")
        if err then
            text[#text + 1] = T(_("Error: %1"), err)
            break
        end
    end
    return table.concat(text, "\n")
end

-- Shows where the background downloads and sends stand (also after they ended).
function Babel:showStatus()
    local dir = self:downloadDir()
    local text = {
        T(_("Babel plugin version %1"), self:version()),
        "",
        self:jobText(_("Downloads"), self.jobs.download, self.jobs.downloadEnded, function(name)
            return lfs.attributes(dir .. "/" .. safeName(name) .. ".part", "size")
        end),
        "",
        self:jobText(_("Sending"), self.jobs.send, self.jobs.sendEnded),
    }
    UIManager:show(InfoMessage:new{ text = table.concat(text, "\n") })
end

function Babel:addToMainMenu(menu_items)
    menu_items.babel = {
        text = _("Babel"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync with Babel"),
                callback = function()
                    NetworkMgr:runWhenOnline(function()
                        self:syncAll(true)
                    end)
                end,
            },
            {
                text = _("Downloads and version"),
                callback = function()
                    self:showStatus()
                end,
            },
            {
                text = _("Options"),
                separator = true,
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
                        text = _("Send my reading progress to Babel"),
                        checked_func = function()
                            return self.settings:readSetting("sync_progress") ~= false
                        end,
                        callback = function()
                            local on = self.settings:readSetting("sync_progress") ~= false
                            self.settings:saveSetting("sync_progress", not on)
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
            },
        },
    }
end

return Babel
