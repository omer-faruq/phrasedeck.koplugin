local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")

local DB = {}

local DB_SCHEMA_VERSION = 2
local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "phrasedeck")
local DB_PATH = ffiUtil.joinPath(DB_DIRECTORY, "phrasedeck.sqlite3")

local SCHEMA_STATEMENTS = {
    [[CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        filepath TEXT NOT NULL UNIQUE,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    )]],
    [[CREATE TABLE IF NOT EXISTS cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        phrase TEXT NOT NULL,
        sentence TEXT NOT NULL DEFAULT '',
        user_note TEXT NOT NULL DEFAULT '',
        ease REAL NOT NULL DEFAULT 2.5,
        interval REAL NOT NULL DEFAULT 0,
        due INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        reps INTEGER NOT NULL DEFAULT 0,
        lapses INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_book ON cards(book_id)]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_book_due ON cards(book_id, due)]],
    [[CREATE TABLE IF NOT EXISTS daily_new_cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        date TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 0,
        UNIQUE(book_id, date)
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_daily_new_cards_book_date ON daily_new_cards(book_id, date)]],
}

local initialized = false

local function execStatements(conn, statements)
    for _, statement in ipairs(statements) do
        local trimmed = util.trim(statement)
        if trimmed ~= "" then
            local final_stmt = trimmed
            if not final_stmt:find(";%s*$") then
                final_stmt = final_stmt .. ";"
            end
            local ok, err = pcall(conn.exec, conn, final_stmt)
            if not ok then
                error(string.format("phrasedeck sqlite schema error: %s -- %s", final_stmt, err))
            end
        end
    end
end

local function ensureDirectory()
    local ok, err = util.makePath(DB_DIRECTORY)
    if not ok then
        logger.warn("phrasedeck: unable to create database directory", err)
    end
end

local function openConnection()
    ensureDirectory()
    local conn = SQ3.open(DB_PATH)
    conn:exec("PRAGMA foreign_keys = ON;")
    conn:exec("PRAGMA synchronous = NORMAL;")
    conn:exec("PRAGMA journal_mode = WAL;")
    return conn
end

local function withConnection(fn)
    local conn = openConnection()
    local results = { pcall(fn, conn) }
    conn:close()
    if not results[1] then
        error(results[2])
    end
    return table.unpack(results, 2)
end

function DB.init()
    if initialized then
        return
    end
    ensureDirectory()
    local conn = openConnection()
    local current_version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if current_version < DB_SCHEMA_VERSION then
        if current_version == 0 then
            conn:exec("PRAGMA writable_schema = ON;")
            conn:exec("DELETE FROM sqlite_master WHERE type IN ('table','index','trigger');")
            conn:exec("PRAGMA writable_schema = OFF;")
            conn:exec("VACUUM;")
            execStatements(conn, SCHEMA_STATEMENTS)
        else
            execStatements(conn, SCHEMA_STATEMENTS)
        end
        if current_version < 2 then
            local ok, err = pcall(function()
                conn:exec("ALTER TABLE cards ADD COLUMN last_reviewed_at INTEGER DEFAULT NULL;")
            end)
            if not ok and not err:match("duplicate column name") then
                logger.warn("phrasedeck: failed to add last_reviewed_at column:", err)
            end
        end
        conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
    else
        execStatements(conn, SCHEMA_STATEMENTS)
    end
    conn:close()
    initialized = true
end

-- ── Book CRUD ──

local function coerceNumber(value, default)
    if value == nil then
        return default
    end
    local n = tonumber(value)
    if not n then
        return default
    end
    return n
end

function DB.getOrCreateBook(title, filepath)
    if not filepath or filepath == "" then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local existing_id = conn:rowexec(
            string.format("SELECT id FROM books WHERE filepath = '%s';", filepath:gsub("'", "''"))
        )
        if existing_id then
            return tonumber(existing_id)
        end
        local stmt = conn:prepare("INSERT INTO books (title, filepath) VALUES (?, ?);")
        stmt:bind(title or "", filepath)
        stmt:step()
        stmt:close()
        local new_id = conn:rowexec("SELECT last_insert_rowid();")
        return new_id and tonumber(new_id) or nil
    end)
end

function DB.listBooks()
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT b.id, b.title, b.filepath, COUNT(c.id) AS card_count
            FROM books b
            LEFT JOIN cards c ON c.book_id = b.id
            GROUP BY b.id, b.title, b.filepath
            ORDER BY b.title COLLATE NOCASE;]])
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[0] or #rows[0] == 0 then
            return {}
        end
        local headers = rows[0]
        local list = {}
        for i = 1, #rows[1] do
            local row = {}
            for col_index, col_name in ipairs(headers) do
                local column_values = rows[col_index]
                row[col_name] = column_values[i]
            end
            list[#list + 1] = {
                id = coerceNumber(row.id, nil),
                title = tostring(row.title or ""),
                filepath = tostring(row.filepath or ""),
                card_count = coerceNumber(row.card_count, 0),
            }
        end
        return list
    end)
end

function DB.deleteBook(book_id)
    if not book_id then
        return false
    end
    DB.init()
    return withConnection(function(conn)
        local stmt1 = conn:prepare("DELETE FROM cards WHERE book_id = ?;")
        stmt1:bind(book_id)
        stmt1:step()
        stmt1:close()
        local stmt2 = conn:prepare("DELETE FROM books WHERE id = ?;")
        stmt2:bind(book_id)
        stmt2:step()
        stmt2:close()
        local stmt3 = conn:prepare("DELETE FROM daily_new_cards WHERE book_id = ?;")
        stmt3:bind(book_id)
        stmt3:step()
        stmt3:close()
        return true
    end)
end

-- ── Card CRUD ──

function DB.addCard(book_id, phrase, sentence, user_note)
    if not book_id then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("INSERT INTO cards (book_id, phrase, sentence, user_note) VALUES (?, ?, ?, ?);")
        stmt:bind(book_id, phrase or "", sentence or "", user_note or "")
        stmt:step()
        stmt:close()
        local new_id = conn:rowexec("SELECT last_insert_rowid();")
        return new_id and tonumber(new_id) or nil
    end)
end

function DB.deleteCard(card_id)
    if not card_id then
        return false
    end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("DELETE FROM cards WHERE id = ?;")
        stmt:bind(card_id)
        stmt:step()
        stmt:close()
        return true
    end)
end

function DB.getCardCountForBook(book_id)
    DB.init()
    return withConnection(function(conn)
        local query
        if book_id then
            query = string.format("SELECT COUNT(*) FROM cards WHERE book_id = %d;", book_id)
        else
            query = "SELECT COUNT(*) FROM cards;"
        end
        local count = conn:rowexec(query)
        return tonumber(count) or 0
    end)
end

function DB.getDueCardCount(book_id, now_ts)
    DB.init()
    local now = now_ts or os.time()
    return withConnection(function(conn)
        local query
        if book_id then
            query = string.format("SELECT COUNT(*) FROM cards WHERE book_id = %d AND due <= %d;", book_id, now)
        else
            query = string.format("SELECT COUNT(*) FROM cards WHERE due <= %d;", now)
        end
        local count = conn:rowexec(query)
        return tonumber(count) or 0
    end)
end

-- ── SM-2 Scheduling ──

local function mapCardRow(row)
    if not row then
        return nil
    end
    return {
        id = coerceNumber(row.id, nil),
        book_id = coerceNumber(row.book_id, nil),
        phrase = row.phrase or "",
        sentence = row.sentence or "",
        user_note = row.user_note or "",
        ease = coerceNumber(row.ease, 2.5),
        interval = coerceNumber(row.interval, 0),
        due = coerceNumber(row.due, os.time()),
        reps = coerceNumber(row.reps, 0),
        lapses = coerceNumber(row.lapses, 0),
        updated_at = coerceNumber(row.updated_at, os.time()),
        last_reviewed_at = coerceNumber(row.last_reviewed_at, nil),
    }
end

local function computeScheduling(card, rating, now_ts, min_interval_days, max_interval_days, algorithm_type)
    local ease = card.ease or 2.5
    local interval = card.interval or 0
    local reps = card.reps or 0
    local lapses = card.lapses or 0
    local now = now_ts or os.time()
    local min_interval_multiplier = tonumber(min_interval_days) or 0
    local max_interval = tonumber(max_interval_days) or 365
    local algo = algorithm_type or "scheduled"

    local is_new = (interval == 0) and (reps == 0)

    -- New card behavior: Anki-style initial steps (same for both algorithms)
    if is_new then
        if rating == "again" then
            lapses = lapses + 1
            ease = math.max(1.3, ease - 0.2)
            if min_interval_multiplier > 0 then
                interval = min_interval_multiplier
                local due = now + interval * 86400
                return ease, interval, reps, lapses, due
            else
                local due = now + 1 * 60
                return ease, interval, reps, lapses, due
            end
        elseif rating == "hard" then
            reps = reps + 1
            ease = math.max(1.3, ease - 0.15)
            if min_interval_multiplier > 0 then
                interval = min_interval_multiplier * 1.5
                local due = now + interval * 86400
                return ease, interval, reps, lapses, due
            else
                local due = now + 6 * 60
                return ease, interval, reps, lapses, due
            end
        elseif rating == "good" then
            reps = reps + 1
            if min_interval_multiplier > 0 then
                interval = min_interval_multiplier * 2
                local due = now + interval * 86400
                return ease, interval, reps, lapses, due
            else
                local due = now + 10 * 60
                return ease, interval, reps, lapses, due
            end
        elseif rating == "easy" then
            reps = reps + 1
            ease = ease + 0.15
            interval = min_interval_multiplier > 0 and (min_interval_multiplier * 4) or 4
            local due = now + interval * 86400
            return ease, interval, reps, lapses, due
        end
    end

    -- Review card behavior: choose algorithm
    if algo == "adaptive" then
        local last_review = card.last_reviewed_at
        if not last_review or last_review == 0 then
            -- Fallback for migrated cards: estimate last review time from due and interval
            local interval_seconds = (card.interval or 0) * 86400
            last_review = (card.due or now) - interval_seconds
            -- Ensure it's not in the future
            if last_review > now then
                last_review = now
            end
        end
        
        local actual_gap_seconds = now - last_review
        local actual_gap_days = actual_gap_seconds / 86400
        
        local scheduled_interval = card.interval or 1
        if actual_gap_days < scheduled_interval then
            actual_gap_days = math.max(actual_gap_days, scheduled_interval * 0.5)
        end
        
        if rating == "again" then
            reps = 0
            lapses = lapses + 1
            ease = math.max(1.3, ease - 0.2)
            if min_interval_multiplier > 0 then
                interval = min_interval_multiplier
                local due = now + interval * 86400
                return ease, interval, reps, lapses, due
            else
                interval = 0
                local due = now + 10 * 60
                return ease, interval, reps, lapses, due
            end
        elseif rating == "hard" then
            reps = reps + 1
            ease = math.max(1.3, ease - 0.15)
            interval = actual_gap_days * 1.2
            interval = math.max(interval, min_interval_multiplier > 0 and min_interval_multiplier or 1)
            interval = math.min(interval, max_interval)
            local due = now + interval * 86400
            return ease, interval, reps, lapses, due
        elseif rating == "good" then
            reps = reps + 1
            interval = actual_gap_days * ease
            interval = math.max(interval, min_interval_multiplier > 0 and min_interval_multiplier or 1)
            interval = math.min(interval, max_interval)
            local due = now + interval * 86400
            return ease, interval, reps, lapses, due
        elseif rating == "easy" then
            reps = reps + 1
            ease = ease + 0.15
            interval = actual_gap_days * ease * 1.3
            interval = math.max(interval, min_interval_multiplier > 0 and min_interval_multiplier or 1)
            interval = math.min(interval, max_interval)
            local due = now + interval * 86400
            return ease, interval, reps, lapses, due
        end
    else
        if rating == "again" then
            reps = 0
            lapses = lapses + 1
            ease = math.max(1.3, ease - 0.2)
            if min_interval_multiplier > 0 then
                interval = min_interval_multiplier
                local due = now + interval * 86400
                return ease, interval, reps, lapses, due
            else
                interval = 0
                local due = now + 10 * 60
                return ease, interval, reps, lapses, due
            end
        elseif rating == "hard" then
            reps = reps + 1
            ease = math.max(1.3, ease - 0.15)
            if interval < 1 then
                interval = 1
            end
            interval = interval * 1.2
            if min_interval_multiplier > 0 then
                interval = math.max(interval, min_interval_multiplier * 1.5)
            end
            interval = math.min(interval, max_interval)
            local due = now + interval * 86400
            return ease, interval, reps, lapses, due
        elseif rating == "good" then
            reps = reps + 1
            if interval == 0 then
                interval = 1
            else
                interval = interval * ease
            end
            if min_interval_multiplier > 0 then
                interval = math.max(interval, min_interval_multiplier * 2)
            end
            interval = math.min(interval, max_interval)
            local due = now + interval * 86400
            return ease, interval, reps, lapses, due
        elseif rating == "easy" then
            reps = reps + 1
            ease = ease + 0.15
            if interval == 0 then
                interval = 3
            else
                interval = interval * ease * 1.3
            end
            if min_interval_multiplier > 0 then
                interval = math.max(interval, min_interval_multiplier * 4)
            end
            interval = math.min(interval, max_interval)
            local due = now + interval * 86400
            return ease, interval, reps, lapses, due
        end
    end

    return ease, interval, reps, lapses, card.due or now
end

local function formatDelta(delta)
    if delta <= 0 then
        return "0m"
    end
    if delta < 3600 then
        local minutes = math.floor(delta / 60 + 0.5)
        return tostring(minutes) .. "m"
    end
    if delta < 86400 then
        local hours = math.floor(delta / 3600 + 0.5)
        return tostring(hours) .. "h"
    end
    local days = math.floor(delta / 86400 + 0.5)
    return tostring(days) .. "d"
end

local function getTodayDateString()
    return os.date("%Y-%m-%d", os.time())
end

function DB.getDailyNewCardsCount(book_id)
    DB.init()
    if not book_id then
        return 0
    end
    local today = getTodayDateString()
    return withConnection(function(conn)
        local stmt = conn:prepare("SELECT count FROM daily_new_cards WHERE book_id = ? AND date = ?;")
        stmt:bind(book_id, today)
        local count_str = stmt:step()
        stmt:close()
        if count_str and count_str[1] then
            return tonumber(count_str[1]) or 0
        end
        return 0
    end)
end

function DB.incrementDailyNewCardsCount(book_id)
    DB.init()
    if not book_id then
        return
    end
    local today = getTodayDateString()
    withConnection(function(conn)
        local stmt = conn:prepare([[INSERT INTO daily_new_cards (book_id, date, count) VALUES (?, ?, 1)
            ON CONFLICT(book_id, date) DO UPDATE SET count = count + 1;]])
        stmt:bind(book_id, today)
        stmt:step()
        stmt:close()
    end)
end

function DB.fetchNextDueCard(book_id, now_ts, randomize, daily_new_limit)
    DB.init()
    local now = now_ts or os.time()
    return withConnection(function(conn)
        randomize = not not randomize
        local new_limit = tonumber(daily_new_limit) or 0

        -- Build WHERE clause: book_id filter is optional (nil = all books)
        local book_filter = ""
        if book_id then
            book_filter = string.format(" AND book_id = %d", book_id)
        end

        -- Check daily new card limit per book
        local skip_new = false
        if new_limit > 0 and book_id then
            local today = getTodayDateString()
            local count_stmt = conn:prepare("SELECT count FROM daily_new_cards WHERE book_id = ? AND date = ?;")
            count_stmt:bind(book_id, today)
            local count_row = count_stmt:step()
            count_stmt:close()
            if count_row and count_row[1] then
                local today_new_count = tonumber(count_row[1]) or 0
                if today_new_count >= new_limit then
                    skip_new = true
                end
            end
        end

        local new_filter = ""
        if skip_new then
            new_filter = " AND NOT (reps = 0 AND interval = 0)"
        end

        local stmt
        if randomize then
            local sql = string.format([[WITH mindue AS (
                    SELECT MIN(due) AS due FROM cards WHERE due <= %d%s%s
                ), candidates AS (
                    SELECT id FROM cards WHERE due = (SELECT due FROM mindue)%s%s
                ), stats AS (
                    SELECT COUNT(*) AS cnt FROM candidates
                ), picked AS (
                    SELECT id FROM candidates
                    LIMIT 1
                    OFFSET (
                        CASE
                            WHEN (SELECT cnt FROM stats) <= 1 THEN 0
                            ELSE (abs(random()) %% (SELECT cnt FROM stats))
                        END
                    )
                )
                SELECT id, book_id, phrase, sentence, user_note, ease, interval, due, reps, lapses, updated_at, last_reviewed_at
                FROM cards WHERE id = (SELECT id FROM picked) LIMIT 1;]],
                now, book_filter, new_filter, book_filter, new_filter)
            stmt = conn:prepare(sql)
        else
            local sql = string.format([[SELECT id, book_id, phrase, sentence, user_note, ease, interval, due, reps, lapses, updated_at, last_reviewed_at
                FROM cards WHERE due <= %d%s%s ORDER BY due ASC LIMIT 1;]],
                now, book_filter, new_filter)
            stmt = conn:prepare(sql)
        end

        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[1] or #rows[1] == 0 then
            return nil
        end
        local headers = rows[0]
        local row = {}
        for header_index, header in ipairs(headers) do
            local column_values = rows[header_index]
            row[header] = column_values[1]
        end
        return mapCardRow(row)
    end)
end

function DB.previewIntervals(card, now_ts, min_interval_days, max_interval_days, algorithm_type)
    if not card or not card.id then
        return nil
    end
    local now = now_ts or os.time()
    local result = {}
    local ratings = { "again", "hard", "good", "easy" }
    
    local preview_card = {}
    for k, v in pairs(card) do
        preview_card[k] = v
    end
    if algorithm_type == "adaptive" then
        preview_card.last_reviewed_at = now
    end
    
    for _, rating in ipairs(ratings) do
        local ease, interval, reps, lapses, due = computeScheduling(preview_card, rating, now, min_interval_days, max_interval_days, algorithm_type)
        local delta = due - now
        result[rating] = {
            ease = ease,
            interval = interval,
            reps = reps,
            lapses = lapses,
            due = due,
            label = formatDelta(delta),
        }
    end
    return result
end

function DB.updateCardScheduling(card, rating, now_ts, min_interval_days, max_interval_days, algorithm_type)
    if not card or not card.id then
        return nil
    end
    DB.init()
    local now = now_ts or os.time()
    local new_ease, new_interval, new_reps, new_lapses, new_due = computeScheduling(card, rating, now, min_interval_days, max_interval_days, algorithm_type)
    withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards
            SET ease = ?, interval = ?, due = ?, reps = ?, lapses = ?, updated_at = ?, last_reviewed_at = ?
            WHERE id = ?;]])
        stmt:bind(new_ease, new_interval, new_due, new_reps, new_lapses, now, now, card.id)
        stmt:step()
        stmt:close()
    end)
    return {
        id = card.id,
        book_id = card.book_id,
        phrase = card.phrase,
        sentence = card.sentence,
        user_note = card.user_note,
        ease = new_ease,
        interval = new_interval,
        due = new_due,
        reps = new_reps,
        lapses = new_lapses,
        last_reviewed_at = now,
    }
end

-- ── Export ──

function DB.getCardsForExport(book_id)
    DB.init()
    return withConnection(function(conn)
        local sql
        if book_id then
            sql = string.format("SELECT phrase, sentence, user_note FROM cards WHERE book_id = %d ORDER BY created_at;", book_id)
        else
            sql = "SELECT phrase, sentence, user_note FROM cards ORDER BY book_id, created_at;"
        end
        local stmt = conn:prepare(sql)
        local cards = {}
        while true do
            local row = stmt:step()
            if not row then
                break
            end
            cards[#cards + 1] = {
                phrase = row[1] or "",
                sentence = row[2] or "",
                user_note = row[3] or "",
            }
        end
        stmt:close()
        return cards
    end)
end

function DB.getBookTitle(book_id)
    if not book_id then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local title = conn:rowexec(string.format("SELECT title FROM books WHERE id = %d;", book_id))
        return title
    end)
end

return DB
