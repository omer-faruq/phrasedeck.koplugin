local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local util = require("util")
local _ = require("gettext")
local PhraseDB = require("phrasedeck_db")

local PhraseDeck = WidgetContainer:extend{
    name = "phrasedeck",
    is_doc_only = false,
}

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/phrasedeck.lua"

-- ── Sentence extraction ──

local SENTENCE_DELIMITERS = "[%.%?!;]"

local function extractSentence(phrase, prev_context, next_context)
    if not phrase or phrase == "" then
        return phrase or ""
    end
    -- Build the full text: prev + phrase + next
    local full_text = (prev_context or "") .. phrase .. (next_context or "")
    if full_text == "" then
        return phrase
    end

    -- Find the phrase position in the full text
    local phrase_start = #(prev_context or "") + 1
    local phrase_end = phrase_start + #phrase - 1

    -- Walk backwards from phrase_start to find sentence beginning
    local sent_start = 1
    for i = phrase_start - 1, 1, -1 do
        local ch = full_text:sub(i, i)
        if ch:match(SENTENCE_DELIMITERS) then
            sent_start = i + 1
            break
        end
    end

    -- Walk forwards from phrase_end to find sentence end
    local sent_end = #full_text
    for i = phrase_end + 1, #full_text do
        local ch = full_text:sub(i, i)
        if ch:match(SENTENCE_DELIMITERS) then
            sent_end = i
            break
        end
    end

    local sentence = full_text:sub(sent_start, sent_end)
    -- Trim whitespace
    sentence = sentence:gsub("^%s+", ""):gsub("%s+$", "")
    if sentence == "" then
        return phrase
    end
    return sentence
end

-- ── Settings helpers ──

function PhraseDeck:readSetting(key, default)
    if not self._settings then
        self._settings = LuaSettings:open(SETTINGS_FILE)
    end
    local val = self._settings:readSetting(key)
    if val == nil then
        return default
    end
    return val
end

function PhraseDeck:saveSetting(key, value)
    if not self._settings then
        self._settings = LuaSettings:open(SETTINGS_FILE)
    end
    self._settings:saveSetting(key, value)
    self._settings:flush()
    self._settings_dirty = true
end

function PhraseDeck:onFlushSettings()
    if self._settings and self._settings_dirty then
        self._settings:flush()
        self._settings_dirty = nil
    end
end

-- ── Document info helpers ──

function PhraseDeck:getDocumentFilePath()
    if self.ui and self.ui.document and self.ui.document.file then
        return self.ui.document.file
    end
    return nil
end

function PhraseDeck:getDocumentTitle()
    if self.ui and self.ui.doc_props then
        local title = self.ui.doc_props.title
        if title and title ~= "" then
            return title
        end
    end
    -- Fallback: extract filename without extension
    local filepath = self:getDocumentFilePath()
    if filepath then
        local filename = filepath:match("([^/\\]+)$") or filepath
        return filename:match("(.+)%.[^%.]+$") or filename
    end
    return _("Unknown")
end

-- ── Export helpers ──

function PhraseDeck:getExportFolder()
    local folder = self:readSetting("export_folder")
    if folder and folder ~= "" and util.pathExists(folder) then
        return folder
    end
    -- Default: phrasedeck directory in data storage
    local default_dir = ffiUtil.joinPath(DataStorage:getDataDir(), "phrasedeck")
    util.makePath(default_dir)
    return default_dir
end

local function sanitizeFilename(name)
    if not name or name == "" then
        return "unknown"
    end
    -- Replace problematic characters
    name = name:gsub("[/\\:*?\"<>|]", "_")
    -- Trim and limit length
    name = name:gsub("^%s+", ""):gsub("%s+$", "")
    if #name > 80 then
        name = name:sub(1, 80)
    end
    if name == "" then
        name = "unknown"
    end
    return name
end

function PhraseDeck:exportBook(book_id)
    local cards = PhraseDB.getCardsForExport(book_id)
    if not cards or #cards == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No cards to export."),
            timeout = 3,
        })
        return
    end

    local title
    if book_id then
        title = PhraseDB.getBookTitle(book_id) or "unknown"
    else
        title = "all_books"
    end

    local folder = self:getExportFolder()
    local filename = sanitizeFilename(title) .. ".tsv"
    local filepath = ffiUtil.joinPath(folder, filename)

    local file, err = io.open(filepath, "w")
    if not file then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Failed to write export file:\n%s"), err or ""),
        })
        return
    end

    -- Header
    file:write("phrase\tsentence\tnote\n")
    for _, card in ipairs(cards) do
        -- Escape tabs and newlines in fields
        local p = (card.phrase or ""):gsub("[\t\n\r]", " ")
        local s = (card.sentence or ""):gsub("[\t\n\r]", " ")
        local n = (card.user_note or ""):gsub("[\t\n\r]", " ")
        file:write(p .. "\t" .. s .. "\t" .. n .. "\n")
    end
    file:close()

    UIManager:show(InfoMessage:new{
        text = string.format(_("Exported %d cards to:\n%s"), #cards, filepath),
    })
end

function PhraseDeck:exportAllBooks()
    local books = PhraseDB.listBooks()
    if not books or #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No cards to export."),
            timeout = 3,
        })
        return
    end

    local total = 0
    local folder = self:getExportFolder()

    for _, book in ipairs(books) do
        if book.card_count and book.card_count > 0 then
            local cards = PhraseDB.getCardsForExport(book.id)
            if cards and #cards > 0 then
                local filename = sanitizeFilename(book.title) .. ".tsv"
                local filepath = ffiUtil.joinPath(folder, filename)
                local file = io.open(filepath, "w")
                if file then
                    file:write("phrase\tsentence\tnote\n")
                    for _, card in ipairs(cards) do
                        local p = (card.phrase or ""):gsub("[\t\n\r]", " ")
                        local s = (card.sentence or ""):gsub("[\t\n\r]", " ")
                        local n = (card.user_note or ""):gsub("[\t\n\r]", " ")
                        file:write(p .. "\t" .. s .. "\t" .. n .. "\n")
                    end
                    file:close()
                    total = total + #cards
                end
            end
        end
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Exported %d cards to:\n%s"), total, folder),
    })
end

-- ── Markdown (Obsidian) export ──

function PhraseDeck:exportBookMd(book_id)
    local cards = PhraseDB.getCardsForExport(book_id)
    if not cards or #cards == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No cards to export."),
            timeout = 3,
        })
        return
    end

    local title
    if book_id then
        title = PhraseDB.getBookTitle(book_id) or "unknown"
    else
        title = "all_books"
    end

    local folder = self:getExportFolder()
    local filename = sanitizeFilename(title) .. ".md"
    local filepath = ffiUtil.joinPath(folder, filename)

    local file, err = io.open(filepath, "w")
    if not file then
        UIManager:show(InfoMessage:new{
            text = string.format(_("Failed to write export file:\n%s"), err or ""),
        })
        return
    end

    file:write("# " .. title .. "\n\n")
    for _, card in ipairs(cards) do
        local phrase = card.phrase or ""
        local sentence = card.sentence or ""
        local note = card.user_note or ""
        file:write("## " .. phrase .. "\n\n")
        if note ~= "" then
            file:write("- **Note:** " .. note .. "\n")
        end
        if sentence ~= "" then
            file:write("- **Sentence:** " .. sentence .. "\n")
        end
        file:write("\n")
    end
    file:close()

    UIManager:show(InfoMessage:new{
        text = string.format(_("Exported %d cards to:\n%s"), #cards, filepath),
    })
end

function PhraseDeck:exportAllBooksMd()
    local books = PhraseDB.listBooks()
    if not books or #books == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No cards to export."),
            timeout = 3,
        })
        return
    end

    local total = 0
    local folder = self:getExportFolder()

    for _, book in ipairs(books) do
        if book.card_count and book.card_count > 0 then
            local cards = PhraseDB.getCardsForExport(book.id)
            if cards and #cards > 0 then
                local btitle = book.title or "unknown"
                local filename = sanitizeFilename(btitle) .. ".md"
                local filepath = ffiUtil.joinPath(folder, filename)
                local file = io.open(filepath, "w")
                if file then
                    file:write("# " .. btitle .. "\n\n")
                    for _, card in ipairs(cards) do
                        local phrase = card.phrase or ""
                        local sentence = card.sentence or ""
                        local note = card.user_note or ""
                        file:write("## " .. phrase .. "\n\n")
                        if note ~= "" then
                            file:write("- **Note:** " .. note .. "\n")
                        end
                        if sentence ~= "" then
                            file:write("- **Sentence:** " .. sentence .. "\n")
                        end
                        file:write("\n")
                    end
                    file:close()
                    total = total + #cards
                end
            end
        end
    end

    UIManager:show(InfoMessage:new{
        text = string.format(_("Exported %d cards to:\n%s"), total, folder),
    })
end

-- ── Highlight menu: Add to Deck ──

function PhraseDeck:showAddToDeckDialog(selected_text_obj)
    if not selected_text_obj then
        return
    end
    local phrase = selected_text_obj.text or ""
    if phrase == "" then
        UIManager:show(InfoMessage:new{
            text = _("No text selected."),
            timeout = 3,
        })
        return
    end

    -- Extract sentence context
    local sentence = phrase
    local has_context = false
    if self.ui and self.ui.document and not self.ui.document.info.has_pages
       and selected_text_obj.pos0 and selected_text_obj.pos1
       and self.ui.document.getSelectedWordContext then
        local nb_words = tonumber(self:readSetting("context_words", 50)) or 50
        local ok, prev_ctx, next_ctx = pcall(
            self.ui.document.getSelectedWordContext,
            self.ui.document,
            phrase, nb_words,
            selected_text_obj.pos0, selected_text_obj.pos1,
            false -- do not restore selection, it was already cleared
        )
        if ok and (prev_ctx or next_ctx) then
            sentence = extractSentence(phrase, prev_ctx, next_ctx)
            has_context = true
        end
    end

    -- Show multi-input dialog: editable phrase + note, sentence as read-only description
    local multi_dialog
    local description_text
    if has_context then
        description_text = _("Sentence: ") .. sentence
    else
        description_text = nil
    end

    local fields = {
        {
            description = _("Phrase"),
            text = phrase,
            hint = _("Selected phrase"),
        },
        {
            description = _("Note / Meaning"),
            text = "",
            hint = _("Enter your note / meaning..."),
        },
    }

    local MultiInputDialog = require("ui/widget/multiinputdialog")
    multi_dialog = MultiInputDialog:new{
        title = _("Add to PhraseDeck"),
        description = description_text,
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(multi_dialog)
                        UIManager:setDirty("all", "partial")
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local input_fields = multi_dialog:getFields()
                        local final_phrase = input_fields[1] or phrase
                        local user_note = input_fields[2] or ""
                        UIManager:close(multi_dialog)
                        UIManager:setDirty("all", "partial")

                        if final_phrase == "" then
                            final_phrase = phrase
                        end

                        -- Save to database
                        local filepath = self:getDocumentFilePath()
                        local title = self:getDocumentTitle()
                        if not filepath then
                            UIManager:show(InfoMessage:new{
                                text = _("Could not determine document path."),
                                timeout = 3,
                            })
                            return
                        end

                        local book_id = PhraseDB.getOrCreateBook(title, filepath)
                        if not book_id then
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to create book record."),
                                timeout = 3,
                            })
                            return
                        end

                        local card_id = PhraseDB.addCard(book_id, final_phrase, sentence, user_note)
                        if card_id then
                            UIManager:show(Notification:new{
                                text = _("Phrase added to deck!"),
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Failed to save card."),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(multi_dialog)
    multi_dialog:onShowKeyboard()
end

-- ── Plugin lifecycle ──

function PhraseDeck:init()
    PhraseDB.init()

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
end

function PhraseDeck:onReaderReady()
    if not self.ui or not self.ui.highlight then
        return
    end

    -- Register highlight menu button
    self.ui.highlight:addToHighlightDialog("phrasedeck_add", function(reader_highlight)
        return {
            text = _("Add to Deck"),
            callback = function()
                local selected = reader_highlight.selected_text
                if selected then
                    -- Close highlight dialog
                    if reader_highlight.highlight_dialog then
                        UIManager:close(reader_highlight.highlight_dialog)
                        reader_highlight.highlight_dialog = nil
                    end
                    reader_highlight:clear()
                    self:showAddToDeckDialog(selected)
                else
                    UIManager:show(InfoMessage:new{
                        text = _("No text selected."),
                        timeout = 3,
                    })
                end
            end,
        }
    end)
end

-- ── Main menu ──

function PhraseDeck:addToMainMenu(menu_items)
    menu_items.phrasedeck = {
        sorting_hint = "tools",
        text = _("PhraseDeck"),
        sub_item_table = {
            {
                text = _("Study"),
                callback = function()
                    local StudyScreen = require("phrasedeck_study")
                    local total = PhraseDB.getCardCountForBook(nil)
                    if total == 0 then
                        UIManager:show(InfoMessage:new{
                            text = _("No cards yet. Add phrases from the highlight menu while reading."),
                            timeout = 4,
                        })
                        return
                    end
                    local study = StudyScreen:new{
                        plugin = self,
                    }
                    UIManager:show(study)
                end,
            },
            {
                text = _("Export"),
                sub_item_table = {
                    {
                        text = _("Current book (TSV)"),
                        enabled_func = function()
                            return self:getDocumentFilePath() ~= nil
                        end,
                        callback = function()
                            local filepath = self:getDocumentFilePath()
                            if not filepath then
                                return
                            end
                            local book_id = PhraseDB.getOrCreateBook(self:getDocumentTitle(), filepath)
                            if book_id then
                                self:exportBook(book_id)
                            end
                        end,
                    },
                    {
                        text = _("All books (TSV)"),
                        callback = function()
                            self:exportAllBooks()
                        end,
                    },
                    {
                        text = _("Current book (Markdown)"),
                        enabled_func = function()
                            return self:getDocumentFilePath() ~= nil
                        end,
                        callback = function()
                            local filepath = self:getDocumentFilePath()
                            if not filepath then
                                return
                            end
                            local book_id = PhraseDB.getOrCreateBook(self:getDocumentTitle(), filepath)
                            if book_id then
                                self:exportBookMd(book_id)
                            end
                        end,
                    },
                    {
                        text = _("All books (Markdown)"),
                        callback = function()
                            self:exportAllBooksMd()
                        end,
                    },
                    {
                        text = _("Export folder"),
                        keep_menu_open = true,
                        callback = function()
                            self:showExportFolderSetting()
                        end,
                    },
                },
            },
        },
    }
end

function PhraseDeck:showExportFolderSetting()
    local current = self:getExportFolder()
    local input_dialog
    input_dialog = InputDialog:new{
        title = _("Export folder"),
        input = current,
        description = _("Folder where TSV export files will be saved."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_folder = input_dialog:getInputText() or ""
                        new_folder = new_folder:gsub("^%s+", ""):gsub("%s+$", "")
                        if new_folder ~= "" then
                            util.makePath(new_folder)
                            if util.pathExists(new_folder) then
                                self:saveSetting("export_folder", new_folder)
                                UIManager:show(Notification:new{
                                    text = _("Export folder updated."),
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Invalid folder path."),
                                    timeout = 3,
                                })
                            end
                        end
                        UIManager:close(input_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

return PhraseDeck
